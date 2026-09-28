import 'package:flutter/material.dart';
import 'package:bittechat/l10n/app_localizations.dart';

import 'core/api.dart';
import 'core/l10n.dart';
import 'core/intent.dart';
import 'core/prefs.dart';
import 'pages/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    return ThemeData(
      useMaterial3: true,
      colorScheme:
          ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
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
      home: Builder(
        builder: (ctx) {
          L.update(ctx);
          return HomePage(prefs: widget.prefs);
        },
      ),
    );
  }
}
