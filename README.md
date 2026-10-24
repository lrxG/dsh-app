# dsh-lanbuddy-pair · dsh pairing QR page

**English** · 中文（同一页面双语）

A tiny dsh plugin that adds **Settings → 扫码配对 (Pair)** showing the live pairing QR code. The Android client (**[DSH Companion](https://github.com/lrxG/dsh-companion)** — see the `app` branch / Releases) scans it to connect to this PC over the LAN.

一个很小的 dsh 插件：在 **设置 →「扫码配对」** 里直接显示可扫的配对二维码。手机端（**DSH Companion**，见 `app` 分支 / Releases）扫码即可通过局域网连上这台 PC。

---

## Quick start · 快速开始

**Install the plugin, open Settings → 扫码配对, scan.** That is all — no companion, no `--host` flag.

**装好插件 → 设置 →「扫码配对」→ 扫码即可**，不需要陪伴进程，也不需要手动加 `--host`。

```powershell
# 1) install (dsh plugin manager: Plugins → Add plugin → absolute path; or see below)
# 2) restart dsh if prompted
# 3) Settings → 扫码配对 → scan with the Android app
```

How it works on a loopback-only instance (the Desktop app): the plugin starts a **LAN gateway** that listens on `<LAN-IP>:3080` and proxies HTTP + WebSocket to the local dsh, rewriting Host/Origin so dsh's trust fence still applies. The QR therefore points at the LAN address and the phone can connect — same process, same sessions.

回环实例（桌面应用）也能直接扫：插件会自动在 `<局域网IP>:3080` 开一个 **局域网网关**，把 HTTP/WebSocket 转发给本机 dsh（重写 Host/Origin 以通过信任围栏），二维码指向局域网地址，手机连的就是同一个进程。

> Security: the gateway exposes the whole dsh surface on the LAN, exactly like `--host` does — cookie/token gated. Disable with `lanGateway: false` in the plugin config, or change `lanPort`.
> 安全：网关等同于 `--host`，会把完整 dsh 暴露到局域网（同样要 cookie/token）。可在插件配置里 `lanGateway: false` 关闭，或改 `lanPort`。

**Without the plugin** you can still start dsh yourself: `dsh web --host <LAN-IP> --port 3080`, then scan any QR of the printed URL.
**不装插件**也可以：自己用 `dsh web --host <局域网IP>` 启动，再扫该 URL 的二维码。

The optional `companion/` folder in this branch automates that start if you prefer a terminal QR.
本分支里的 `companion/` 是可选的自动化启动脚本（终端出码）。

## LAN gateway · 局域网网关

- Binds `<LAN-IP>:3080` (falls back to the next free port when taken) · 绑定局域网 3080，占用则自动顺延；
- Proxies every path, including `/api` and the `/api/remote.mux` WebSocket upgrade · 代理全部路径，含 API 与 WS；
- Rewrites `Host`/`Origin` to `127.0.0.1:<dsh-port>` so dsh's fence accepts the request · 重写 Host/Origin 通过围栏；
- Only starts when dsh itself is loopback-bound · 仅当 dsh 只监听回环时启动；
- Config: `{ lanGateway: false }` to disable, `{ lanHost, lanPort }` to override · 配置项关闭/改地址端口。

## What it does · 它做什么

- `GET /lanbuddy/pair` — a standalone page with the QR (open it in any browser) · 独立配对页；
- `GET /lanbuddy/pair/qr.svg` — the QR itself (`image/svg+xml`, `no-store`) · 二维码图片；
- `GET /lanbuddy/pair/info` — `{url, host, port, loopback, lan}` JSON · 配对信息；
- `POST /lanbuddy/devices/revoke` — rotate the browser-session signing secret (all phones must re-pair after a dsh restart) · 解除所有设备（重启 dsh 后生效）；
- A **Settings** section (`settings.section`) that renders the QR · 设置页入口。

The QR encodes exactly the URL dsh prints at startup (`http://<PC-IP>:<port>/?token=…`), read from `ctx.connection.authenticatedUrl()` — so it is always the **current process token**, never stale. All routes use `ctx.connection.admit()`, the same Host/cookie fence as `/api`.

二维码内容取自 `ctx.connection.authenticatedUrl()`（与 dsh 启动横幅同源），永远对应当前进程的 token；所有路由都走 `connection.admit()` 鉴权，匿名请求 401。

## Requirements · 前提

- dsh 0.2.x with the web UI (`dsh web`) · 带 Web UI 的 dsh；
- `pnpm` available on PATH for the plugin manager install · 插件管理器安装需要 PATH 里有 `pnpm`。

## Install · 安装

### Option A — dsh plugin manager (recommended) · 用 dsh 插件管理器（推荐）

1. Put this package somewhere on the PC, e.g. `D:\dsh-lanbuddy-pair` · 把本目录放到 PC 上；
2. dsh → sidebar **插件 (Plugins)** → **添加插件 (Add plugin)** → paste the **absolute path** · 侧栏「插件 → 添加插件」粘贴**绝对路径**；
3. Restart dsh when prompted · 按提示重启 dsh；
4. Open **Settings → 扫码配对** · 打开设置 →「扫码配对」。

> The package declares `dsh.bundle` so the manager accepts it; a package with only `dsh.client` is rejected as `not-a-bundle`.
> 本包声明了 `dsh.bundle`，插件管理器才会接受；只有 `dsh.client` 的包会被判 `not-a-bundle`。

### Option B — manual profile wiring · 手动写 profile

Junction + patch entry in `%USERPROFILE%\.dsh\profiles\<profile>\`:

```powershell
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.dsh\profiles\<profile>\node_modules\dsh-lanbuddy-pair" `
  -Target "D:\dsh-lanbuddy-pair"
```

```yaml
# cordis.patch.yml
- insert:
    - id: lanbuddy-pair
      name: "dsh-lanbuddy-pair"
```

Restart dsh. · 然后重启 dsh。

## Configuration · 配置（可选）

If a **loopback-only** instance (the dsh Desktop app, which binds `127.0.0.1`) should still offer a scannable code, point it at a LAN instance's live pair file:

桌面应用只监听回环，手机连不上。若想让它的设置页也能扫码，可以配置一个局域网实例的配对文件：

```yaml
- id: lanbuddy-pair
  config:
    lanPairFile: "C:/path/to/pair-url.txt"   # rewritten by your companion on every restart
```

The plugin reads the token from that file, verifies it with a `303` grant before showing it, and otherwise shows a warning instead of a dead QR.

插件会从该文件读取 token，并先用 `GET /?token=…` 验证（303 才算有效），无效时显示警告而不是让人白扫。

## Security · 安全

- No new listening port: the plugin only mounts routes on dsh's existing web server; 不新增端口；
- QR/token only served to an authenticated dsh session (cookie); 只对已登录会话提供二维码；
- `cache-control: no-store` on every route; 所有路由不缓存；
- “解除所有设备” deletes the `client-connection/browser-session` credential; restart dsh to apply; 解除所有设备会删除签名凭据，重启生效。

## Troubleshooting · 常见问题

| Symptom | Cause / fix |
|---|---|
| Settings entry missing | Plugin not loaded — check dsh logs for `lanbuddy-pair`; restart dsh · 插件未加载，看日志并重启 |
| QR exists but phone says connection refused | You scanned a loopback instance (`127.0.0.1`) — use the LAN-bound instance · 扫到了回环实例，改用绑定局域网的实例 |
| “手机连不上这个实例” warning | That instance only binds `127.0.0.1`; run `dsh web --host <LAN-IP>` or configure `lanPairFile` · 该实例只监听回环 |
| `not-a-bundle` when installing | Old package without `dsh.bundle`; use this repo's version · 旧包缺 `dsh.bundle` |

## Uninstall · 卸载

Remove the bundle from the plugin manager (or delete the patch entry + junction), then restart dsh.
在插件管理器里删除，或删除 patch 条目与链接后重启 dsh。

## License

MIT
