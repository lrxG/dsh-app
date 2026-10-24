# dsh pairing plugin · dsh 扫码配对插件

<p>
  <a href="https://github.com/lrxG/dsh-app/releases/latest"><img alt="app" src="https://img.shields.io/badge/app-Download%20APK-007AFF"></a>
  <img alt="dsh" src="https://img.shields.io/badge/dsh-0.2.x-4D6BFE">
  <img alt="license" src="https://img.shields.io/github/license/lrxG/dsh-app">
</p>

**English** · **中文**（同一页面双语）

Adds **dsh → Settings → 扫码配对** with the live pairing QR. Scan it with the Android app to connect over the LAN — including the dsh **Desktop app**, which normally only listens on `127.0.0.1`.

在 **dsh → 设置 →「扫码配对」** 里显示可扫的配对二维码。用安卓 App 扫码即可通过局域网连接——**桌面应用**（平时只监听 `127.0.0.1`）也可以。

📱 **Android app (APK): [Releases](https://github.com/lrxG/dsh-app/releases/latest)** · App 源码：[`main` branch](https://github.com/lrxG/dsh-app)

<p align="center">
  <img src="https://raw.githubusercontent.com/lrxG/dsh-app/main/docs/images/paired.jpg" alt="Paired" width="280">
</p>

---

## Install · 安装

### A. dsh plugin manager (recommended) · 用插件管理器（推荐）

```powershell
git clone -b plugin https://github.com/lrxG/dsh-app dsh-plugin
```

1. dsh → **插件 (Plugins)** → **添加插件 (Add plugin)** · dsh → 插件 → 添加插件；
2. Paste the **absolute path** `…\dsh-plugin` · 粘贴该目录的绝对路径；
3. Restart dsh when prompted · 按提示重启 dsh；
4. Open **Settings → 扫码配对** · 打开设置 →「扫码配对」。

> Requires `pnpm` on PATH. The package declares `dsh.bundle`, so the manager accepts it.
> 需要 PATH 里有 `pnpm`；本包声明了 `dsh.bundle`。

### B. Manual profile wiring · 手动接线

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

Restart dsh. · 然后重启 dsh。

## Use · 使用

1. Open **dsh → Settings → 扫码配对** · 打开设置 →「扫码配对」；
2. Scan the QR with the **DeepSeek Harness** app (or paste the URL under it) · 用 App 扫码或粘贴链接；
3. Done — sessions and models sync in real time · 完成，会话与模型实时同步。

The QR encodes `http://<LAN-IP>:<port>/?token=…`; the token rotates on every dsh start, but the app keeps a 30-day signed cookie, so **restarts do not require re-scanning**.
二维码内容形如 `http://<局域网IP>:<port>/?token=…`；token 每次启动轮换，但 App 保存 30 天签名 cookie，**重启无需重扫**。

## What it does · 它做了什么

- **Settings page**: renders the pairing QR (`settings.section`) · 设置页显示二维码；
- `GET /lanbuddy/pair` — standalone QR page · 独立配对页；
- `GET /lanbuddy/pair/qr.svg` — QR image (`no-store`) · 二维码图片；
- `GET /lanbuddy/pair/info` — `{url, host, port, loopback, lan, gateway}` · 配对信息；
- `POST /lanbuddy/devices/revoke` — rotate the signing secret (all phones re-pair after restart) · 解除所有设备；
- **LAN gateway** for loopback-only instances · 给回环实例用的局域网网关。

## How it works · 原理

The QR is built from `ctx.connection.authenticatedUrl()`, i.e. the **same live launch token** dsh prints at startup — never stale. Every route passes `ctx.connection.admit()`, the same Host/cookie fence as `/api`; anonymous requests receive **401**.

二维码取自 `ctx.connection.authenticatedUrl()`（与 dsh 启动横幅同源），永远对应当前进程；所有路由都过 `connection.admit()` 鉴权，匿名 401。

### LAN gateway · 局域网网关

When dsh only listens on loopback (the Desktop app), the plugin binds `<LAN-IP>:3080` (next free port when taken) and proxies **HTTP + WebSocket** to the local dsh, rewriting `Host`/`Origin` to `localhost`. The port-less loopback authority keeps cookies valid across desktop restarts.

当 dsh 只监听回环（桌面应用）时，插件在 `<局域网IP>:3080` 起监听（占用则顺延），代理 **HTTP 与 WebSocket**，并把 `Host`/`Origin` 重写为 `localhost`；无端口的回环 authority 让 cookie 在桌面应用重启后仍有效。

- Only starts for loopback-only instances · 仅对回环实例启动；
- `lanGateway: false` disables it; `lanHost` / `lanPort` override the bind · 可关闭或改地址端口；
- Security is the same as `--host`: the full dsh surface is exposed to the LAN, gated by token/cookie · 安全性等同 `--host`，同样受 token/cookie 保护。

## Security · 安全

- No new port besides the gateway · 除网关外不新增端口；
- QR/token served only to an authenticated dsh session · 二维码只给已登录会话；
- `cache-control: no-store` everywhere · 全部不缓存；
- “解除所有设备” deletes the `client-connection/browser-session` credential (restart to apply) · 解绑删除签名凭据，重启生效。

## Troubleshooting · 常见问题

| Symptom | Fix |
|---|---|
| No settings entry · 设置里没有入口 | Plugin not loaded — check dsh logs, restart · 插件未加载，查看日志并重启 |
| Phone: connection refused · 手机连不上 | Scanned a loopback URL or gateway not running — restart dsh · 扫到回环地址或网关未启动，重启 dsh |
| `not-a-bundle` | Old package without `dsh.bundle`; use this branch · 使用本分支版本 |
| `EADDRINUSE` | Another instance holds the port; the gateway falls back automatically · 端口被占，自动顺延 |

## Uninstall · 卸载

Remove the bundle in the plugin manager (or delete the patch entry + junction) and restart dsh.
在插件管理器里删除，或删除 patch 条目与联接后重启 dsh。

## License

MIT
