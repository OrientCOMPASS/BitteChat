// magnet: intent 桥接（Android 系统级"用 BitteChat 打开磁力链"）

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 待处理的入群磁力链（UI 消费后清空）。
final ValueNotifier<String?> pendingMagnet = ValueNotifier<String?>(null);

const _channel = MethodChannel('bittechat/intent');

bool _bound = false;

void bindIntentChannel() {
  if (_bound) return;
  _bound = true;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'magnet' && call.arguments is String) {
      pendingMagnet.value = call.arguments as String;
    }
    return null;
  });
  // pull the launch intent (cold start)
  _channel.invokeMethod<String>('takePendingMagnet').then((m) {
    if (m != null && m.isNotEmpty) pendingMagnet.value = m;
  }).catchError((_) {});
}
