#!/usr/bin/env bash
# Boot the DeepSeek Harness web profile with the Abliteration + MCP wiring.
#
#   bash scripts/start-harness.sh
#   DSH_PORT=8080 bash scripts/start-harness.sh
#   OPEN=1 bash scripts/start-harness.sh     # open a browser window
#
# Secrets are read from .env and exported only into this process tree; they are
# never written into the profile patch (which only names the variables).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export DSH_HOME="${DSH_HOME:-$ROOT/.dsh-home}"
PROFILE="${DSH_PROFILE:-web}"
PORT="${DSH_PORT:-3080}"
HOST="${DSH_HOST:-127.0.0.1}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
else
  echo "warning: no .env found -- copy .env.example to .env and add your keys" >&2
fi

if [[ -z "${ABLIT_KEY:-}" || "${ABLIT_KEY}" == "ak_REPLACE_ME" ]]; then
  echo "warning: ABLIT_KEY is unset/placeholder; the Abliteration route will fail with MISSING_CREDENTIAL" >&2
fi

profile_dir="$DSH_HOME/profiles/$PROFILE"
mkdir -p "$DSH_HOME"
if [[ ! -d "$profile_dir" ]]; then
  echo "profile '$PROFILE' not initialized yet; running first-boot initialization"
  npx --no-install dsh "$PROFILE" --dump-config >/dev/null
fi

target="$profile_dir/cordis.patch.yml"
if [[ ! -L "$target" || "$(readlink "$target")" != "$ROOT/dsh/cordis.patch.yml" ]]; then
  cp -L "$target" "$target.bak" 2>/dev/null || true
  rm -f "$target"
  ln -s "$ROOT/dsh/cordis.patch.yml" "$target"
  echo "linked $target -> dsh/cordis.patch.yml"
fi

# Optional self-hosted model route (step 3).
[[ -n "${RUNPOD_LLM_BASE_URL:-}" ]] && echo "self-hosted route: ${RUNPOD_LLM_BASE_URL}"

args=(web --port "$PORT" --host "$HOST")
[[ "${OPEN:-0}" == "1" ]] || args+=(--no-open)

echo "starting dsh ($PROFILE) on http://$HOST:$PORT"
echo "harness home: $DSH_HOME"
exec npx --no-install dsh "${args[@]}"
