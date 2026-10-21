import 'package:flutter/foundation.dart';

/// Platforms BitteChat can run on.
///
/// Android is the shipping target today; the desktop and web entries are
/// groundwork for the multi-platform track (see `docs/PLATFORMS.md`) and are
/// deliberately not wired into any build yet.
enum HostPlatform {
  android,
  ios,
  linux,
  macos,
  windows,
  web,
  unknown;

  bool get isDesktop => this == linux || this == macos || this == windows;

  /// True when the native core (libbitte_core) can be loaded in-process via
  /// dart:ffi. Web has no dart:ffi; its transport will be a network bridge
  /// to a self-hosted gateway instead (not implemented yet).
  bool get supportsNativeFfi => this != web && this != unknown;
}

/// Pure mapping kept separate from [detectHostPlatform] so tests can drive
/// every branch without faking the host platform.
HostPlatform hostPlatformFrom(TargetPlatform? target, bool isWeb) {
  if (isWeb) return HostPlatform.web;
  switch (target) {
    case TargetPlatform.android:
      return HostPlatform.android;
    case TargetPlatform.iOS:
      return HostPlatform.ios;
    case TargetPlatform.linux:
      return HostPlatform.linux;
    case TargetPlatform.macOS:
      return HostPlatform.macos;
    case TargetPlatform.windows:
      return HostPlatform.windows;
    case TargetPlatform.fuchsia:
      return HostPlatform.unknown;
    case null:
      return HostPlatform.unknown;
  }
}

/// The platform this process runs on.
HostPlatform detectHostPlatform() =>
    hostPlatformFrom(defaultTargetPlatform, kIsWeb);

/// File name of the native core library on a platform.
///
/// Groundwork for desktop packaging: only Android ships a library today, but
/// the naming is fixed here so the FFI loader and future desktop builds agree
/// on one source of truth. Empty string = no native library on this platform.
String nativeLibraryName(HostPlatform p) {
  switch (p) {
    case HostPlatform.android:
    case HostPlatform.linux:
      return 'libbitte_core.so';
    case HostPlatform.macos:
    case HostPlatform.ios:
      return 'libbitte_core.dylib';
    case HostPlatform.windows:
      return 'bitte_core.dll';
    case HostPlatform.web:
    case HostPlatform.unknown:
      return '';
  }
}
