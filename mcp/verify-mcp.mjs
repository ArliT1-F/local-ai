#!/usr/bin/env node
/**
 * verify-mcp.mjs -- prove that every MCP server declared in dsh/cordis.patch.yml
 * actually connects and publishes tools.
 *
 * It reads the *real* config the harness uses, so a pass here means the same
 * command + args + env dsh will spawn does complete an MCP handshake:
 *
 *     initialize -> tools/list
 *
 * Faithful to dsh's stdio behaviour:
 *   - ambient variables matching /KEY|PASSWORD|SECRET|TOKEN/i and DSH_* are
 *     scrubbed before the configured env is merged on top, exactly like
 *     @deepseek-ai/dsh-mcp-client does. If you forget to map a key into the
 *     `env:` block, this script fails the same way the harness would.
 *   - `!!js process.env.NAME` values are resolved by *name only* (no eval).
 *
 * Usage:
 *   node mcp/verify-mcp.mjs                # all servers: handshake + tools/list
 *   node mcp/verify-mcp.mjs --live         # also make one real tool call per server
 *   node mcp/verify-mcp.mjs --only playwright
 *   node mcp/verify-mcp.mjs --json         # machine-readable
 *   node mcp/verify-mcp.mjs --list         # show parsed config, spawn nothing
 *
 * Exit code: 0 = every server connected, 1 = at least one failed.
 */
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import process from 'node:process';

import { parse } from 'yaml';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const PATCH_FILE = resolve(ROOT, 'dsh/cordis.patch.yml');
const MCP_PLUGIN = '@deepseek-ai/dsh-mcp-client';
const HANDSHAKE_TIMEOUT_MS = 90_000;
const SCRUB = /KEY|PASSWORD|SECRET|TOKEN/i;

/**
 * One cheap real call per server, used by --live. A handshake only proves the
 * process starts; these prove the credential and the browser actually work.
 * `firecrawl_search` bills a tiny amount of credit -- that is the point.
 */
const TESTAPP_URL = process.env.TESTAPP_URL ?? 'http://127.0.0.1:8787';

/** Is the local test app up right now? It is optional, so don't fail on it. */
async function reachable(url) {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(1500) });
    return res.status < 500;
  } catch {
    return false;
  }
}

const LIVE_CHECKS = {
  // The test app is optional (step 8 SKIPs it when it isn't running), so a
  // stopped test app must not look like a broken browser: fall back to a
  // data: URL, which still proves the browser launched and rendered a page.
  playwright: async () => ({
    tool: 'browser_navigate',
    args: {
      url: (await reachable(TESTAPP_URL)) ? TESTAPP_URL : 'data:text/html,<h1>mcp verify</h1>',
    },
  }),
  firecrawl: async () => ({ tool: 'firecrawl_search', args: { query: 'example.com', limit: 1 } }),
};

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const option = (name) => {
  const i = argv.indexOf(`--${name}`);
  return i === -1 ? undefined : argv[i + 1];
};

/** `!!js` stays literal so nothing is evaluated twice. */
const jsTag = { tag: 'tag:yaml.org,2002:js', resolve: (value) => ({ $js: String(value) }) };

async function loadPatch(file) {
  const text = await readFile(file, 'utf8');
  const doc = parse(text, { customTags: [jsTag] });
  if (!Array.isArray(doc)) throw new Error(`${file}: expected a top-level YAML array`);

  const entries = [];
  for (const row of doc) {
    if (row?.name === MCP_PLUGIN) entries.push(row);
    for (const child of row?.insert ?? []) {
      if (child?.name === MCP_PLUGIN) entries.push(child);
    }
  }
  return entries;
}

/** Resolve the small, documented subset of `!!js` we allow in env values. */
function resolveEnvValue(key, value) {
  if (value && typeof value === 'object' && '$js' in value) {
    const expr = value.$js.trim();
    const m = /^process\.env\.([A-Za-z_][A-Za-z0-9_]*)$/.exec(expr);
    if (!m) throw new Error(`env.${key}: unsupported !!js expression "${expr}" (use process.env.NAME)`);
    const resolved = process.env[m[1]];
    if (resolved === undefined) throw new Error(`env.${key}: process.env.${m[1]} is not set (put it in .env)`);
    return resolved;
  }
  return String(value);
}

function buildEnv(configured = {}) {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (SCRUB.test(k) || k.startsWith('DSH_')) continue; // dsh scrubs these
    env[k] = v;
  }
  for (const [k, v] of Object.entries(configured)) env[k] = resolveEnvValue(k, v);
  return env;
}

function describe(entry) {
  const c = entry.config;
  const where = c.transport === 'stdio' ? `${c.command} ${(c.args ?? []).join(' ')}` : c.url;
  return `${c.serverName} [${c.transport}] ${where}`;
}

async function verify(entry) {
  const c = entry.config;
  const name = c.serverName;
  let transport;
  try {
    transport =
      c.transport === 'stdio'
        ? new StdioClientTransport({
            command: c.command,
            args: c.args ?? [],
            env: buildEnv(c.env),
            cwd: ROOT,
            stderr: 'pipe',
          })
        : new StreamableHTTPClientTransport(new URL(c.url), {
            requestInit: { headers: c.headers ?? {} },
          });
  } catch (err) {
    return { server: name, ok: false, detail: `config: ${err.message}` };
  }

  if (c.transport === 'stdio') {
    // keep the child's stderr for diagnosis, but never leak a token
    transport.stderr?.on('data', (chunk) => {
      const line = String(chunk).trim().split('\n').pop();
      if (line) console.error(`    [${name}] ${line.slice(0, 300)}`);
    });
  }

  const client = new Client({ name: 'dsh-mcp-verify', version: '1.0.0' }, { capabilities: {} });
  const started = Date.now();
  try {
    await Promise.race([
      client.connect(transport),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`handshake timed out after ${HANDSHAKE_TIMEOUT_MS / 1000}s`)), HANDSHAKE_TIMEOUT_MS),
      ),
    ]);
    const info = client.getServerVersion?.() ?? {};
    const { tools } = await client.listTools();

    let liveNote = '';
    const live = flag('live') ? await LIVE_CHECKS[name]?.() : undefined;
    if (live) {
      const known = tools.some((t) => t.name === live.tool);
      if (!known) throw new Error(`live check: tool "${live.tool}" not published by the server`);
      // MCP wire params are { name, arguments } -- passing the internal
      // { tool, args } shape here makes the server reject the request with
      // "expected string, received undefined" at params.name (-32602/-32603).
      const call = await client.callTool(
        { name: live.tool, arguments: live.args },
        undefined,
        { timeout: 120_000 },
      );
      if (call.isError) {
        const text = (call.content ?? []).map((c) => c.text ?? '').join(' ').slice(0, 300);
        throw new Error(`live check: ${live.tool} failed -- ${text}`);
      }
      liveNote = `, live call ${live.tool} OK`;
    }

    return {
      server: name,
      ok: true,
      detail: `${tools.length} tools in ${Date.now() - started}ms (server: ${info.name ?? '?'} ${info.version ?? ''})${liveNote}`.trim(),
      tools: tools.map((t) => t.name),
    };
  } catch (err) {
    return { server: name, ok: false, detail: err.message };
  } finally {
    await client.close().catch(() => {});
  }
}

const entries = await loadPatch(PATCH_FILE);
const only = option('only');
const selected = only ? entries.filter((e) => e.config?.serverName === only) : entries;

if (!entries.length) {
  console.error(`No ${MCP_PLUGIN} rows found in ${PATCH_FILE}`);
  process.exit(1);
}
if (only && !selected.length) {
  console.error(`No MCP server named "${only}". Known: ${entries.map((e) => e.config.serverName).join(', ')}`);
  process.exit(1);
}

if (flag('list')) {
  for (const entry of selected) console.log(describe(entry));
  process.exit(0);
}

if (!flag('json')) {
  console.log(`MCP servers declared in dsh/cordis.patch.yml — verifying ${selected.length}\n`);
}

const results = await Promise.all(
  selected.map(async (entry) => {
    if (!flag('json')) console.log(`-> ${describe(entry)}`);
    const result = await verify(entry);
    if (!flag('json')) {
      console.log(`   ${result.ok ? 'PASS' : 'FAIL'}  ${result.detail}`);
      if (result.tools?.length) {
        const sample = result.tools.slice(0, 8).join(', ');
        const more = result.tools.length > 8 ? ', …' : '';
        console.log(`         ${sample}${more}`);
      }
      console.log('');
    }
    return result;
  }),
);

if (flag('json')) {
  console.log(JSON.stringify(results, null, 2));
} else {
  const failed = results.filter((r) => !r.ok);
  console.log(failed.length ? `FAILED: ${failed.map((r) => r.server).join(', ')}` : 'All MCP servers connected.');
}

process.exit(results.every((r) => r.ok) ? 0 : 1);
