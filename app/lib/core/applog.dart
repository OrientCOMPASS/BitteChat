// Dart-side file logging + crash capture + log export.
//
// Writes <dataDir>/logs/app.log (rolling: app.log -> app.1.log at 2 MB) and
// installs Flutter error handlers so widget/async errors land in the same
// exportable bundle as the core's logs. Export copies every log file into
// one text file and hands it to the platform channel, which writes it to
// the public Download directory (MediaStore on API 29+).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppLog {
  AppLog._(this._dir);

  final String _dir;
  static AppLog? _instance;
  static AppLog get instance => _instance!;
  static bool get ready => _instance != null;

  static const _maxBytes = 2 * 1024 * 1024;

  File get _file => File('$_dir/logs/app.log');

  static Future<void> init(String dataDir) async {
    try {
      await Directory('$dataDir/logs').create(recursive: true);
      final log = AppLog._(dataDir);
      _instance = log;
      await log._rotateIfNeeded();
      log.write('app log started (pid=${pid})');
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

  Future<void> _rotateIfNeeded() async {
    try {
      final f = _file;
      if (await f.exists() && await f.length() > _maxBytes) {
        final old = File('$_dir/logs/app.1.log');
        if (await old.exists()) await old.delete();
        await f.rename(old.path);
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
    const ch = MethodChannel('bittechat/files');
    final res = await ch.invokeMethod<String>('exportToDownloads', {
      'path': tmp.path,
      'name': 'bittechat-log-$stamp.txt',
    });
    debugPrint('log exported: $res');
    return res ?? 'Download/BitteChat';
  }
}

/// Log a line if the logger is up (no-op before init / on host tests).
void appLog(String msg) {
  AppLog._safeWrite(msg);
}
