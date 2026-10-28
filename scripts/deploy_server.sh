#!/bin/zsh
# Deploys server/ to the Vercel project docsnap-api (scope adi-201) in production.
# The owner allowed the adi-201 scope ONLY for this project — never touch other projects there.
# Requires `vercel login` once. Secrets live in Vercel's env settings, never in this repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/server"
vercel whoami >/dev/null 2>&1 || { echo "Run 'vercel login' first." >&2; exit 1; }
npm run -s typecheck
npm test --silent
vercel deploy --prod --yes --scope adi-201 </dev/null >/dev/null 2>&1
vercel ls docsnap-api --scope adi-201 </dev/null 2>&1 | sed -n '5p'
curl -s -m 20 https://docsnap-api.vercel.app/api/answer; echo
