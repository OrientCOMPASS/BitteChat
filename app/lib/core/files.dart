// 通过 Android FileProvider + ACTION_VIEW 让其他应用打开本地文件

import 'package:flutter/services.dart';

const _filesChannel = MethodChannel('bittechat/files');

/// Ask Android to open [path] with an external app capable of [mime].
Future<bool> openWithExternalApp(String path, String mime) async {
  try {
    final ok = await _filesChannel.invokeMethod<bool>('openWith', {
      'path': path,
      'mime': mime,
    });
    return ok ?? false;
  } catch (_) {
    return false;
  }
}

/// Guess a MIME type from a file name (small, pragmatic table).
String mimeFromName(String name) {
  final n = name.toLowerCase();
  String ext(String e) => n.endsWith(e) ? e : '';
  final map = <String, String>{
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.webp': 'image/webp',
    '.gif': 'image/gif',
    '.bmp': 'image/bmp',
    '.mp3': 'audio/mpeg',
    '.m4a': 'audio/mp4',
    '.aac': 'audio/aac',
    '.flac': 'audio/flac',
    '.ogg': 'audio/ogg',
    '.wav': 'audio/wav',
    '.opus': 'audio/opus',
    '.mp4': 'video/mp4',
    '.mkv': 'video/x-matroska',
    '.webm': 'video/webm',
    '.avi': 'video/x-msvideo',
    '.mov': 'video/quicktime',
    '.pdf': 'application/pdf',
    '.txt': 'text/plain',
    '.md': 'text/markdown',
    '.json': 'application/json',
    '.csv': 'text/csv',
    '.log': 'text/plain',
    '.zip': 'application/zip',
    '.apk': 'application/vnd.android.package-archive',
  };
  for (final e in map.keys) {
    if (ext(e).isNotEmpty) return map[e]!;
  }
  return 'application/octet-stream';
}

enum MediaKind { image, audio, video, text, other }

MediaKind mediaKindOf(String name, String mime) {
  final n = name.toLowerCase();
  if (mime.startsWith('image/') ||
      ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'].any(n.endsWith)) {
    return MediaKind.image;
  }
  if (mime.startsWith('audio/') ||
      ['.mp3', '.m4a', '.aac', '.flac', '.ogg', '.wav', '.opus']
          .any(n.endsWith)) {
    return MediaKind.audio;
  }
  if (mime.startsWith('video/') ||
      ['.mp4', '.mkv', '.webm', '.avi', '.mov'].any(n.endsWith)) {
    return MediaKind.video;
  }
  if (mime.startsWith('text/') ||
      ['.txt', '.md', '.json', '.csv', '.log', '.yml', '.yaml', '.toml']
          .any(n.endsWith)) {
    return MediaKind.text;
  }
  return MediaKind.other;
}
