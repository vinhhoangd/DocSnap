#!/bin/zsh
# Deploys server/ to the owner's personal Vercel account (production) and prints the URL.
# Requires `vercel login` once. Secrets live in Vercel's env settings, never in this repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/server"
vercel whoami >/dev/null 2>&1 || { echo "Run 'vercel login' first." >&2; exit 1; }
npm run -s typecheck
vercel deploy --prod --yes 2>&1 | tail -3
