/**
 * dsh-lanbuddy-pair — host half.
 *
 * Serves the live pairing QR inside dsh's own web origin:
 *   GET /lanbuddy/pair/qr.svg   the QR (authenticated, no-store)
 *   GET /lanbuddy/pair          a plain page showing the same QR
 *
 * The URL comes from `connection.authenticatedUrl(baseUrl)`, i.e. the SAME
 * per-process launch token dsh prints at startup, so the QR never goes stale.
 * Requests are admitted through `connection.admit`, so a LAN stranger without
 * a cookie gets 401/403 instead of the token.
 */
import { networkInterfaces } from 'node:os'
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { createLanGateway } from './gateway.js'

const require = createRequire(import.meta.url)
// Vendored MIT encoder (qrcode-generator 1.4.4 by Kazuhiko Arase); CommonJS.
const qrcode = require('./qrcode.cjs')

export const name = 'lanbuddy-pair'

/** First non-internal IPv4, used when the listener binds a wildcard. */
function firstLanIPv4() {
  for (const addrs of Object.values(networkInterfaces())) {
    for (const addr of addrs ?? []) {
      if (addr.family === 'IPv4' && !addr.internal) return addr.address
    }
  }
  return undefined
}

/** Loopback-only listeners can never be paired from a phone. */
function isLoopback(host) {
  return host === 'localhost' || host === '::1' || host === '[::1]' || host.startsWith('127.')
}

/** The address the LAN (or loopback-only) instance actually serves on. */
function servedAddress(webServer) {
  const protocol = webServer.protocol === 'https:' ? 'https' : 'http'
  let host = webServer.host
  if (host === undefined || host === '' || host === '0.0.0.0' || host === '::' || host === '[::]') {
    host = firstLanIPv4() ?? '127.0.0.1'
  }
  const display = host.includes(':') && !host.startsWith('[') ? `[${host}]` : host
  const port = webServer.port
  return {
    host,
    port,
    protocol,
    loopback: isLoopback(host),
    url: `${protocol}://${display}${port === undefined || port === null ? '' : `:${port}`}/`,
  }
}

/**
 * The LAN companion's live pair URL, read from the file it rewrites on every
 * restart (`pc-host/src/pair-url.txt`). The Desktop app's own instance binds
 * loopback only (hard-coded by dsh-desktop-host), so its settings page can
 * only offer pairing for that separate, LAN-bound instance — which shares the
 * same session store.
 */
function readCompanionPair(file) {
  try {
    const raw = readFileSync(file, 'utf8').trim()
    const url = new URL(raw)
    const token = url.searchParams.get('token')
    if (token === null || token === '') return null
    return { origin: url.origin, token, url: raw }
  } catch {
    return null
  }
}

/** A grant attempt tells us both reachability and token freshness. */
async function probePair(origin, token) {
  try {
    const response = await fetch(
      `${origin}/?token=${encodeURIComponent(token)}`,
      { redirect: 'manual', signal: AbortSignal.timeout(1200) },
    )
    await response.arrayBuffer().catch(() => undefined)
    return response.status === 303
  } catch {
    return false
  }
}

function qrSvg(url) {
  const qr = qrcode(0, 'M')
  qr.addData(url)
  qr.make()
  return qr.createSvgTag(6, 4, 'LanBuddy', 'LanBuddy')
}

function htmlPage(svg, url) {
  const escaped = url.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  const loopback = isLoopback(new URL(url).hostname.replace(/^\[|\]$/g, ''))
  const body = loopback
    ? `<h1>手机连不上这个实例</h1>
<p>当前 dsh 只监听本机回环地址，手机无法访问。</p>
<div class="warn">请改用绑定局域网地址的实例（例如陪伴进程的
<code>192.168.x.x:3080</code>），在那里打开「设置 → 扫码配对」。</div>
<div class="url">${escaped}</div>`
    : `<h1>用手机扫码连接</h1>
<p>手机与这台 PC 连同一个 WiFi</p>
<div class="qr">${svg}</div>
<div class="url">${escaped}</div>`
  return `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LanBuddy 配对</title>
<style>
 body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
      background:#f2f2f7;font:15px/1.5 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;color:#1c1c1e}
 .card{background:#fff;border-radius:18px;padding:28px 32px;box-shadow:0 8px 30px rgba(0,0,0,.08);text-align:center;max-width:90vw}
 h1{font-size:17px;margin:0 0 4px}
 p{margin:0;color:#8e8e93;font-size:13px}
 .qr{margin:18px auto}
 .warn{margin:16px auto 0;max-width:420px;color:#8a5300;background:#fff6e5;border:1px solid #ffe0a3;
       border-radius:10px;padding:12px 14px;font-size:13px;text-align:left}
 .warn code{background:#fff;border-radius:4px;padding:1px 4px}
 .url{word-break:break-all;font:12px/1.4 ui-monospace,Consolas,monospace;color:#8e8e93;margin-top:10px;max-width:420px}
</style></head>
<body><div class="card">
${body}
</div></body></html>`
}

export function apply(ctx, config) {
  // Optional: point at a companion's live pair URL file so a loopback-only
  // instance (the Desktop app) can still show a scannable code. Without it the
  // page explains why the phone cannot connect.
  const lanPairFile = config?.lanPairFile ?? null
  // LAN gateway: when this dsh only listens on loopback (the Desktop app),
  // expose it on the LAN through a proxy so the phone can pair with THIS
  // instance. Enabled by default; `lanGateway: false` turns it off.
  const gatewayEnabled = config?.lanGateway !== false
  const gatewayHost = config?.lanHost ?? firstLanIPv4()
  const gatewayPort = config?.lanPort ?? 3080

  ctx.inject(['webServer', 'connection', 'credentials'], (scope) => {
    /** Same Host/cookie fence as /api: LAN strangers never see the token. */
    const admit = (req, res) => {
      const admission = scope.connection.admit(req)
      if ('rejection' in admission) {
        res.writeHead(admission.rejection)
        res.end(admission.rejection === 401 ? 'unauthorized' : 'forbidden')
        return false
      }
      return true
    }

    // Loopback-only instance? Publish it on the LAN through the gateway so the
    // QR points at an address the phone can actually reach.
    let gateway = null
    const self = servedAddress(scope.webServer)
    if (gatewayEnabled && self.loopback && gatewayHost) {
      createLanGateway({
        host: gatewayHost,
        port: gatewayPort,
        targetPort: scope.webServer.port,
      })
        .then((started) => {
          if (started === null) return
          gateway = started
          scope.effect(() => () => {
            try {
              started.server.close()
            } catch {
              // already closed
            }
          }, 'lanbuddy-pair: LAN gateway')
          scope.logger?.info?.(
            `lanbuddy-pair: LAN gateway ${started.baseUrl} -> 127.0.0.1:${scope.webServer.port}`,
          )
        })
        .catch(() => {
          // The page falls back to the loopback warning.
        })
    }

    /** Where the phone should connect: the gateway when one is up. */
    const effectiveAddress = () => gateway === null
      ? servedAddress(scope.webServer)
      : { host: gateway.host, port: gateway.port, url: gateway.baseUrl, loopback: false }

    const serve = (kind) => async (req, res) => {
      if (!admit(req, res)) return
      let address
      let url
      let lan = null
      try {
        address = effectiveAddress()
        url = scope.connection.authenticatedUrl(address.url)
      } catch (error) {
        res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' })
        res.end(`LanBuddy: cannot build the pairing URL: ${error}`)
        return
      }

      // A loopback-only instance (the Desktop app) can still hand the phone a
      // working code when a companion's live pair file is configured.
      if (address.loopback && lanPairFile !== null) {
        const pair = readCompanionPair(lanPairFile)
        if (pair !== null) {
          const reachable = await probePair(pair.origin, pair.token)
          lan = {
            url: `${pair.origin}/?token=${encodeURIComponent(pair.token)}`,
            origin: pair.origin,
            reachable,
          }
          if (reachable) url = lan.url
        }
      }

      if (kind === 'info') {
        res.writeHead(200, {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
          'referrer-policy': 'no-referrer',
        })
        res.end(JSON.stringify({
          url,
          host: address.host,
          port: address.port ?? null,
          loopback: address.loopback,
          lan,
          gateway: gateway === null
            ? null
            : { host: gateway.host, port: gateway.port },
        }))
        return
      }
      if (kind === 'svg') {
        res.writeHead(200, {
          'content-type': 'image/svg+xml; charset=utf-8',
          'cache-control': 'no-store',
          'referrer-policy': 'no-referrer',
        })
        res.end(qrSvg(url))
        return
      }
      res.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
      })
      res.end(htmlPage(qrSvg(url), url))
    }

    scope.effect(() => scope.webServer.register({
      kind: 'exact',
      path: '/lanbuddy/pair/info',
      handler: serve('info'),
    }), 'lanbuddy-pair: info route')
    scope.effect(() => scope.webServer.register({
      kind: 'exact',
      path: '/lanbuddy/pair/qr.svg',
      handler: serve('svg'),
    }), 'lanbuddy-pair: qr route')
    scope.effect(() => scope.webServer.register({
      kind: 'exact',
      path: '/lanbuddy/pair',
      handler: serve('page'),
    }), 'lanbuddy-pair: page route')

    // Revoke every paired device: delete the browser-session signing secret.
    // The running process keeps its in-memory copy, so dsh must restart before
    // the revocation takes effect (the next boot mints a new secret).
    scope.effect(() => scope.webServer.register({
      kind: 'exact',
      path: '/lanbuddy/devices/revoke',
      handler: async (req, res) => {
        if (req.method !== 'POST') {
          res.writeHead(405, { allow: 'POST' })
          res.end()
          return
        }
        if (!admit(req, res)) return
        try {
          await scope.credentials.deleteRecord('client-connection/browser-session')
          res.writeHead(200, {
            'content-type': 'application/json; charset=utf-8',
            'cache-control': 'no-store',
          })
          res.end(JSON.stringify({ ok: true, restartRequired: true }))
        } catch (error) {
          res.writeHead(500, { 'content-type': 'application/json; charset=utf-8' })
          res.end(JSON.stringify({ ok: false, error: String(error) }))
        }
      },
    }), 'lanbuddy-pair: device revoke route')
  })
}
