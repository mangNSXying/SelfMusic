import 'package:file_selector/file_selector.dart';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../platform/harmonyos/ohos_bootstrap.dart';
import '../../providers/direct_source_manager.dart';
import '../../services/artist_resolver.dart';
import '../../theme/app_theme.dart';
import '../../utils/format_bytes.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/row_action_button.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/single_choice_dialog.dart';
import '../../widgets/single_choice_group.dart';
import '../../widgets/text_input_dialog.dart';
import 'settings_focus.dart';

/// 歌曲设置：扫描过滤 / 元数据 / 播放源。
class SongsSection extends StatefulWidget {
  const SongsSection();
  @override
  State<SongsSection> createState() => _SongsSettingsState();
}

class _SongsSettingsState extends State<SongsSection> {
  late AppSettings _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
  }

  Widget _anchor(String label, Widget child) => SettingsFocusAnchor(
        id: settingsAnchorId(SettingsItem.songs, label),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsSectionHeader('扫描过滤'),
          _anchor(
            '时长过滤',
            ListTile(
              title: const Text('时长过滤'),
              subtitle: Text(_settings.scanIgnoreMinDurationSec > 0
                  ? '${_settings.scanIgnoreMinDurationSec} 秒'
                  : '关闭'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editIgnoreDuration(context),
            ),
          ),
          _anchor(
            '大小过滤',
            ListTile(
              title: const Text('大小过滤'),
              subtitle: Text(_settings.scanIgnoreMinSizeBytes > 0
                  ? _labelBytes(_settings.scanIgnoreMinSizeBytes)
                  : '关闭'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editIgnoreBytes(context),
            ),
          ),
          _anchor(
            '仅 Wi-Fi',
            SwitchListTile(
              title: const Text('仅 Wi-Fi'),
              subtitle: const Text('手机只在 Wi-Fi 下扫描'),
              value: _settings.scanWifiOnly,
              onChanged: (v) {
                setState(() => _settings.scanWifiOnly = v);
              },
            ),
          ),
          _anchor(
            '扫描间隔',
            ListTile(
              title: const Text('扫描间隔'),
              subtitle: Text(_settings.scanAutoIntervalMin > 0
                  ? '每 ${_settings.scanAutoIntervalMin} 分钟'
                  : '关闭'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editScanInterval(context),
            ),
          ),
          const Divider(height: 32),
          const SettingsSectionHeader('元数据'),
          _subHeader('在线来源'),
          _anchor(
            '歌词来源',
            ListTile(
              title: const Text('歌词来源'),
              subtitle: Text(_settings.onlineMetaLyricSource.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickLyricSource(context),
            ),
          ),
          _anchor(
            '封面来源',
            ListTile(
              title: const Text('封面来源'),
              subtitle: Text(_settings.onlineMetaCoverSource.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickCoverSource(context),
            ),
          ),
          _subHeader('保存方式'),
          _anchor(
            '保存方式',
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SingleChoiceGroup<OnlineMetaSaveMode>(
                options: const [
                  SingleChoiceOption(
                      value: OnlineMetaSaveMode.appCache, label: '仅应用缓存'),
                  SingleChoiceOption(
                      value: OnlineMetaSaveMode.sidecar, label: '同时写回源目录'),
                  SingleChoiceOption(
                      value: OnlineMetaSaveMode.embed, label: '内嵌到歌曲'),
                ],
                value: _settings.onlineMetaSaveMode,
                onChanged: (v) {
                  setState(() => _settings.onlineMetaSaveMode = v);
                  context.read<DirectSourceManager>().refresh();
                },
              ),
            ),
          ),
          _anchor(
            '歌词目录',
            ListTile(
              title: const Text('歌词目录'),
              subtitle: Text(_settings.onlineMetaLyricDir.isEmpty
                  ? '默认'
                  : _settings.onlineMetaLyricDir),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_settings.onlineMetaLyricDir.isNotEmpty)
                    RowActionIconButton(
                      icon: Icons.clear,
                      tooltip: '清除（恢复歌曲同目录）',
                      onPressed: _settings.onlineMetaSaveMode !=
                              OnlineMetaSaveMode.sidecar
                          ? null
                          : () {
                              setState(() => _settings.onlineMetaLyricDir = '');
                              context.read<DirectSourceManager>().refresh();
                            },
                    ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              enabled:
                  _settings.onlineMetaSaveMode == OnlineMetaSaveMode.sidecar,
              onTap: _settings.onlineMetaSaveMode != OnlineMetaSaveMode.sidecar
                  ? null
                  : () => _pickLyricDir(context),
            ),
          ),
          const Divider(height: 24),
          _subHeader('歌手解析'),
          _anchor(
            '自动解析',
            SwitchListTile(
              title: const Text('自动解析'),
              subtitle: const Text('自动补全歌手信息'),
              value: _settings.artistResolveAuto,
              onChanged: (v) {
                setState(() => _settings.artistResolveAuto = v);
                if (v) {
                  context.read<ArtistResolver>().wake();
                }
              },
            ),
          ),
          _anchor(
            '重试解析',
            ListTile(
              title: const Text('重试解析'),
              trailing: const Icon(Icons.refresh),
              onTap: () async {
                await context.read<ArtistResolver>().retryAll();
                if (context.mounted) {
                  AppToast.show('已开始重试解析歌手', isError: false);
                }
              },
            ),
          ),
          _anchor(
            '强制解析',
            ListTile(
              title: const Text('强制解析'),
              trailing: const Icon(Icons.playlist_add_check),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('确认强制解析全部歌手？'),
                    content: const Text(
                        '会把所有歌手（含已解析成功的）重新拉取一遍，并重新展开组合成员。请求受 MusicBrainz 限流，需要一定时间。'),
                    actions: appDialogActions(
                      c,
                      confirmLabel: '开始',
                      onCancel: () => Navigator.of(c).pop(false),
                      onConfirm: () => Navigator.of(c).pop(true),
                    ),
                  ),
                );
                if (ok != true || !context.mounted) return;
                await context.read<ArtistResolver>().forceRetryAll();
                if (context.mounted) {
                  AppToast.show('已开始强制解析歌手', isError: false);
                }
              },
            ),
          ),
          const Divider(height: 32),
          const SettingsSectionHeader('播放源'),
          _anchor(
            '备用源同步',
            SwitchListTile(
              title: const Text('备用源同步'),
              subtitle: const Text('备用源缺歌时自动补一份'),
              value: _settings.fallbackAutoRepair,
              onChanged: (v) {
                setState(() => _settings.fallbackAutoRepair = v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _subHeader(String title) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          color: cs.primary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Future<void> _pickLyricDir(BuildContext context) async {
    if (isOhos) {
      AppToast.show('鸿蒙端暂不支持自定义歌词目录', isError: false);
      return;
    }
    final dir = await getDirectoryPath(confirmButtonText: '选择');
    if (dir == null || !context.mounted) return;
    setState(() => _settings.onlineMetaLyricDir = dir);
    context.read<DirectSourceManager>().refresh();
    AppToast.show('已设置自定义歌词目录', isError: false);
  }

  /// 歌词来源选择（手动设定，无自动串源）。
  Future<void> _pickLyricSource(BuildContext context) async {
    const notes = {
      OnlineMetaLyricSource.lrclib: '免费无Key；中文小众覆盖弱',
      OnlineMetaLyricSource.qq: '中文覆盖好；需联网直调 QQ 公开接口',
      OnlineMetaLyricSource.netease: '中文覆盖好；反爬严格，失败请换源',
    };
    final chosen = await showSingleChoiceDialog<OnlineMetaLyricSource>(
      context: context,
      title: '歌词来源',
      values: OnlineMetaLyricSource.values,
      current: _settings.onlineMetaLyricSource,
      labelOf: (s) => s.label,
      subtitleOf: (s) => notes[s]!,
    );
    if (chosen == null || !context.mounted) return;
    setState(() => _settings.onlineMetaLyricSource = chosen);
    context.read<DirectSourceManager>().refresh();
  }

  /// 封面来源选择（手动设定，无自动串源）。
  Future<void> _pickCoverSource(BuildContext context) async {
    const notes = {
      OnlineMetaCoverSource.mbCaa: '录音搜索→CAA；无图常见',
      OnlineMetaCoverSource.qq: '中文覆盖好；800 方图',
      OnlineMetaCoverSource.netease: '中文覆盖好；反爬严格，失败请换源',
    };
    final chosen = await showSingleChoiceDialog<OnlineMetaCoverSource>(
      context: context,
      title: '封面来源',
      values: OnlineMetaCoverSource.values,
      current: _settings.onlineMetaCoverSource,
      labelOf: (s) => s.label,
      subtitleOf: (s) => notes[s]!,
    );
    if (chosen == null || !context.mounted) return;
    setState(() => _settings.onlineMetaCoverSource = chosen);
    context.read<DirectSourceManager>().refresh();
  }

  Future<void> _editIgnoreDuration(BuildContext context) async {
    final text = await showTextInputDialog(
      context: context,
      title: '忽略音频：最小时长（秒）',
      initial: _settings.scanIgnoreMinDurationSec.toString(),
      numeric: true,
    );
    if (text == null || !context.mounted) return;
    final result = int.tryParse(text) ?? 0;
    setState(() => _settings.scanIgnoreMinDurationSec = result);
    // 忽略规则变更：让已入库歌曲按新规则过滤（喜欢/歌曲/专辑/歌手/源浏览即时生效）。
    context.read<DirectSourceManager>().settingsChanged();
  }

  Future<void> _editIgnoreBytes(BuildContext context) async {
    final mb = _settings.scanIgnoreMinSizeBytes ~/ (1024 * 1024);
    final text = await showTextInputDialog(
      context: context,
      title: '忽略音频：最小大小（MB）',
      initial: (mb > 0 ? mb : 0).toString(),
      numeric: true,
    );
    if (text == null || !context.mounted) return;
    final result = int.tryParse(text) ?? 0;
    setState(() => _settings.scanIgnoreMinSizeBytes = result * 1024 * 1024);
    // 忽略规则变更：让已入库歌曲按新规则过滤（喜欢/歌曲/专辑/歌手/源浏览即时生效）。
    context.read<DirectSourceManager>().settingsChanged();
  }

  static String _labelBytes(int bytes) =>
      formatBytes(bytes, zero: '0 MB', minUnit: ByteUnit.mb);

  Future<void> _editScanInterval(BuildContext context) async {
    final text = await showTextInputDialog(
      context: context,
      title: '自动扫描间隔（分钟）',
      initial: _settings.scanAutoIntervalMin.toString(),
      numeric: true,
      footer: '0 为关闭，建议关闭。开启后按固定周期增量扫描全部直连源；'
          '本地目录变化也会自动触发增量扫描。',
    );
    if (text == null || !context.mounted) return;
    final result = int.tryParse(text) ?? 0;
    setState(() => _settings.scanAutoIntervalMin = result);
    context.read<DirectSourceManager>().restartAutoScan();
  }
}
