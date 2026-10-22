/// 全 App 按钮/工具条尺寸 token。
///
/// 与 [AppTheme] 中的按钮主题配合使用：文本按钮高度、圆角在这里定义，
/// 各页面不再各写 `styleFrom`。工具条图标（排序/分类/视图/关闭等）统一
/// [kToolbarButtonSize] 见方、[kToolbarIconSize] 图标，避免同一条栏内出现
/// 32/40/48 三种命中区。
library;

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
