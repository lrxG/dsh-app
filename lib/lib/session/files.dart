import 'dart:io';

import 'package:flutter/services.dart';

/// One document selected through the system picker (copied into app cache).
class AttachmentFile {
  const AttachmentFile({
    required this.path,
    required this.name,
    required this.size,
  });

  final String path;
  final String name;
  final int size;

  Future<Uint8List> readBytes() => File(path).readAsBytes();

  /// Best-effort removal of the cache copy (after send or removal).
  Future<void> deleteTemp() async {
    try {
      await File(path).delete();
    } catch (_) {
      // Already gone or cache cleared by the system.
    }
  }
}

/// Bridge to the native SAF picker (`lanbuddy/files`).
class FilePickerBridge {
  FilePickerBridge._();

  static const MethodChannel _channel = MethodChannel('lanbuddy/files');

  /// Opens the system document picker; null when the user cancels.
  static Future<AttachmentFile?> pick() async {
    try {
      final value = await _channel.invokeMapMethod<String, Object?>('pick');
      if (value == null) return null;
      final path = value['path'];
      final name = value['name'];
      final size = value['size'];
      if (path is! String || path.isEmpty) return null;
      return AttachmentFile(
        path: path,
        name: name is String && name.isNotEmpty ? name : 'file',
        size: size is int ? size : 0,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
