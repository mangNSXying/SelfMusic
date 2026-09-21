import 'package:flutter/material.dart';

import '../data/local/app_settings.dart';

/// 按设置构建页面切换过渡：关闭 / 淡入 / 滑动 / 缩放。
///
/// 播放页（播放/歌词）与全局内容区（各分组/设置/源内/歌单详情）共用。
/// [slideOffset] 为滑动模式新页面的进入方向：(1,0) 从右侧整页滑入（前进），
/// (-1,0) 从左侧滑入（返回），(0,1)/(0,-1) 为竖向手势（上滑进播放页/下滑回列表）。
/// [backdrop] 为新页衬底色（AnimatedSwitcher 新旧页共存时防重叠透视，
/// 改进 B6-U8；调用方传 `Theme.of(context).scaffoldBackgroundColor`）。
Widget pageTransition(PlayerTransition t, Widget child, Animation<double> anim,
    {Offset slideOffset = const Offset(1, 0), Color? backdrop}) {
  Widget opaque(Widget w) =>
      backdrop == null ? w : ColoredBox(color: backdrop, child: w);
  switch (t) {
    case PlayerTransition.none:
      return child;
    case PlayerTransition.fade:
      return FadeTransition(opacity: anim, child: opaque(child));
    case PlayerTransition.slide:
      return SlideTransition(
        position: Tween<Offset>(begin: slideOffset, end: Offset.zero)
            .animate(anim),
        child: opaque(child),
      );
    case PlayerTransition.scale:
      return ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1.0).animate(anim),
        child: FadeTransition(opacity: anim, child: opaque(child)),
      );
  }
}
