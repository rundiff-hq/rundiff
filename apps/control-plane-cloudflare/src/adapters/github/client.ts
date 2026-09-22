export interface GitHubCredentials {
  RUNDIFF_GITHUB_APP_ID?: string;
  RUNDIFF_GITHUB_APP_PRIVATE_KEY?: string;
}

export type GitHubInstallationPermissions = {
  actions?: "read" | "write";
  contents?: "read" | "write";
};
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
    const response = await this.perform(path, method, body);
    if (response.status === 204) return undefined as T;
    return response.json() as Promise<T>;
  }

  async requestNoContent(
    path: string,
    method = "POST",
    body?: unknown,
  ): Promise<void> {
    const response = await this.perform(path, method, body);
    if (response.status !== 204) {
      throw new Error(`GitHub ${method} expected 204 but received ${response.status}`);
    }
  }

  async dispatchWorkflow(
    repository: string,
    workflow: string,
    ref: string,
    inputs: Record<string, string>,
  ): Promise<void> {
    await this.requestNoContent(
      `/repos/${repository}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`,
      "POST",
      { ref, inputs },
    );
  }

  private async perform(
    path: string,
    method: string,
    body?: unknown,
  ): Promise<Response> {
    const transport = this.transport;
    const response = await transport(`https://api.github.com${path}`, {
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
    return response;
  }
  accessToken(): string {
    return this.token;
  }

  static async installation(
    env: GitHubCredentials,
    installationId: number,
    repositoryId?: number,
    repositoryName?: string,
  ): Promise<GitHubClient> {
    const app = await GitHubClient.app(env);
    const result = await app.request<{ token: string }>(
      `/app/installations/${installationId}/access_tokens`,
      "POST",
      repositoryId
        ? { repository_ids: [repositoryId] }
        : repositoryName
          ? {
              repositories: [repositoryName],
              permissions: { contents: "read" },
            }
          : {},
    );
    return new GitHubClient(result.token);
  }

  static async repositoryInstallation(
    env: GitHubCredentials,
    repository: string,
    permissions: GitHubInstallationPermissions,
    transport: typeof fetch = fetch,
  ): Promise<GitHubClient> {
    const [owner, name, extra] = repository.split("/");
    if (!owner || !name || extra) throw new Error("invalid GitHub repository");
    const app = await GitHubClient.app(env, transport);
    const installation = await app.request<{ id: number }>(
      `/repos/${owner}/${name}/installation`,
    );
    const result = await app.request<{ token: string }>(
      `/app/installations/${installation.id}/access_tokens`,
      "POST",
      { repositories: [name], permissions },
    );
    return new GitHubClient(result.token, transport);
  }

  private static async app(
    env: GitHubCredentials,
    transport: typeof fetch = fetch,
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
    return new GitHubClient(`${data}.${encode(signature)}`, transport);
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
