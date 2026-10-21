// 全局本地化访问器：根 Builder 每帧刷新，业务代码任意位置可用 L.t.xxx。
// （避免 200+ 处调用点层层传递 BuildContext；locale 切换时 MaterialApp
//   重建 home，L.update 随之刷新。）

import 'package:flutter/widgets.dart';
import 'package:bittechat/l10n/app_localizations.dart';
import 'package:bittechat/l10n/app_localizations_zh.dart';

class L {
  static AppLocalizations? _current;

  static void update(BuildContext context) {
    _current = AppLocalizations.of(context);
  }

  static AppLocalizations get t =>
      _current ?? AppLocalizationsZh(); // fallback before first frame

  /// Test hook: force a locale without a widget tree.
  static void debugSet(AppLocalizations? value) => _current = value;
}
