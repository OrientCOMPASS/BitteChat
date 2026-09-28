import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:bittechat/l10n/app_localizations.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'core/api.dart';
import 'core/l10n.dart';
import 'core/intent.dart';
import 'core/prefs.dart';
import 'pages/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Route video_player through libmdk (fvp): hardware decode when available
  // with an FFmpeg software fallback, so formats the platform decoder cannot
  // handle (Hi10P / HEVC10 / AV1 / VP9 …) still show a picture instead of
  // playing audio over a black screen.
  fvp.registerWith(options: {
    'platforms': ['android'],
  });
  final api = await BitteApi.init();
  bindIntentChannel();
  final prefs = await UiPrefs.load(api.dataDir);
  runApp(BitteChatApp(prefs: prefs));
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

/// Global wallpaper layer: full-bleed image at the configured opacity,
/// optionally blurred. Rendered under the Navigator so it spans the whole
/// application (chat, torrents, feeds, settings), not just the chat page.
class AppWallpaper extends StatelessWidget {
  const AppWallpaper({super.key, required this.prefs});

  final UiPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final path = prefs.wallpaperPath;
    if (path == null) return const SizedBox.shrink();
    Widget img = Image.file(
      File(path),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      // cap the decoded size so huge photos don't blow up memory
      cacheWidth: 1440,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    if (prefs.wallpaperBlur) {
      img = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: img,
      );
    }
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
            opacity: prefs.wallpaperOpacity.clamp(0.03, 1.0), child: img),
      ),
    );
  }
}
