#!/usr/bin/env bash
# Install the official Runpod skills (and print the MCP registration command)
# for the coding agent you actually use.
#
#   bash runpod/install-agent-skills.sh cursor
#   bash runpod/install-agent-skills.sh --list
#   bash runpod/install-agent-skills.sh --project claude   # .agents/skills, not ~/.agents
#
# Source of truth: https://agents.runpod.io/ (https://docs.runpod.io/agent-setup.md)
# This script only wraps the documented commands so the agent id can't be typo'd.
# It installs nothing else: runpodctl, the Flash SDK and API keys are fetched by
# the skills later, when a task first needs them.
set -euo pipefail

REQ_NODE_MAJOR=22
REQ_NODE_MINOR=20
SCOPE="--global"
AGENT=""

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Agent ids:
  codex  cursor  github-copilot  windsurf  cline  opencode  gemini-cli
  pi  hermes-agent  goose  zed  kilo  amp  grok  universal

Claude Code does not use this script -- run:
  claude plugin marketplace add runpod/runpod-plugins-official
  claude plugin install runpod@runpod
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list|-l)   usage; exit 0 ;;
    --project)   SCOPE=""; shift
                 [[ $# -gt 0 && "$1" != --* ]] && { AGENT="$1"; shift; } ;;
    -h|--help)   usage; exit 0 ;;
    --*)         echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)           AGENT="$1"; shift ;;
  esac
done

if [[ -z "$AGENT" ]]; then
  echo "error: no agent id given (try --list)" >&2
  exit 2
fi

if [[ "$AGENT" == "claude" || "$AGENT" == "claude-code" ]]; then
  cat >&2 <<'EOF'
Claude Code uses its plugin marketplace, not the skills installer:

  claude plugin marketplace add runpod/runpod-plugins-official
  claude plugin install runpod@runpod
  claude plugin list | grep -A2 'runpod@runpod'    # Status: enabled
  # then, inside Claude Code: /reload-plugins
EOF
  exit 0
fi

command -v npx >/dev/null || { echo "error: npx not found (install Node.js)" >&2; exit 1; }

# Skills need Node 22.20+; older Node can still register the MCP server (step 2).
node_ok=1
if command -v node >/dev/null; then
  read -r maj min < <(node -p 'process.versions.node.split(".").slice(0,2).join(" ")')
  if (( maj > REQ_NODE_MAJOR )) || (( maj == REQ_NODE_MAJOR && min >= REQ_NODE_MINOR )); then
    node_ok=0
  fi
fi

if (( node_ok != 0 )); then
  echo "node $(node --version 2>/dev/null || echo 'not found') is older than ${REQ_NODE_MAJOR}.${REQ_NODE_MINOR}: skipping skills." >&2
  echo "The MCP server serves the same playbooks (list-guides / read-guide), so continue with step 2." >&2
  exit 0
fi

echo "==> installing Runpod skills for agent '$AGENT' ${SCOPE:+(global)}"
npx -y skills add runpod/runpod-plugins-official --skill '*' --agent "$AGENT" --yes ${SCOPE:+"$SCOPE"}

echo
echo "==> installed skills"
npx -y skills list ${SCOPE:+"$SCOPE"} || true

cat <<EOF

==> next: register the hosted MCP server (https://mcp.runpod.io/)
    Codex:            codex plugin marketplace add https://github.com/runpod/runpod-plugins-official.git
                      codex plugin add runpod@runpod
    Gemini CLI:       gemini mcp add -s user -t http runpod https://mcp.runpod.io/
    Pi:               pi mcp add runpod --url https://mcp.runpod.io/
    Cursor/Windsurf/VS Code/opencode/Claude Desktop:
                      npx @runpod/mcp-server@latest add --client <cursor|windsurf|vscode|opencode|claude-desktop>
    Anything else:    add {"mcpServers":{"runpod":{"url":"https://mcp.runpod.io/"}}} to its MCP config

    Then restart the agent and approve the "Sign in with Runpod" OAuth prompt
    on the first Runpod tool call. Full walkthrough: runpod/agent-setup.md
EOF
