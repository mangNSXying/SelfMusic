import 'package:flutter/material.dart';

import '../data/local/app_settings.dart';

/// 按设置构建页面切换过渡：关闭 / 淡入 / 滑动 / 缩放。
///
/// 播放页（播放/歌词）与全局内容区（各分组/设置/源内/歌单详情）共用。
Widget pageTransition(PlayerTransition t, Widget child, Animation<double> anim) {
  switch (t) {
    case PlayerTransition.none:
      return child;
    case PlayerTransition.fade:
      return FadeTransition(opacity: anim, child: child);
    case PlayerTransition.slide:
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(0.3, 0), end: Offset.zero)
            .animate(anim),
        child: FadeTransition(opacity: anim, child: child),
      );
    case PlayerTransition.scale:
      return ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1.0).animate(anim),
        child: FadeTransition(opacity: anim, child: child),
      );
  }
}
