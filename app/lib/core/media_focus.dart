// 统一的 Android 音频焦点 / 播放抢断协调器。
//
// 目标：应用内**任意**会出声的播放（视频、语音/音乐条）开始时，都要
//   1) 抢占系统音频焦点（AUDIOFOCUS_GAIN）——让系统里**其他**正在播放的
//      媒体（音乐 App、浏览器…）收到 LOSS 并暂停（这就是「播放抢断」）；
//   2) 停掉应用内**另一个**正在播放的媒体（视频 ↔ 语音条互斥）；
//   3) 当本应用**失去**焦点（被别的 App 抢走 / 来电）时暂停自己。
//
// 之前只有视频页各自调用 MethodChannel 申请焦点，语音条从不申请，所以
// 「音乐播放不会让系统其他媒体暂停」，且视频与语音可能叠播。这里把焦点
// 收敛成单一持有者（同一时刻只有一个 in-app owner），视频与音频共用。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'applog.dart';

/// Called when this owner must stop making noise: either because another
/// in-app surface took over ([MediaFocus.acquire] with a different owner) or
/// because Android revoked our audio focus (loss / transient loss).
typedef MediaFocusStop = FutureOr<void> Function();

class MediaFocus {
  MediaFocus._();

  static final MediaFocus instance = MediaFocus._();
  static const MethodChannel _ch = MethodChannel('bittechat/media');

  bool _handlerBound = false;
  Object? _owner;
  MediaFocusStop? _onStop;

  /// True while we hold the *system* audio focus (one flag for the whole app:
  /// hand-offs video↔audio keep it, a real stop releases it).
  bool _systemFocus = false;

  void _bind() {
    if (_handlerBound) return;
    _handlerBound = true;
    _ch.setMethodCallHandler((call) async {
      // Native forwards AudioManager focus changes here.
      if (call.method == 'audioFocusChange') {
        final change = call.arguments;
        _onSystemFocusChange(change is int ? change : 0);
      }
      return null;
    });
  }

  void _onSystemFocusChange(int change) {
    // AudioManager.AUDIOFOCUS_LOSS == -1, AUDIOFOCUS_LOSS_TRANSIENT == -2,
    // AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK == -3. All mean "stop / duck"; for a
    // chat client the sane response to any loss is to pause playback.
    if (change < 0) {
      appLog('media focus lost ($change) -> pausing current media');
      final stop = _onStop;
      if (stop != null) unawaited(Future.sync(stop).catchError((_) {}));
    }
  }

  /// Take over the audio path for [owner]. Stops any other in-app surface
  /// first, then requests the system audio focus (which interrupts whatever
  /// else on the device is playing).
  Future<void> acquire(Object owner, MediaFocusStop onStop) async {
    _bind();
    final prev = _owner;
    final prevStop = _onStop;
    _owner = owner;
    _onStop = onStop;
    if (prev != null && !identical(prev, owner) && prevStop != null) {
      try {
        await Future.sync(prevStop);
      } catch (_) {}
    }
    if (!Platform.isAndroid || _systemFocus) return;
    _systemFocus = true;
    try {
      final ok = await _ch.invokeMethod<bool>('requestAudioFocus');
      appLog('media focus: granted=$ok owner=$owner');
    } catch (e) {
      appLog('media focus request failed: $e');
    }
  }

  /// Release focus held by [owner]. A no-op if a different surface already
  /// took over (so a stopping voice row never kills the video's focus).
  Future<void> release(Object owner) async {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _onStop = null;
    if (!Platform.isAndroid || !_systemFocus) return;
    _systemFocus = false;
    try {
      await _ch.invokeMethod<bool>('abandonAudioFocus');
    } catch (_) {}
  }

  /// Tell the native side whether a fresh AUDIOFOCUS_GAIN may be granted.
  ///
  /// [accept]=false after a user pause / system focus loss, so a video that
  /// keeps reporting `playing=true` cannot immediately steal focus back and
  /// re-interrupt the user's music; [accept]=true again once audio really
  /// stops. No-op off Android.
  Future<void> setAcceptGain(bool accept) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<bool>(
          'setAcceptAudioFocusGain', <String, dynamic>{'accept': accept});
    } catch (_) {}
  }
}
