#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/control-plane-cloudflare"

cd "$APP"

echo "==> Verify Wrangler authentication"
npx wrangler whoami

echo "==> Prepare production Wrangler config"
cp wrangler.production.jsonc.example wrangler.production.jsonc

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

echo "==> Production control plane deployed"
echo "Next proof should create a fresh external PR synchronize event and verify:"
echo "  scenario_id=http.request.behavior"
echo "  ALLOW with WARNING publication"
