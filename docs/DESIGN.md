# LanBuddy — 设计文档

局域网内的 DSH 手机伴侣：Android APP（Flutter）+ PC 陪伴进程，扫码配对，Owner Peer 同步。

## 产品定位

- WordBuddy 式体验：**PC 与手机共享同一 DSH，手机是无缝续聊的第二块屏幕**
- 仅限局域网：不经过任何中继/云端；PC 与手机在同一 WiFi 下即可
- 零侵入：DSH 本体零修改，全部走官方协议（源码事实见 PROTOCOL.md）

## 架构

```
┌────────── PC ──────────┐        局域网        ┌────── 手机 ──────┐
│  DSH (dsh web)          │                      │  LanBuddy APP    │
│   ├─ /connect?token=…   │◄── ①扫码 POST/GET ──│                  │
│   ├─ /api RPC (HTTP)    │◄── ② RPC ───────────│  owner Peer      │
│   └─ /api/remote.mux WS │◄── ③流式帧 ─────────│  WS 常连         │
│  [pc-host 陪伴进程]      │                      │                  │
│   托管 dsh web、捕获      │                      │                  │
│   token、显示二维码       │                      │                  │
└─────────────────────────┘                      └──────────────────┘
```

## MVP（v0.1）范围

**pc-host（Node.js）**
1. 自动探测局域网 IP，托管 `dsh web --host <ip> --port 3080 --no-open`
2. 从 stdout 捕获 `dsh web: http://…/?token=…` 行内的 launch token
3. 生成配对 URL `http://<ip>:<port>/connect?token=<t>&interactions=answer`
4. 终端 ASCII 二维码 + PNG 落盘（后续升级为托盘窗）
5. dsh 崩溃自动重启（新 token → 新二维码，旧 Cookie 随重启自然失效）

**app（Flutter / Android）**
1. 扫码页面（qr_flutter 解码 mobile_scanner）→ `GET /connect?token=…&interactions=answer`
2. 跟随 302 拿到 API Cookie（Dio/CookieJar），保留给后续请求
3. WS 连接 `/api/remote.mux`（Cookie 附带）→ owner Peer
4. 会话列表 + 聊天续写 UI；流式回复直读 `RemoteStream` item 帧
5. 断线自动走 `/connect` 重认（token 要重新扫码，DPI 感知）

**明确不做（v0.1）**：TLS 证书自动生成（v0.2）、非 owner 受限 grant（v0.3）、发送新消息 outside current session、通知推送、多 PC 管理。

##里程碑

| 版本 | 内容 |
|---|---|
| v0.1 | pc-host 扫码配对 + APP 只读同步会话列表/流式续聊 |
| v0.2 | 自签 TLS + Let's-Encrypt 局域网 trick 不可行 → 本地 CA 方案；托盘 GUI（Electron 或 WinForms） |
| v0.3 | 手机作为非 owner Peer（官方 remoteAccess grant），受限权限模式 |
| v0.4 | 通知、多会话、语音输入、PWA 替代原生壳的对比评估 |

## 风险清单

1. **HTTP 明文 cookie**：官方文档明示 LAN 明文=cookie 可被嗅探（connection/README.md L81）。v0.2 必须 TLS；v0.1 仅家庭可信网络
2. **dsh 重启 = token 轮换**：所有 Peer 失效，APP 需引导重新扫码（WordBuddy 的"重连"按钮同模型）
3. **npx 首跑需要网络**：pc-host 依赖 `npx @deepseek-ai/dsh`；机器离线时启用缓存
4. **desktop app 与 `dsh web` 并存**：同一 `$DSH_HOME` 下两个进程会话隔离规则待实测（MVP 假定用户关桌面端或仅在工作时段使用 web CLI）
