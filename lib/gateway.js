/**
 * A small LAN gateway for a loopback-only dsh instance.
 *
 * The dsh Desktop app binds `127.0.0.1` and cannot be reconfigured. To let a
 * phone reach that very instance, this module listens on the LAN address and
 * transparently proxies HTTP and WebSocket upgrades to the loopback server.
 *
 * dsh's Host/Origin fence accepts loopback authorities, so upstream requests
 * are rewritten to `127.0.0.1:<port>`; the browser/phone still talks to the
 * LAN authority and stores cookies for it. No dsh code is modified.
 */
import { createServer, request as httpRequest } from 'node:http'
import { connect } from 'node:net'

const DEFAULT_ATTEMPTS = 8

/** Rewrite an absolute http(s) URL's authority (used for `Origin`). */
function rewriteOrigin(value, authority) {
  if (typeof value !== 'string' || value === '') return value
  return value.replace(/^https?:\/\/[^/]+/i, `http://${authority}`)
}

/** Upstream headers: drop hop-by-hop Host, pin it to the loopback authority. */
function upstreamHeaders(req, authority) {
  const headers = {}
  for (const [name, value] of Object.entries(req.headers)) {
    const lower = name.toLowerCase()
    if (lower === 'host') continue
    if (lower === 'origin') {
      headers.origin = rewriteOrigin(value, authority)
      continue
    }
    headers[name] = value
  }
  headers.host = authority
  return headers
}

function headerLines(headers) {
  return Object.entries(headers)
    .map(([name, value]) => `${name}: ${Array.isArray(value) ? value.join(', ') : value}`)
    .join('\r\n')
}

/**
 * Start the gateway on the first free port.
 * @param options.host - LAN address to bind.
 * @param options.port - first port to try.
 * @param options.targetHost - loopback dsh host.
 * @param options.targetPort - loopback dsh port.
 * @returns `{server, port, baseUrl}` or null when every port is busy.
 */
export function createLanGateway({ host, port, targetHost = '127.0.0.1', targetPort, attempts = DEFAULT_ATTEMPTS }) {
  // Port-less loopback authority: dsh's fence accepts loopback on any port and
  // the cookie authority stays stable across restarts (the desktop app picks a
  // random port each launch), so phones do not have to re-pair.
  const authority = 'localhost'

  const makeServer = () => {
    const server = createServer((req, res) => {
      const upstream = httpRequest(
        {
          host: targetHost,
          port: targetPort,
          method: req.method,
          path: req.url,
          headers: upstreamHeaders(req, authority),
        },
        (response) => {
          res.writeHead(response.statusCode ?? 502, response.headers)
          response.pipe(res)
        },
      )
      upstream.on('error', () => {
        if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' })
        res.end('lanbuddy gateway: upstream unavailable')
      })
      req.on('error', () => upstream.destroy())
      req.pipe(upstream)
    })

    server.on('upgrade', (req, socket, head) => {
      const upstream = connect(targetPort, targetHost, () => {
        const headers = upstreamHeaders(req, authority)
        upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n${headerLines(headers)}\r\n\r\n`)
        if (head !== undefined && head.length > 0) upstream.write(head)
        socket.pipe(upstream)
        upstream.pipe(socket)
      })
      upstream.on('error', () => socket.destroy())
      socket.on('error', () => upstream.destroy())
    })

    return server
  }

  return new Promise((resolve) => {
    const tryListen = (candidate, left) => {
      const server = makeServer()
      server.once('error', (error) => {
        server.close()
        if (error.code === 'EADDRINUSE' && left > 0) {
          tryListen(candidate + 1, left - 1)
          return
        }
        resolve(null)
      })
      server.listen(candidate, host, () => {
        resolve({ server, port: candidate, baseUrl: `http://${host}:${candidate}/`, host })
      })
    }
    tryListen(port, attempts)
  })
}
