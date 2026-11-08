import 'dart:io';

import 'package:file_selector/file_selector.dart';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/player_provider.dart';
import '../../services/custom_font_service.dart';
import '../../services/ttc_font.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_provider.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/inline_spinner.dart';
import '../../widgets/single_choice_dialog.dart';
import '../../widgets/single_choice_group.dart';

import 'color_picker.dart';
import 'settings_focus.dart';

/// 界面设置：强调色/背景色/明暗/恢复默认，实时生效并持久化。
class AppearanceSection extends StatefulWidget {
  const AppearanceSection();
  @override
  State<AppearanceSection> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSection> {
  late AppSettings _settings;
  bool _fontBusy = false;
  bool _zhBusy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
  }

  Widget _anchor(String label, Widget child) => SettingsFocusAnchor(
        id: settingsAnchorId(SettingsItem.appearance, label),
        child: child,
      );

  Widget _groupHeader(String title) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final hasCustomFont = _settings.customFontFamily.isNotEmpty;
    final customFontLabel = _settings.customFontLabel;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('界面',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('自定义配色与字体，实时生效并保存到本机',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 24),

          _groupHeader('主题'),
          // 明暗模式：跟随系统 / 浅色 / 深色
          Text('明暗模式',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _anchor(
            '明暗模式',
            SingleChoiceGroup<ThemeMode>(
              options: const [
                SingleChoiceOption(
                    value: ThemeMode.system,
                    label: '跟随系统',
                    icon: Icons.brightness_auto),
                SingleChoiceOption(
                    value: ThemeMode.light,
                    label: '浅色',
                    icon: Icons.light_mode_outlined),
                SingleChoiceOption(
                    value: ThemeMode.dark,
                    label: '深色',
                    icon: Icons.dark_mode_outlined),
              ],
              value: theme.themeMode,
              onChanged: theme.setThemeMode,
            ),
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 强调色
          Text('强调色',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _anchor(
            '强调色',
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final col in AppTheme.accentPalette)
                  ColorDot(
                    color: col,
                    selected: theme.accent.toARGB32() == col.toARGB32(),
                    onTap: () => theme.setAccent(col),
                  ),
                ColorDot(
                  color: theme.accent,
                  selected: !AppTheme.accentPalette
                      .any((c) => c.toARGB32() == theme.accent.toARGB32()),
                  icon: Icons.add,
                  onTap: () => _pickAccent(context, theme),
                  isCustom: true,
                ),
              ],
            ),
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 背景色
          Text('背景色',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          _anchor(
            '背景色',
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: const Text('自动（跟随强调色）'),
                  onPressed: theme.clearBackgroundOverride,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.colorize, size: 18),
                  label: const Text('自定义背景色'),
                  onPressed: () => _pickBackground(context, theme),
                ),
              ],
            ),
          ),
          if (theme.background != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                SwatchPreview(color: theme.background!),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('当前自定义背景 ${_rgb(theme.background!)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _anchor(
            '恢复默认',
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.restart_alt),
                label: const Text('恢复默认'),
                onPressed: theme.resetDefaults,
              ),
            ),
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 文字：自定义字体（导入文件、仅本机生效）
          _groupHeader('文字'),
          _anchor(
            '界面字体',
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.font_download_outlined),
              title: const Text('界面字体'),
              subtitle: Text(customFontLabel.isEmpty
                  ? (hasCustomFont ? '自定义字体' : '系统默认')
                  : '当前：$customFontLabel'),
              trailing: _fontBusy ? const InlineSpinner(size: 24) : null,
            ),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.upload_file, size: 18),
                label: Text(hasCustomFont ? '更换字体' : '导入字体文件'),
                onPressed: _fontBusy ? null : _importFont,
              ),
              if (hasCustomFont)
                OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('恢复系统字体'),
                  onPressed: _fontBusy ? null : _resetFont,
                ),
            ],
          ),
          if (hasCustomFont) ...[
            const SizedBox(height: 12),
            Text(
              '预览：音乐让生活更美好 SelfMusic 0123456789',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
          const SizedBox(height: 4),
          _anchor(
            '歌词行数',
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.format_line_spacing),
              title: const Text('歌词行数'),
              subtitle: Text(_settings.lyricMaxLines == 0
                  ? '不限制'
                  : '${_settings.lyricMaxLines} 行'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickLyricMaxLines(context),
            ),
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 显示：标题格式 / 简繁 / 播放页权重与控件隐藏
          _groupHeader('显示'),
          _anchor(
            '标题格式',
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.title),
              title: const Text('标题格式'),
              subtitle: Text('当前：${_settings.songTitleFormat.label}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickTitleFormat(context),
            ),
          ),
          _anchor(
            '简繁转换',
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.translate),
              title: const Text('简繁转换'),
              subtitle: Text('当前：${_settings.zhVariant.label}'),
              trailing: _zhBusy
                  ? const InlineSpinner(size: 24)
                  : const Icon(Icons.chevron_right),
              onTap: _zhBusy ? null : () => _pickZhVariant(context),
            ),
          ),
          _anchor(
            '播放页显示权重',
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('播放页显示权重'),
              value: _settings.playerShowWeight,
              onChanged: (v) => setState(() => _settings.playerShowWeight = v),
            ),
          ),
          _anchor(
            '歌词页显示封面',
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('歌词页显示封面'),
              subtitle: const Text('竖屏歌词页顶部显示专辑封面'),
              value: _settings.lyricsShowCover,
              onChanged: (v) {
                setState(() => _settings.lyricsShowCover = v);
                // AppSettings 非 ChangeNotifier：通知已挂载的歌词页即时重建。
                context.read<DirectSourceManager>().refresh();
              },
            ),
          ),
          _anchor(
            '播放页控件隐藏',
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timer_outlined),
              title: const Text('播放页控件隐藏'),
              subtitle: Text(_settings.playerAutoHideIdleSec > 0
                  ? '${_settings.playerAutoHideIdleSec} 秒'
                  : '关闭'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickPlayerAutoHide(context),
            ),
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 动效
          _groupHeader('动效'),
          _anchor(
            '切换动画',
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.animation_outlined),
              title: const Text('切换动画'),
              subtitle: Text(_settings.playerTransition.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickTransition(context),
            ),
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 交互
          _groupHeader('交互'),
          _anchor(
            '长按组头',
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('长按组头'),
              subtitle: Text(_settings.longPressCollapseGroups
                  ? '长按展开/折叠；多选用工具条'
                  : '长按多选整组；展开/折叠用工具条'),
              value: _settings.longPressCollapseGroups,
              onChanged: (v) {
                setState(() => _settings.longPressCollapseGroups = v);
                // AppSettings 非 ChangeNotifier：通知已打开的列表页按新行为重建。
                context.read<DirectSourceManager>().refresh();
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _pickAccent(BuildContext context, ThemeProvider theme) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (c) => ColorPickerDialog(
          title: '选择强调色',
          onPicked: (col) {
            Navigator.of(c).pop(col);
          }),
    );
    if (picked != null) await theme.setAccent(picked);
  }

  Future<void> _pickBackground(
      BuildContext context, ThemeProvider theme) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (c) => ColorPickerDialog(
          title: '选择背景色',
          onPicked: (col) {
            Navigator.of(c).pop(col);
          }),
    );
    if (picked != null) await theme.setBackground(picked);
  }

  /// 导入本地字体（设置 → 界面 → 文字）。文件复制到应用支持目录并注册后，
  /// 立即把新家族应用到全局主题；设置持久化由 CustomFontService 负责。
  Future<void> _importFont() async {
    if (_fontBusy) return;
    XFile? picked;
    // 安卓文件管理器常把字体标成 application/octet-stream，严格 MIME 过滤会
    // 把可用的 TTF/OTF/TTC 藏起来；安卓端放开选择，仍由服务层校验扩展名与文件头。
    // 桌面/鸿蒙保留字体过滤（鸿蒙原生按后缀过滤；大小写各列一份，GTK 区分大小写）。
    final loosePicker = Platform.isAndroid;
    try {
      picked = await openFile(
        acceptedTypeGroups: loosePicker
            ? const []
            : const [
                XTypeGroup(
                    label: '字体文件',
                    extensions: ['ttf', 'otf', 'ttc', 'TTF', 'OTF', 'TTC'])
              ],
      );
    } catch (e) {
      debugPrint('打开字体文件选择器失败：$e');
      if (mounted) AppToast.show('无法打开文件选择器', isError: true);
      return;
    }
    if (picked == null || !mounted) return;
    // 先取根级主题 Provider：导入期间即使设置页被关闭，字体也应立即全局生效，
    // 而不是等到下次启动（设置本身已落库）。
    final theme = context.read<ThemeProvider>();
    setState(() => _fontBusy = true);
    try {
      final service = CustomFontService(_settings);
      int? faceIndex;
      if (await service.isTtcFile(picked.path)) {
        final faces = await service.listTtcFaces(sourcePath: picked.path);
        if (faces.isEmpty) {
          throw const CustomFontException('TTC 字体集合为空');
        }
        if (faces.length == 1) {
          faceIndex = faces.first.index;
        } else {
          if (!mounted) return;
          final chosen = await _pickTtcFace(picked.name, faces);
          if (chosen == null) return;
          faceIndex = chosen.index;
        }
      }
      final label = await service.importFont(
        sourcePath: picked.path,
        sourceName: picked.name,
        faceIndex: faceIndex,
      );
      await theme.setFontFamily(service.family);
      if (!mounted) return;
      setState(() {});
      AppToast.show('已应用字体：$label', isError: false);
    } on CustomFontException catch (e) {
      if (mounted) AppToast.show(e.message, isError: true);
    } catch (e) {
      debugPrint('字体导入失败：$e');
      if (mounted) AppToast.show('字体导入失败，请确认文件可读取', isError: true);
    } finally {
      if (mounted) setState(() => _fontBusy = false);
    }
  }

  /// TTC 字面选择：集合内可能是不同语言/字重，不能默认取首字面
  /// （Noto CJK 首字面是 JP，中文用户通常需要 SC）。
  Future<TtcFaceInfo?> _pickTtcFace(String fileName, List<TtcFaceInfo> faces) {
    final counts = <String, int>{};
    for (final face in faces) {
      counts[face.label] = (counts[face.label] ?? 0) + 1;
    }
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.5)
        .clamp(120.0, 420.0)
        .toDouble();
    final height = (faces.length * 56.0).clamp(120.0, maxHeight).toDouble();
    return showDialog<TtcFaceInfo>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('选择字体字面（${faces.length}）'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SizedBox(
            width: double.maxFinite,
            height: height,
            child: ListView.builder(
              itemCount: faces.length,
              itemBuilder: (c, i) {
                final face = faces[i];
                final base = face.label.isEmpty
                    ? '$fileName #${face.index + 1}'
                    : face.label;
                final label = (counts[face.label] ?? 0) > 1
                    ? '$base（#${face.index + 1}）'
                    : base;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title:
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.of(c).pop(face),
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// 删除已导入字体并恢复系统默认（文件与设置一并清理）。
  Future<void> _resetFont() async {
    if (_fontBusy) return;
    final theme = context.read<ThemeProvider>();
    setState(() => _fontBusy = true);
    try {
      await CustomFontService(_settings).clear();
      await theme.setFontFamily(null);
      if (!mounted) return;
      setState(() {});
      AppToast.show('已恢复系统字体', isError: false);
    } catch (e) {
      debugPrint('恢复系统字体失败：$e');
      if (mounted) AppToast.show('恢复系统字体失败', isError: true);
    } finally {
      if (mounted) setState(() => _fontBusy = false);
    }
  }

  Future<void> _pickTransition(BuildContext context) async {
    final current = _settings.playerTransition;
    final picked = await showSingleChoiceDialog<PlayerTransition>(
      context: context,
      title: '页面切换动画',
      values: PlayerTransition.values,
      current: current,
      labelOf: (t) => t.label,
      asRadio: true,
    );
    if (picked == null || picked == current || !context.mounted) return;
    _settings.playerTransition = picked;
    // 通知全局监听者（根路由切换器）即时生效。
    context.read<DirectSourceManager>().refresh();
    setState(() {});
  }

  /// 标题显示格式选择（从 设置>歌曲 迁入 设置>界面，改进.txt UI4）。
  Future<void> _pickTitleFormat(BuildContext context) async {
    final chosen = await showSingleChoiceDialog<SongTitleFormat>(
      context: context,
      title: '标题显示格式',
      values: SongTitleFormat.values,
      current: _settings.songTitleFormat,
      labelOf: (f) => f.label,
    );
    if (chosen == null || !context.mounted) return;
    setState(() => _settings.songTitleFormat = chosen);
    // 设置写入后通知全局重建（AppSettings 非 ChangeNotifier）。
    context.read<DirectSourceManager>().refresh();
  }

  /// 简繁显示：只影响元数据展示，不修改存储；首次切换会加载 OpenCC 词库。
  Future<void> _pickZhVariant(BuildContext context) async {
    final chosen = await showSingleChoiceDialog<ZhVariant>(
      context: context,
      title: '简繁显示',
      values: ZhVariant.values,
      current: _settings.zhVariant,
      labelOf: (v) => v.label,
      hintOf: (v) => v.hint,
    );
    if (chosen == null || !context.mounted) return;
    if (chosen == _settings.zhVariant) return;
    setState(() => _settings.zhVariant = chosen);
    if (chosen == ZhVariant.original) {
      // 释放词库不耗时，无需展示加载态。
      await context.read<DirectSourceManager>().applyZhVariantSetting();
      if (!context.mounted) return;
      context.read<PlayerProvider>().refreshSystemMedia();
      setState(() {});
      return;
    }
    setState(() => _zhBusy = true);
    final ok =
        await context.read<DirectSourceManager>().applyZhVariantSetting();
    if (!context.mounted) return;
    context.read<PlayerProvider>().refreshSystemMedia();
    setState(() => _zhBusy = false);
    if (!ok) {
      AppToast.show('简繁词库加载失败，已保持原文', isError: true);
    }
  }

  /// 歌词行数：0=不限制；大屏按上限放大字号（只放大不缩小）。
  Future<void> _pickLyricMaxLines(BuildContext context) async {
    final current = _settings.lyricMaxLines;
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.6)
        .clamp(200.0, 420.0)
        .toDouble();
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('歌词行数'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SizedBox(
            width: double.maxFinite,
            height: maxHeight,
            child: RadioGroup<int>(
              groupValue: current,
              onChanged: (v) {
                if (v != null) Navigator.of(c).pop(v);
              },
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final n in AppSettings.lyricMaxLinesOptions)
                    RadioListTile<int>(
                      title: Text(n == 0 ? '不限制（沿用当前字号）' : '$n 行'),
                      value: n,
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked == null || picked == current || !context.mounted) return;
    setState(() => _settings.lyricMaxLines = picked);
    // AppSettings 非 ChangeNotifier：通知歌词页/全局监听者即时重建。
    context.read<DirectSourceManager>().refresh();
  }

  /// 播放页控件静置自动隐藏秒数（0=不隐藏）。
  Future<void> _pickPlayerAutoHide(BuildContext context) async {
    final chosen = await showSingleChoiceDialog<int>(
      context: context,
      title: '播放页控件隐藏',
      values: AppSettings.playerAutoHideIdleOptions,
      current: _settings.playerAutoHideIdleSec,
      labelOf: (sec) => sec == 0 ? '不自动隐藏' : '$sec 秒',
    );
    if (chosen == null || !context.mounted) return;
    setState(() => _settings.playerAutoHideIdleSec = chosen);
    context.read<DirectSourceManager>().refresh();
  }

  String _rgb(Color c) => 'rgb(${c.r}, ${c.g}, ${c.b})'.replaceAll('.0', '');
}
