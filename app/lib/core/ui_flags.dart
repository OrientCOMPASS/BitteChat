import 'package:flutter/foundation.dart';

/// Globally suppresses the wallpaper layer.
///
/// The video page sets this while open: removing every Opacity/filter layer
/// underneath an external video texture eliminates one compositing variable
/// on GPU drivers with flaky external-texture + saveLayer interactions
/// (the suspect class for the on-device "decoded but black" reports).
final ValueNotifier<bool> wallpaperSuppressed = ValueNotifier<bool>(false);
