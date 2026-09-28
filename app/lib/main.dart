import 'package:flutter/material.dart';

import 'core/api.dart';
import 'core/intent.dart';
import 'pages/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BitteApi.init();
  bindIntentChannel();
  runApp(const BitteChatApp());
}

class BitteChatApp extends StatelessWidget {
  const BitteChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E7CF6);
    return MaterialApp(
      title: 'BitteChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        fontFamilyFallback: const [
          'Noto Sans CJK SC',
          'PingFang SC',
          'sans-serif'
        ],
        listTileTheme: const ListTileThemeData(dense: false),
        appBarTheme: const AppBarTheme(centerTitle: false),
        snackBarTheme:
            const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        fontFamilyFallback: const [
          'Noto Sans CJK SC',
          'PingFang SC',
          'sans-serif'
        ],
        appBarTheme: const AppBarTheme(centerTitle: false),
        snackBarTheme:
            const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      ),
      home: const HomePage(),
    );
  }
}
