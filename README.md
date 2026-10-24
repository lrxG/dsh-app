# DeepSeek Harness

**English · 中文（同一页面双语）**

Android client for **DeepSeek Harness (dsh)**: scan a QR from the dsh **pairing plugin**, then read and continue your sessions from the phone over your own LAN. No cloud relay, no account.

**DeepSeek Harness (dsh)** 的 Android 客户端：用 dsh **配对插件**显示的二维码扫码，即可在手机上查看并续聊会话。局域网直连，无云端中转、无需账号。

> **This branch (`main`) is the Android app source.** · 本分支是 **安卓客户端源码**。
> The dsh plugin lives on the **`plugin` branch** · dsh 插件在 **`plugin` 分支**。
> Ready-to-install APK is in **Releases** · 安装包在 **Releases**。

<p align="center"><img src="docs/images/paired.jpg" alt="DeepSeek Harness — paired with the PC" width="320"></p>

Keywords: DeepSeek Harness, dsh, Android, Flutter, LAN, QR pairing, mobile client, self-hosted.

---

## 1. Install the app · 安装 App

Open **Releases** → `dsh-app-release.apk` → install on Android 8+.

到 **Releases** 下载 `dsh-app-release.apk`，安装到 Android 8 及以上。

```powershell
adb install -r dsh-app-release.apk
```

Build from this branch · 在本分支自行编译：

```powershell
flutter pub get
flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk
```

## 2. Install the dsh plugin · 安装 dsh 插件

Install the plugin from the **`plugin` branch** (that branch's README has the steps), then restart dsh. The plugin adds **Settings → 扫码配对** and, when dsh only listens on loopback (the Desktop app), a small **LAN gateway** so the phone can reach that same instance.

从 **`plugin` 分支** 安装插件（步骤见该分支 README），重启 dsh。插件会在 **设置 →「扫码配对」** 里显示二维码；若 dsh 只监听回环（桌面应用），它会自动开一个**局域网网关**，手机连到的就是同一个实例。

## 3. Scan and use · 扫码使用

Open **dsh → Settings → 扫码配对**, scan with the app (or paste the URL under the QR via **「手动粘贴配对链接」**). Sessions, models and messages mirror from the PC.

打开 **dsh → 设置 →「扫码配对」**，用 App 扫二维码（也可点「手动粘贴配对链接」粘贴二维码下方的链接）。会话、模型、消息与 PC 实时同步。

The token rotates on restart, but the phone keeps a 30-day signed cookie, so **restarts do not require re-scanning**.

token 每次重启都会变，但手机保存的是 30 天 cookie，**重启后不用重新扫码**。

## Features · 功能

- Session list grouped by the PC's workspaces; archive/restore, pin, rename, search (name + content) · 会话列表与 PC 分组一致，归档/恢复、置顶、重命名、搜索（名称 + 内容）
- Each row shows the model it uses (name + reasoning effort) · 每行显示该会话使用的模型（名称 + 思考深度）
- Streaming replies, reasoning disclosure, tool-call chips, image & file attachments, stop current turn · 流式回复、思考过程折叠、工具调用芯片、图片/文件附件、停止当前轮次
- Model catalog read from the PC, two-level picker written back to the PC · 读取 PC 模型目录，两级选择并写回
- Approval prompts (allow once / reject) and system notifications · 审批弹窗与系统通知
- Background jobs panel, subagent list, multiple saved PCs · 后台任务、子任务列表、多 PC 切换

## Security · 安全

- LAN only, no relay servers · 仅局域网直连
- QR token: per-process 256-bit random; exchanged for a signed HttpOnly cookie (30 days) · token 进程级随机，换取 30 天签名 cookie
- Every data route passes dsh's `connection.admit()`; anonymous requests get 401 · 所有数据路由过 dsh 鉴权
- The plugin page can revoke all devices · 插件页可「解除所有设备」
- Tip: static DHCP lease for the PC keeps its IP (and the cookie) valid · 建议给 PC 固定 DHCP 租约

## Notes · 注意

- The dsh **desktop app** binds `127.0.0.1`; the plugin's gateway makes it reachable from the phone. Without the plugin, run `dsh web --host <LAN-IP>` yourself and scan any QR of the printed URL.
- 桌面应用只监听回环；插件网关负责把它开放给手机。不装插件也可以自己 `dsh web --host <局域网IP>`，再扫该 URL 的二维码。

## License

MIT — see [LICENSE](LICENSE).
