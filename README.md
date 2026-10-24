# DeepSeek Harness · dsh app

**简体中文** | [English](README.en.md)

<p>
  <img alt="platform" src="https://img.shields.io/badge/platform-Android-3ddc84">
  <img alt="flutter" src="https://img.shields.io/badge/Flutter-3.x-02569B">
  <a href="../../releases/latest"><img alt="release" src="https://img.shields.io/github/v/release/lrxG/dsh-app"></a>
  <img alt="license" src="https://img.shields.io/github/license/lrxG/dsh-app">
</p>

**DeepSeek Harness (dsh)** 的 Android 客户端。用 dsh **配对插件**显示的二维码扫一次，就能在手机上查看并续聊会话——局域网直连，无云端中转、无需账号。

<p align="center">
  <img src="docs/images/paired.jpg" alt="配对成功" width="300">
  <img src="docs/images/sessions.jpg" alt="会话列表（每行显示所用模型）" width="300">
</p>

## 安装与使用 · 三步

1. **装 App** —— 到 [**Releases**](../../releases/latest) 下载 `dsh-app-release.apk`（Android 8+）安装。
2. **装 dsh 插件** —— 在 PC 上：
   ```powershell
   git clone -b plugin https://github.com/lrxG/dsh-app dsh-plugin
   ```
   然后 **dsh → 插件 → 添加插件**，粘贴 `dsh-plugin` 的绝对路径，按提示重启 dsh。（需要 `pnpm`；本包声明了 `dsh.bundle`。）
3. **配对** —— 打开 **dsh → 设置 →「扫码配对」**，用 App 扫二维码；也可以点「手动粘贴配对链接」粘贴二维码下方的链接。

完成。会话、模型、消息与 PC 实时同步，手机上可以直接续聊。

> dsh **桌面应用**只监听 `127.0.0.1`。插件内置的**局域网网关**会自动把它开放给手机——不需要额外启动器，也不用加 `--host` 参数。

## 能做什么

| | |
|---|---|
| **会话** | 与 PC 工作区分组一致 · 归档/恢复 · 置顶 · 重命名 · 搜索（名称 + 内容）· 子任务 · 后台任务 |
| **聊天** | 流式回复 · 思考过程折叠 · 工具调用芯片 · 停止当前轮次 · 图片/文件附件 |
| **模型** | 读取 PC 模型目录 · 两级选择（模型 → 思考深度）· 每行显示会话所用模型 · 选择写回 PC |
| **子智能体** | 父会话派活后自己闲置时不误判「空闲」：列表绿点与「子智能体 ×N」按整棵子 agent 树算，点开可看子会话（只读） |
| **交互** | 审批弹窗（允许一次 / 拒绝）· 后台完成通知（点通知直达对应会话） |
| **多设备** | 保存多台 PC 并一键切换 |

## 后台通知

退到后台、锁屏之后，PC 上某个**主会话**跑完，手机会收到一条普通通知（不是常驻通知，任务结束后才有）：

- 只针对主会话：子智能体结束时**不会**单独弹通知，等这一整棵子 agent 树都空闲了，才以主会话的名义提醒一次；
- 你正停在那个会话里、或 App 在前台时不会弹，避免打扰；
- 点通知直接打开对应会话。

**要收到通知，必须让系统别冻结 App**：首次配对成功时会弹一次提示，点「去设置」直接打开省电策略，选**无限制**；HyperOS 顺便允许**自启动**。之后配对页不会再常驻任何开关。想再改：系统设置 → 应用 → DeepSeek Harness → 省电策略 → 无限制。没有前台服务、没有常驻通知。

局限（Android 的机制，不是 App 不想做）：从最近任务里**上滑清掉** App，或系统在长时间待机后强制回收，进程内的 WebSocket 就断了，这段时间的通知会漏；重新打开 App 后状态会补齐。


## 东西在哪

| 内容 | 位置 |
|---|---|
| Android 安装包（推荐） | [**Releases**](../../releases/latest) |
| App 源码 | 本 `main` 分支（根目录即 Flutter 工程） |
| dsh 配对插件 | [`plugin` 分支](../../tree/plugin) |
| 协议笔记 | [`docs/PROTOCOL.md`](docs/PROTOCOL.md) |

## 原理

```
┌──────────── PC ────────────┐                 ┌──────── 手机 ────────┐
│ dsh（桌面应用或 CLI）       │                 │  DeepSeek Harness App │
│  ├─ 设置 → 二维码（插件）   │◄── ① 扫码 ──────│                       │
│  ├─ /api  RPC (HTTP)       │◄── ② RPC ───────│  dsh-auth cookie      │
│  └─ /api/remote.mux  (WS)  │◄── ③ 流式帧 ────│  （30 天）            │
│  [插件局域网网关]           │                 │                       │
│   局域网IP:3080 → 127.0.0.1 │                 │                       │
└────────────────────────────┘                 └───────────────────────┘
```

- 插件把 dsh 的**当前 launch token**（`connection.authenticatedUrl`）画成二维码，永远是最新有效的；
- App 用这个一次性 token 换一枚**签名 HttpOnly cookie**（30 天），之后所有 RPC / WebSocket 只带 cookie；
- 签名密钥落盘，**重启 dsh 或重启 PC 都不用重新扫码**；
- dsh 只监听回环时，插件自动开一个**局域网网关**（`<局域网IP>:3080`）把 HTTP/WebSocket 转发给本机 dsh，并把 `Host`/`Origin` 重写为 `localhost`；鉴权仍由 dsh 自己完成。

## 安全

- 仅局域网直连，无中转、无遥测。
- 二维码 token：每个进程 256-bit 随机，重启轮换。
- cookie：由 PC 本地持久密钥签名，`HttpOnly`、`SameSite=Strict`，30 天。
- 所有数据路由都过 dsh 的 `connection.admit()`，匿名请求一律 **401**。
- 插件页可**解除所有设备**（轮换签名密钥）。
- 建议给 PC 固定 DHCP 租约，避免 IP 变化导致 cookie 失效。

## 常见问题

**手机提示「连接被拒绝」**：确认插件已安装且 dsh 已重启（网关由插件启动）。在 PC 上访问 `http://<局域网IP>:3080/` 返回 **401** 说明网关正常。

**设置里没有二维码/显示警告**：插件没加载或端口全被占用。重启 dsh，并在日志里搜 `lanbuddy-pair`。

**重启后要重新扫码吗**：不用。只有 cookie 过期（30 天）、PC 的 IP 变了、或点了「解除所有设备」才需要重扫。

**数据会上传吗**：不会。App 只连你自己的 PC。

**点了「分叉会话」但没发消息，为什么没多出会话？**：这是有意的。分叉会立刻在 PC 上落盘、又没有删除接口，所以 App 改成「分叉待发」：顶部出现提示条，**发送第一条消息时才真正创建**分叉；直接退出则什么都不会留下。

**子智能体在跑，但父会话显示空闲？**：不会了。父会话派活后自己闲置时，列表仍显示绿点并标注「子智能体 ×N」，聊天页顶部也有同样入口。

## 自行构建

```powershell
git clone https://github.com/lrxG/dsh-app
cd dsh-app
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk
```

## 许可证

MIT，见 [LICENSE](LICENSE)。
