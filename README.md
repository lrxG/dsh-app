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

## 2. Install the dsh plugin · 安装 dsh 插件

Install the plugin from the **`plugin` branch** (that branch's README has the steps), then restart dsh if asked. No `--host` flag and no companion are needed: on a loopback-only instance (like the dsh Desktop app) the plugin opens a **LAN gateway** so the phone can reach that same instance.

从 **`plugin` 分支** 安装插件（步骤见该分支 README），按提示重启 dsh。**不需要**加 `--host`、也不需要陪伴进程：如果 dsh 只监听回环（比如桌面应用），插件会自动开一个**局域网网关**，让手机连到同一个实例。

## 3. Scan · 扫码

Open **dsh → Settings → 扫码配对**, scan with the app. Or paste the URL shown next to the QR into the app via **「手动粘贴配对链接」**.

打开 **dsh → 设置 →「扫码配对」**，用 App 扫二维码；也可以把二维码下方的链接粘进 App 的「手动粘贴配对链接」。

The token rotates on restart, but the phone keeps a 30-day signed cookie, so **restarts do not require re-scanning**.

token 每次重启都会变，但手机保存的是 30 天 cookie，**重启后不用重新扫码**。

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
