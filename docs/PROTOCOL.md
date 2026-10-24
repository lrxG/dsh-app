# LanBuddy 协议事实卡

全部结论来自阅读 `the dsh source tree`（0.2.1-rc.3）源码，出处文件为锚，DSH 升级时按此复核。

## 配对（成为 Owner Peer）

| 事实 | 出处 |
|---|---|
| `GET /connect?token=<launchToken>&interactions=answer\|none` 一次交换，302 返回 Mux 目的地 + 签名 API Cookie，**直接创建 owner principal Peer** | `packages/client/connection/README.md` L51 |
| launch token 每进程随机生成；`dsh-web-app` 以 `?token=…` 打开/打印应用 URL | `connection/README.md` L41 |
| stdout 精确格式：`dsh web: http://127.0.0.1:4567/?token=test-token`（另有 `open:` 行） | `packages/bundle/web-app/tests/web-app.spec.ts:131` |
| `interactions=answer` 才能接收并回答转发的人类交互（waterfall）；重复声明或非法值 → 400 | `connection/README.md` L51 + `connect-protocol.ts` |
| Cookie 签名密钥存于 `$DSH_HOME/.credentials.yaml` 的 owner 级 `client-connection/browser-session` 记录；删除该记录+重启=吊销所有会话 | `connection/README.md` L43、L83 |
| HTTP 带查询 token 只认根路径交换与 `/connect`；**任何其他 API 路径不接受 Authorization 头** | `connection/README.md` L41 |
| 明文 HTTP 下 cookie 无法标记 `Secure`（嗅探风险），官方建议 web carrier 配置 TLS | `connection/README.md` L81 |
| API socket 与清理绑定：重复挂接 409；socket 关 Peer 即销毁；`peer-disposed` 后的调用一律失败 | `connection/README.md` L51；gateway README L33 |
| 无注销操作；无 connect deadline；过期 cookie 一律 401 | `connection/README.md` L83 |

## RPC 与流

| 事实 | 出处 |
|---|---|
| 一元 Remote 调用 = HTTP POST；流式 = `/api/remote.mux` WebSocket 逻辑流（可多路复用） | `api-gateway.md`、`connection/README.md` L34 |
| 方法返回 `RemoteStream<Out, In>`；上行帧 `item`/`end`/`cancel`，Host 经 `ctx.invocation.uplink()` 消费；上行每项都要 Host 校验，下行项不过校验透传 | gateway README L43 |
| 流 inbox 上行缓冲默认 262144 字节，超限 `gateway/uplink-overflow`；`end` 之后再来项 → `gateway/protocol`；不关 socket | gateway README L43 |
| `$events` 流：opening 帧含 `{type:'ready', clientId, host:{home}}`；owner 收转发 waterfall，非 owner 只收判定允许的 `event:<name>` 广播 | gateway README L47 |
| 非owner 事件的资源若取不出 → 不判定不投递；被拒帧只丢弃不关流 | gateway README L47 |
| Peer 释放时其流 `signal` 中止、流以 `gateway/cancelled` 结束；已运行调用不被取消 | gateway README L43 |

## 权限（非 owner 模式，v0.3 预研）

| 事实 | 出处 |
|---|---|
| 每个调用在 Typert 校验后、lookup 前解析资源并询问 `remoteAccess.decide({principal, action, resources, args})`；owner 调用跳过判定 | gateway README L33 |
| 拒绝错误 `remote-access/denied`，details `{action, reason}`；reason 枚举：`resource-invalid`/`no-allow`/`policy-failed` | remote-access README |
| role `{name, resource, actions}`；binding 可带 condition；`global` 资源的全权 grant 蕴含一切 | remote-access README |
| index 渲染时按 Peer 注入快照 `__DSH_REMOTE_ACCESS__`；客户端以 `whenResourceAccess()/useSessionAccess()` 显示受控操作 | remote-access README |

## 参考实现锚点

| 需求 | 看这个文件 |
|---|---|
| /connect 服务端行为 | `packages/client/connection/src/browser-auth.ts:309` |
| 协议常量 | `packages/client/connection/src/connect-protocol.ts` |
| WS Mux 帧编解码 | `packages/api/gateway/src/*` + `packages/typert/protocol/src/index.ts` |
| 会话 UI 的 RPC 用法 | `packages/client/ui-session/README.md` |
| 手机断点 UX | `packages/client/ui-conversation/tests/*phone*` |

## 实测确认（2026-10-24，dsh 0.2.1-rc.3 本地验证）

| 事实 | 验证方式 |
|---|---|
| `GET /connect?token=…&interactions=answer` 返回 **HTTP 302**，Location=`./api/remote.mux` | `test/connect-e2e.mjs` 实测 |
| 下发签名 Cookie 名带随机后缀：`dsh-auth-<base64sig>`（HttpOnly/Set-Cookie 属性齐全） | 同上 |
| `/api/remote.mux` 对普通 HTTP GET 返回 404（仅 WS Upgrade） | 同上 |
| 明文 HTTP 启动时官方打印警告 "restrict this port to a trusted proxy or network" | dsh stdout |

## 一元 RPC wire 格式（实测+源码双确认）

```
POST /api/<namespace>/<method>          # endpoint = "sessionController/list" 等两段式
Content-Type: application/json
Cookie: dsh-auth-<sig>=<value>
{"type":"client-request","rpcId":"<uuid>","method":"<namespace>/<method>","payload":{"args":{…}}}
```

- `payload` 必须是**恰好一个** plain-object 字段 `args`（`gateway/src/index.ts:1264`）
- 响应：`{"type":"server-response","rpcId":"…","result":{"ok":true,"value":…}|{"ok":false,"error":{code,message,details}}}`
- 出处：`packages/client/connection/src/client/rpc.ts:40`（请求）、`rpc.ts:81-92`（信封）、`rpc-schema.ts:36`

## 会话域 RPC 面（`packages/api/session-controller`）

服务类 `SessionController` → namespace `sessionController`；`/api` HTTP 一元调用：

| 方法 | args 形状（wire 字段名 = 源码参数名原文） | 返回 |
|---|---|---|
| `list` | `{_request: {cursor?}}` | `{items: SessionSummary[]}`（`sessionId/updatedAt/running/blank/agentAvailable/cwd`），**实测 200 通过** |
| `search` | `{request: {query}}` | `{items: {sessionId,snippet}[], hasMore}` |
| `create` | `{request: {workspaceId?,cwd?,sessionId?,agentPreset?}}` | `{sessionId, agentPreset?}` |
| `prompt` | `{request: {requestId, sessionId, mode, content, clientTimeZone?}}` | `{accepted:true}` |
| `cancel` | `{request: {sessionId}}` | `{accepted:true}` |
| `page` | `{request: {address, throughSeq, beforeSeq?, maxMessages?, turnWindow?}}` | `{records,hasMore}` |
| `projections` | `{request: {sessionId}}` | `{kind:'sequenced',…}` \| `null` |
| `follow` (stream) | `{request: {address, maxMessages?, turnWindow?, assistantStream?}}` | 帧：`snapshot` → `event` → `assistant-stream` |
| `control` (stream) | `{}`（`@Remote async *control(signal)`，无业务参数） | 帧：`baseline` → `projection` |

- 非 owner 收到的 `list/follow/control` 都已被 remoteAccess 按 session 资源过滤（源码 `list()`/`control()` 内直接 `allows()` 过滤）
- `assistantStream:true` 的 chunk 帧 `index`/`nextIndex` 稠密递增，`end` 帧的 `outcome.kind: 'committed'|'abandoned'`

## LanBuddy PC↔手机 时序

```
dsh web --host <LAN_IP>
        ↓ stdout 行 "dsh web: http://<host>:<port>/?token=T"
取 T → pairURL = { scheme}://{LAN_IP}:{port}/connect?token=T&interactions=answer
        ↓ 屏显二维码
手机 SDK 扫码 → HTTP GET pairURL → 302 Set-Cookie(API) → 存入 CookieJar
        ↓
WS { scheme}://{host}:{port}/api/remote.mux （带 Cookie）→ owner Peer 建立
        ↓
RPC: 会话列表/创建/续写；流式回复逐 item 帧渲染
重启 dsh → token 变 → APP 406/401 → 引导手机重新扫码
```
