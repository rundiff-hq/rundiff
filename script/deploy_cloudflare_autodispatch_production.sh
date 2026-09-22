#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/control-plane-cloudflare"
DISPATCH_REF="${RUNDIFF_EXECUTOR_DISPATCH_REF:-main}"

cd "$APP"

echo "==> Verify Wrangler authentication"
npx wrangler whoami

echo "==> Prepare production Wrangler config"
cp wrangler.production.jsonc.example wrangler.production.jsonc

echo "==> Enable automatic GitHub Actions dispatch"
python3 - "$DISPATCH_REF" <<'PY'
from pathlib import Path
import sys

dispatch_ref = sys.argv[1]
path = Path("wrangler.production.jsonc")
content = path.read_text()
content = content.replace(
    '"RUNDIFF_EXECUTOR_AUTODISPATCH": "disabled"',
    '"RUNDIFF_EXECUTOR_AUTODISPATCH": "github_actions"',
)
content = content.replace(
    '"RUNDIFF_EXECUTOR_DISPATCH_REF": "main"',
    f'"RUNDIFF_EXECUTOR_DISPATCH_REF": "{dispatch_ref}"',
)
path.write_text(content)
PY

echo "==> Effective dispatch config"
grep -A4 '"RUNDIFF_EXECUTOR_AUTODISPATCH"' wrangler.production.jsonc

echo "==> Install exact dependencies"
npm ci

echo "==> Typecheck"
npm run typecheck

echo "==> Focused control-plane tests"
npm test

echo "==> Deploy production Worker"
npm run deploy:production

echo "==> Verify production health"
curl --fail --silent --show-error https://rundiff.com/api/health
printf "\n"

echo "==> Automatic dispatch production cutover deployed"
echo "dispatch_ref=$DISPATCH_REF"
echo "Next: create one harmless synchronize commit on external fixture PR #1."
