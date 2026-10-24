# DSH Companion · DSH 手机伴侣

**English · 中文（同一页面双语）**

An Android client for **DeepSeek Harness (dsh)** plus a **dsh plugin that shows a pairing QR code right inside dsh settings**. Pair over your own LAN by scanning a code — no cloud relay, no account, no data leaves your network.

一个 **DeepSeek Harness (dsh)** 的 Android 客户端，附带一个**在 dsh 设置里直接显示配对二维码的插件**。局域网扫码即连，不走云端、不需要账号，数据只在你自己的电脑和手机之间流动。

> **This branch (`main`) is the Android app source.** · 本分支是 **安卓客户端源码**。
> The dsh QR plugin lives on the **`plugin` branch** · dsh 二维码插件在 **`plugin` 分支**。
> Ready-to-install APK is in **Releases** · 安装包在 **Releases**。

Keywords: DeepSeek Harness, dsh, Android, Flutter, LAN, QR pairing, mobile companion, self-hosted, remote chat.

---

## 1. Download the app · 下载 App

Open **Releases** → `dsh-companion-release.apk` → install on Android 8+.

到 **Releases** 下载 `dsh-companion-release.apk`，安装到 Android 8 及以上。

```powershell
adb install -r dsh-companion-release.apk
```

Build from this branch · 在本分支自行编译：

```powershell
flutter pub get
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```

## 2. Get a pairing QR on the PC · 在 PC 上拿到二维码

The phone must reach a **LAN-bound** dsh. The dsh **desktop app** binds `127.0.0.1` and cannot be used for this. Two ways:

手机必须连到一个**绑定局域网地址**的 dsh；**桌面应用只监听 127.0.0.1，不能用**。两种方式：

**A. Easiest — PC companion from the `plugin` branch · 最省事：`plugin` 分支里的陪伴进程**

```powershell
git clone -b plugin https://github.com/lrxG/dsh-companion
cd dsh-companion/companion
npm install
npm start
```

It starts `dsh web --host <LAN-IP> --port 3080` and prints the QR (also `pair-qr.png` / `pair-url.txt`). Scan that QR.

它会以局域网地址启动 dsh 并在终端打印二维码（同时写出 `pair-qr.png` / `pair-url.txt`），直接扫即可。

**B. QR inside dsh settings — install the plugin · 在 dsh 设置里显示二维码（装插件）**

Install the plugin from the `plugin` branch, then run dsh on the LAN:

安装 `plugin` 分支里的插件，然后以局域网地址启动：

```powershell
dsh web --host <PC-IP> --port 3080
```

Open **dsh → Settings → 扫码配对** and scan. No plugin? Generate a QR from the printed URL with any QR tool, or paste the URL into the app via **「手动粘贴配对链接」**.

打开 **dsh → 设置 →「扫码配对」** 扫码；不装插件也可以：用任意工具把打印出的 URL 生成二维码，或在 App 里「手动粘贴配对链接」。

dsh prints `http://<PC-IP>:3080/?token=…` — exactly what the QR encodes. The token rotates on restart, but the phone keeps a 30-day signed cookie, so **restarts do not require re-scanning**.

dsh 启动时打印的 `http://<PC-IP>:3080/?token=…` 就是二维码内容。token 每次重启都会变，但手机保存的是 30 天 cookie，**重启后不用重新扫码**。

## 3. Scan · 扫码

App →「扫码配对」→ scan; or「手动粘贴配对链接」paste the URL. Then open sessions.
App →「扫码配对」→ 扫描；或「手动粘贴配对链接」粘贴。成功后进入会话。

## 4. Done · 完成

Sessions, models and messages mirror from the PC; keep chatting from the phone.
会话、模型、消息与 PC 实时同步，手机上直接续聊。

## Features · 功能

- Session list grouped by the PC's workspaces; archive/restore, pin, rename, search (name + content) · 会话列表与 PC 分组一致，归档/恢复、置顶、重命名、搜索（名称 + 内容）
- Streaming replies, reasoning disclosure, tool-call chips, image & file attachments, stop current turn · 流式回复、思考过程折叠、工具调用芯片、图片/文件附件、停止当前轮次
- Model catalog read from the PC, two-level picker (model → effort) written back to the PC · 读取 PC 模型目录，两级选择并写回
- Approval prompts (allow once / reject) and system notifications · 审批弹窗与系统通知
- Background jobs panel, subagent list, multiple saved PCs · 后台任务、子任务列表、多 PC 切换

## Security · 安全

- LAN only, no relay servers · 仅局域网直连，无中转
- QR token: per-process 256-bit random; exchanged for a signed HttpOnly cookie (30 days) · token 进程级随机，换取 30 天签名 cookie
- Every data route passes dsh's `connection.admit()`; anonymous requests get 401 · 所有数据路由过 dsh 鉴权
- The plugin page can revoke all devices (rotate the signing secret, effective after restart) · 插件页可「解除所有设备」
- Tip: static DHCP lease for the PC keeps its IP (and the cookie) valid · 建议给 PC 固定 DHCP 租约

## Notes · 注意

- The **dsh desktop app** binds `127.0.0.1` only; phones cannot reach it. Use `dsh web --host <LAN-IP>`.
- 桌面应用只监听回环，手机连不上；请使用绑定局域网地址的 `dsh web` 实例。

## License

MIT — see [LICENSE](LICENSE).
