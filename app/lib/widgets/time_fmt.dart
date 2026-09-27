// 时间格式化助手（毫秒时间戳 → 中文习惯显示）

import 'package:intl/intl.dart';

DateTime _dt(int ms) => DateTime.fromMillisecondsSinceEpoch(ms <= 0 ? 0 : ms);

/// 列表页时间：今天 → HH:mm；今年 → MM-dd；更早 → yyyy-MM-dd
String formatListTime(int ms) {
  if (ms <= 0) return '';
  final d = _dt(ms);
  final now = DateTime.now();
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return DateFormat('HH:mm').format(d);
  }
  if (d.year == now.year) {
    return DateFormat('MM-dd').format(d);
  }
  return DateFormat('yyyy-MM-dd').format(d);
}

/// 气泡时间 HH:mm
String formatClock(int ms) =>
    ms <= 0 ? '' : DateFormat('HH:mm').format(_dt(ms));

/// 日期分割条：今天/昨天/星期X/MM-dd/yyyy-MM-dd
String formatDayLabel(int ms) {
  if (ms <= 0) return '';
  final d = _dt(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final diff = today.difference(that).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (diff < 7) {
    const names = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    return names[that.weekday - 1];
  }
  if (d.year == now.year) return DateFormat('MM-dd').format(d);
  return DateFormat('yyyy-MM-dd').format(d);
}

/// 完整时间
String formatFull(int ms) =>
    ms <= 0 ? '—' : DateFormat('yyyy-MM-dd HH:mm').format(_dt(ms));
