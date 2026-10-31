# Security testing setup

The point of this directory: give the agent **one target you own** so that
"test the site for XSS" never turns into "scan a stranger's website".

## The test app

`testapp/server.js` is a dependency-free Node server on
`http://127.0.0.1:8787`. It is deliberately broken:

| Route | Deliberate flaw |
| - | - |
| `/search?q=` | reflected XSS — the query is interpolated into HTML unescaped |
| `/api/users/:id` | IDOR (any id readable) + stack-trace/path/DSN disclosure on bad input |
| `/admin` | missing authorization, fake admin key in the page |
| `/redirect?next=` | open redirect |
| `/.git/config` | fake "exposed VCS" file, a classic nuclei exposure hit |
| `/login` | no CSRF token, cookie without `HttpOnly`/`Secure`/`SameSite`, no rate limit |
| all responses | `X-Powered-By` version disclosure, permissive CORS, no CSP/HSTS/frame options |

Safety rails, in code:

- the process **refuses to bind** anything that is not loopback (exit code 2);
- no outbound requests, no persistence, no real secrets — the only credentials
  in the app are obvious fakes;
- everything it knows about is generated at boot.

```sh
npm run testapp                      # http://127.0.0.1:8787
TESTAPP_PORT=9000 npm run testapp    # different port
```

## Scanning it

```sh
npm run nuclei:install
npm run nuclei:scan
```

`scan.sh`:

1. validates the target is loopback — `127.0.0.1`, `localhost`, `[::1]` — and
   aborts otherwise. There is no flag to widen this;
2. requires the app to answer `/health`, so a scan never silently targets
   nothing;
3. runs nuclei with `low,medium,high,critical`, excludes
   `dos,fuzz,intrusive,brute-force,file,headless`, and writes JSONL plus a log
   to `security/findings/` (git-ignored);
4. prints a severity histogram and the first hits.

`bash security/nuclei/scan.sh --self-test` asserts the guard accepts loopback
and rejects `example.com`, `10.0.0.5`, `192.168.1.1`, `127.0.0.1.evil.com` and
non-HTTP schemes. It runs as part of `scripts/verify-all.sh`.

## Browser checks

The Playwright MCP server is launched with
`--allowed-origins=http://127.0.0.1:8787;http://localhost:8787`,
`--isolated` (throwaway profile, no saved logins) and `--headless`.

Try, in a harness session:

> Open http://127.0.0.1:8787/search?q=<script>alert(1)</script> and tell me
> whether the payload is reflected unescaped, then check what security headers
> the response is missing.

That exercises `browser_navigate`, `browser_console_messages` and
`browser_evaluate` against a target that cannot be harmed.

## Scope

Only run this tooling against:

- `security/testapp` (this repo), or
- systems you own or have written authorization to test.

The guard in `scan.sh` enforces the first. It cannot enforce the second — if you
delete the guard to scan something else, that decision is yours, and so is the
paperwork.
