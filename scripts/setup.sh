#!/usr/bin/env bash
# One-shot setup for the local AI agent stack.
#
#   bash scripts/setup.sh                # everything
#   SKIP_BROWSERS=1 bash scripts/setup.sh
#   SKIP_NUCLEI=1   bash scripts/setup.sh
#
# Installs: harness (dsh) + MCP servers from package.json, the Playwright
# chromium build, the nuclei binary, the harness home, and the dsh profile
# patch that wires up Abliteration + Playwright + Firecrawl.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DSH_HOME="${DSH_HOME:-$ROOT/.dsh-home}"
PROFILE="${DSH_PROFILE:-web}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '    ok   %s\n' "$*"; }
warn() { printf '    warn %s\n' "$*"; }

# ---------------------------------------------------------------- node ----
say "Checking Node.js"
command -v node >/dev/null || { echo "error: Node.js 22+ is required (https://nodejs.org)" >&2; exit 1; }
node_major="$(node -p 'process.versions.node.split(".")[0]')"
if (( node_major < 22 )); then
  echo "error: Node.js >=22 required (found $(node -v)); firecrawl-mcp needs it" >&2
  exit 1
fi
ok "node $(node -v) / npm $(npm -v)"

# ------------------------------------------------------------ packages ----
say "Installing packages (harness + MCP servers)"
if [[ -f package-lock.json ]]; then
  npm ci --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi
ok "dsh $(npx --no-install dsh --version 2>/dev/null || echo '?')"
ok "@playwright/mcp $(node -p "require('./node_modules/@playwright/mcp/package.json').version")"
ok "firecrawl-mcp $(node -p "require('./node_modules/firecrawl-mcp/package.json').version")"

# ------------------------------------------------------------ browsers ----
if [[ "${SKIP_BROWSERS:-0}" != "1" ]]; then
  say "Installing the Playwright chromium build"
  # The MCP server can start without browsers but every browser_* tool fails.
  if npx --no-install playwright install chromium --with-deps 2>/dev/null || npx --no-install playwright install chromium; then
    ok "chromium ready"
  else
    warn "browser install failed (offline?) -- browser_* tools will error until 'npx playwright install chromium' succeeds"
  fi
else
  say "Skipping Playwright browsers (SKIP_BROWSERS=1)"
fi

# ------------------------------------------------------------- secrets ----
say "Checking .env"
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  warn "created .env from .env.example -- fill in ABLIT_KEY and FIRECRAWL_API_KEY"
else
  chmod 600 .env || true
  ok ".env present (mode 600)"
fi
grep -q '^ABLIT_KEY=ak_REPLACE_ME$' .env && warn "ABLIT_KEY is still the placeholder"
grep -q '^FIRECRAWL_API_KEY=fc_REPLACE_ME$' .env && warn "FIRECRAWL_API_KEY is still the placeholder"

# -------------------------------------------------------------- nuclei ----
if [[ "${SKIP_NUCLEI:-0}" != "1" ]]; then
  say "Installing nuclei (official release, checksum verified)"
  if [[ -x "$ROOT/bin/nuclei" ]]; then
    ok "already installed: $("$ROOT/bin/nuclei" -version 2>&1 | head -1)"
  elif bash security/nuclei/install-nuclei.sh; then
    ok "nuclei installed to bin/nuclei"
  else
    warn "nuclei install failed -- run 'bash security/nuclei/install-nuclei.sh' later"
  fi
else
  say "Skipping nuclei (SKIP_NUCLEI=1)"
fi

# ------------------------------------------------------- harness home -----
say "Preparing the harness home ($DSH_HOME)"
mkdir -p "$DSH_HOME"
export DSH_HOME
# Booting the profile once initializes profiles/web (package.json + patch).
npx --no-install dsh "$PROFILE" --dump-config >/dev/null
profile_dir="$DSH_HOME/profiles/$PROFILE"
[[ -d "$profile_dir" ]] || { echo "error: $profile_dir was not created" >&2; exit 1; }
ok "profile '$PROFILE' initialized"

target="$profile_dir/cordis.patch.yml"
if [[ -L "$target" || -f "$target" ]]; then
  if [[ -L "$target" ]] && [[ "$(readlink "$target")" == "$ROOT/dsh/cordis.patch.yml" ]]; then
    ok "patch already linked"
  else
    cp -L "$target" "$target.bak" 2>/dev/null || true
    rm -f "$target"
    ln -s "$ROOT/dsh/cordis.patch.yml" "$target"
    ok "patch linked (previous file kept as cordis.patch.yml.bak)"
  fi
fi

# ------------------------------------------------------------ validate ----
say "Validating the composed configuration"
if ABLIT_KEY="${ABLIT_KEY:-unset}" npx --no-install dsh "$PROFILE" --dump-config 2>/dev/null \
     | grep -q 'abliterated-model-large-flash'; then
  ok "Abliteration route composes with model abliterated-model-large-flash"
else
  warn "could not confirm the Abliteration route in --dump-config"
fi
if npx --no-install dsh "$PROFILE" --dump-config 2>/dev/null | grep -q 'mcp-playwright'; then
  ok "MCP rows compose (playwright, firecrawl)"
else
  warn "could not confirm MCP rows in --dump-config"
fi

say "Done"
cat <<EOF

Next:
  1. put your keys in .env        (ABLIT_KEY, FIRECRAWL_API_KEY)
  2. bash scripts/verify-all.sh   (live checks, exit code tells you if it's good)
  3. bash scripts/start-harness.sh

Harness UI: http://127.0.0.1:${DSH_PORT:-3080}
EOF
