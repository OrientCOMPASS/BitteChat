import 'package:bittechat/core/platform/core_transport.dart';
import 'package:bittechat/core/platform/host_platform.dart';
import 'package:bittechat/core/platform/native_transport.dart';
import 'package:bittechat/core/platform/web_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HostPlatform detection', () {
    test('web wins over any target platform', () {
      expect(
        hostPlatformFrom(TargetPlatform.android, true),
        HostPlatform.web,
      );
    });

    test('maps every flutter target', () {
      expect(
        hostPlatformFrom(TargetPlatform.android, false),
        HostPlatform.android,
      );
      expect(hostPlatformFrom(TargetPlatform.iOS, false), HostPlatform.ios);
      expect(
        hostPlatformFrom(TargetPlatform.linux, false),
        HostPlatform.linux,
      );
      expect(
        hostPlatformFrom(TargetPlatform.macOS, false),
        HostPlatform.macos,
      );
      expect(
        hostPlatformFrom(TargetPlatform.windows, false),
        HostPlatform.windows,
      );
      expect(
        hostPlatformFrom(TargetPlatform.fuchsia, false),
        HostPlatform.unknown,
      );
      expect(hostPlatformFrom(null, false), HostPlatform.unknown);
    });

    test('detectHostPlatform yields a known enum value', () {
      expect(HostPlatform.values, contains(detectHostPlatform()));
    });
  });

  group('native library naming', () {
    test('android and linux share the .so name', () {
      expect(nativeLibraryName(HostPlatform.android), 'libbitte_core.so');
      expect(nativeLibraryName(HostPlatform.linux), 'libbitte_core.so');
    });

    test('apple platforms use .dylib, windows uses .dll', () {
      expect(nativeLibraryName(HostPlatform.macos), 'libbitte_core.dylib');
      expect(nativeLibraryName(HostPlatform.ios), 'libbitte_core.dylib');
      expect(nativeLibraryName(HostPlatform.windows), 'bitte_core.dll');
    });

    test('web has no native library and no ffi', () {
      expect(nativeLibraryName(HostPlatform.web), '');
      expect(HostPlatform.web.supportsNativeFfi, isFalse);
      expect(HostPlatform.unknown.supportsNativeFfi, isFalse);
      expect(HostPlatform.linux.isDesktop, isTrue);
      expect(HostPlatform.android.isDesktop, isFalse);
    });
  });

  group('transports (groundwork contract)', () {
    test('native transport declines on web without touching ffi', () {
      final t = NativeCoreTransport.open(
        dataDir: '/nonexistent',
        platform: HostPlatform.web,
      );
      expect(t.available, isFalse);
      expect(() => t.call('sys.info'), throwsA(isA<Exception>()));
    });

    test('native transport degrades to demo mode when lib is absent', () {
      // CI hosts carry no libbitte_core.so: opening must fall back to
      // demo mode instead of throwing.
      final t = NativeCoreTransport.open(
        dataDir: '/nonexistent',
        platform: HostPlatform.linux,
      );
      expect(t.available, isFalse);
    });

    test('web transport placeholder is never available', () {
      expect(WebCoreTransport.tryOpen(gatewayUrl: 'ws://gw'), isNull);
      final CoreTransport? t = WebCoreTransport.tryOpen();
      expect(t, isNull);
    });
  });
}
