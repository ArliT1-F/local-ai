# local-ai — DeepSeek Harness + Abliterated Large Flash + browser/scrape/security tooling

A reproducible local setup that gives you:

- **[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)** (`dsh`) running locally as a web app,
- wired to **Abliterated Large Flash** (`abliterated-model-large-flash`) over the
  Abliteration OpenAI-compatible API,
- with **Playwright** and **Firecrawl** attached as MCP servers,
- **nuclei** available through the terminal, pointed only at a deliberately
  vulnerable **local test app** you own,
- and an optional **self-hosted abliterated model on RunPod** as a second provider.

Nothing in here needs sudo, and nothing leaves your machine except calls to the
two APIs you hold keys for.

---

## Verification status

I built and tested this in a sandbox that could only reach npm and GitHub, so
here is exactly what has been proven versus what needs your keys/machine:

| Check | Result |
| - | - |
| `dsh` 0.2.1-rc.5 installs, boots, serves the UI | ✅ **verified** |
| Config composes: provider route + both MCP rows (`dsh --dump-config`) | ✅ **verified** |
| Both MCP servers complete a real MCP handshake and list tools | ✅ **verified** — Playwright 25 tools, Firecrawl 28 tools |
| Harness itself activates both MCP servers at startup | ✅ **verified** — booted with `failOnStartupError: true` on both rows and zero activation errors; a negative control (bogus `command: definitely-not-a-command`) does log `initial connection or tool synchronization failed`, so the clean boot is meaningful |
| Local test app serves the intended flaws | ✅ **verified** |
| Nuclei loopback-only guard rejects public targets | ✅ **verified** |
| `GET /v1/models` + a chat completion on Abliterated Large Flash | ⏳ needs your `ABLIT_KEY` (sandbox had no egress to `api.abliteration.ai`) |
| Firecrawl tool call (live scrape/search) | ⏳ needs your `FIRECRAWL_API_KEY` |
| Playwright actually driving a browser | ⏳ needs `npx playwright install chromium` (browser CDN blocked in sandbox) |
| Nuclei binary + templates | ⏳ needs GitHub release download (blocked in sandbox); script verifies the published SHA-256 |

`bash scripts/verify-all.sh` re-runs every one of these on your machine and
exits non-zero if anything that should work doesn't. `LIVE=1` adds one real
tool call per MCP server and a 16-token completion.

---

## Quickstart

```sh
git clone <this repo> && cd local-ai

npm run setup                     # installs dsh + MCP servers, browsers, nuclei, harness home
$EDITOR .env                      # ABLIT_KEY, FIRECRAWL_API_KEY

npm run verify                    # PASS/FAIL matrix
LIVE=1 npm run verify             # + real tool call + real model completion

npm run start                     # harness UI on http://127.0.0.1:3080
```

Then in the UI: **Choose workspace** → this repo, pick
**Abliteration → Abliterated Large Flash**, and start a session.

---

## How it fits together

```
                    ┌──────────────────────────────────────────┐
   your browser ───▶│  dsh web  (http://127.0.0.1:3080)         │
                    │                                          │
                    │  dsh-llm-pi-ai ──▶ Abliteration API      │  chat completions
                    │                     (Large Flash)        │  + reasoning effort
                    │                  └▶ RunPod vLLM (opt.)   │
                    │                                          │
                    │  dsh-mcp-client ──▶ playwright (stdio)   │  25 tools
                    │                  └▶ firecrawl  (stdio)   │  28 tools
                    │  dsh-bash ────────▶ nuclei               │  terminal
                    └──────────────────────────────────────────┘
                                     │
                                     ▼
                        security/testapp (127.0.0.1:8787)
                        intentionally vulnerable, loopback only
```

The wiring lives in **one** file, `dsh/cordis.patch.yml`, which
`scripts/setup.sh` links to `$DSH_HOME/profiles/web/cordis.patch.yml`. dsh
hot-reloads it, so config edits apply without a restart.

### The model

```yaml
abliteration:
  apiKeyEnv: ABLIT_KEY                    # key never enters the YAML
  api: openai-completions
  baseURL: https://api.abliteration.ai/v1
  compat: { supportsDeveloperRole: false, maxTokensField: max_tokens }
  models:
    - id: abliterated-model-large-flash   # 1,048,576 ctx, text+image
      reasoningEfforts: { off: none, low: low, high: high, max: max }
```

`Abliterated Large Flash` supports `off / low / high / max`; the harness Effort
menu maps straight onto them. `maxTokens` is capped at 65 536 here — the API
allows 262 144, but a runaway output cap is a good way to burn credit.

### The MCP servers

Both use the official packages over stdio, version-pinned:

| Server | Package | Tools | Notable flags |
| - | - | -: | - |
| Playwright | `@playwright/mcp@0.0.83` | 25 | `--headless --isolated --allowed-origins=http://127.0.0.1:8787` |
| Firecrawl | `firecrawl-mcp@3.36.0` | 28 | key via `env: FIRECRAWL_API_KEY` |

dsh exposes them as `mcp__playwright__*` and `mcp__firecrawl__*`. dsh **scrubs**
ambient `*KEY*`/`*TOKEN*` variables from MCP child processes, so the Firecrawl
key must be mapped explicitly in the `env:` block — `mcp/verify-mcp.mjs`
reproduces that scrubbing, so a missing mapping fails loudly there too.

### nuclei, on a loopback-only leash

```sh
npm run testapp                       # start the target
npm run nuclei:install                # official release + SHA-256 check
npm run nuclei:scan                   # scan http://127.0.0.1:8787
bash security/nuclei/scan.sh --self-test
```

`scan.sh` refuses anything that isn't `127.0.0.1`, `localhost`, or `[::1]` —
that check is not a toggle, and the self-test proves it rejects
`example.com`, `10.0.0.5`, `192.168.1.1` and a DNS-rebinding style
`127.0.0.1.evil.com`. Destructive template families (`dos`, `fuzz`,
`intrusive`, `brute-force`) are excluded even against the test app.

---

## Security posture

- **Keys** live in `.env` (mode 600, git-ignored). The YAML only ever names the
  variable: `apiKeyEnv: ABLIT_KEY`, `!!js process.env.FIRECRAWL_API_KEY`.
- **The harness home** (`$DSH_HOME`, default `.dsh-home/`) holds credentials and
  session history. It is git-ignored. Nothing is written to `~/.dsh`.
- **The test app is intentionally vulnerable** and binds to loopback only; it
  refuses to start on a non-loopback host. Never expose port 8787.
- **Do not put `DSH_*` variables in `.env`** — dsh reads `.env` itself and
  refuses variables that decide how the process starts. Export them in the
  shell instead.
- `--allowed-origins` on the Playwright MCP server is a convenience fence, not
  a security boundary (upstream says so explicitly; it doesn't constrain
  redirects). Real isolation comes from the container/VM you run this in.

---

## Repo map

```
dsh/cordis.patch.yml            provider routes + MCP servers (the one config)
mcp/verify-mcp.mjs              MCP handshake verifier (--live for real calls)
security/testapp/server.js      intentionally vulnerable local target
security/nuclei/install-nuclei.sh   official binary, checksum-verified
security/nuclei/scan.sh         loopback-only scan wrapper + --self-test
runpod/start-vllm.sh            serve an abliterated model as an OpenAI API
runpod/README.md                serverless vs pod, env vars, costs
research/runpod-abliterated-models.md   step 3: top 3 models + hourly costs
scripts/setup.sh                one-shot install
scripts/start-harness.sh        boot dsh with .env loaded
scripts/verify-all.sh           the PASS/FAIL matrix
```

---

## Troubleshooting

| Symptom | Cause / fix |
| - | - |
| `MISSING_CREDENTIAL` in the harness | `ABLIT_KEY` not exported or still the placeholder. `.env` is read by `scripts/start-harness.sh`. |
| `EADDRINUSE 127.0.0.1:3080` | Another `dsh web` is running: `pkill -f 'dsh web'`, or `DSH_PORT=3081 npm run start`. |
| `DSH_PORT sets ..., which only the launching environment may set` | A `DSH_*` variable is in `.env`. Remove it; export it instead. |
| Firecrawl tools error with 401 | Key missing from the MCP `env:` block, or invalid. `node mcp/verify-mcp.mjs --only firecrawl`. |
| `browser_navigate` fails with "Executable doesn't exist" | `npx playwright install chromium`. |
| `npx` hangs on first MCP start | It is fetching the pinned package once; later runs are cached. `npm install` pre-installs the same versions. |
| Harness shows no tools from a server | `node mcp/verify-mcp.mjs` — if the handshake fails there, it fails in dsh for the same reason. |

Model shortlist and hourly cost analysis: [`research/runpod-abliterated-models.md`](research/runpod-abliterated-models.md).

## Reference

- DeepSeek Harness — <https://github.com/deepseek-ai/deepseek-harness>
- Abliteration API + the official dsh integration guide — <https://docs.abliteration.ai/integrations/deepseek-harness>
- Playwright MCP — <https://github.com/microsoft/playwright-mcp> · CI intro: <https://playwright.dev/docs/ci-intro>
- Firecrawl MCP — <https://docs.firecrawl.dev/mcp-server>
- nuclei — <https://github.com/projectdiscovery/nuclei>
