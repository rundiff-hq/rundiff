import crypto from "node:crypto";
import fs from "node:fs";
import https from "node:https";
import process from "node:process";

const upstream = process.env.GITHUB_EMULATOR_URL ?? "http://github-emulator:4001";
const controlPlaneWebhook =
  process.env.RUNDIFF_CONTROL_PLANE_WEBHOOK_URL ?? "https://control-plane-tls:4444/github/webhooks";
const webhookSecret = process.env.LAB_GITHUB_WEBHOOK_SECRET ?? "rundiff-production-lab-webhook-secret";
const adminToken = process.env.RUNDIFF_LAB_GITHUB_ADMIN_TOKEN ?? "lab-admin-token";
const statePath = process.env.RUNDIFF_LAB_SHA_STATE ?? "/lab-state/shas.json";
const tlsRoot = process.env.RUNDIFF_LAB_TLS_ROOT ?? "/lab-tls";
const repository = "admin/customer-rails";

const pullRequestMappings = new Map();

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

function readRealMapping(number) {
  const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
  return state.pull_requests?.[String(number)] ?? null;
}

function rememberPullRequest(number, payload) {
  const real = readRealMapping(number);
  if (!real) return null;

  const key = Number(number);
  const previous = pullRequestMappings.get(key) ?? null;
  const emulatorHeadSha = payload.pull_request?.head?.sha;
  let realHeadSha = previous?.realHeadSha ?? real.head_sha;

  if (
    real.fixed_sha &&
    previous?.emulatorHeadSha &&
    emulatorHeadSha &&
    previous.emulatorHeadSha !== emulatorHeadSha
  ) {
    realHeadSha = real.fixed_sha;
  }

  const mapping = {
    number: key,
    emulatorBaseSha: payload.pull_request?.base?.sha,
    emulatorHeadSha,
    realBaseSha: real.base_sha,
    realHeadSha,
    kind: real.kind,
  };
  pullRequestMappings.set(key, mapping);
  return mapping;
}

function mappingForNumber(number) {
  return pullRequestMappings.get(Number(number)) ?? null;
}

function mappingForRealSha(sha) {
  for (const mapping of pullRequestMappings.values()) {
    if (mapping.realHeadSha === sha || mapping.realBaseSha === sha) return mapping;
  }
  return null;
}

function emulatorShaForRealSha(sha) {
  const mapping = mappingForRealSha(sha);
  if (!mapping) return sha;
  if (mapping.realHeadSha === sha) return mapping.emulatorHeadSha;
  if (mapping.realBaseSha === sha) return mapping.emulatorBaseSha;
  return sha;
}

function realShaForEmulatorSha(sha) {
  for (const mapping of pullRequestMappings.values()) {
    if (mapping.emulatorHeadSha === sha) return mapping.realHeadSha;
    if (mapping.emulatorBaseSha === sha) return mapping.realBaseSha;
  }
  return sha;
}

function signature(body) {
  return `sha256=${crypto.createHmac("sha256", webhookSecret).update(body).digest("hex")}`;
}

function validSignature(body, supplied) {
  if (typeof supplied !== "string") return false;
  const expected = Buffer.from(signature(body));
  const actual = Buffer.from(supplied);
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

async function fetchLatestPullRequest() {
  const target = new URL(`/repos/${repository}/pulls?state=open&per_page=100`, upstream);
  const response = await fetch(target, {
    headers: {
      authorization: `Bearer ${adminToken}`,
      accept: "application/vnd.github+json",
    },
  });

  if (!response.ok) {
    throw new Error(`failed to hydrate pull_request webhook: HTTP ${response.status}`);
  }

  const pulls = await response.json();
  const latest = pulls
    .filter((pull) => Number.isInteger(Number(pull.number)))
    .sort((left, right) => Number(right.number) - Number(left.number))[0];

  if (!latest) {
    throw new Error("failed to hydrate pull_request webhook: no open pull request found");
  }

  return latest;
}

async function rewriteWebhookPayload(event, payload) {
  if (
    event === "pull_request" &&
    payload.repository?.full_name === repository
  ) {
    let pullRequest = payload.pull_request;
    let pullNumber = payload.number ?? pullRequest?.number;

    if (!pullRequest || !Number.isInteger(Number(pullNumber))) {
      const hydrated = await fetchLatestPullRequest();
      pullRequest = { ...hydrated, ...(pullRequest ?? {}) };
      pullNumber = payload.number ?? pullRequest.number;
    }

    if (!Number.isInteger(Number(pullNumber))) {
      throw new Error("pull_request webhook is missing a numeric pull request number");
    }

    payload.number = Number(pullNumber);
    payload.pull_request = pullRequest;

    const mapping = rememberPullRequest(payload.number, payload);
    if (mapping) {
      payload.pull_request.base.sha = mapping.realBaseSha;
      payload.pull_request.head.sha = mapping.realHeadSha;
    }
  }

  if (
    event === "check_run" &&
    payload.repository?.full_name === repository &&
    payload.check_run?.head_sha
  ) {
    payload.check_run.head_sha = realShaForEmulatorSha(payload.check_run.head_sha);
  }

  return payload;
}

function copyHeaders(source) {
  const headers = new Headers();
  for (const [name, value] of Object.entries(source)) {
    if (value === undefined) continue;
    if (["host", "content-length", "connection"].includes(name.toLowerCase())) continue;
    headers.set(name, Array.isArray(value) ? value.join(", ") : value);
  }
  return headers;
}

function rewriteApiPath(pathname) {
  const match = pathname.match(
    /^\/repos\/admin\/customer-rails\/commits\/([^/]+)\/check-runs$/,
  );
  if (!match) return pathname;

  const realSha = decodeURIComponent(match[1]);
  const emulatorSha = emulatorShaForRealSha(realSha);
  return pathname.replace(match[1], encodeURIComponent(emulatorSha));
}

function rewriteApiSearch(pathname, search) {
  if (!pathname.startsWith("/repos/admin/customer-rails/contents/")) return search;

  const params = new URLSearchParams(search);
  const ref = params.get("ref");
  if (!ref) return search;

  const emulatorRef = emulatorShaForRealSha(ref);
  if (emulatorRef === ref) return search;

  params.set("ref", emulatorRef);
  const encoded = params.toString();
  return encoded ? `?${encoded}` : "";
}

function rewriteRequestBody(method, pathname, rawBody) {
  if (method !== "POST" || pathname !== "/repos/admin/customer-rails/check-runs" || rawBody.length === 0) {
    return rawBody;
  }

  const body = JSON.parse(rawBody.toString("utf8"));
  if (body.head_sha) body.head_sha = emulatorShaForRealSha(body.head_sha);
  return Buffer.from(JSON.stringify(body));
}

function rewritePullRequestResponse(pathname, contentType, body) {
  const match = pathname.match(/^\/repos\/admin\/customer-rails\/pulls\/(\d+)$/);
  if (!match || !contentType.includes("application/json") || body.length === 0) return body;

  const mapping = mappingForNumber(Number(match[1]));
  if (!mapping) return body;

  const payload = JSON.parse(body.toString("utf8"));
  if (payload.base) payload.base.sha = mapping.realBaseSha;
  if (payload.head) payload.head.sha = mapping.realHeadSha;
  return Buffer.from(JSON.stringify(payload));
}

async function handleWebhook(request, response, rawBody) {
  const suppliedSignature = request.headers["x-hub-signature-256"];
  if (!validSignature(rawBody, suppliedSignature)) {
    response.writeHead(401, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: false, error: "invalid_emulator_signature" }));
    return;
  }

  const event = String(request.headers["x-github-event"] ?? "");
  const payload = await rewriteWebhookPayload(event, JSON.parse(rawBody.toString("utf8")));
  const forwardedBody = Buffer.from(JSON.stringify(payload));
  const forwarded = await fetch(controlPlaneWebhook, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-github-event": event,
      "x-github-delivery": String(request.headers["x-github-delivery"] ?? crypto.randomUUID()),
      "x-hub-signature-256": signature(forwardedBody),
    },
    body: forwardedBody,
  });

  const responseBody = Buffer.from(await forwarded.arrayBuffer());
  response.writeHead(forwarded.status, {
    "content-type": forwarded.headers.get("content-type") ?? "application/json",
  });
  response.end(responseBody);
}

async function handleProxy(request, response, rawBody) {
  const incoming = new URL(request.url, "https://github-edge:4002");
  const rewrittenPath = rewriteApiPath(incoming.pathname);
  const rewrittenSearch = rewriteApiSearch(incoming.pathname, incoming.search);
  const target = new URL(`${rewrittenPath}${rewrittenSearch}`, upstream);
  const body = rewriteRequestBody(request.method, incoming.pathname, rawBody);
  const headers = copyHeaders(request.headers);

  const upstreamResponse = await fetch(target, {
    method: request.method,
    headers,
    body: ["GET", "HEAD"].includes(request.method) ? undefined : body,
    redirect: "manual",
  });

  let responseBody = Buffer.from(await upstreamResponse.arrayBuffer());
  responseBody = rewritePullRequestResponse(
    incoming.pathname,
    upstreamResponse.headers.get("content-type") ?? "",
    responseBody,
  );

  const outgoingHeaders = {};
  upstreamResponse.headers.forEach((value, name) => {
    if (!["content-length", "connection", "transfer-encoding"].includes(name.toLowerCase())) {
      outgoingHeaders[name] = value;
    }
  });
  outgoingHeaders["content-length"] = String(responseBody.length);

  response.writeHead(upstreamResponse.status, outgoingHeaders);
  response.end(responseBody);
}

const server = https.createServer(
  {
    key: fs.readFileSync(`${tlsRoot}/github-edge.key`),
    cert: fs.readFileSync(`${tlsRoot}/github-edge.crt`),
  },
  async (request, response) => {
    try {
      if (request.url === "/health") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ status: "ok" }));
        return;
      }

      const rawBody = await readBody(request);
      if (request.url === "/webhooks" && request.method === "POST") {
        await handleWebhook(request, response, rawBody);
      } else {
        await handleProxy(request, response, rawBody);
      }
    } catch (error) {
      console.error(error);
      response.writeHead(502, { "content-type": "application/json" });
      response.end(JSON.stringify({ ok: false, error: error.message }));
    }
  },
);

server.listen(4002, "0.0.0.0", () => {
  console.log("production_lab_github_edge=https://github-edge:4002");
});
