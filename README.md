# dsh 扫码配对插件

**简体中文** | [English](README.en.md)

<p>
  <a href="https://github.com/lrxG/dsh-app/releases/latest"><img alt="app" src="https://img.shields.io/badge/app-%E4%B8%8B%E8%BD%BD%20APK-007AFF"></a>
  <img alt="dsh" src="https://img.shields.io/badge/dsh-0.2.x-4D6BFE">
  <img alt="license" src="https://img.shields.io/github/license/lrxG/dsh-app">
</p>

在 **dsh → 设置 →「扫码配对」** 里显示可扫的配对二维码。用安卓 App 扫码即可通过局域网连接——**桌面应用**（平时只监听 `127.0.0.1`）也可以。

📱 **安卓 App（APK）：[Releases](https://github.com/lrxG/dsh-app/releases/latest)** —— App 源码：[`main` 分支](https://github.com/lrxG/dsh-app)

<p align="center">
  <img src="https://raw.githubusercontent.com/lrxG/dsh-app/main/docs/images/paired.jpg" alt="配对成功" width="280">
</p>

## 安装与使用

**1. 安装插件**

```powershell
git clone -b plugin https://github.com/lrxG/dsh-app dsh-plugin
```

- **dsh → 插件 → 添加插件** → 粘贴 `dsh-plugin` 的绝对路径 → 重启 dsh；
- 或按下面的「手动接线」写入 profile。

需要 PATH 里有 `pnpm`；本包声明了 `dsh.bundle`，插件管理器才会安装。

没装过 `pnpm` 的话：先装 [Node.js LTS](https://nodejs.org/)（一路 Next），然后在 **PowerShell** 里执行 `npm install -g pnpm`，重开终端后 `pnpm -v` 有版本号即可。官方说明：[pnpm.io/installation](https://pnpm.io/installation)。

**2. 配对**

1. 打开 **dsh → 设置 →「扫码配对」**；
2. 用 [App](https://github.com/lrxG/dsh-app/releases/latest) 扫二维码，或粘贴二维码下方的链接；
3. 完成，会话与模型实时同步。

token 每次启动轮换，但 App 保存 30 天签名 cookie，**重启无需重扫**。

## 它做了什么

- **设置页**显示配对二维码（`settings.section`）
- `GET /lanbuddy/pair` —— 独立配对页
- `GET /lanbuddy/pair/qr.svg` —— 二维码图片（`no-store`）
- `GET /lanbuddy/pair/info` —— `{url, host, port, loopback, lan, gateway}`
- `POST /lanbuddy/devices/revoke` —— 解除所有设备（轮换签名密钥，重启生效）
- 给回环实例用的**局域网网关**

所有路由都过 `ctx.connection.admit()`（与 `/api` 同一套 Host/cookie 围栏），匿名请求一律 **401**。

## 原理

二维码取自 `ctx.connection.authenticatedUrl()`——就是 dsh 启动时打印的当前 launch token，永远是最新有效的。

### 局域网网关

当 dsh 只监听回环（桌面应用）时，插件在 `<局域网IP>:3080` 起监听（占用则自动顺延），把 **HTTP 与 WebSocket** 转发给本机 dsh，并把 `Host`/`Origin` 重写为 `localhost`；无端口的回环 authority 让 cookie 在桌面应用重启后仍有效。

- 仅对回环实例启动；
- `lanGateway: false` 可关闭，`lanHost` / `lanPort` 可改地址端口；
- 安全性等同 `--host`：完整 dsh 暴露到局域网，但受 token/cookie 保护。

## 手动接线

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

然后重启 dsh。

## 安全

- 除网关外不新增端口；
- 二维码/token 只提供给已登录的 dsh 会话；
- 所有路由 `cache-control: no-store`；
- 「解除所有设备」会删除 `client-connection/browser-session` 凭据（重启生效）。

## 常见问题

| 现象 | 处理 |
|---|---|
| 设置里没有入口 | 插件未加载——查看 dsh 日志并重启 |
| 手机提示连接被拒绝 | 扫到了回环地址，或网关未启动——重启 dsh |
| `not-a-bundle` | 旧包缺少 `dsh.bundle`，使用本分支版本 |
| `EADDRINUSE` | 端口被其他实例占用，网关会自动顺延 |

## 卸载

在插件管理器里删除，或删除 patch 条目与联接，然后重启 dsh。

## 许可证

MIT
