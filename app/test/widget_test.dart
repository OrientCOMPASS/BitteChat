// Widget tests runnable without the native core (demo mode).

import 'package:bittechat/core/api.dart';
import 'package:bittechat/core/l10n.dart';
import 'package:bittechat/l10n/app_localizations_en.dart';
import 'package:bittechat/l10n/app_localizations_zh.dart';
import 'package:bittechat/main.dart';
import 'package:bittechat/core/prefs.dart';
import 'package:bittechat/models.dart';
import 'package:bittechat/pages/chat_view.dart';
import 'package:bittechat/widgets/avatar.dart';
import 'package:bittechat/widgets/time_fmt.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots in demo mode without native core', (tester) async {
    final api = await BitteApi.init();
    final prefs = UiPrefs(File('${api.dataDir}/ui_prefs_test.json'));
    await tester.pumpWidget(BitteChatApp(prefs: prefs));
    await tester.pumpAndSettle();
    // test platform locale is en_US -> English UI
    expect(find.widgetWithText(NavigationDestination, 'Chats'), findsOneWidget);
    expect(
        find.widgetWithText(NavigationDestination, 'Torrents'), findsOneWidget);
    expect(find.widgetWithText(NavigationDestination, 'Feeds'), findsOneWidget);
    // demo hint on the chat tab
    expect(find.text('Demo mode'), findsOneWidget);
  });

  testWidgets('avatar renders initial with stable color', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KeyAvatar(keyHex: 'aa' * 20, name: '小明'),
      ),
    ));
    expect(find.text('小'), findsOneWidget);
  });

  testWidgets('message bubble shows text and author', (tester) async {
    final m = ChatMessage(
      id: 'x',
      group: 'g',
      authorPk: 'bb' * 32,
      authorName: '小红',
      ts: DateTime(2026, 9, 27, 10, 30).millisecondsSinceEpoch,
      kind: 1,
      own: false,
      state: 1,
      text: '链上见！',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MessageBubble(message: m, showAuthor: true),
        ),
      ),
    ));
    expect(find.text('链上见！'), findsOneWidget);
    expect(find.text('小红'), findsOneWidget);
    expect(find.text(formatClock(m.ts)), findsOneWidget);
  });

  testWidgets('system message centered', (tester) async {
    final m = ChatMessage(
      id: 'y',
      group: 'g',
      authorPk: 'cc' * 32,
      authorName: '阿伟',
      ts: 1700000000000,
      kind: 3,
      own: false,
      state: 1,
      systemCode: 'create',
      systemDetail: '测试群',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MessageBubble(message: m, showAuthor: false)),
    ));
    expect(find.textContaining('created group'), findsOneWidget);
  });

  test('time formatting labels follow locale', () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 9, 5);
    final yesterday = today.subtract(const Duration(days: 1));
    L.debugSet(AppLocalizationsZh());
    expect(formatDayLabel(today.millisecondsSinceEpoch), '今天');
    expect(formatDayLabel(yesterday.millisecondsSinceEpoch), '昨天');
    L.debugSet(AppLocalizationsEn());
    expect(formatDayLabel(today.millisecondsSinceEpoch), 'Today');
    expect(formatDayLabel(yesterday.millisecondsSinceEpoch), 'Yesterday');
    expect(formatClock(today.millisecondsSinceEpoch), '09:05');
    expect(formatListTime(0), '');
    L.debugSet(null);
  });
}
