# DeepSeek Harness · dsh app

<p>
  <img alt="platform" src="https://img.shields.io/badge/platform-Android-3ddc84">
  <img alt="flutter" src="https://img.shields.io/badge/Flutter-3.x-02569B">
  <a href="../../releases/latest"><img alt="release" src="https://img.shields.io/github/v/release/lrxG/dsh-app"></a>
  <img alt="license" src="https://img.shields.io/github/license/lrxG/dsh-app">
</p>

**English** · **中文**（同一页面双语）

An Android client for **DeepSeek Harness (dsh)** plus a **dsh plugin that puts the pairing QR right inside dsh settings**. Scan once, then read and continue your sessions from the phone — over your own LAN, no cloud relay, no account.

**DeepSeek Harness (dsh)** 的 Android 客户端，外加一个**把配对二维码放进 dsh 设置的插件**。扫一次码，就能在手机上查看并续聊你的会话——局域网直连，无云端中转、无需账号。

<p align="center">
  <img src="docs/images/paired.jpg" alt="Paired with the PC" width="300">
  <img src="docs/images/sessions.jpg" alt="Session list with per-session models" width="300">
</p>

---

## Where to find what · 东西在哪

| 内容 | 位置 |
|---|---|
| **Android 安装包（推荐）** | [**Releases**](../../releases/latest) → `dsh-app-release.apk` |
| **App 源码** | 本 `main` 分支（Flutter 工程，根目录直接构建） |
| **dsh 配对插件源码** | [`plugin` 分支](../../tree/plugin)（`Settings → 扫码配对`） |
| 协议笔记 | [`docs/PROTOCOL.md`](docs/PROTOCOL.md) |

> The app never talks to any server except your own PC. 除了你自己的 PC，App 不连接任何服务器。

## Install · 安装

### 1. App · 手机端

Download the APK from **Releases** and install it (Android 8+):

从 **Releases** 下载 APK 安装（Android 8+）：

```powershell
adb install -r dsh-app-release.apk
```

### 2. Plugin · dsh 插件

Clone the plugin branch and install it with the dsh plugin manager:

```powershell
git clone -b plugin https://github.com/lrxG/dsh-app dsh-plugin
```

Then: **dsh → Plugins → Add plugin →** paste the absolute path of `dsh-plugin`, restart dsh.
然后：**dsh → 插件 → 添加插件** → 粘贴 `dsh-plugin` 的绝对路径，重启 dsh。

> Requires `pnpm` on PATH (the plugin manager installs with it). The package declares `dsh.bundle`, so the manager accepts it.
> 需要 PATH 里有 `pnpm`；本包声明了 `dsh.bundle`，插件管理器才会安装。

### 3. Pair · 配对

Open **dsh → Settings → 扫码配对**, scan with the app. Or paste the URL shown under the QR via **「手动粘贴配对链接」**.

打开 **dsh → 设置 →「扫码配对」**，用 App 扫码；也可以点「手动粘贴配对链接」粘贴二维码下方的链接。

That's it. Sessions, models and messages sync from the PC, and you can keep chatting from the phone.
完成。会话、模型、消息与 PC 实时同步，手机上直接续聊。

## How it works · 原理

```
┌──────────── PC ────────────┐                 ┌──────── phone ────────┐
│ dsh (desktop app or CLI)   │                 │  DeepSeek Harness app │
│  ├─ Settings → QR (plugin) │◄── ① scan ──────│                       │
│  ├─ /api  RPC (HTTP)       │◄── ② RPC ───────│  dsh-auth cookie      │
│  └─ /api/remote.mux  (WS)  │◄── ③ streaming ─│  (30 days)            │
│  [plugin LAN gateway]      │                 │                       │
│   LAN IP:3080 → 127.0.0.1  │                 │                       │
└────────────────────────────┘                 └───────────────────────┘
```

1. The plugin reads the **live launch token** from dsh (`connection.authenticatedUrl`) and renders it as a QR — always the current process token.
2. The app exchanges that one-time token for a **signed HttpOnly cookie** (30 days). All later RPC / WebSocket calls use only this cookie.
3. dsh's signing secret is stored on disk, so **restarting dsh or the PC does not require re-scanning**.
4. When dsh only listens on loopback (the Desktop app), the plugin starts a **small LAN gateway** (`<LAN-IP>:3080`, next free port when taken) that proxies HTTP + WebSocket to the local dsh, rewriting `Host`/`Origin` to `localhost`. The phone talks to the LAN address; dsh still applies its own trust fence and cookie checks.

1. 插件从 dsh 进程读取**当前 launch token**（`connection.authenticatedUrl`）生成二维码，永远有效不会过期；
2. App 用这个一次性 token 换一枚**签名 HttpOnly cookie**（30 天），之后所有 RPC / WebSocket 只带它；
3. 签名密钥落盘，**重启 dsh 或重启 PC 都不需要重新扫码**；
4. dsh 只监听回环（桌面应用）时，插件自动开一个**局域网网关**（`<局域网IP>:3080`，被占用则顺延），把 HTTP/WebSocket 转发给本机 dsh，并把 `Host`/`Origin` 重写为 `localhost`；手机连局域网地址，鉴权仍由 dsh 自己完成。

## Features · 功能

| | |
|---|---|
| **会话** | 与 PC 工作区分组一致 · 归档/恢复 · 置顶 · 重命名 · 搜索（名称 + 内容）· 子任务 · 后台任务 |
| **聊天** | 流式回复 · 思考过程折叠 · 工具调用芯片 · 停止当前轮次 · 图片/文件附件 |
| **模型** | 读取 PC 模型目录 · 两级选择（模型 → 思考深度）· 每行显示会话所用模型 · 选择写回 PC |
| **交互** | 审批弹窗（允许一次 / 拒绝）· 回答完成与审批的系统通知 |
| **多设备** | 保存多台 PC 并一键切换 |

## Security · 安全

- LAN only; no relay, no telemetry. 仅局域网直连，无中转。
- QR token: 256-bit random per process, rotates on restart. token 为进程级 256-bit 随机值，重启轮换。
- Cookie: signed, `HttpOnly`, `SameSite=Strict`, 30 days. cookie 由 PC 本地密钥签名，30 天。
- Every data route passes dsh's `connection.admit()`; anonymous requests get **401**. 所有数据路由过 dsh 鉴权，匿名 401。
- Plugin page has **“解除所有设备”** (rotate the signing secret; effective after restart). 插件页可一键解除所有设备。
- Tip: give the PC a static DHCP lease so its IP (and the cookie) stays valid. 建议固定 PC 的 DHCP 租约。

## FAQ · 常见问题

**Q: The phone says “connection refused / 连不上”.**
Make sure the plugin is installed and dsh was restarted (the gateway only starts with the plugin). Check `http://<PC-IP>:3080/` on the PC — a **401** means the gateway is up.

**Q: dsh Desktop app shows a warning instead of a QR?**
The gateway failed to bind (ports busy) or the plugin did not load. Restart dsh and check its log for `lanbuddy-pair`.

**Q: Do I need to re-scan after rebooting the PC?**
No. The token rotates, but the cookie is signed by a durable secret. Only re-scan if the cookie expired (30 days), the PC's IP changed, or you used “解除所有设备”.

**Q: Is my data sent anywhere?**
No. The app only talks to your PC on the LAN.

## Build from source · 自行构建

```powershell
git clone https://github.com/lrxG/dsh-app
cd dsh-app
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk
```

## License

MIT — see [LICENSE](LICENSE).
