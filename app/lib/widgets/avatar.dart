// 头像组件：颜色由公钥/群 ID 哈希决定（稳定不变），文字取名称首字符

import 'package:flutter/material.dart';

import '../models.dart';

class KeyAvatar extends StatelessWidget {
  const KeyAvatar({
    super.key,
    required this.keyHex,
    required this.name,
    this.size = 40,
    this.fontSize,
  });

  final String keyHex;
  final String name;
  final double size;
  final double? fontSize;

  Color get _color =>
      HSLColor.fromAHSL(1, colorFromKey(keyHex), 0.45, 0.45).toColor();

  String get _initial {
    final n = name.trim();
    if (n.isEmpty) return '?';
    final r = n.runes.first;
    return String.fromCharCode(r).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _color,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Text(
        _initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: fontSize ?? size * 0.45,
        ),
      ),
    );
  }
}

class GroupAvatar extends StatelessWidget {
  const GroupAvatar({
    super.key,
    required this.name,
    required this.keyHex,
    this.size = 48,
  });

  final String name;
  final String keyHex;
  final double size;

  @override
  Widget build(BuildContext context) {
    return KeyAvatar(keyHex: keyHex, name: name, size: size);
  }
}
