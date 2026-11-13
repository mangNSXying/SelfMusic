import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../providers/direct_source_manager.dart';
import '../../theme/app_theme.dart';
import '../../utils/cover_thumb.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/inline_spinner.dart';
import '../../widgets/settings_tile.dart';
import 'backup_section.dart';
import 'settings_focus.dart';
import 'storage_sections.dart';

/// 存储：离线缓存 / 缓存容量 / 缓存位置 / 封面缓存 / 备份与迁移。
class StorageSection extends StatefulWidget {
  const StorageSection();

  @override
  State<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends State<StorageSection> {
  late AppSettings _settings;
  bool _clearingThumbs = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
  }

  Widget _anchor(String label, Widget child) => SettingsFocusAnchor(
        id: settingsAnchorId(SettingsItem.storage, label),
        child: child,
      );

  Widget _groupTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _groupTitle('离线缓存'),
          _anchor(
            '收藏自动缓存',
            SettingsTile.toggle(
              title: '收藏自动缓存',
              description: '收藏的歌曲自动离线保存',
              value: _settings.autoCacheFavorites,
              onChanged: (v) {
                setState(() => _settings.autoCacheFavorites = v);
              },
            ),
          ),
          const Divider(height: 32),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: CacheConfigSection(),
          ),
          const Divider(height: 32),
          _groupTitle('缓存位置'),
          _anchor(
            '缓存目录',
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: CacheDirTile(),
            ),
          ),
          const Divider(height: 32),
          _groupTitle('封面缓存'),
          _anchor(
            '压缩画质',
            SettingsTile.toggle(
              title: '压缩画质',
              description: _settings.compressCoverImage ? '省空间，可能发热' : '原图（推荐）',
              value: _settings.compressCoverImage,
              onChanged: (v) async {
                setState(() => _settings.compressCoverImage = v);
                await context
                    .read<DirectSourceManager>()
                    .applyCoverThumbSetting();
                if (mounted) setState(() {});
              },
            ),
          ),
          _anchor(
            '清理缩略图',
            SettingsTile(
              title: '清理缩略图',
              description: '删除已生成的封面缩略图',
              trailing: _clearingThumbs
                  ? const InlineSpinner(size: 24)
                  : SettingsValueText('清理'),
              onTap: _clearingThumbs ? null : () => _clearCoverThumbs(context),
            ),
          ),
          const Divider(height: 32),
          _anchor('备份与迁移', const BackupMigrationTile()),
        ],
      ),
    );
  }

  /// 清理缩略图：二次确认后删 `*.thumb.jpg`（开关状态不变）。
  Future<void> _clearCoverThumbs(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清理缩略图？'),
        content: const Text('将删除已生成的封面缩略图文件，列表即回原图显示。\n'
            '压缩开关保持不变：开时后续滚动会重新生成，关时不再生成。'),
        actions: appDialogActions(
          c,
          confirmLabel: '清理',
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    setState(() => _clearingThumbs = true);
    try {
      final mgr = context.read<DirectSourceManager>();
      final removed = await clearCoverThumbFiles(mgr.index.allCoverPaths());
      if (!context.mounted) return;
      setState(() => _clearingThumbs = false);
      mgr.refresh();
      AppToast.show(removed == 0 ? '没有可清理的缩略图' : '已清理 $removed 张缩略图',
          isError: false);
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _clearingThumbs = false);
      AppToast.error(e, '清理缩略图失败');
    }
  }
}
