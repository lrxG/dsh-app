# dsh pairing plugin · dsh 扫码配对插件

**English · 中文（同一页面双语）**

Adds **dsh → Settings → 扫码配对** with the live pairing QR. The Android app (**[dsh app](https://github.com/lrxG/dsh-app)** — see its `main` branch / Releases) scans it to connect over the LAN.

在 **dsh → 设置 →「扫码配对」** 里显示可扫的配对二维码。手机端（**dsh app**，见其 `main` 分支 / Releases）扫码即通过局域网连接。

---

## Install · 安装

### dsh plugin manager (recommended) · 用 dsh 插件管理器（推荐）

1. Put this package on the PC · 把本目录放到 PC 上；
2. dsh → **插件 (Plugins)** → **添加插件 (Add plugin)** → paste the **absolute path** · 粘贴绝对路径；
3. Restart dsh when prompted · 按提示重启 dsh；
4. Open **Settings → 扫码配对** · 打开设置 →「扫码配对」。

> The package declares `dsh.bundle`, so the manager accepts it. Requires `pnpm` on PATH.
> 本包声明了 `dsh.bundle`，管理器才会安装；需要 PATH 里有 `pnpm`。

### Manual profile wiring · 手动写 profile

```powershell
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.dsh\profiles\<profile>\node_modules\dsh-pair" `
  -Target "D:\path\to\dsh-pair"
```

```yaml
# cordis.patch.yml
- insert:
    - id: lanbuddy-pair
      name: "dsh-lanbuddy-pair"
```

Restart dsh. · 然后重启 dsh。

## What it does · 它做什么

- **Settings section** rendering the QR · 设置页入口，直接显示二维码；
- `GET /lanbuddy/pair` — standalone QR page · 独立配对页；
- `GET /lanbuddy/pair/qr.svg` — the QR (`image/svg+xml`, `no-store`) · 二维码图片；
- `GET /lanbuddy/pair/info` — `{url, host, port, loopback, lan, gateway}` · 配对信息；
- `POST /lanbuddy/devices/revoke` — rotate the browser-session signing secret (all phones must re-pair after restart) · 解除所有设备（重启生效）；
- **LAN gateway** (below) · 局域网网关。

The QR encodes `http://<LAN-IP>:<port>/?token=…` from `ctx.connection.authenticatedUrl()` — always the current process token, never stale. Every route uses `ctx.connection.admit()` (401 without a cookie).

二维码取自 `ctx.connection.authenticatedUrl()`（与 dsh 启动横幅同源），永远对应当前进程；所有路由都过 `connection.admit()` 鉴权。

## LAN gateway · 局域网网关

When dsh only listens on loopback (the Desktop app), the plugin listens on `<LAN-IP>:3080` (next free port when taken) and proxies HTTP + WebSocket to the local dsh, rewriting `Host`/`Origin` to `localhost`. The port-less loopback authority keeps the cookie stable across desktop restarts.

当 dsh 只监听回环（桌面应用）时，插件在 `<局域网IP>:3080` 起监听（占用则顺延），代理 HTTP 与 WebSocket，并把 `Host`/`Origin` 重写为 `localhost`；无端口的回环 authority 让 cookie 在桌面应用重启后依然有效。

- Only starts for loopback-only instances · 仅对回环实例启动；
- Config: `lanGateway: false` to disable, `lanHost` / `lanPort` to override · 可关闭/改地址端口；
- Security: equivalent to `--host` — exposes the full dsh surface to the LAN, cookie/token gated · 等同于 `--host`，同样受 cookie/token 保护。

## Security · 安全

- No extra port beyond the gateway · 除网关外不新增端口；
- QR/token only served to an authenticated dsh session · 二维码只提供给已登录会话；
- `cache-control: no-store` on every route · 所有路由不缓存；
- “解除所有设备” deletes the `client-connection/browser-session` credential; restart dsh to apply · 解绑会删除签名凭据，重启生效。

## Troubleshooting · 常见问题

| Symptom | Cause / fix |
|---|---|
| Settings entry missing | Plugin not loaded — check dsh logs and restart · 插件未加载，看日志并重启 |
| Phone says connection refused | Scanned a loopback URL; restart dsh so the gateway is active · 扫到回环地址，重启 dsh 让网关生效 |
| `not-a-bundle` | The package lacks `dsh.bundle`; use this version · 旧包缺 `dsh.bundle` |
| Address already in use | Another dsh instance holds 3080; the plugin falls back to 3081 · 端口被占，自动顺延 |

## Uninstall · 卸载

Remove the bundle in the plugin manager (or delete the patch entry + junction), then restart dsh.
在插件管理器里删除，或删除 patch 条目与联接后重启 dsh。

## License

MIT
