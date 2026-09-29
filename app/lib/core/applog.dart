// Dart-side file logging + crash capture + log export.
//
// Writes a single bounded <dataDir>/logs/app.log: once it passes 64 KiB the
// FIRST HALF OF THE LINES is dropped and accumulation continues until the cap
// is hit again (same policy as the core's `core.log`), so an exported bundle
// always holds the newest ~128 KiB of Dart-side context instead of a stale
// older generation. Flutter error handlers are installed so widget/async
// errors land in the same exportable bundle as the core's logs. Export copies
// every log file into one text file and hands it to the platform channel,
// which writes it to the public Download directory (MediaStore on API 29+).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Log size cap in bytes; at that point the older half of the lines is
/// dropped (see [trimFrontHalf]).
const int kLogMaxBytes = 64 * 1024;

/// Keep the newer half of [text] (split on line count, not bytes) prefixed
/// with a marker line that folds in any marker already present.
///
/// Pure so it can be unit tested without touching the filesystem.
@visibleForTesting
String trimFrontHalf(String text, {String marker = 'log'}) {
  final endsWithNewline = text.endsWith('\n');
  final lines = text.split('\n');
  if (endsWithNewline && lines.isNotEmpty) lines.removeLast();
  var already = 0;
  var start = 0;
  if (lines.isNotEmpty && lines.first.startsWith('[$marker trimmed:')) {
    already = 1;
    start = 1;
  }
  final total = lines.length - start;
  if (total <= 1) return text;
  final drop = total ~/ 2;
  if (drop == 0) return text;
  final kept = lines.sublist(start + drop);
  final buf = StringBuffer()
    ..writeln('[$marker trimmed: ${drop + already} older lines dropped]');
  for (final l in kept) {
    buf.writeln(l);
  }
  return buf.toString();
}

class AppLog {
  AppLog._(this._dir);

  final String _dir;
  static AppLog? _instance;
  static AppLog get instance => _instance!;
  static bool get ready => _instance != null;

  static const _maxBytes = kLogMaxBytes;

  File get _file => File('$_dir/logs/app.log');

  static Future<void> init(String dataDir) async {
    try {
      await Directory('$dataDir/logs').create(recursive: true);
      final log = AppLog._(dataDir);
      _instance = log;
      // retire the pre-0.5.6 rotated generation so an export can never carry
      // stale duplicates of lines that are still in app.log
      final legacy = File('$dataDir/logs/app.1.log');
      if (await legacy.exists()) await legacy.delete();
      await log._trimIfNeeded();
      log.write('app log started (pid=$pid)');
    } catch (_) {
      // logging must never break startup
    }
  }

  /// Install global error funnels: framework errors, async zone errors and
  /// platform dispatcher errors all end up in app.log.
  static void captureErrors() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _safeWrite(
          'FLUTTER ERROR: ${details.exceptionAsString()}\n${details.stack}');
    };
    PlatformDispatcher.instance.onError = (e, st) {
      _safeWrite('PLATFORM ERROR: $e\n$st');
      return true;
    };
  }

  static void _safeWrite(String line) {
    try {
      if (_instance != null) _instance!.write(line);
    } catch (_) {}
  }

  void write(String msg) {
    try {
      final ts = DateTime.now().toIso8601String();
      _trimIfNeededSync();
      final sink = _file.openSync(mode: FileMode.append);
      try {
        for (final l in msg.split('\n')) {
          sink.writeStringSync('$ts $l\n');
        }
      } finally {
        sink.closeSync();
      }
    } catch (_) {}
  }

  /// Drop the older half of the log once it passes the cap. The size check is
  /// a `lengthSync`, the rewrite only happens once per ~32 KiB logged.
  void _trimIfNeededSync() {
    try {
      final f = _file;
      if (!f.existsSync()) return;
      if (f.lengthSync() <= _maxBytes) return;
      f.writeAsStringSync(
          trimFrontHalf(f.readAsStringSync(), marker: 'app.log'),
          flush: true);
    } catch (_) {}
  }

  Future<void> _trimIfNeeded() async {
    try {
      final f = _file;
      if (await f.exists() && await f.length() > _maxBytes) {
        await f.writeAsString(
            trimFrontHalf(await f.readAsString(), marker: 'app.log'),
            flush: true);
      }
    } catch (_) {}
  }

  /// All log files (Dart + core), newest first.
  Future<List<File>> logFiles() async {
    final out = <File>[];
    try {
      final d = Directory('$_dir/logs');
      if (await d.exists()) {
        await for (final e in d.list()) {
          if (e is File && e.path.endsWith('.log')) out.add(e);
        }
      }
    } catch (_) {}
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// Concatenate every log into one export file and write it to the public
  /// Downloads directory via the platform channel. Returns the destination
  /// description string, or throws with a message on failure.
  static Future<String> exportToDownloads() async {
    final api = _instance;
    if (api == null) throw Exception('logger not ready');
    final files = await api.logFiles();
    final buf = StringBuffer();
    buf.writeln('BitteChat log export ${DateTime.now().toIso8601String()}');
    buf.writeln('flutter ${Platform.operatingSystem} ${Platform.version}');
    buf.writeln('');
    for (final f in files) {
      buf.writeln('===== ${f.uri.pathSegments.last} =====');
      try {
        buf.writeln(await f.readAsString());
      } catch (e) {
        buf.writeln('<unreadable: $e>');
      }
      buf.writeln('');
    }
    final tmp = File('${api._dir}/tmp/log-export.txt');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(buf.toString());
    final stamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    return exportFileToDownloads(tmp.path, 'bittechat-log-$stamp.txt');
  }
}

/// Write [srcPath] into the public Downloads directory (MediaStore on API 29+,
/// direct write on 28) through the platform channel and return a
/// human-readable destination description. Shared by the log export and the
/// filter-script export.
Future<String> exportFileToDownloads(String srcPath, String name) async {
  const ch = MethodChannel('bittechat/files');
  final res = await ch.invokeMethod<String>(
      'exportToDownloads', {'path': srcPath, 'name': name});
  debugPrint('exported to downloads: $res');
  return res ?? 'Download/BitteChat/$name';
}

/// Log a line if the logger is up (no-op before init / on host tests).
void appLog(String msg) {
  AppLog._safeWrite(msg);
}

/// Dump our own process's logcat into the app log (Android only).
///
/// An app may always read its OWN log entries without permissions — this
/// captures the lines we cannot see from Dart: the Flutter renderer banner
/// ("Using the Impeller rendering backend…" vs Skia), MediaCodec/OpenGL
/// driver messages, mpv native logs, and native crash traces right before a
/// hard crash (which leaves nothing in the Dart log).
Future<void> captureOwnLogcat(String tag, {int tailLines = 220}) async {
  if (!Platform.isAndroid) return;
  if (!AppLog.ready) return;
  try {
    final r = await Process.run(
      'logcat',
      ['-d', '-v', 'brief', '--pid=$pid'],
    );
    final out = (r.stdout as String?) ?? '';
    final lines = out.split('\n').where((l) {
      final t = l.toLowerCase();
      // keep renderer/GPU/codec/crash/mpv-relevant lines, drop chattier ones
      return t.contains('impeller') ||
          t.contains('skia') ||
          t.contains('opengl') ||
          t.contains('egl') ||
          t.contains('vulkan') ||
          t.contains('mediacodec') ||
          t.contains('codec2') ||
          t.contains('c2.') ||
          t.contains('omx') ||
          t.contains('mpv') ||
          t.contains('mdk') ||
          t.contains('flutter') ||
          t.contains('androidruntime') ||
          t.contains('libc') ||
          t.contains('debug') ||
          t.contains('surface') ||
          t.contains('buffer') ||
          t.contains('bitte');
    }).toList();
    final tail = lines.length > tailLines
        ? lines.sublist(lines.length - tailLines)
        : lines;
    AppLog.instance
        .write('--- logcat($tag) ${tail.length} lines ---\n${tail.join('\n')}');
  } catch (e) {
    AppLog.instance.write('logcat capture failed: $e');
  }
}
