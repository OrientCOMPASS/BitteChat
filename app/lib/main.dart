import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:bittechat/l10n/app_localizations.dart';
import 'package:media_kit/media_kit.dart';

import 'core/api.dart';
import 'core/applog.dart';
import 'core/ui_flags.dart';
import 'core/l10n.dart';
import 'core/intent.dart';
import 'core/prefs.dart';
import 'pages/home.dart';

/// Media stack = media_kit (libmpv) for BOTH video and voice messages.
/// Video: hardware decode chain (hwdec=mediacodec,auto-safe, no ffmpeg
/// software fallback) rendered through mpv's EGL surface — the architecture
/// proven at scale by PiliPala-class apps on mainstream Android hardware.
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
    final api = await BitteApi.init();
    await AppLog.init(api.dataDir);
    appLog('=== app start ===');
    bindIntentChannel();
    final prefs = await UiPrefs.load(api.dataDir);
    initMediaStack();
    runApp(BitteChatApp(prefs: prefs));
  }, (e, st) {
    appLog('ZONE ERROR: $e\n$st');
  });
}

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
/// The image is decoded ONCE into a [ui.Image] (blur baked in when enabled)
/// and painted with [RawImage]: navigating between pages never re-resolves
/// or re-decodes anything, so there is no flicker and no load delay — the
/// old Image.file-based layer visibly lagged route transitions.
class AppWallpaper extends StatefulWidget {
  const AppWallpaper({super.key, required this.prefs});

  final UiPrefs prefs;

  @override
  State<AppWallpaper> createState() => _AppWallpaperState();
}

class _AppWallpaperState extends State<AppWallpaper> {
  ui.Image? _image;
  String? _loadedPath;
  double? _loadedSigma;
  int _loadedRev = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AppWallpaper oldWidget) {
    super.didUpdateWidget(oldWidget);
    // the root state rebuilds us on every prefs notification; reload only
    // when the image source or the blur flag changed (opacity is a paint
    // parameter and needs no decode)
    if (_loadedPath != widget.prefs.wallpaperPath ||
        _loadedSigma != widget.prefs.wallpaperBlurSigma ||
        _loadedRev != widget.prefs.wallpaperRev) {
      _load();
    }
  }

  Future<void> _load() async {
    final path = widget.prefs.wallpaperPath;
    final sigma = widget.prefs.wallpaperBlurSigma;
    _loadedPath = path;
    _loadedSigma = sigma;
    _loadedRev = widget.prefs.wallpaperRev;
    if (path == null) {
      if (_image != null && mounted) {
        setState(() {
          _image?.dispose();
          _image = null;
        });
      }
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1440);
      final frame = await codec.getNextFrame();
      codec.dispose();
      var img = frame.image;
      if (sigma > 0) img = await _blurred(img, sigma);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = img;
      });
    } catch (e) {
      appLog('wallpaper load failed: $e');
      if (mounted) {
        setState(() {
          _image?.dispose();
          _image = null;
        });
      }
    }
  }

  /// Bake the blur into the decoded bitmap once — an ImageFiltered layer
  /// would re-render a full-screen blur on every navigation frame.
  static Future<ui.Image> _blurred(ui.Image src, double sigma) async {
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    final paint = Paint()
      ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    canvas.drawImage(src, Offset.zero, paint);
    final pic = rec.endRecording();
    final out = await pic.toImage(src.width, src.height);
    pic.dispose();
    src.dispose();
    return out;
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: wallpaperSuppressed,
      builder: (context, suppressed, _) {
        if (suppressed) return const SizedBox.shrink();
        return Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: widget.prefs.wallpaperOpacity.clamp(0.03, 1.0),
              child: RawImage(image: img, fit: BoxFit.cover),
            ),
          ),
        );
      },
    );
  }
}
