import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../services/api_client.dart';
import '../services/server_settings.dart';
import '../theme/app_theme.dart';
import '../theme/theme_provider.dart';

/// 设置页：根据侧边栏选中的分区渲染对应设置面板。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final item = nav.settings;
    if (item == null) {
      return const Center(child: Text('请从左侧选择设置分区'));
    }
    switch (item) {
      case SettingsItem.appearance:
        return const _AppearanceSettings();
      case SettingsItem.server:
        return const _ServerSettings();
      case SettingsItem.general:
      case SettingsItem.playback:
      case SettingsItem.songs:
      case SettingsItem.notifications:
        return _CategoryPlaceholder(item: item);
    }
  }
}

/// 「服务端」设置：后端地址（运行时可改，替代编译期 --dart-define）。
class _ServerSettings extends StatefulWidget {
  const _ServerSettings();

  @override
  State<_ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<_ServerSettings> {
  late final TextEditingController _controller;
  late String _saved;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<ServerSettings>();
    _saved = settings.baseUrl;
    _controller = TextEditingController(text: settings.baseUrl);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final settings = context.read<ServerSettings>();
    final api = context.read<ApiClient>();
    final entered = _controller.text.trim();
    // 空表示清空（未配置）
    await settings.setBaseUrl(entered);
    api.setBaseUrl(settings.baseUrl);
    if (!mounted) return;
    setState(() {
      _saved = settings.baseUrl;
      _saving = false;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已保存服务端地址：${_saved.isEmpty ? "（未配置）" : _saved}')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('服务端',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('配置后端地址；选择「服务端代理」模式的源会走后端拉取整体库',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 24),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '后端地址',
              hintText: 'http://192.168.1.10:18089',
              helperText: '含协议与端口，留空表示未配置',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 12),
          if (_saved.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('当前已配置：$_saved',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.primary)),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _saving
                  ? null
                  : () {
                      setState(() => _saving = true);
                      _save();
                    },
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 界面设置：强调色/背景色/明暗/恢复默认，实时生效并持久化。
class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('界面', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('自定义背景色与强调色，实时生效并保存到本机',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 24),

          // 明暗模式
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('暗色模式'),
            subtitle: const Text('切换明暗主题'),
            value: theme.isDark,
            onChanged: (v) => theme.setMode(v ? Brightness.dark : Brightness.light),
            secondary: Icon(theme.isDark ? Icons.dark_mode : Icons.light_mode),
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 强调色
          Text('强调色', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final col in AppTheme.accentPalette)
                _ColorDot(
                  color: col,
                  selected: theme.accent.toARGB32() == col.toARGB32(),
                  onTap: () => theme.setAccent(col),
                ),
              _ColorDot(
                color: theme.accent,
                selected: !AppTheme.accentPalette.any((c) => c.toARGB32() == theme.accent.toARGB32()),
                icon: Icons.add,
                onTap: () => _pickAccent(context, theme),
                isCustom: true,
              ),
            ],
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 背景色
          Text('背景色', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.auto_fix_high, size: 18),
                label: const Text('自动（跟随强调色）'),
                onPressed: theme.clearBackgroundOverride,
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.colorize, size: 18),
                label: const Text('自定义背景色'),
                onPressed: () => _pickBackground(context, theme),
              ),
            ],
          ),
          if (theme.background != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _SwatchPreview(color: theme.background!),
                const SizedBox(width: 12),
                Text('当前自定义背景 ${_rgb(theme.background!)}',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ],
          const Divider(),
          const SizedBox(height: 12),

          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: const Text('恢复默认主题'),
              onPressed: theme.resetDefaults,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAccent(BuildContext context, ThemeProvider theme) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (c) => _ColorPickerDialog(title: '选择强调色', onPicked: (col) {
        Navigator.of(c).pop(col);
      }),
    );
    if (picked != null) await theme.setAccent(picked);
  }

  Future<void> _pickBackground(BuildContext context, ThemeProvider theme) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (c) => _ColorPickerDialog(title: '选择背景色', onPicked: (col) {
        Navigator.of(c).pop(col);
      }),
    );
    if (picked != null) await theme.setBackground(picked);
  }

  String _rgb(Color c) =>
      'rgb(${c.r}, ${c.g}, ${c.b})'.replaceAll('.0', '');
}

class _CategoryPlaceholder extends StatelessWidget {
  final SettingsItem item;
  const _CategoryPlaceholder({required this.item});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(item.icon, size: 72, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text('${item.label}设置开发中', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('该设置项尚未实现', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool isCustom;
  const _ColorDot({required this.color, required this.selected, required this.onTap, this.icon, this.isCustom = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isCustom ? Colors.transparent : color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.2),
            width: selected ? 3 : 1,
          ),
        ),
        child: isCustom
            ? Center(child: Icon(icon, color: color))
            : (selected ? const Icon(Icons.check, color: Colors.white, size: 20) : null),
      ),
    );
  }
}

class _SwatchPreview extends StatelessWidget {
  final Color color;
  const _SwatchPreview({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).colorScheme.outline)),
    );
  }
}

/// 简易取色器：预设的饱和色网格 + 常用色。
class _ColorPickerDialog extends StatefulWidget {
  final String title;
  final ValueChanged<Color> onPicked;
  const _ColorPickerDialog({required this.title, required this.onPicked});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  static const List<List<Color>> _grid = [
    [
      Color(0xFF000000), Color(0xFF434343), Color(0xFF7B7B7B), Color(0xFFBFBFBF),
      Color(0xFFF2F2F2), Color(0xFFFFFFFF),
    ],
    [
      Color(0xFFB71C1C), Color(0xFFC62828), Color(0xFFE53935), Color(0xFFF44336), Color(0xFFEF9A9A), Color(0xFFFFCDD2),
    ],
    [
      Color(0xFF880E4F), Color(0xFFAD1457), Color(0xFFD81B60), Color(0xFFE91E63), Color(0xFFF48FB1), Color(0xFFF8BBD0),
    ],
    [
      Color(0xFF4A148C), Color(0xFF6A1B9A), Color(0xFF8E24AA), Color(0xFF9C27B0), Color(0xFFCE93D8), Color(0xFFE1BEE7),
    ],
    [
      Color(0xFF1A237E), Color(0xFF283593), Color(0xFF3949AB), Color(0xFF3F51B5), Color(0xFF9FA8DA), Color(0xFFC5CAE9),
    ],
    [
      Color(0xFF0D47A1), Color(0xFF1565C0), Color(0xFF1E88E5), Color(0xFF2196F3), Color(0xFF90CAF9), Color(0xFFBBDEFB),
    ],
    [
      Color(0xFF006064), Color(0xFF00838F), Color(0xFF00ACC1), Color(0xFF00BCD4), Color(0xFF80DEEA), Color(0xFFB2EBF2),
    ],
    [
      Color(0xFF004D40), Color(0xFF00695C), Color(0xFF00897B), Color(0xFF009688), Color(0xFF80CBC4), Color(0xFFB2DFDB),
    ],
    [
      Color(0xFF1B5E20), Color(0xFF2E7D32), Color(0xFF43A047), Color(0xFF4CAF50), Color(0xFFA5D6A7), Color(0xFFC8E6C9),
    ],
    [
      Color(0xFFE65100), Color(0xFFEF6C00), Color(0xFFF57C00), Color(0xFFFF9800), Color(0xFFFFCC80), Color(0xFFFFE0B2),
    ],
    [
      Color(0xFF263238), Color(0xFF37474F), Color(0xFF546E7A), Color(0xFF607D8B), Color(0xFFB0BEC5), Color(0xFFCFD8DC),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _grid)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final col in row)
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => widget.onPicked(col),
                      child: Container(
                        width: 32,
                        height: 32,
                        margin: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: col,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Theme.of(context).colorScheme.outline),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
      ],
    );
  }
}
