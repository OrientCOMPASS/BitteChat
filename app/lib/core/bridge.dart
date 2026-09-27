// FFI bridge to libbitte_core.so (Rust core).
//
// Two channels:
//   * bc_call(method, jsonParams) -> jsonResult   (synchronous commands)
//   * event callback -> Stream<String>            (asynchronous UI events)
//
// The native library only exists on Android builds produced by CI; on host
// platforms (flutter test / desktop) [BitteBridge.tryOpen] returns null and
// the app runs in "demo" mode.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _InitNative = ffi.Int64 Function(
    ffi.Pointer<Utf8> cfg,
    ffi.Pointer<
            ffi.NativeFunction<
                ffi.Void Function(
                    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Uint32)>>
        cb,
    ffi.Pointer<ffi.Void> ctx);
typedef _InitDart = int Function(
    ffi.Pointer<Utf8>,
    ffi.Pointer<
        ffi.NativeFunction<
            ffi.Void Function(
                ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Uint32)>>,
    ffi.Pointer<ffi.Void>);

typedef _CallNative = ffi.Pointer<Utf8> Function(
    ffi.Int64 handle, ffi.Pointer<Utf8> method, ffi.Pointer<Utf8> params);
typedef _CallDart = ffi.Pointer<Utf8> Function(
    int, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>);

typedef _FreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeDart = void Function(ffi.Pointer<Utf8>);

typedef _ShutdownNative = ffi.Void Function(ffi.Int64);
typedef _ShutdownDart = void Function(int);

typedef _VersionNative = ffi.Pointer<Utf8> Function();
typedef _VersionDart = ffi.Pointer<Utf8> Function();

/// Native (C) signature of the event callback. The Dart-side closure uses
/// `(Pointer<Void>, Pointer<Utf8>, int)` via NativeCallable's conversion.
typedef _EventNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Uint32);

class BridgeException implements Exception {
  BridgeException(this.message);
  final String message;
  @override
  String toString() => 'BridgeException: $message';
}

class BitteBridge {
  BitteBridge._(
      this._lib, this._handle, this._callable, this._controller, this.events);

  final ffi.DynamicLibrary _lib;
  final int _handle;
  final ffi.NativeCallable<_EventNative> _callable;
  final StreamController<String> _controller;

  /// Raw JSON event strings pushed by the core.
  final Stream<String> events;

  late final _CallDart _call =
      _lib.lookupFunction<_CallNative, _CallDart>('bc_call');
  late final _FreeDart _free =
      _lib.lookupFunction<_FreeNative, _FreeDart>('bc_free');
  late final _ShutdownDart _shutdown =
      _lib.lookupFunction<_ShutdownNative, _ShutdownDart>('bc_shutdown');

  static String? get nativeVersion {
    try {
      final lib = _openLib();
      final v =
          lib.lookupFunction<_VersionNative, _VersionDart>('bc_version')();
      return v.toDartString();
    } catch (_) {
      return null;
    }
  }

  static ffi.DynamicLibrary _openLib() {
    if (Platform.isAndroid) return ffi.DynamicLibrary.open('libbitte_core.so');
    throw UnsupportedError('native core only available on Android');
  }

  /// Open the core. Returns null when the native library is unavailable
  /// (host tests / desktop).
  static BitteBridge? tryOpen(
      {required String dataDir, int listenPort = 17531}) {
    try {
      final lib = _openLib();
      final controller = StreamController<String>.broadcast();
      late final ffi.NativeCallable<_EventNative> callable;
      callable = ffi.NativeCallable<_EventNative>.listener(
          (ffi.Pointer<ffi.Void> ctx, ffi.Pointer<Utf8> json, int len) {
        if (json == ffi.nullptr) return;
        final bytes = json.cast<ffi.Uint8>().asTypedList(len);
        try {
          controller.add(utf8.decode(bytes));
        } catch (_) {
          // ignore malformed events
        }
      });

      final init = lib.lookupFunction<_InitNative, _InitDart>('bc_init');
      final cfg = jsonEncode({'data_dir': dataDir, 'listen_port': listenPort});
      final cfgPtr = cfg.toNativeUtf8();
      final handle = init(cfgPtr, callable.nativeFunction, ffi.nullptr);
      calloc.free(cfgPtr);
      if (handle <= 0) {
        callable.close();
        return null;
      }
      return BitteBridge._(
          lib, handle, callable, controller, controller.stream);
    } catch (e) {
      return null;
    }
  }

  /// Invoke a core method; throws [BridgeException] on error responses.
  Map<String, dynamic> call(String method,
      [Map<String, dynamic> params = const {}]) {
    final mPtr = method.toNativeUtf8();
    final pPtr = jsonEncode(params).toNativeUtf8();
    try {
      final out = _call(_handle, mPtr, pPtr);
      if (out == ffi.nullptr) {
        throw BridgeException('$method: null response');
      }
      final text = out.toDartString();
      _free(out);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw BridgeException('$method: malformed response');
      }
      if (decoded['ok'] != true) {
        throw BridgeException('${decoded['error'] ?? 'unknown error'}');
      }
      return decoded;
    } finally {
      calloc.free(mPtr);
      calloc.free(pPtr);
    }
  }

  Future<void> close() async {
    _shutdown(_handle);
    _callable.close();
    await _controller.close();
  }
}
