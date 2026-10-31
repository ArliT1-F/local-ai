# Wiring your coding agent to Runpod

The official onboarding guide lives at <https://agents.runpod.io/> (mirror:
`https://docs.runpod.io/agent-setup.md`). It does two things:

1. installs the **Runpod skills** (playbooks your agent reads on demand), and
2. registers the **hosted Runpod MCP server** (`https://mcp.runpod.io/`) so the
   agent can drive pods, endpoints, templates, volumes and billing through
   structured tool calls instead of you clicking through the console.

This page is the walkthrough, with the parts that need *you* (a browser and an
OAuth approval) marked **[User step]**. `runpod/install-agent-skills.sh` runs
the non-interactive half for you.

> Runpod spells the company/product with one capital letter, "Runpod"; older
> files in this repo say "RunPod". Same thing.

---

## What was verified, and what wasn't

Setup ran in a sandbox whose egress is limited to GitHub and npm, so the two
halves split cleanly:

| Step | Result |
| - | - |
| Skills install (`npx -y skills add runpod/runpod-plugins-official ...`) | ✅ **verified** — 16 skills copied to `~/.agents/skills/`, every one with a non-empty `SKILL.md` |
| Skill inventory | ✅ `cost-audit, discovery, endpoint-ops, flash, lifecycle-crud, pod-deploy, pod-doctor, runpod, runpod-build-template, runpod-mcp, runpod-migrate, runpod-templates, runpod-usage, runpodctl, serverless-deploy` (+ `companion-clis`) |
| MCP client detection (`npx @runpod/mcp-server@latest add --list`) | ✅ installer runs and lists supported clients; **none present in that sandbox**, so nothing was written |
| Register the MCP server | ⏳ needs *your* agent — config file path, below |
| OAuth "Sign in with Runpod" | ⏳ **[User step]** — `mcp.runpod.io` is unreachable from the sandbox |
| Anything that bills (pod / endpoint) | ⏳ not attempted — no API key, no egress to `api.runpod.ai` |

Nothing in this repo changed what your account is doing: no pods, no endpoints,
no keys.

---

## Step 1 — Skills (non-interactive)

Needs **Node.js 22.20+** (`node --version`). If it's older, skip to step 2: the
MCP server serves the same playbooks via `list-guides` / `read-guide`, so setup
still works.

Pick your agent's id:

| Agent | id | | Agent | id |
| - | - | - | - | - |
| Claude Code | *use the plugin route in step 1b* | | Gemini CLI | `gemini-cli` |
| Codex | `codex` | | Pi | `pi` |
| Cursor | `cursor` | | Hermes | `hermes-agent` |
| GitHub Copilot (VS Code) | `github-copilot` | | Goose | `goose` |
| Windsurf | `windsurf` | | Zed | `zed` |
| Cline | `cline` | | Kilo Code | `kilo` |
| opencode | `opencode` | | Amp | `amp` |
| anything else | `universal` (writes `~/.agents/skills`) | | | |

```sh
npx -y skills add runpod/runpod-plugins-official --skill '*' --agent cursor --yes --global
npx -y skills list --global      # verify
```

- Leave off `--global` to install into this project's `.agents/skills/` instead.
- On Windows `cmd`, single quotes pass through literally: use `--skill "*"`.
- If it reports `No matching skills found`, name them explicitly:
  `npx -y skills add runpod/runpod-plugins-official --list` then `--skill runpod,pod-deploy,...`.
- Unsure of an id? `--agent list-ids` prints every valid one (and installs nothing).

Or just: `bash runpod/install-agent-skills.sh cursor` — same command, with the
id validated first.

### 1b — Claude Code (one step, no `npx skills`)

```sh
claude plugin marketplace add runpod/runpod-plugins-official
claude plugin install runpod@runpod
claude plugin list | grep -A2 'runpod@runpod'     # expect: Status: ✔ enabled
```

If it's listed but disabled: `claude plugin enable runpod@runpod`.
**[User step]** then run `/reload-plugins` inside Claude Code.

---

## Step 2 — Register the MCP server

Same hosted server for every agent. Register **one** address only —
`https://mcp.getrunpod.io/` is the old name of `https://mcp.runpod.io/` and each
address has its own sign-in. Don't open the URL in a browser: it's an MCP
endpoint and answers `405`.

```sh
# Codex (installs skills + MCP together; skip step 1 for Codex)
codex plugin marketplace add https://github.com/runpod/runpod-plugins-official.git
codex plugin add runpod@runpod

# Gemini CLI
gemini mcp add -s user -t http runpod https://mcp.runpod.io/

# Pi
pi mcp add runpod --url https://mcp.runpod.io/

# Grok Build
grok mcp add --transport http runpod https://mcp.runpod.io/
```

**Everything else** (Cursor, Windsurf, VS Code, opencode, Pi, Claude Desktop):

```sh
npx @runpod/mcp-server@latest add --client cursor    # cursor|windsurf|vscode|opencode|pi|claude-desktop
npx @runpod/mcp-server@latest add --list             # what it detects, and where each config lives
```

Exit `0` = all named clients configured, `1` = one failed, `2` = bad usage.
Always pass `--client`; with no terminal and no client it exits `2` and writes
nothing.

By hand, for any other client (merge into the existing file — don't overwrite
other servers):

```json
{
  "mcpServers": {
    "runpod": { "url": "https://mcp.runpod.io/" }
  }
}
```

opencode uses the `mcp` key and needs `"type": "remote"`:

```json
{
  "mcp": {
    "runpod": { "type": "remote", "url": "https://mcp.runpod.io/" }
  }
}
```

Restart the agent. **[User step]** the first Runpod tool call opens the OAuth
"Sign in with Runpod" flow — approve it in the browser. Codex Desktop must be
fully quit and reopened before the tools appear.

If OAuth fails (`redirect_uri is not allowed`, or `403` before the browser
opens), fall back to an API key: create one at
<https://console.runpod.io/user/settings>, export it as `RUNPOD_API_KEY`, and
add a header to the server entry:

```json
{
  "mcpServers": {
    "runpod": { "url": "https://mcp.runpod.io/",
                "headers": { "Authorization": "Bearer ${RUNPOD_API_KEY}" } }
  }
}
```

---

## Step 3 — Say hello

Once signed in, ask your agent *"list my Runpod pods"*. An empty list is a
**pass** — it means the connection works and the account has nothing running.
Empty list but you *do* have funded Pods? The sign-in landed on a different
account: sign out of the `runpod` MCP entry, sign in again.

Don't install `runpodctl`, the Flash SDK, or create API keys "just in case" —
the skills do that at the moment a task first needs them. When one does:

```sh
curl -sSL https://cli.runpod.net | bash     # runpodctl
runpodctl update && runpodctl user          # always update first; old builds have fixed bugs
```

---

## Step 4 — The Runpod part this repo actually needs

The MCP gives you console power in chat. This repo's *goal* is narrower: an
OpenAI-compatible vLLM endpoint serving
`huihui-ai/Huihui-Qwen3-8B-abliterated-v2`, wired to the `runpod` provider route
in `dsh/cordis.patch.yml`. Both paths are in [`README.md`](./README.md):

- **Serverless** (cheap, scales to zero, 20–90 s cold start) → import
  `runpod-workers/worker-vllm` from GitHub, 24 GB pool, then
  `RUNPOD_LLM_BASE_URL=https://api.runpod.ai/v2/<ENDPOINT_ID>/openai/v1`.
- **GPU pod** (always warm, bills hourly) → `MODEL=... bash runpod/start-vllm.sh`
  inside the pod, then `RUNPOD_LLM_BASE_URL=https://<POD_ID>-8000.proxy.runpod.net/v1`.

Either way it lands in `.env` as:

```sh
RUNPOD_LLM_BASE_URL=...
RUNPOD_LLM_API_KEY=<the API_KEY you set on the endpoint/pod>
```

`.env` is git-ignored. Always set `API_KEY`: a pod's proxy URL is world-reachable
and unauthenticated by default.

With the skills installed, you can hand the whole thing to your agent instead:

> "Deploy a serverless vLLM endpoint for
> `huihui-ai/Huihui-Qwen3-8B-abliterated-v2` on a 24 GB pool using
> `runpod-workers/worker-vllm`, with `MAX_MODEL_LEN=40960`,
> `ENABLE_AUTO_TOOL_CHOICE=1`, `TOOL_CALL_PARSER=hermes` and an `API_KEY`.
> Tell me the base URL and the hourly cost."

It will route through the `runpod-mcp` → `serverless-deploy` skills, read GPU
stock before creating anything, and quote the cost first — a pod or endpoint
bills from the moment it exists.

---

## Troubleshooting

| Symptom | Fix |
| - | - |
| `marketplace add` fails with an SSH `known_hosts` error (Claude Code) | Check `curl -sI https://github.com` — a network blocking GitHub, not SSH |
| `codex plugin add` unknown / `plugin not found` | Codex too old or plugins off: `features.plugins` must not be `false` in `~/.codex/config.toml` |
| Skills folder exists but is empty | Re-run the install command |
| Agent doesn't see the skills | Restart / reload it (`/reload-plugins` in Claude Code) |
| Two `runpod` MCP entries, each asking to sign in | You registered both `mcp.runpod.io` and `mcp.getrunpod.io`; keep one |
| Agent can't load skills at all | The MCP serves the same content: `list-guides` + `read-guide`, `search-concepts` + `lookup-concept` |

Docs: <https://docs.runpod.io/get-started/agent-skills> ·
<https://docs.runpod.io/get-started/mcp-servers> ·
plugin source <https://github.com/runpod/runpod-plugins-official>
