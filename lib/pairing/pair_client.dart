import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Outcome of the one-shot pairing exchange against the PC's `dsh web`.
class PairResult {
  const PairResult({
    this.ok = false,
    this.pcOrigin = '',
    this.status,
    this.cookieName,
    this.cookieHeader,
    this.error,
  });

  final bool ok;
  /// e.g. `http://192.168.1.10:3456`
  final String pcOrigin;
  final int? status;
  final String? cookieName;
  /// Raw `Cookie` header value for owner-peer requests (`dsh-auth-…=…`).
  final String? cookieHeader;
  final String? error;

  /// The `/connect` exchange hands back the Mux base as its redirect target
  /// (protocol: packages/client/connection, docs/PROTOCOL.md).
  Uri get muxUrl => Uri.parse('$pcOrigin/api/remote.mux').replace(scheme: scheme);

  String get scheme => pcOrigin.startsWith('https') ? 'wss' : 'ws';
}

/// Performs `GET /?token=…` with redirects disabled to observe the 303 + the
/// signed browser-session cookie.
///
/// Why the index grant and not `/connect` (the API-operator grant): the v2
/// cookie binds one socket-bound owner Peer that the Host deletes as soon as
/// that WebSocket closes (`admitConnection.release` → `peers.delete`), so any
/// disconnect invalidates it — the only recovery there is re-pairing. The
/// index grant mints the browser-session cookie instead: connection-service
/// `admit` maps it onto the always-live `browserPeer` (owner principal), with
/// the signing secret persisted across dsh restarts. Result: RPC + mux
/// survive both dsh restarts and socket drops with the same cookie, which is
/// what the phone app needs.
class PairClient {
  PairClient() : dio = Dio(BaseOptions(
    followRedirects: false,
    validateStatus: (code) => true,
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    responseType: ResponseType.plain,
  ));

  final Dio dio;

  Future<PairResult> exchange(Uri pairUrl) async {
    final origin = '${pairUrl.scheme}://${pairUrl.authority}';
    // Accept a full pair URL but normalize to the plain index grant.
    final token = pairUrl.queryParameters['token'] ?? '';
    final grantUrl = Uri.parse('$origin/?token=${Uri.encodeComponent(token)}');
    try {
      if (token.isEmpty) {
        return PairResult(
          ok: false,
          pcOrigin: origin,
          error: '链接无效（缺少 token）',
        );
      }
      final res = await dio.getUri<void>(grantUrl);
      final setCookies = res.headers['set-cookie'] ?? const <String>[];
      if (res.statusCode != 303) {
        return PairResult(
          ok: false,
          pcOrigin: origin,
          status: res.statusCode,
          error: res.statusCode == 401
              ? 'PC 不认这个 token（可能已被 PC 重启轮换）；重新扫码拿到新链接即可'
              : 'PC 返回了 ${res.statusCode}，未下发会话 Cookie',
        );
      }
      if (setCookies.isEmpty) {
        return PairResult(
          ok: false,
          pcOrigin: origin,
          status: res.statusCode,
          error: '303 但没有下发 Cookie，请重新扫码',
        );
      }
      // First cookie carries the signed browser session, `dsh-auth-<hash>=…`.
      final raw = setCookies.first;
      final name = raw.substring(0, raw.indexOf('='));
      final value = raw.substring(raw.indexOf('=') + 1, raw.indexOf(';'));
      return PairResult(
        ok: true,
        pcOrigin: origin,
        status: res.statusCode,
        cookieName: name,
        cookieHeader: '$name=$value',
      );
    } on DioException catch (e) {
      final detail = switch (e.type) {
        DioExceptionType.connectionError =>
          'PC 端口没有响应（dsh 可能正在重启，或扫到的二维码已过期；稍等几秒重扫）',
        DioExceptionType.connectionTimeout => '连接超时（手机与 PC 不在同一 WiFi？）',
        _ => '${e.type.name}${e.message != null ? ' — ${e.message}' : ''}',
      };
      return PairResult(
        ok: false,
        pcOrigin: origin,
        error: '连接 $origin 失败：$detail',
      );
    } on SocketException catch (e) {
      return PairResult(
        ok: false,
        pcOrigin: origin,
        error: '连接 $origin 失败：${e.message}',
      );
    } on TimeoutException catch (e) {
      return PairResult(
        ok: false,
        pcOrigin: origin,
        error: '连接 $origin 超时：${e.message}',
      );
    }
  }
}
