# PC companion · PC 陪伴进程（可选，推荐）

**English · 中文（同一页面双语）**

Starts `dsh web` bound to this PC's LAN IP, prints the pairing QR in the terminal, writes `pair-qr.png` and `pair-url.txt` next to the script, and restarts dsh automatically if it exits.

自动以**局域网地址**启动 `dsh web`，在终端打印配对二维码，同时写出 `pair-qr.png` / `pair-url.txt`；dsh 退出后自动重启。

## Run · 运行

```powershell
cd companion
npm install
npm start
# options · 可选参数
npm start -- --profile web --port 3080
```

- Node 20+；`dsh` 作为本目录的依赖自动安装（`@deepseek-ai/dsh`）；
- 默认 profile 为 `web`；用 `--profile <name>` 选择带你自己模型配置的 profile；
- 终端会显示二维码，手机 App →「扫码配对」扫描即可；也可以把 `pair-url.txt` 里的链接手动粘进 App。

## Why a companion? · 为什么需要它

The dsh **desktop app** binds `127.0.0.1` only (hard-coded), so a phone can never reach it. This companion starts a normal `dsh web` bound to your LAN IP — that is the instance the phone connects to.

dsh **桌面应用**只监听 `127.0.0.1`（宿主写死），手机无法连接。本进程启动一个绑定局域网 IP 的普通 `dsh web`，手机连的是它。

## Notes · 注意

- The phone stores a 30-day cookie; restarting dsh or the PC does not require re-scanning. · 手机保存 30 天 cookie，重启 dsh/PC 不用重扫。
- Give this PC a static DHCP lease so its IP stays the same. · 建议给这台 PC 固定 DHCP 租约。
- The QR encodes `http://<LAN-IP>:<port>/?token=…`; the token rotates per process. · 二维码内容形如 `http://<LAN-IP>:<port>/?token=…`，token 每次启动轮换。
