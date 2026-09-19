import fs from "node:fs";
import process from "node:process";
import { createEmulator } from "emulate";

const webhookSecret = process.env.LAB_GITHUB_WEBHOOK_SECRET ?? "rundiff-production-lab-webhook-secret";
const appId = Number(process.env.LAB_GITHUB_APP_ID ?? "12345");
const installationId = Number(process.env.LAB_GITHUB_INSTALLATION_ID ?? "100");
const stateRoot = process.env.RUNDIFF_LAB_STATE_ROOT ?? "/lab-state";

fs.mkdirSync(stateRoot, { recursive: true });

const seed = {
  tokens: {
    "lab-admin-token": {
      login: "admin",
      scopes: ["repo", "user", "admin:repo_hook"],
    },
  },
  github: {
    users: [
      {
        login: "admin",
        name: "RunDiff Lab Admin",
        email: "production-lab@rundiff.local",
      },
    ],
    repos: [
      {
        owner: "admin",
        name: "customer-rails",
        private: true,
        auto_init: true,
      },
      {
        owner: "admin",
        name: "not-allowed",
        private: true,
        auto_init: true,
      },
    ],
    apps: [
      {
        app_id: appId,
        slug: "rundiff-lab",
        name: "RunDiff Lab",
        permissions: {
          contents: "read",
          checks: "write",
          pull_requests: "write",
        },
        events: ["pull_request", "check_run"],
        webhook_url: "https://github-edge:4002/webhooks",
        webhook_secret: webhookSecret,
        installations: [
          {
            installation_id: installationId,
            account: "admin",
            repository_selection: "all",
          },
        ],
      },
    ],
  },
};

const emulator = await createEmulator({
  service: "github",
  port: 4001,
  baseUrl: "http://github-emulator:4001",
  seed,
});

const privateKey = emulator.generatedSecrets.find(
  (secret) => secret.kind === "github.app_private_key" && secret.id === String(appId),
);

if (!privateKey) {
  throw new Error("GitHub emulator did not expose the generated App private key");
}

const privateKeyPath = `${stateRoot}/github-app.pem`;
fs.writeFileSync(privateKeyPath, privateKey.value, { mode: 0o600 });
fs.chmodSync(privateKeyPath, 0o600);

console.log(`production_lab_github_emulator=${emulator.url}`);
console.log(`production_lab_github_app_id=${appId}`);
console.log(`production_lab_github_installation_id=${installationId}`);
console.log(`production_lab_github_private_key=${privateKeyPath}`);

const shutdown = async () => {
  await emulator.close();
  process.exit(0);
};

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
