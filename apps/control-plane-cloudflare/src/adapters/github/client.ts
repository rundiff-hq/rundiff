export interface GitHubCredentials {
  RUNDIFF_GITHUB_APP_ID?: string;
  RUNDIFF_GITHUB_APP_PRIVATE_KEY?: string;
}
const encode = (value: string | Uint8Array) =>
  btoa(typeof value === "string" ? value : String.fromCharCode(...value))
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");

export function githubPrivateKeyPkcs8(pemValue: string): ArrayBuffer {
  const pem = pemValue.replace(/\\n/g, "\n");
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const der = Uint8Array.from(atob(body), (character) =>
    character.charCodeAt(0),
  );
  if (pem.includes("BEGIN PRIVATE KEY"))
    return der.buffer.slice(
      der.byteOffset,
      der.byteOffset + der.byteLength,
    ) as ArrayBuffer;
  if (!pem.includes("BEGIN RSA PRIVATE KEY"))
    throw new Error("Unsupported GitHub App private key format");

  const length = (size: number) => {
    if (size < 128) return Uint8Array.of(size);
    const bytes: number[] = [];
    for (let value = size; value > 0; value >>>= 8) bytes.unshift(value & 0xff);
    return Uint8Array.of(0x80 | bytes.length, ...bytes);
  };
  const element = (tag: number, value: Uint8Array) =>
    Uint8Array.of(tag, ...length(value.length), ...value);
  const algorithm = Uint8Array.of(
    0x30,
    0x0d,
    0x06,
    0x09,
    0x2a,
    0x86,
    0x48,
    0x86,
    0xf7,
    0x0d,
    0x01,
    0x01,
    0x01,
    0x05,
    0x00,
  );
  const wrapped = element(
    0x30,
    Uint8Array.of(0x02, 0x01, 0x00, ...algorithm, ...element(0x04, der)),
  );
  return wrapped.buffer.slice(
    wrapped.byteOffset,
    wrapped.byteOffset + wrapped.byteLength,
  ) as ArrayBuffer;
}

export class GitHubClient {
  constructor(
    private readonly token: string,
    private readonly transport: typeof fetch = fetch,
  ) {}
  async request<T>(path: string, method = "GET", body?: unknown): Promise<T> {
    const response = await this.transport(`https://api.github.com${path}`, {
      method,
      headers: {
        authorization: `Bearer ${this.token}`,
        accept: "application/vnd.github+json",
        "user-agent": "RunDiff",
        "x-github-api-version": "2022-11-28",
        "content-type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!response.ok)
      throw new Error(`GitHub ${method} failed (${response.status})`);
    return response.json() as Promise<T>;
  }
  static async installation(
    env: GitHubCredentials,
    installationId: number,
    repositoryId?: number,
  ): Promise<GitHubClient> {
    if (!env.RUNDIFF_GITHUB_APP_ID || !env.RUNDIFF_GITHUB_APP_PRIVATE_KEY)
      throw new Error("GitHub App credentials are not configured");
    const bytes = githubPrivateKeyPkcs8(env.RUNDIFF_GITHUB_APP_PRIVATE_KEY);
    const key = await crypto.subtle.importKey(
      "pkcs8",
      bytes,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const now = Math.floor(Date.now() / 1000);
    const data = `${encode(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${encode(JSON.stringify({ iat: now - 60, exp: now + 540, iss: env.RUNDIFF_GITHUB_APP_ID }))}`;
    const signature = new Uint8Array(
      await crypto.subtle.sign(
        "RSASSA-PKCS1-v1_5",
        key,
        new TextEncoder().encode(data),
      ),
    );
    const app = new GitHubClient(`${data}.${encode(signature)}`);
    const result = await app.request<{ token: string }>(
      `/app/installations/${installationId}/access_tokens`,
      "POST",
      repositoryId ? { repository_ids: [repositoryId] } : {},
    );
    return new GitHubClient(result.token);
  }
  async current(
    repository: string,
    number: number,
    sha: string,
  ): Promise<boolean> {
    const pr = await this.request<{ state: string; head: { sha: string } }>(
      `/repos/${repository}/pulls/${number}`,
    );
    return pr.state === "open" && pr.head.sha === sha;
  }
}
