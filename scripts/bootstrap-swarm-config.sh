#!/usr/bin/env bash
# Re-applies this deployment's non-secret, DB-only swarm_config and repo
# state after a fresh boot (e.g. `docker compose down -v && up -d`).
#
# What this covers (lives in swarm_config / agent_tasks tables, wiped by
# `down -v`, NOT persisted by .env or docker-compose.example.yml):
#   - MODEL_TIER_PI_* global config (so the dashboard's task-creation flow
#     resolves to Bedrock instead of the OpenRouter tier-default — see
#     SWARM-SETUP-NOTES.md "Gotcha: GET /api/models-catalog/tiers ignores
#     the fix the dashboard needs").
#   - Registered repos.
#
# What this deliberately does NOT cover (re-do manually — see
# SWARM-SETUP-NOTES.md for why):
#   - GitHub OAuth App (client id/secret) — recreate via the dashboard
#     /integrations GitHub flow; the secret must be re-entered on both
#     GitHub's side and here after a reset.
#   - EngFlow Pyrite / opal_dev MCP servers — their auth is a personal
#     session cookie with its own expiry; re-paste a fresh one, don't
#     bake an old one into a script.
#   - Anything in .env (GITHUB_TOKEN, AWS_*, API_KEY, MODEL_OVERRIDE,
#     COMPOSIO_API_KEY, etc.) — that file already survives `down -v` on
#     its own; nothing to do here.
#
# Usage:
#   ./scripts/bootstrap-swarm-config.sh
# Requires: API_KEY in this project's .env, and the API container healthy
# at MCP_BASE_URL (defaults to http://localhost:3013).

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "FATAL: .env not found in repo root." >&2
  exit 1
fi

API_KEY="$(grep -E '^API_KEY=' .env | head -1 | cut -d= -f2-)"
if [ -z "$API_KEY" ]; then
  echo "FATAL: API_KEY is empty in .env." >&2
  exit 1
fi

BASE_URL="${MCP_BASE_URL:-http://localhost:3013}"

echo "Waiting for API at ${BASE_URL}/health ..."
for i in $(seq 1 30); do
  if curl -sf "${BASE_URL}/health" >/dev/null 2>&1; then
    echo "API healthy."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FATAL: API did not become healthy after 30 attempts." >&2
    exit 1
  fi
  sleep 2
done

echo ""
echo "=== Re-applying MODEL_TIER_PI_* global config (Bedrock Haiku) ==="
MODEL="amazon-bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0"
for tier in SMOL REGULAR SMART ULTRA; do
  key="MODEL_TIER_PI_${tier}"
  code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${BASE_URL}/api/config" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"scope\":\"global\",\"key\":\"${key}\",\"value\":\"${MODEL}\"}")
  echo "  ${key} -> ${code}"
done

echo ""
echo "=== Re-registering repos ==="
# Add one block per repo you want auto-registered on every fresh boot.
# Fields mirror POST /api/repos (src/http/repos.ts). 409 (duplicate) is
# expected and harmless on a non-fresh DB — this script is idempotent.

create_or_skip_repo() {
  local url="$1" name="$2" default_branch="$3" auto_clone="$4"
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/api/repos" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"${url}\",\"name\":\"${name}\",\"defaultBranch\":\"${default_branch}\",\"autoClone\":${auto_clone}}")
  local code
  code=$(echo "$response" | tail -1)
  case "$code" in
    201) echo "  ${name}: created" ;;
    409) echo "  ${name}: already exists, skipped" ;;
    *) echo "  ${name}: unexpected HTTP ${code}" >&2 ;;
  esac
}

create_or_skip_repo "https://github.com/svelezsaffon/raylib.git" "raylib" "main" "true"

echo ""
echo "=== Still manual (secrets with their own expiry — see script header) ==="
echo "  - GitHub OAuth App (client id/secret): /integrations -> GitHub in the dashboard"
echo "  - EngFlow Pyrite / opal_dev MCP servers: re-create with a fresh session cookie"
echo "  - Repo guidelines (update-repo): set via the Lead or dashboard before routing coding tasks"
echo ""
echo "Done."
