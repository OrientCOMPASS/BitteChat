import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bittechat/l10n/app_localizations.dart';
import 'package:media_kit/media_kit.dart';

import 'core/api.dart';
import 'core/applog.dart';
import 'core/l10n.dart';
import 'core/intent.dart';
import 'core/prefs.dart';
import 'core/video_decode.dart';
import 'core/wallpaper.dart';
import 'pages/home.dart';

/// Media stack = media_kit (libmpv) for BOTH video and voice messages.
/// Video: decode ladder (zero-copy MediaCodec → MediaCodec read-back →
/// software) rendered through mpv's EGL surface — the rendering architecture
/// proven at scale by PiliPala-class apps on mainstream Android hardware,
/// with an automatic downgrade when a device's hwdec interop stalls (see
/// `core/video_decode.dart`).
/// Initialized once here; pages create Player instances on demand.
void initMediaStack() {
  try {
    MediaKit.ensureInitialized();
    appLog('media_kit initialized');
  } catch (e) {
    // e.g. host/desktop run without libmpv — playback degrades to disabled
    appLog('media_kit init FAILED: $e');
  }
}

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    AppLog.captureErrors();
    // lifecycle flips feed the crash-dump breadcrumb ring (the
    // resume-from-background crash leaves "paused" as its last crumb)
    WidgetsBinding.instance.addObserver(_CrashBreadcrumb());
    final api = await BitteApi.init();
    await AppLog.init(api.dataDir);
    appLog('=== app start ===');
    bindIntentChannel();
    final prefs = await UiPrefs.load(api.dataDir);
    initMediaStack();
    // remember which video decode rung this device settled on, and decode the
    // wallpaper BEFORE the first frame so page 1 already shows it
    await VideoDecodeChain.instance.bind(api.dataDir);
    await prewarmWallpaper(prefs);
    runApp(BitteChatApp(prefs: prefs));
  }, (e, st) {
    appLog('ZONE ERROR: $e\n$st');
    AppLog.crashDump('zone', e, st);
  });
}

/// Folds app lifecycle flips into the crash-dump breadcrumb ring so a
/// resume-from-background crash is diagnosable from `crash_dart.log`.
class _CrashBreadcrumb extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLog.breadcrumb('lifecycle:$state');
  }
}

/// Decode the configured wallpaper up-front so the very first frame of the app
/// already has it — the alternative is a visible "background pops in a moment
/// later" on cold start. Bounded: a corrupt/huge image must never delay the
/// UI, the layer just starts empty and fills in when the decode lands.
Future<void> prewarmWallpaper(UiPrefs prefs) async {
  if (prefs.wallpaperPath == null) return;
  try {
    await WallpaperCache.instance
        .load(wallpaperKeyOf(prefs), () => buildWallpaperFor(prefs))
        .timeout(const Duration(seconds: 4));
  } catch (e) {
    appLog('wallpaper prewarm skipped: $e');
  }
}

/// Cache key of the wallpaper described by [prefs]. Opacity is NOT part of it:
/// it is applied while painting, so dragging the opacity slider never triggers
/// a re-decode.
String wallpaperKeyOf(UiPrefs prefs) => WallpaperCache.buildKey(
      path: prefs.wallpaperPath,
      rev: prefs.wallpaperRev,
      sigma: prefs.wallpaperBlurSigma,
    );

/// Decoder for the wallpaper described by [prefs] (throws if there is none).
Future<WallpaperEntry> buildWallpaperFor(UiPrefs prefs) => WallpaperCache.build(
      key: wallpaperKeyOf(prefs),
      path: prefs.wallpaperPath!,
      sigma: prefs.wallpaperBlurSigma,
    );

class BitteChatApp extends StatefulWidget {
  const BitteChatApp({super.key, required this.prefs});

  final UiPrefs prefs;

  @override
  State<BitteChatApp> createState() => _BitteChatAppState();
}

class _BitteChatAppState extends State<BitteChatApp> {
  @override
  void initState() {
    super.initState();
    widget.prefs.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.prefs.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  ThemeData _theme(Brightness brightness) {
    final seed = widget.prefs.effectiveSeed();
    final scheme =
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // the global wallpaper (below) shows through every page
      scaffoldBackgroundColor: Colors.transparent,
      fontFamilyFallback: const [
        'Noto Sans CJK SC',
        'PingFang SC',
        'sans-serif'
      ],
      listTileTheme: const ListTileThemeData(dense: false),
      appBarTheme: const AppBarTheme(centerTitle: false),
      snackBarTheme:
          const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BitteChat',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: widget.prefs.materialThemeMode(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) {
        // app-wide background: solid theme color + optional wallpaper under
        // every route (scaffolds are transparent)
        final base = Theme.of(context).colorScheme.surface;
        return Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: base)),
            AppWallpaper(prefs: widget.prefs),
            Positioned.fill(child: child ?? const SizedBox.shrink()),
          ],
        );
      },
      home: Builder(
        builder: (ctx) {
          L.update(ctx);
          return HomePage(prefs: widget.prefs);
        },
      ),
    );
  }
}

/// Global wallpaper layer, rendered under the Navigator so it spans the
/// whole application (chat, torrents, feeds, settings).
///
/// All decoding lives in the app-wide [WallpaperCache]: this widget only asks
/// for a key and paints whatever bitmap the cache has. Rebuilding it (route
/// changes, prefs notifications, activity recreation) is therefore free — no
/// re-read, no re-decode, no flash — which is what used to make navigating
/// back from the chat detail page feel laggy. Opacity changes repaint only.
class AppWallpaper extends StatefulWidget {
  const AppWallpaper({super.key, required this.prefs});

  final UiPrefs prefs;

  @override
  State<AppWallpaper> createState() => _AppWallpaperState();
}

class _AppWallpaperState extends State<AppWallpaper> {
  @override
  void initState() {
    super.initState();
    WallpaperCache.instance.addListener(_onChange);
    _request();
  }

  @override
  void didUpdateWidget(AppWallpaper oldWidget) {
    super.didUpdateWidget(oldWidget);
    _request();
  }

  @override
  void dispose() {
    WallpaperCache.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _request() {
    final path = widget.prefs.wallpaperPath;
    if (path == null) {
      WallpaperCache.instance.clear();
      return;
    }
    unawaited(WallpaperCache.instance.load(
        wallpaperKeyOf(widget.prefs), () => buildWallpaperFor(widget.prefs)));
  }

  @override
  Widget build(BuildContext context) {
    final entry = WallpaperCache.instance.current;
    if (entry == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          // opacity rides along in the paint's alpha (WallpaperPainter), so
          // there is no Opacity layer and no full-screen saveLayer per frame;
          // the RepaintBoundary keeps route transitions from repainting us
          child: CustomPaint(
            size: Size.infinite,
            painter: WallpaperPainter(
              image: entry.image,
              opacity: widget.prefs.wallpaperOpacity,
            ),
          ),
        ),
      ),
    );
  }
}
