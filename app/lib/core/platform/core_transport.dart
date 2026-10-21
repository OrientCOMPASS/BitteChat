/// Transport between the Dart app and the BitteChat core (Rust).
///
/// The app talks to the core exclusively through a synchronous JSON-RPC
/// surface plus a stream of JSON event strings. Today the only production
/// implementation is the in-process FFI bridge (`NativeCoreTransport`,
/// Android). The interface exists so additional platforms can be slotted in
/// without touching the API layer:
///
/// * desktop (Linux/Windows/macOS): the same FFI transport, loading a
///   differently named library — see `nativeLibraryName` in
///   `host_platform.dart`;
/// * web: a network transport speaking JSON-RPC to a self-hosted gateway
///   that runs the native core server-side, with server-pushed events
///   replacing the `sys.drain_events` poll. Not implemented yet — this
///   milestone is groundwork only (see `docs/PLATFORMS.md`).
abstract class CoreTransport {
  /// False when the core is unavailable and the app runs in demo mode.
  bool get available;

  /// Synchronous JSON-RPC call; implementations throw on `ok:false`
  /// responses (the error message is the `error` field).
  Map<String, dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]);

  /// Raw core events as JSON strings: `{"type": ..., "data": {...}}`.
  Stream<String> get events;

  /// Releases the underlying core session (idempotent).
  Future<void> close();
}
