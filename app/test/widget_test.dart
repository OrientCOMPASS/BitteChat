// Widget tests runnable without the native core (demo mode).

import 'package:bittechat/core/api.dart';
import 'package:bittechat/main.dart';
import 'package:bittechat/models.dart';
import 'package:bittechat/pages/chat_view.dart';
import 'package:bittechat/widgets/avatar.dart';
import 'package:bittechat/widgets/time_fmt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots in demo mode without native core', (tester) async {
    await BitteApi.init();
    await tester.pumpWidget(const BitteChatApp());
    await tester.pumpAndSettle();
    expect(find.widgetWithText(NavigationDestination, '聊天'), findsOneWidget);
    expect(find.widgetWithText(NavigationDestination, '种子'), findsOneWidget);
    expect(find.widgetWithText(NavigationDestination, '订阅'), findsOneWidget);
    // demo hint on the chat tab
    expect(find.text('演示模式'), findsOneWidget);
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
    expect(find.textContaining('创建了群聊'), findsOneWidget);
  });

  test('time formatting labels', () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 9, 5);
    expect(formatDayLabel(today.millisecondsSinceEpoch), '今天');
    final yesterday = today.subtract(const Duration(days: 1));
    expect(formatDayLabel(yesterday.millisecondsSinceEpoch), '昨天');
    expect(formatClock(today.millisecondsSinceEpoch), '09:05');
    expect(formatListTime(0), '');
  });
}
