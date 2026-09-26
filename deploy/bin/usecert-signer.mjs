#!/usr/bin/env node
// Serves the attester's SIGNED attestations so a minter can relay them.
//
// The attester used to broadcast on a timer, which cost ~0.0071 ETH/day to keep an
// idle protocol open and, on 2026-09-20, failed silently for 11.6 hours when the
// wallet ran dry. Here it signs instead: this process holds the key, produces
// signatures, and hands them out. Nothing is broadcast and nothing is spent.
//
// REFRESH CADENCE IS LOAD-BEARING. SolvencyRegistry.SIGNATURE_VALIDITY is 60s, and
// a signature is refused the moment block.timestamp passes its deadline. Signing on
// a 30s cycle means a client always receives one with at least ~30s of life left -
// enough to be relayed inside a user's transaction without racing its own expiry.
// Signing per request instead would put a 5-10s forge run in front of every mint.
import { spawn } from 'node:child_process';
import http from 'node:http';

const PORT = 8787;
const REFRESH_MS = 30_000;
const FORGE = '/home/usecert/.foundry/bin/forge';
const CWD = '/opt/usecert';

let cache = { generatedAt: 0, attestations: [], error: 'not yet generated' };

function sign() {
  return new Promise((resolve) => {
    const p = spawn(FORGE, ['script', 'script/keepers/AttesterSign.s.sol', '--rpc-url', process.env.RPC_URL],
      { cwd: CWD, env: process.env });
    let out = '';
    p.stdout.on('data', d => out += d);
    p.stderr.on('data', d => out += d);
    p.on('close', () => {
      const lines = out.split('\n').map(l => l.replace(/\x1b\[[0-9;]*m/g, '').trim())
        .filter(l => l.startsWith('SIGNED '));
      if (!lines.length) return resolve({ error: 'no signatures produced' });
      try {
        resolve({ attestations: lines.map(l => JSON.parse(l.slice(7))) });
      } catch (e) { resolve({ error: 'unparseable: ' + e.message }); }
    });
    setTimeout(() => { try { p.kill('SIGKILL'); } catch {} }, 60_000);
  });
}

async function refresh() {
  const r = await sign();
  if (r.error) {
    // Keep serving the previous batch rather than nothing: it may still be inside
    // its deadline, and a client can see `ageSec` and decide for itself.
    cache = { ...cache, error: r.error, lastErrorAt: Math.floor(Date.now() / 1000) };
    console.error(`[${new Date().toISOString()}] sign failed: ${r.error}`);
  } else {
    cache = { generatedAt: Math.floor(Date.now() / 1000), attestations: r.attestations, error: null };
    console.log(`[${new Date().toISOString()}] signed ${r.attestations.length} mirrors`);
  }
}

http.createServer((req, res) => {
  const cors = {
    'access-control-allow-origin': '*',            // public, signed, and read-only
    'content-type': 'application/json',
    'cache-control': 'no-store',
  };
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  if (!req.url.startsWith('/attestations')) { res.writeHead(404, cors); return res.end('{"error":"not found"}'); }

  const age = Math.floor(Date.now() / 1000) - cache.generatedAt;
  // A signature older than its validity window is dead on arrival; say so rather
  // than let a client spend gas discovering it.
  const stale = cache.generatedAt === 0 || age > 60;
  res.writeHead(stale ? 503 : 200, cors);
  res.end(JSON.stringify({
    generatedAt: cache.generatedAt,
    ageSec: cache.generatedAt ? age : null,
    validitySec: 60,
    stale,
    error: cache.error,
    attestations: cache.attestations,
  }));
}).listen(PORT, '127.0.0.1', () => console.log(`signer on 127.0.0.1:${PORT}`));

refresh();
setInterval(refresh, REFRESH_MS);
