/// 全 App 按钮/工具条尺寸 token。
///
/// 与 [AppTheme] 中的按钮主题配合使用：文本按钮高度、圆角在这里定义，
/// 各页面不再各写 `styleFrom`。工具条图标（排序/分类/视图/关闭等）以
/// [kToolbarButtonSize] 见方、[kToolbarIconSize] 图标为 1.0 基准，再乘
/// [appUiScaleOf] 随窗口放大，避免同一条栏内出现 32/40/48 三种命中区。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 竖屏窗口的缩放口径：400×800 为 1.0，小窗口锁定 1.0，封顶 2.4。
double portraitUiScale(Size viewport) {
  final w = math.max(1.0, viewport.width);
  final h = math.max(1.0, viewport.height);
  return _clampScale(math.min(w / 400, h / 800), 2.4);
}

/// 横屏窗口的缩放口径：1920×1080 为 1.0，小窗口锁定 1.0，封顶 2.2。
double landscapeUiScale(Size viewport) {
  final w = math.max(1.0, viewport.width);
  final h = math.max(1.0, viewport.height);
  return _clampScale(math.min(w / 1920, h / 1080), 2.2);
}

/// 按窗口朝向取统一缩放系数：播放页控件与内容页工具条共用同一口径，
/// 避免大窗口下播放控制放大、工具条仍停在小尺寸。
double appUiScaleOf(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width > size.height
      ? landscapeUiScale(size)
      : portraitUiScale(size);
}

double _clampScale(double value, double max) =>
    value < 1.0 ? 1.0 : (value > max ? max : value);

/// 标准按钮高度（Filled / Outlined / Text）。
const double kButtonHeight = 40;

/// 标准按钮圆角（与输入框、卡片一致）。
const double kButtonRadius = 12;

/// 内容页计数栏/工具条按钮的边长。
const double kToolbarButtonSize = 36;

/// 内容页头部动作按钮（播放/扫描等）高度：比标准按钮更紧凑，
/// 给标题和工具图标留出横向空间。
const double kHeaderButtonHeight = 36;

/// 内容页头部动作按钮水平内边距。
const double kHeaderButtonHorizontalPadding = 12;

/// 内容页工具条图标尺寸。
const double kToolbarIconSize = 20;

/// 列表行/设置行右侧操作图标按钮的边长（比工具条再紧凑一档）。
const double kRowActionButtonSize = 32;

/// 列表行/设置行右侧操作图标尺寸。
const double kRowActionIconSize = 20;

/// 列表行/设置行右侧文字按钮高度。
const double kRowActionTextButtonHeight = 28;

/// 页面级导航图标（返回、关闭、AppBar 动作）尺寸。
const double kPageIconSize = 24;

/// 播放页次级控制图标尺寸。
const double kPlayerSecondaryIconSize = 22;

/// 播放页次级按钮（工具行 / 睡眠定时 / 播放模式 / 音量）的命中区基准边长。
///
/// 与 [kPlayerSecondaryIconSize] 同一口径随窗口缩放（48×scale / 22×scale），
/// 避免同一行里混着固定 48 与随字号放大的隐式命中区。
const double kPlayerSecondaryButtonSize = 48;

/// 播放页工具行按钮之间的间距基准。
///
/// 工具行与主控制行同构（都由内容定宽、不铺满容器），间距取
/// [kPlayerSecondaryButtonSize] 的 1/4：5 枚工具按钮合计
/// 5×48 + 4×12 = [kPlayerToolRowWidth]，比主控制行
/// [kPlayerControlsRowWidth] 略窄——工具栏是次级入口，比播控行窄是对的，
/// 反过来会抢视觉重心。
const double kPlayerToolGap = kPlayerSecondaryButtonSize / 4;

/// 播放页工具行的内容宽度（5 枚按钮 + 4 段间距）。
const double kPlayerToolRowWidth =
    kPlayerSecondaryButtonSize * 5 + kPlayerToolGap * 4;

/// 播放页主控制行里的切歌按钮：命中区与图标基准。
const double kPlayerSkipButtonSize = 56;
const double kPlayerSkipIconSize = 34;

/// 播放页主控制行的播放/暂停键图标基准与内边距基准。
const double kPlayerPrimaryButtonSize = 74;
const double kPlayerPrimaryButtonPadding = 8;

/// 播放页主控制行的内容宽度（次级键×2 + 切歌×2 + 播放键 + 内边距 + 两段 8 间距）。
///
/// 全部由上方 token 派生，工具行据此比对宽度口径，不再各写一个孤立的魔数。
/// 内边距也必须随 scale（[kPlayerPrimaryButtonPadding] × scale），否则本行
/// 是 `298×scale + 16` 而非纯正比，与工具行的比值会随缩放漂移。
const double kPlayerControlsRowWidth =
    kPlayerSecondaryButtonSize * 2 +
        kPlayerSkipButtonSize * 2 +
        kPlayerPrimaryButtonSize +
        kPlayerPrimaryButtonPadding * 2 +
        8 * 2;
