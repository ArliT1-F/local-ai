#!/usr/bin/env node
/**
 * Local test app for the harness's security tooling (Playwright MCP + nuclei).
 *
 * !! INTENTIONALLY VULNERABLE. IT MUST NEVER BE EXPOSED. !!
 *
 * It exists so the agent has a *disposable target you own* to point browser
 * automation and vulnerability scans at, instead of the public internet.
 * Every flaw here is deliberate and documented in security/README.md.
 *
 * Hard rules enforced in code:
 *   - binds to a loopback address only (127.0.0.1 / ::1 / localhost)
 *   - no outbound network calls, no persistence, no real credentials
 *   - fake secrets only, and they are obviously fake
 *
 * Zero dependencies: `node security/testapp/server.js`
 */
import { createServer } from 'node:http';
import process from 'node:process';

const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost', '::ffff:127.0.0.1']);
const HOST = process.env.TESTAPP_HOST ?? '127.0.0.1';
const PORT = Number(process.env.TESTAPP_PORT ?? process.argv[2] ?? 8787);

if (!LOOPBACK.has(HOST)) {
  console.error(`refusing to bind ${HOST}: this app is only allowed on loopback`);
  process.exit(2);
}

// Deliberately weak fixtures. Nothing here is a real credential.
const USERS = {
  1: { id: 1, name: 'Ada', role: 'user', email: 'ada@example.test', ssn: '000-00-0001' },
  2: { id: 2, name: 'Grace', role: 'admin', email: 'grace@example.test', ssn: '000-00-0002' },
};

const page = (title, body) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>${title}</title></head>
<body>
<h1>${title}</h1>
${body}
<hr>
<small>local-ai deliberately vulnerable test app — do not expose</small>
</body></html>`;

const routes = {
  '/': (req, res) => {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(
      page(
        'Acme Test App',
        `<ul>
          <li><a href="/search?q=hello">Search (reflected XSS)</a></li>
          <li><a href="/api/users/2">/api/users/2 (IDOR / verbose errors)</a></li>
          <li><a href="/admin">/admin (missing authz)</a></li>
          <li><a href="/redirect?next=https://example.com">/redirect (open redirect)</a></li>
          <li><a href="/.git/config">/.git/config (exposed file)</a></li>
          <li><a href="/login">/login (no CSRF token)</a></li>
        </ul>`,
      ),
    );
  },

  // Reflected XSS + missing output encoding.
  '/search': (req, res, url) => {
    const q = url.searchParams.get('q') ?? '';
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(page('Search', `<p>You searched for: ${q}</p><p>No results.</p>`));
  },

  // IDOR: any id is readable, and the response leaks internals.
  '/api/users': (req, res, url) => {
    const id = url.pathname.split('/').pop();
    if (!/^\d+$/.test(id)) {
      res.writeHead(500, { 'content-type': 'application/json' });
      return res.end(
        JSON.stringify({
          error: 'invalid id',
          // deliberate stack-trace / path disclosure
          stack: `TypeError: Cannot read properties of undefined (reading 'name')
    at /srv/app/src/routes/users.js:42:19
    at Layer.handle [as handle_request] (/srv/app/node_modules/express/lib/router/layer.js:95:5)
    db: postgres://app:hunter2@10.0.0.7:5432/prod`,
        }),
      );
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(USERS[id] ?? { error: 'not found' }));
  },

  // Broken access control: admin surface served to anyone.
  '/admin': (req, res) => {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(
      page(
        'Admin',
        `<p>Welcome, administrator.</p>
         <table><tr><th>Key</th><td>FAKE-admin-api-key-do-not-use</td></tr>
         <tr><th>Users</th><td>${Object.keys(USERS).length}</td></tr></table>`,
      ),
    );
  },

  // Open redirect.
  '/redirect': (req, res, url) => {
    res.writeHead(302, { location: url.searchParams.get('next') ?? '/' });
    res.end();
  },

  // Fake "exposed VCS" file: a classic nuclei exposure template hit.
  '/.git/config': (req, res) => {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = https://example.test/acme/app.git\n');
  },

  // No CSRF token, no rate limit, permissive cookie, any password accepted.
  '/login': (req, res) => {
    res.writeHead(200, {
      'content-type': 'text/html',
      'set-cookie': 'session=fake-session-token; Path=/', // no HttpOnly, no Secure, no SameSite
    });
    res.end(
      page(
        'Sign in',
        `<form method="POST" action="/login">
           <input name="username" placeholder="username">
           <input name="password" type="password" placeholder="password">
           <button>Sign in</button>
         </form>`,
      ),
    );
  },

  '/robots.txt': (req, res) => {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('User-agent: *\nDisallow: /admin\nDisallow: /api\n');
  },

  '/health': (req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, app: 'local-ai-testapp', hosts: USERS }));
  },
};

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? `${HOST}:${PORT}`}`);
  const path = url.pathname;

  // Weak headers on purpose: no CSP, no HSTS, no X-Frame-Options.
  res.setHeader('x-powered-by', 'Express/4.18.2'); // version disclosure
  res.setHeader('access-control-allow-origin', '*'); // permissive CORS

  console.log(`${new Date().toISOString()} ${req.method} ${path}${url.search}`);

  const handler = routes[path] ?? (path.startsWith('/api/users/') ? routes['/api/users'] : undefined);
  if (!handler) {
    res.writeHead(404, { 'content-type': 'text/html' });
    return res.end(page('Not found', `<p>${path} not found</p>`));
  }
  try {
    handler(req, res, url);
  } catch (err) {
    res.writeHead(500, { 'content-type': 'text/plain' });
    res.end(String(err?.stack ?? err));
  }
});

server.listen(PORT, HOST, () => {
  console.log(`test app listening on http://${HOST}:${PORT}`);
  console.log('INTENTIONALLY VULNERABLE — loopback only, never expose this port.');
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    console.log(`\n${signal}: shutting down`);
    server.close(() => process.exit(0));
  });
}
