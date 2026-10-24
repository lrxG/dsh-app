# dsh pairing plugin

**English** | [简体中文](README.zh-CN.md)

<p>
  <a href="https://github.com/lrxG/dsh-app/releases/latest"><img alt="app" src="https://img.shields.io/badge/app-Download%20APK-007AFF"></a>
  <img alt="dsh" src="https://img.shields.io/badge/dsh-0.2.x-4D6BFE">
  <img alt="license" src="https://img.shields.io/github/license/lrxG/dsh-app">
</p>

Adds **dsh → Settings → 扫码配对** with the live pairing QR. Scan it with the Android app to connect over the LAN — including the dsh **Desktop app**, which normally only listens on `127.0.0.1`.

📱 **Android app (APK): [Releases](https://github.com/lrxG/dsh-app/releases/latest)** — app source: [`main` branch](https://github.com/lrxG/dsh-app)

<p align="center">
  <img src="https://raw.githubusercontent.com/lrxG/dsh-app/main/docs/images/paired.jpg" alt="Paired" width="280">
</p>

## Install · Use

**1. Install the plugin**

```powershell
git clone -b plugin https://github.com/lrxG/dsh-app dsh-plugin
```

- **dsh → Plugins → Add plugin** → paste the absolute path of `dsh-plugin` → restart dsh
- or wire it manually (see below)

Requires `pnpm` on PATH. The package declares `dsh.bundle`, so the plugin manager accepts it.

**2. Pair**

1. Open **dsh → Settings → 扫码配对**
2. Scan the QR with the [app](https://github.com/lrxG/dsh-app/releases/latest), or paste the URL under it
3. Done — sessions and models sync in real time

The token rotates on every dsh start, but the app keeps a 30-day signed cookie, so restarts do not require re-scanning.

## What it does

- **Settings page** with the pairing QR (`settings.section`)
- `GET /lanbuddy/pair` — standalone QR page
- `GET /lanbuddy/pair/qr.svg` — QR image (`no-store`)
- `GET /lanbuddy/pair/info` — `{url, host, port, loopback, lan, gateway}`
- `POST /lanbuddy/devices/revoke` — rotate the signing secret (all phones re-pair after restart)
- **LAN gateway** for loopback-only instances

All routes pass `ctx.connection.admit()`, the same Host/cookie fence as `/api`; anonymous requests get **401**.

## How it works

The QR is built from `ctx.connection.authenticatedUrl()`, i.e. the same live launch token dsh prints at startup — never stale.

### LAN gateway

When dsh only listens on loopback (the Desktop app), the plugin binds `<LAN-IP>:3080` (next free port when taken) and proxies **HTTP + WebSocket** to the local dsh, rewriting `Host`/`Origin` to `localhost`. The port-less loopback authority keeps cookies valid across desktop restarts.

- Only starts for loopback-only instances
- `lanGateway: false` disables it; `lanHost` / `lanPort` override the bind
- Security is the same as `--host`: the full dsh surface is exposed to the LAN, gated by token/cookie

## Manual wiring

```powershell
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.dsh\profiles\<profile>\node_modules\dsh-pair" `
  -Target "D:\path\to\dsh-plugin"
```

```yaml
# cordis.patch.yml
- insert:
    - id: lanbuddy-pair
      name: "dsh-lanbuddy-pair"
```

Restart dsh.

## Security

- No new port besides the gateway
- QR/token served only to an authenticated dsh session
- `cache-control: no-store` everywhere
- “Revoke all devices” deletes the `client-connection/browser-session` credential (restart to apply)

## Troubleshooting

| Symptom | Fix |
|---|---|
| No settings entry | Plugin not loaded — check dsh logs, restart |
| Phone: connection refused | Scanned a loopback URL or gateway not running — restart dsh |
| `not-a-bundle` | Old package without `dsh.bundle`; use this branch |
| `EADDRINUSE` | Another instance holds the port; the gateway falls back automatically |

## Uninstall

Remove the bundle in the plugin manager (or delete the patch entry + junction) and restart dsh.

## License

MIT
