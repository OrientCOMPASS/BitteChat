import 'core_transport.dart';

/// Placeholder for the future WebUI transport (see `docs/PLATFORMS.md`).
///
/// Planned shape: JSON-RPC over WebSocket to a self-hosted gateway that runs
/// the native core server-side, with server-pushed events replacing the
/// `sys.drain_events` poll used by the FFI transport. A pure-wasm core is
/// the alternative long-term route; either way the app-facing contract is
/// this [CoreTransport] interface, which is the reason it exists.
///
/// Deliberately NOT implemented — the current milestone is groundwork only,
/// so [tryOpen] always reports "unavailable" and the demo-mode fallback
/// applies on the web.
class WebCoreTransport implements CoreTransport {
  /// Returns null until the gateway transport is implemented; the signature
  /// fixes the future configuration surface (gateway URL).
  static WebCoreTransport? tryOpen({String? gatewayUrl}) => null;

  @override
  bool get available => false;

  @override
  Map<String, dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    throw UnsupportedError('web transport is not implemented yet');
  }

  @override
  Stream<String> get events => const Stream.empty();

  @override
  Future<void> close() async {}
}
