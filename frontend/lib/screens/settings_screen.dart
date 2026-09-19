import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/local/app_settings.dart';
import '../data/local/backup_service.dart';
import '../providers/auth_provider.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../services/api_client.dart';
import '../services/server_settings.dart';
import '../theme/app_theme.dart';
import '../theme/theme_provider.dart';
import '../widgets/app_toast.dart';
import 'pairing_screen.dart';

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
      case SettingsItem.songs:
        return const _SongsSettings();
      case SettingsItem.general:
        return const _GeneralSettings();
      case SettingsItem.playback:
        return const _PlaybackSettings();
      case SettingsItem.notifications:
        return const _NotificationsSettings();
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
  String _pairingToken = '';

  @override
  void initState() {
    super.initState();
    final settings = context.read<ServerSettings>();
    _saved = settings.baseUrl;
    _controller = TextEditingController(text: settings.baseUrl);
    // 先展示本地保存的密钥（离线也能看到），再尝试向服务端刷新。
    _pairingToken = settings.pairingKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchPairingKey();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 拉取配对密钥并落盘；失败保留本地缓存（副标题仍可见）。
  Future<void> _fetchPairingKey() async {
    final api = context.read<ApiClient>();
    final settings = context.read<ServerSettings>();
    if (settings.baseUrl.isEmpty) return;
    final t = await api.fetchPairingToken();
    if (!mounted || t == null || t.isEmpty) return;
    await settings.setPairingKey(t);
    if (mounted) setState(() => _pairingToken = t);
  }

  /// 配对服务器副标题：配对态 + 同一份配对密钥（与配对页一致）。
  String _pairingSubtitle(bool paired) {
    final state = paired ? '已配对' : '未配对（首次启动不强制，直连模式仍可用）';
    if (_pairingToken.isEmpty) return state;
    final t = _pairingToken;
    final masked = t.length <= 8
        ? '••••••••'
        : '${t.substring(0, 4)}••••••${t.substring(t.length - 4)}';
    return '$state · 密钥 $masked';
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
    // 地址变化后刷新配对密钥展示。
    await _fetchPairingKey();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已保存服务端地址：${_saved.isEmpty ? "（未配置）" : _saved}')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
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
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.key),
            title: const Text('配对服务器'),
            subtitle: Text(_pairingSubtitle(auth.isPaired)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PairingScreen()),
            ),
          ),
          const Divider(height: 24),
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
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('预载下一首'),
            subtitle: const Text('播放时按播放顺序算法确定下一首并后台缓存（加权随机也先抽样确定并复用；开关只决定是否预载）'),
            value: context
                .read<DirectSourceManager>()
                .settings
                .preloadNext,
            onChanged: (v) {
              context.read<DirectSourceManager>().settings.preloadNext = v;
              setState(() {});
            },
          ),
          const SizedBox(height: 32),
          const Divider(),
          const _CacheConfigSection(),
          const Divider(height: 24),
          const _CacheDirTile(),
        ],
      ),
    );
  }
}

/// 服务端 → 缓存目录：展示真实路径与当前占用，点击复制路径。
class _CacheDirTile extends StatelessWidget {
  const _CacheDirTile();

  static String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final index = context.read<DirectSourceManager>().index;
    final count = index.listCache().length;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_open),
      title: const Text('缓存目录'),
      subtitle: Text('${index.cacheDir}\n已缓存 $count 首 · 占用 ${_fmtBytes(index.cacheTotalBytes())}'),
      isThreeLine: true,
      trailing: const Icon(Icons.copy_outlined),
      onTap: () {
        Clipboard.setData(ClipboardData(text: index.cacheDir));
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已复制缓存目录路径')));
      },
    );
  }
}

/// 服务端 → 缓存配置（settings.md §3.3）：
/// 「跟随服务端 / 自定义」双来源；跟随模式暂灰显（待阶段 6 服务端下发能力）。
class _CacheConfigSection extends StatefulWidget {
  const _CacheConfigSection();
  @override
  State<_CacheConfigSection> createState() => _CacheConfigSectionState();
}

class _CacheConfigSectionState extends State<_CacheConfigSection> {
  late AppSettings _settings;
  bool _fetched = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
    if (!_fetched) {
      _fetched = true;
      context.read<DirectSourceManager>().refreshServerConfig();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final followReady =
        _settings.serverCacheMaxBytes != null && _settings.serverCacheSongLimit != null;
    final followLocked =
        _settings.cacheConfigMode == CacheConfigMode.followServer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('缓存配置',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: const Icon(Icons.sync, size: 20),
              tooltip: '刷新服务端建议值',
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final ok =
                    await context.read<DirectSourceManager>().refreshServerConfig();
                if (!mounted) return;
                setState(() {});
                messenger.showSnackBar(SnackBar(
                    content: Text(ok ? '已刷新服务端建议值' : '拉取失败（检查后端连接）')));
              },
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('上限来源与建议值；同键项的服务端对照见 settings.md §5',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
        const SizedBox(height: 8),
        RadioGroup<CacheConfigMode>(
          groupValue: _settings.cacheConfigMode,
          onChanged: (v) {
            if (v == null) return;
            setState(() => _settings.cacheConfigMode = v);
          },
          child: Column(
            children: [
              const RadioListTile<CacheConfigMode>(
                contentPadding: EdgeInsets.zero,
                title: Text('自定义'),
                subtitle: Text('使用本机设置的上限'),
                value: CacheConfigMode.custom,
              ),
              RadioListTile<CacheConfigMode>(
                contentPadding: EdgeInsets.zero,
                title: const Text('跟随服务端'),
                subtitle: Text(
                  followReady
                      ? '使用服务端建议值：'
                          '${_labelBytes(_settings.serverCacheMaxBytes!)} / '
                          '${_settings.serverCacheSongLimit} 首'
                      : '服务端建议值未拉取（检查后端连接）',
                ),
                value: CacheConfigMode.followServer,
                enabled: followReady,
              ),
            ],
          ),
        ),
        if (followLocked)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('已启用跟随服务端：${_labelBytes(_settings.effectiveCacheMaxBytes)} / ${_settings.effectiveCacheSongLimit} 首',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.primary)),
          )
        else ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.storage_outlined),
            title: const Text('缓存总上限'),
            subtitle: Text(_labelBytes(_settings.effectiveCacheMaxBytes)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editMaxBytes(context),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.library_music_outlined),
            title: const Text('歌曲数量上限'),
            subtitle: Text('${_settings.effectiveCacheSongLimit} 首'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editSongLimit(context),
          ),
        ],
      ],
    );
  }

  Future<void> _editMaxBytes(BuildContext context) async {
    final current = _settings.cacheMaxBytes ~/ (1024 * 1024);
    final controller = TextEditingController(text: current.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('缓存总上限（MB）'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c)
                  .pop(int.tryParse(controller.text) ?? current),
              child: const Text('确定')),
        ],
      ),
    );
    if (result != null && result > 0 && mounted) {
      setState(() => _settings.cacheMaxBytes = result * 1024 * 1024);
    }
  }

  Future<void> _editSongLimit(BuildContext context) async {
    final controller =
        TextEditingController(text: _settings.cacheSongLimit.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('歌曲数量上限'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c)
                  .pop(int.tryParse(controller.text) ?? _settings.cacheSongLimit),
              child: const Text('确定')),
        ],
      ),
    );
    if (result != null && result > 0 && mounted) {
      setState(() => _settings.cacheSongLimit = result);
    }
  }

  static String _labelBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}

/// 界面设置：强调色/背景色/明暗/恢复默认，实时生效并持久化。
class _AppearanceSettings extends StatefulWidget {
  const _AppearanceSettings();
  @override
  State<_AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<_AppearanceSettings> {
  late PlayerTransition _transition;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _transition = context.read<DirectSourceManager>().settings.playerTransition;
  }

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
          if (theme.background != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _SwatchPreview(color: theme.background!),
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
          const Divider(),
          const SizedBox(height: 8),

          // 播放页切换动画
          Text('播放页', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.animation_outlined),
            title: const Text('页面切换动画'),
            subtitle: Text('播放页、分组、设置等全部页面切换效果：${_transition.label}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickTransition(context),
          ),
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

  Future<void> _pickTransition(BuildContext context) async {
    final picked = await showDialog<PlayerTransition>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('页面切换动画'),
        children: [
          RadioGroup<PlayerTransition>(
            groupValue: _transition,
            onChanged: (v) {
              if (v != null) Navigator.of(c).pop(v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in PlayerTransition.values)
                  RadioListTile<PlayerTransition>(
                    title: Text(t.label),
                    value: t,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null || picked == _transition || !context.mounted) return;
    context.read<DirectSourceManager>().settings.playerTransition = picked;
    // 通知全局监听者（根路由切换器）即时生效。
    context.read<DirectSourceManager>().refresh();
    setState(() => _transition = picked);
  }

  String _rgb(Color c) =>
      'rgb(${c.r}, ${c.g}, ${c.b})'.replaceAll('.0', '');
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

/// 歌曲设置：缓存上限 / 歌曲上限 / 收藏自动缓存（stage2.md §1.4）。
class _SongsSettings extends StatefulWidget {
  const _SongsSettings();
  @override
  State<_SongsSettings> createState() => _SongsSettingsState();
}

class _SongsSettingsState extends State<_SongsSettings> {
  late AppSettings _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('缓存与离线',
              style: TextStyle(
                  color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        SwitchListTile(
          title: const Text('收藏自动缓存'),
          subtitle: const Text('喜欢的歌自动下载离线可用'),
          value: _settings.autoCacheFavorites,
          onChanged: (v) {
            setState(() => _settings.autoCacheFavorites = v);
          },
        ),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('歌曲显示与扫描',
              style: TextStyle(
                  color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        ListTile(
          title: const Text('忽略音频（时长过滤）'),
          subtitle: Text(_settings.scanIgnoreMinDurationSec > 0
              ? '扫描时忽略短于 ${_settings.scanIgnoreMinDurationSec} 秒的音频'
              : '关闭（按时长不过滤）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editIgnoreDuration(context),
        ),
        ListTile(
          title: const Text('忽略音频（大小过滤）'),
          subtitle: Text(_settings.scanIgnoreMinSizeBytes > 0
              ? '扫描时忽略小于 ${_labelBytes(_settings.scanIgnoreMinSizeBytes)} 的音频'
              : '关闭（按大小不过滤）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editIgnoreBytes(context),
        ),
        SwitchListTile(
          title: const Text('仅 Wi-Fi 扫描'),
          subtitle: const Text('移动端直连扫描仅在 Wi-Fi 下进行（桌面忽略）'),
          value: _settings.scanWifiOnly,
          onChanged: (v) {
            setState(() => _settings.scanWifiOnly = v);
          },
        ),
        ListTile(
          title: const Text('扫描模式'),
          subtitle: Text(_scanModeLabel(_settings.scanMode)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickScanMode(context),
        ),
        ListTile(
          title: const Text('读取音频头部'),
          subtitle: Text('扫描时每个文件最多下载 ${_settings.scanHeadBytes ~/ 1024} KB（完整模式才解析全部元数据）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editScanHead(context),
        ),
        SwitchListTile(
          title: const Text('扫描时提取内嵌封面'),
          subtitle: const Text('完整模式下把封面另存到本地；关闭可加快大曲库扫描'),
          value: _settings.scanEmbedCover,
          onChanged: (v) {
            setState(() => _settings.scanEmbedCover = v);
          },
        ),
        ListTile(
          title: const Text('自动扫描间隔'),
          subtitle: Text(_settings.scanAutoIntervalMin > 0
              ? '每 ${_settings.scanAutoIntervalMin} 分钟增量扫描一次（本地目录变化也会立即触发）'
              : '关闭（手动扫描 / 打开源页触发）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editScanInterval(context),
        ),
      ],
    );
  }

  Future<void> _editIgnoreDuration(BuildContext context) async {
    final controller =
        TextEditingController(text: _settings.scanIgnoreMinDurationSec.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('忽略音频：最小时长（秒）'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c)
                  .pop(int.tryParse(controller.text) ?? 0),
              child: const Text('确定')),
        ],
      ),
    );
    if (result != null && result >= 0 && mounted) {
      setState(() => _settings.scanIgnoreMinDurationSec = result);
    }
  }

  Future<void> _editIgnoreBytes(BuildContext context) async {
    final mb = _settings.scanIgnoreMinSizeBytes ~/ (1024 * 1024);
    final controller = TextEditingController(text: (mb > 0 ? mb : 0).toString());
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('忽略音频：最小大小（MB）'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c)
                  .pop(int.tryParse(controller.text) ?? 0),
              child: const Text('确定')),
        ],
      ),
    );
    if (result != null && result >= 0 && mounted) {
      setState(() => _settings.scanIgnoreMinSizeBytes = result * 1024 * 1024);
    }
  }

  static String _labelBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  static String _scanModeLabel(String mode) {
    switch (mode) {
      case 'fast':
        return '快速：只建索引，不读文件头部（歌名取文件名，最快）';
      case 'full':
        return '完整：读取全部元数据（时长/专辑/年份/封面）';
      default:
        return '最小：只读歌名/歌手/专辑，其余播放时再补全（推荐）';
    }
  }

  Future<void> _pickScanMode(BuildContext context) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('扫描模式'),
        children: [
          for (final m in ['minimal', 'fast', 'full'])
            SimpleDialogOption(
              onPressed: () => Navigator.of(c).pop(m),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(_scanModeLabel(m))),
                    if (m == _settings.scanMode)
                      Icon(Icons.check, color: Theme.of(c).colorScheme.primary),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen != null && chosen != _settings.scanMode && mounted) {
      setState(() => _settings.scanMode = chosen);
    }
  }

  Future<void> _editScanHead(BuildContext context) async {
    final kb = _settings.scanHeadBytes ~/ 1024;
    final controller = TextEditingController(text: kb.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('读取音频头部（KB）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              autofocus: true,
            ),
            const SizedBox(height: 8),
            const Text('每个音频扫描时最多读取的字节数。越小扫描越快，'
                '但大于该值的内嵌封面/尾置元数据可能缺失（建议 ≥64）。'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c)
                  .pop(int.tryParse(controller.text) ?? 0),
              child: const Text('确定')),
        ],
      ),
    );
    if (result != null && result >= 16 && mounted) {
      setState(() => _settings.scanHeadBytes = result * 1024);
    }
  }

  Future<void> _editScanInterval(BuildContext context) async {
    final controller =
        TextEditingController(text: _settings.scanAutoIntervalMin.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('自动扫描间隔（分钟）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              autofocus: true,
            ),
            const SizedBox(height: 8),
            const Text('0 表示关闭。开启后按固定周期增量扫描全部直连源；'
                '本地目录变化也会自动触发增量扫描。'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c)
                  .pop(int.tryParse(controller.text) ?? 0),
              child: const Text('确定')),
        ],
      ),
    );
    if (result != null && result >= 0 && context.mounted) {
      setState(() => _settings.scanAutoIntervalMin = result);
      context.read<DirectSourceManager>().restartAutoScan();
    }
  }
}

/// 播放设置（settings.md §3.2）：默认播放模式 / 断点续播 / 淡入淡出 / 均衡器。
class _PlaybackSettings extends StatefulWidget {
  const _PlaybackSettings();
  @override
  State<_PlaybackSettings> createState() => _PlaybackSettingsState();
}

class _PlaybackSettingsState extends State<_PlaybackSettings> {
  static const List<String> _eqLabels = [
    '低音 60Hz', '中低 230Hz', '中音 910Hz', '中高 3.6kHz', '高音 14kHz',
  ];

  late AppSettings _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = PlayModeParse.fromStored(_settings.playModeDefault);
    final eqBands = _settings.eqBands;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('播放', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        ListTile(
          leading: const Icon(Icons.playlist_play),
          title: const Text('默认播放模式'),
          subtitle: Text(_modeLabel(current)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickMode(context, current),
        ),
        SwitchListTile(
          title: const Text('断点续播自动恢复'),
          subtitle: const Text('启动时恢复上次队列与位置（恢复为暂停态，不自动播放）'),
          value: _settings.resumeOnStartup,
          onChanged: (v) => setState(() => _settings.resumeOnStartup = v),
        ),
        SwitchListTile(
          title: const Text('播放页滑动手势'),
          subtitle: const Text('横滑切换播放页与歌词页、下滑返回列表（关闭后仅用按钮操作）'),
          value: _settings.playerGestureSwipe,
          onChanged: (v) => setState(() => _settings.playerGestureSwipe = v),
        ),
        SwitchListTile(
          title: const Text('睡眠定时默认播完最后曲目'),
          subtitle: const Text('到点不中断当前歌曲，放完这曲再暂停（弹窗内可单独调整）'),
          value: _settings.sleepPlayThroughDefault,
          onChanged: (v) => setState(() => _settings.sleepPlayThroughDefault = v),
        ),
        SwitchListTile(
          title: const Text('播放页显示权重信息'),
          subtitle: const Text('播放页展示当前歌曲喜欢 / 权重状态'),
          value: _settings.playerShowWeight,
          onChanged: (v) => setState(() => _settings.playerShowWeight = v),
        ),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('音效', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        SwitchListTile(
          title: const Text('淡入淡出'),
          subtitle: Text('播放淡入、暂停淡出${_settings.fadeEnabled ? '，时长 ${(_settings.fadeDurationMs / 1000).toStringAsFixed(1)}s' : ''}'),
          value: _settings.fadeEnabled,
          onChanged: (v) => setState(() => _settings.fadeEnabled = v),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
          child: Row(
            children: [
              const Text('时长', style: TextStyle(fontSize: 13)),
              Expanded(
                child: Slider(
                  value: (_settings.fadeDurationMs / 1000).clamp(1.0, 3.0),
                  min: 1,
                  max: 3,
                  divisions: 4,
                  label: '${(_settings.fadeDurationMs / 1000).toStringAsFixed(1)} 秒',
                  onChanged: (v) => setState(
                      () => _settings.fadeDurationMs = (v * 1000).round()),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        SwitchListTile(
          title: const Text('均衡器'),
          subtitle: const Text('5 段频段增益（JustAudio 原生支持，Android 生效）'),
          value: _settings.equalizerEnabled,
          onChanged: _toggleEqualizer,
        ),
        if (_settings.equalizerEnabled) ...[
          for (var i = 0; i < 5; i++)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(_eqLabels[i], style: const TextStyle(fontSize: 13)),
                  ),
                  Expanded(
                    child: Slider(
                      value: eqBands[i].clamp(-12.0, 12.0),
                      min: -12,
                      max: 12,
                      divisions: 48,
                      label: '${eqBands[i].toStringAsFixed(1)} dB',
                      onChanged: (v) {
                        setState(() {});
                        context.read<PlayerProvider>().setEqBand(i, v);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${eqBands[i] >= 0 ? '+' : ''}${eqBands[i].toStringAsFixed(1)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  void _toggleEqualizer(bool v) {
    setState(() => _settings.equalizerEnabled = v);
    context.read<PlayerProvider>().applyAudioConfig();
  }

  Future<void> _pickMode(BuildContext context, PlayMode current) async {
    final picked = await showDialog<PlayMode>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('默认播放模式'),
        children: [
          RadioGroup<PlayMode>(
            groupValue: current,
            onChanged: (v) {
              if (v != null) Navigator.of(c).pop(v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in PlayMode.values)
                  RadioListTile<PlayMode>(
                    title: Text(_modeLabel(m)),
                    value: m,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null || picked == current || !context.mounted) return;
    setState(() => _settings.playModeDefault = picked.name);
    context.read<PlayerProvider>().setMode(picked);
  }

  static String _modeLabel(PlayMode m) => switch (m) {
        PlayMode.sequence => '顺序播放',
        PlayMode.loopList => '列表循环',
        PlayMode.loopOne => '单曲循环',
        PlayMode.weighted => '加权随机',
      };
}

/// 常规设置（settings.md §3.5）：设置/歌单导出导入（不含令牌与源凭据）。
class _GeneralSettings extends StatefulWidget {
  const _GeneralSettings();
  @override
  State<_GeneralSettings> createState() => _GeneralSettingsState();
}

class _GeneralSettingsState extends State<_GeneralSettings> {
  List<File> _backups = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final direct = context.read<DirectSourceManager>();
    _backups = _service(direct).listBackups();
  }

  BackupService _service(DirectSourceManager direct) => BackupService(
        index: direct.index,
        server: context.read<ServerSettings>(),
        theme: context.read<ThemeProvider>(),
      );

  void _refresh() {
    setState(() {
      final direct = context.read<DirectSourceManager>();
      _backups = _service(direct).listBackups();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('备份与迁移',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('导出设置'),
          subtitle: const Text('本机设置 + 服务端地址 + 主题 → JSON 备份文件'),
          trailing: const Icon(Icons.arrow_downward),
          onTap: () => _doExportSettings(),
        ),
        ListTile(
          leading: const Icon(Icons.upload_file),
          title: const Text('导入设置（选择文件）'),
          subtitle: const Text('从任意位置选择设置备份文件恢复'),
          trailing: const Icon(Icons.folder_open),
          onTap: () => _pickAndImport(BackupKind.settings),
        ),
        ListTile(
          leading: const Icon(Icons.queue_music),
          title: const Text('导出歌单'),
          subtitle: const Text('全部歌单（含歌曲快照）→ JSON 备份文件'),
          trailing: const Icon(Icons.arrow_downward),
          onTap: () => _doExportPlaylists(),
        ),
        ListTile(
          leading: const Icon(Icons.playlist_add),
          title: const Text('导入歌单（选择文件）'),
          subtitle: const Text('从任意位置选择歌单备份文件恢复'),
          trailing: const Icon(Icons.folder_open),
          onTap: () => _pickAndImport(BackupKind.playlists),
        ),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('本机备份',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        if (_backups.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('暂无备份。点击上方「导出」创建。',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        for (final f in _backups) _backupTile(context, f),
      ],
    );
  }

  Widget _backupTile(BuildContext context, File f) {
    final name = f.path.split('/').last;
    final kind = BackupService.kindOf(f);
    final kindLabel = switch (kind) {
      BackupKind.settings => '设置',
      BackupKind.playlists => '歌单',
      BackupKind.full => '设置 + 歌单',
    };
    return ListTile(
      leading: const Icon(Icons.description_outlined),
      title: Text(name),
      subtitle: Text('$kindLabel · ${_sizeLabel(f.lengthSync())}'),
      onTap: () => _confirmImport(f, name, kind),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: '导入此备份',
            onPressed: () => _confirmImport(f, name, kind),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除备份',
            onPressed: () => _doDelete(f),
          ),
        ],
      ),
    );
  }

  Future<void> _doExportSettings() async {
    final direct = context.read<DirectSourceManager>();
    final file = _service(direct).exportSettings();
    _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出：${file.path.split('/').last}（不含令牌与源凭据）')));
  }

  Future<void> _doExportPlaylists() async {
    final direct = context.read<DirectSourceManager>();
    final file = _service(direct).exportPlaylists();
    _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出：${file.path.split('/').last}')));
  }

  /// 文件选择器导入设置/歌单。
  Future<void> _pickAndImport(BackupKind kind) async {
    const groups = [
      XTypeGroup(label: 'JSON 备份', extensions: ['json'], mimeTypes: ['application/json']),
      XTypeGroup(label: '所有文件', mimeTypes: ['*/*']),
    ];
    final XFile? picked;
    try {
      picked = await openFile(acceptedTypeGroups: groups);
    } catch (e) {
      if (mounted) return _toast('打开文件失败：$e');
      return;
    }
    if (picked == null) return;
    if (!mounted) return;
    final f = File(picked.path);
    if (!f.existsSync()) {
      _toast('所选文件不存在：${picked.path}');
      return;
    }
    final direct = context.read<DirectSourceManager>();
    final service = _service(direct);
    try {
      final summary = kind == BackupKind.settings
          ? await service.importSettings(f)
          : await service.importPlaylists(f);
      if (kind == BackupKind.playlists) {
        if (!mounted) return;
        context.read<PlaylistsProvider>().refresh();
      }
      if (!mounted) return;
      _toast(summary);
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _confirmImport(File f, String name, BackupKind kind) async {
    final scope = switch (kind) {
      BackupKind.settings => '将覆盖当前设置（含服务端地址与主题）',
      BackupKind.playlists => '将以本机歌单重建',
      BackupKind.full => '将覆盖当前设置并重建歌单',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导入备份'),
        content: Text('$scope，是否继续？\n\n$name'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final direct = context.read<DirectSourceManager>();
    final service = _service(direct);
    try {
      final summaries = <String>[];
      if (kind == BackupKind.settings || kind == BackupKind.full) {
        summaries.add(await service.importSettings(f));
      }
      if (kind == BackupKind.playlists || kind == BackupKind.full) {
        summaries.add(await service.importPlaylists(f));
      }
      if (!mounted) return;
      context.read<PlaylistsProvider>().refresh();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(summaries.join('；'))));
    } catch (e) {
      if (!mounted) return;
      AppToast.error(e, '导入失败');
    }
  }

  Future<void> _doDelete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除备份'),
        content: Text('确定删除 ${f.path.split('/').last}？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      f.deleteSync();
    } catch (_) {}
    _refresh();
  }

  static String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

/// 通知设置（settings.md §3.6）：通知栏控制/后台播放（Android）；音频焦点开关。
class _NotificationsSettings extends StatefulWidget {
  const _NotificationsSettings();
  @override
  State<_NotificationsSettings> createState() => _NotificationsSettingsState();
}

class _NotificationsSettingsState extends State<_NotificationsSettings> {
  late AppSettings _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('通知',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '通知栏播放控制 / 后台播放 / 音频焦点基于 just_audio_background 与 audio_session，'
              '仅 Android 生效；Linux 桌面忽略这些开关。',
              style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        SwitchListTile(
          title: const Text('通知栏播放控制'),
          subtitle: const Text('通知栏常驻播放控制与后台播放（修改后重启生效）'),
          value: _settings.notificationControls,
          onChanged: (v) {
            setState(() => _settings.notificationControls = v);
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('通知栏播放控制将在重启应用后生效')));
          },
        ),
        const Divider(height: 24),
        SwitchListTile(
          title: const Text('自动暂停/恢复'),
          subtitle: const Text('通话等音频焦点抢占时自动暂停，结束后恢复'),
          value: _settings.audioFocusEnabled,
          onChanged: (v) {
            setState(() => _settings.audioFocusEnabled = v);
            context.read<PlayerProvider>().applyAudioConfig();
          },
        ),
      ],
    );
  }
}
