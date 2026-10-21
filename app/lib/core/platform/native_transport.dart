import '../bridge.dart';
import 'core_transport.dart';
import 'host_platform.dart';

/// In-process FFI transport — the production path on Android, and the
/// prepared path for desktop (same code, different library file name).
///
/// Wraps the existing [BitteBridge] 1:1 so there is exactly one dart:ffi
/// code path in the app; the API layer can migrate to [CoreTransport]
/// later without any behavior change.
class NativeCoreTransport implements CoreTransport {
  NativeCoreTransport(this._bridge, this._events);

  final BitteBridge? _bridge;
  final Stream<String> _events;

  /// Opens the core for [platform] (defaults to the current host).
  ///
  /// Never throws: platforms without native FFI support, or a missing /
  /// unloadable library, degrade to an unavailable transport so the UI can
  /// fall back to demo mode exactly like it does on Android today.
  static NativeCoreTransport open({
    required String dataDir,
    int listenPort = 17531,
    HostPlatform? platform,
  }) {
    final p = platform ?? detectHostPlatform();
    if (!p.supportsNativeFfi) {
      return NativeCoreTransport(null, const Stream.empty());
    }
    final bridge = BitteBridge.tryOpen(
      dataDir: dataDir,
      listenPort: listenPort,
    );
    return NativeCoreTransport(
      bridge,
      bridge?.events ?? const Stream.empty(),
    );
  }

  @override
  bool get available => _bridge != null;

  @override
  Map<String, dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    final b = _bridge;
    if (b == null) {
      throw BridgeException('native core unavailable on this platform');
    }
    return b.call(method, params);
  }

  @override
  Stream<String> get events => _events;

  @override
  Future<void> close() async {
    await _bridge?.close();
  }
}
