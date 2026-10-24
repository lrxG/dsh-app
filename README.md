# DSH Companion — Android client

**English** · 中文（同一页面双语）

Flutter source of the **DSH Companion** Android app: pair with a local DeepSeek Harness (dsh) instance by scanning a QR code, then read and continue your sessions from the phone over the LAN.

Flutter 源码：通过扫码与局域网内的 DeepSeek Harness (dsh) 配对，在手机上查看并继续你的会话。

> Overview, the dsh QR plugin and the ready-to-install APK live in the [main repo](../../) — see **Releases** for the APK.
> 总览、dsh 二维码插件与安装包在主仓库：安装包见 **Releases**。

## Build · 构建

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

APK output: `build/app/outputs/flutter-apk/app-release.apk`.

## How it works · 原理

1. The QR (shown by dsh settings or the companion) carries `http://<PC-IP>:3080/?token=…` — a one-time launch token;
2. The app exchanges it for a 30-day signed cookie (dsh keeps its signing secret on disk, so restarts do not require re-pairing);
3. All RPC and the realtime WebSocket then authenticate with that cookie only.

二维码内容就是 dsh 启动时打印的带 token 地址；APP 用它换 30 天 cookie（dsh 的签名密钥落盘，重启后无需重扫），之后所有请求只带 cookie。

## Requirements · 环境

- Flutter 3.x / Dart 3.13+
- Android 8+ (minSdk from the Flutter template)
- The PC must expose dsh on the LAN: `dsh web --host <PC-IP> --port 3080`

## Notes · 说明

- The dsh **desktop app** binds `127.0.0.1` only, so a phone cannot reach it; point the phone at a LAN-bound `dsh web` instance.
- 桌面应用只监听回环，手机连不上；请连接绑定局域网地址的 `dsh web` 实例。
