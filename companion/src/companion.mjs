#!/usr/bin/env node
/**
 * DSH Companion — PC companion (starting dsh on the LAN and printing the pairing QR)
 *
 * - Detects the LAN IPv4 of this PC.
 * - Spawns `dsh web --host <ip> --port <port> --no-open` (official CLI, zero patching).
 * - Watches stdout for the launch line `dsh web: http://<host>:<port>/?token=<t>`
 *   (source of truth: packages/bundle/web-app/src, packages/bundle/web-app/tests/web-app.spec.ts).
 * - Builds the API-pairing URL  {scheme}://{ip}:{port}/connect?token=<t>&interactions=answer
 *   (packages/client/connection/README.md L51 — exchange creates an owner-principal Peer).
 * - Shows it as a console QR + writes a PNG next to this script so it can be
 *   displayed later in a tray window (v0.2).
 * - Restarts dsh if it exits; each restart rotates the token, so the QR refreshes.
 *
 * Docs: ../docs/PROTOCOL.md, ../docs/DESIGN.md
 */

import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { setTimeout as delay } from 'node:timers/promises';

const QR = (await import('qrcode')).default;

// ---------- CLI args ----------
const argv = process.argv.slice(2);
function argValue(name, fallback, flags) {
  if (flags && flags.includes(name)) return true;
  const i = argv.indexOf(name);
  if (i !== -1 && i + 1 < argv.length) return argv[i + 1];
  return fallback;
}

const cfg = {
  port: Number(argValue('--port', '3080')),
  ip: argValue('--ip', null),
  scheme: argValue('--scheme', 'http'), // https 依赖 --tls-cert/--tls-key（v0.2）
  // dsh profile to boot (default: the shipped `web` profile). Use --profile
  // to pick a profile that carries your own LLM plugins/models.
  profile: argValue('--profile', 'web'),
  dshCmd: argValue('--dsh-cmd', null) ?? splitCmd(
    argValue('--dsh', `node ${new URL('../node_modules/@deepseek-ai/dsh/lib/bin.js', import.meta.url).pathname.replace(/^\//, '')} --profile ${argValue('--profile', 'web')}`),
  ),
  extraArgs: [],
  qrFile: null,
};

// split "npx @deepseek-ai/dsh web" style command lines (no quotes needed for our defaults)
function splitCmd(s) {
  if (Array.isArray(s)) return s;
  const m = s.match(/(?:[^\s"]+|"[^"]*")+/g);
  return (m ?? []).map((x) => x.replace(/^"|"$/g, '')).filter(Boolean);
}

// ---------- LAN IP detection ----------
function lanIPv4() {
  if (cfg.ip) return cfg.ip;
  const wsl = /^(169\.254\.|fe80:)/i;
  const filter = (addrs) =>
    addrs.filter((a) => a.family === 'IPv4' && !a.internal && !a.address.startsWith('169.254.'));
  for (const nets of Object.values(os.networkInterfaces())) {
    const usable = filter(nets ?? []);
    // 192.168.x first, then 10.x, then anything else
    usable.sort((a, b) => {
      const rank = (ip) => (ip.startsWith('192.168.') ? 0 : ip.startsWith('10.') ? 1 : 2);
      return rank(a.address) - rank(b.address);
    });
    if (usable[0]) return usable[0].address;
  }
  return '127.0.0.1';
}
const LAN_IP = lanIPv4();

// ---------- stdout parsing ----------
// `dsh web: http://127.0.0.1:4567/?token=test-token`  → token
const DSH_LINE = /dsh web:\s*(\S+)/;
function extractLaunch(line) {
  const m = DSH_LINE.exec(line);
  if (!m) return null;
  const url = m[1];
  const t = /[?&]token=([^&\s]+)/.exec(url);
  return t ? t[1] : null;
}

// ---------- banner / QR ----------
async function banner(pairUrl) {
  clearLastBanner();
  const w = 66;
  const bar = '─'.repeat(w);
  console.log(`┌${bar}┐`);
  const rows = [
    ` DSH Companion · ${new Date().toLocaleTimeString()}`,
    ` LAN IP   : ${LAN_IP}`,
    ` port     : ${cfg.port} (${cfg.scheme})`,
    ` pairing  : scan → owner peer`,
  ];
  for (const r of rows) console.log(`│ ${r.padEnd(w)} │`);
  console.log(`│ ${cut(pairUrl).padEnd(w)} │`);
  console.log(`└${bar}┘`);
  const out = path.join(fileURLToPath(new URL('.', import.meta.url)), 'pair-qr.png');
  await QR.toFile(out, pairUrl, { width: 512 });
  fs.writeFileSync(path.join(path.dirname(out), 'pair-url.txt'), pairUrl, 'utf8');
  console.log(`  QR image : ${out}`);
  console.log('  (PNG 落盘☫，托盘窗 v0.2)');
}

let lastBannerLines = 0;
function clearLastBanner() {
  if (lastBannerLines) {
    process.stdout.moveCursor(0, -lastBannerLines);
    process.stdout.clearScreenDown();
  }
}
function cut(s, n = w) { return s.length <= n ? s : s.slice(0, n - 1) + '…'; }
const w = 63; // bordchar width for url row

// ---------- runner ----------
let dsh = null;
let bannerTimer = null;
let restarting = false;

function killTree() {
  if (!dsh) return;
  if (process.platform === 'win32' && dsh.pid) {
    spawn('taskkill', ['/pid', String(dsh.pid), '/T', '/F'], { stdio: 'ignore' });
  } else {
    try { dsh.kill('SIGTERM'); } catch {}
  }
}

async function main() {
  console.log(`[dsh-companion] lan ip=${LAN_IP} port=${cfg.port}`);
  await spawnDsh();
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
  process.on('exit', () => killTree());
}

async function spawnDsh() {
  const full = [...cfg.dshCmd, '--host', LAN_IP, '--port', String(cfg.port), '--no-open'];
  console.log(`[dsh-companion] spawn: ${full.join(' ')}`);
  dsh = spawn(full[0], full.slice(1), {
    stdio: ['ignore', 'pipe', 'pipe'],
    shell: process.platform === 'win32',
    env: { ...process.env, ELECTRON_RUN_AS_NODE: undefined },
  });
  dsh.stdout.setEncoding('utf8');
  dsh.stderr.setEncoding('utf8');
  dsh.stdout.on('data', (chunk) => handleStream(chunk, dsh));
  dsh.stderr.on('data', (c) => process.stderr.write(withPrefix(c, 'dsh|err] ')));
  dsh.on('exit', (code, sig) => {
    dsh = null;
    if (restarting) return; // shutdown, not a crash
    console.log(`[dsh-companion] dsh exited code=${code} sig=${sig}; restarting in 3s…`);
    setTimeout((_) => spawnDsh().catch(fatal), 3000);
  });
}

function handleStream(chunk, proc) {
  for (const line of chunk.split(/\r?\n/)) {
    process.stdout.write(withPrefix(line + '\n', 'dsh|out] '));
    const token = extractLaunch(line);
    if (token && proc === dsh) scheduleBanner(token);
  }
}

function withPrefix(s, p) {
  return s.split('\n').filter((l) => l.length > 0).map((l) => `[${p}${l}`).join('\n') + '\n';
}

let pendingToken = null;
function scheduleBanner(token) {
  pendingToken = token;
  if (bannerTimer) return;
  bannerTimer = setTimeout(async () => {
    bannerTimer = null;
    if (pendingToken) {
      const pairUrl = `${cfg.scheme}://${LAN_IP}:${cfg.port}/connect?token=${encodeURIComponent(pendingToken)}&interactions=answer`;
      await banner(pairUrl);
    }
  }, 800); // 合并多行输出，取最终一次
}

function shutdown() {
  console.log('\n[dsh-companion] shutting down…');
  restarting = true;
  killTree();
  process.exit(0);
}

function fatal(e) {
  console.error('[dsh-companion] fatal:', e);
  process.exit(1);
}

main().catch(fatal);
