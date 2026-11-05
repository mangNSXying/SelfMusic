import 'package:file_selector/file_selector.dart';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../platform/harmonyos/ohos_bootstrap.dart';
import '../../platform/harmonyos/ohos_platform_bridge.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/player_provider.dart';
import '../../services/api_client.dart';
import '../../services/server_settings.dart';
import '../../theme/app_metrics.dart';
import '../../utils/format_bytes.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/inline_spinner.dart';
import '../../widgets/row_action_button.dart';
import '../../widgets/single_choice_group.dart';
import '../../widgets/text_input_dialog.dart';

/// 服务端 → 缓存目录：展示真实路径与当前占用；复制路径 / 更改目录（含迁移）。
class CacheDirTile extends StatefulWidget {
  const CacheDirTile();

  @override
  State<CacheDirTile> createState() => _CacheDirTileState();

  static String _fmtBytes(int bytes) =>
      formatBytes(bytes, mbDecimals: 1, useGb: false);
}

class _CacheDirTileState extends State<CacheDirTile> {
  var _moving = false;

  Future<void> _changeDir() async {
    if (isOhos) {
      if (!await OhosPlatformBridge.supportsFolderSelection()) {
        AppToast.show('当前系统SDK无法选择文件夹，建议更新鸿蒙7', ms: 4000);
        return;
      }
      final picked = await OhosPlatformBridge.pickDirectory(write: true);
      if (!mounted || picked == null) return;
      if (!picked.persisted) {
        AppToast.show('目录写授权持久化失败：应用重启后需重新选择');
        return;
      }
      final path = picked.path;
      if (path == null || path.isEmpty) {
        AppToast.show('无法解析所选目录路径');
        return;
      }
      await _migrateTo(path, uri: picked.uri);
      return;
    }
    final dir = await getDirectoryPath(confirmButtonText: '选择');
    if (dir == null || !mounted) return;
    await _migrateTo(dir);
  }

  Future<void> _migrateTo(String dir, {String? uri}) async {
    setState(() => _moving = true);
    try {
      final index = context.read<DirectSourceManager>().index;
      final moved = await index.migrateCacheDir(dir, uri: uri);
      if (!mounted) return;
      setState(() => _moving = false);
      AppToast.show(moved == 0 ? '缓存目录已是该位置' : '缓存目录已更改，迁移 $moved 首',
          isError: false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _moving = false);
      AppToast.error(e, '更改缓存目录失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = context.read<DirectSourceManager>().index;
    final count = index.countUserCachedSongs();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_open),
      title: const Text('缓存目录'),
      subtitle: Text(
          '${index.cacheDir}${index.usingDefaultCacheDir ? '（默认）' : '（自定义）'}\n已缓存 $count 首 · 占用 ${CacheDirTile._fmtBytes(index.cacheTotalBytes())}（含预载）'),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RowActionIconButton(
            icon: Icons.copy_outlined,
            tooltip: '复制路径',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: index.cacheDir));
              AppToast.show('已复制缓存目录路径', isError: false);
            },
          ),
          _moving
              ? const SizedBox(
                  width: kRowActionButtonSize,
                  height: kRowActionButtonSize,
                  child: Center(
                    child: InlineSpinner(size: 20),
                  ),
                )
              : RowActionIconButton(
                  icon: Icons.edit_outlined,
                  tooltip: '更改目录（迁移已有缓存）',
                  onPressed: _changeDir,
                ),
        ],
      ),
    );
  }
}

/// 服务端 → 代理（阶段6，无状态代理，不建库）：
/// 总开关 + 码率三档 + 响度均衡 + 服务端 ffmpeg 可用性（GET /meta/server）。
/// 未配对/旧服务端/无 ffmpeg 时开关灰显；播放失败自动回落直连原文件。
class TranscodeSection extends StatefulWidget {
  const TranscodeSection();

  @override
  State<TranscodeSection> createState() => _TranscodeSectionState();
}

class _TranscodeSectionState extends State<TranscodeSection> {
  bool? _ffmpegAvailable;
  String? _version;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshMeta();
    });
  }

  Future<void> _refreshMeta() async {
    final api = context.read<ApiClient>();
    final server = context.read<ServerSettings>();
    if (server.baseUrl.isEmpty) {
      if (mounted) setState(() => _ffmpegAvailable = null);
      return;
    }
    try {
      final meta = await api.fetchServerMeta();
      if (!mounted) return;
      setState(() {
        _ffmpegAvailable = (meta?['ffmpegAvailable'] as bool?) ?? false;
        _version = meta?['version']?.toString();
      });
    } catch (_) {
      if (mounted) setState(() => _ffmpegAvailable = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<DirectSourceManager>().settings;
    final cs = Theme.of(context).colorScheme;
    final canUse = _ffmpegAvailable == true;
    final unknown = _ffmpegAvailable == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('代理',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
            unknown
                ? '播放源设为代理生效；正在探测服务端能力…'
                : canUse
                    ? '播放源设为代理生效；（${_version == null ? '' : ' · 服务端 $_version'}）'
                    : '服务端不可用或无 ffmpeg；播放自动走直连原文件',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('转码省流'),
          subtitle: const Text('失败回落直连'),
          value: settings.transcodeEnabled && canUse,
          onChanged: !canUse
              ? null
              : (v) {
                  setState(() => settings.transcodeEnabled = v);
                  // 转码总开关即时生效：重载当前曲（保位置/保播放态），无需重启；
                  // 已缓存歌曲仍播本地原文件，内部自动跳过。
                  _applyTranscodeNow();
                },
        ),
        SingleChoiceGroup<int>(
          options: const [
            SingleChoiceOption(value: 192, label: '192k'),
            SingleChoiceOption(value: 256, label: '256k'),
            SingleChoiceOption(value: 320, label: '320k'),
          ],
          value: settings.transcodeBitrate,
          onChanged: !canUse
              ? null
              : (v) {
                  setState(() => settings.transcodeBitrate = v);
                  _applyTranscodeNow();
                },
        ),
        const SizedBox(height: 8),
        Text('响度均衡（需开启转码）',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
        const SizedBox(height: 4),
        SingleChoiceGroup<String>(
          options: const [
            SingleChoiceOption(value: 'off', label: '关'),
            SingleChoiceOption(value: '8', label: '-8'),
            SingleChoiceOption(value: '10', label: '-10'),
            SingleChoiceOption(value: '14', label: '-14'),
            SingleChoiceOption(value: '16', label: '-16'),
            SingleChoiceOption(value: '23', label: '-23'),
          ],
          value: settings.transcodeLoudnorm,
          onChanged: !(canUse && settings.transcodeEnabled)
              ? null
              : (v) {
                  setState(() => settings.transcodeLoudnorm = v);
                  _applyTranscodeNow();
                },
        ),
      ],
    );
  }

  /// 转码/响度变更后即时重载当前曲（fire-and-forget，失败静默）。
  void _applyTranscodeNow() {
    if (!mounted) return;
    final player = context.read<PlayerProvider>();
    // 不 await：重载走网络装载（15s 看门狗），不能卡住开关动画。
    player.reloadCurrentForPlaybackRoute().then((reloaded) {
      if (!mounted || !reloaded) return;
      AppToast.show('已切换到新转码设置', isError: false);
    }).catchError((Object _) {});
  }
}

/// 服务端 → 缓存上限（settings.md §3.3）：跟随服务端 / 自定义双来源（阶段6）。
class CacheConfigSection extends StatefulWidget {
  const CacheConfigSection();
  @override
  State<CacheConfigSection> createState() => _CacheConfigSectionState();
}

class _CacheConfigSectionState extends State<CacheConfigSection> {
  late AppSettings _settings;
  bool _syncing = false;
  bool _serverReachable = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshServerConfig(silent: true);
    });
  }

  /// 拉取服务端建议值并落本地镜像；成功才解锁 follow_server。
  Future<void> _refreshServerConfig({bool silent = false}) async {
    final api = context.read<ApiClient>();
    final server = context.read<ServerSettings>();
    if (server.baseUrl.isEmpty) {
      if (mounted) setState(() => _serverReachable = false);
      return;
    }
    if (!silent && mounted) setState(() => _syncing = true);
    try {
      final data = await api.fetchAdminConfig();
      final bytes = (data['cache_max_bytes'] as num?)?.toInt();
      final limit = (data['cache_song_limit'] as num?)?.toInt();
      if (bytes != null) _settings.serverCacheMaxBytes = bytes;
      if (limit != null) _settings.serverCacheSongLimit = limit;
      if (mounted) setState(() => _serverReachable = true);
      if (!silent && mounted) AppToast.show('已同步服务端缓存建议', isError: false);
    } catch (e) {
      if (mounted) {
        setState(
            () => _serverReachable = _settings.serverCacheMaxBytes != null);
      }
      if (!silent) AppToast.error(e, '同步服务端缓存建议失败');
    } finally {
      if (!silent && mounted) setState(() => _syncing = false);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final follow = _settings.followServer;
    // 未拉取成功过且无镜像时，follow_server 不可选（灰显）。
    final canFollow = _serverReachable || _settings.serverCacheMaxBytes != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('缓存上限',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            if (_syncing)
              const InlineSpinner(size: 20)
            else
              RowActionIconButton(
                tooltip: '同步服务端建议值',
                icon: Icons.sync,
                onPressed: () => _refreshServerConfig(),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text('字节上限与预载共用；歌曲上限只算离线缓存',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
        const SizedBox(height: 8),
        SingleChoiceGroup<String>(
          options: const [
            SingleChoiceOption(value: 'custom', label: '自定义'),
            SingleChoiceOption(value: 'follow_server', label: '跟随服务端'),
          ],
          value: follow ? 'follow_server' : 'custom',
          onChanged: (v) async {
            if (v == 'follow_server' && !canFollow) {
              // 先拉一次，成功才允许切换。
              await _refreshServerConfig();
              if (!mounted) return;
              if (!(_serverReachable ||
                  _settings.serverCacheMaxBytes != null)) {
                AppToast.show('服务端不可达，请检查后端连接', isError: true);
                return;
              }
            }
            setState(() => _settings.cacheConfigMode = v);
          },
        ),
        if (follow)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _settings.serverCacheMaxBytes == null
                  ? '尚未同步到服务端建议值（点右上同步）'
                  : '服务端建议：${_labelBytes(_settings.serverCacheMaxBytes!)} · ${_settings.serverCacheSongLimit ?? _settings.cacheSongLimit} 首'
                      '${_serverReachable ? '' : '（离线，回退显示上次镜像）'}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
              '当前生效：${_labelBytes(_settings.effectiveCacheMaxBytes)} · 离线缓存 ${_settings.effectiveCacheSongLimit} 首',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.storage_outlined),
          title: const Text('缓存总上限'),
          subtitle: Text(_labelBytes(_settings.cacheMaxBytes)),
          trailing: const Icon(Icons.chevron_right),
          enabled: !follow,
          onTap: follow ? null : () => _editMaxBytes(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.library_music_outlined),
          title: const Text('歌曲数量上限'),
          subtitle: Text('${_settings.cacheSongLimit} 首'),
          trailing: const Icon(Icons.chevron_right),
          enabled: !follow,
          onTap: follow ? null : () => _editSongLimit(context),
        ),
      ],
    );
  }

  Future<void> _editMaxBytes(BuildContext context) async {
    final current = _settings.cacheMaxBytes ~/ (1024 * 1024);
    final text = await showTextInputDialog(
      context: context,
      title: '缓存总上限（MB）',
      initial: current.toString(),
      numeric: true,
    );
    if (text == null || !mounted) return;
    final result = int.tryParse(text) ?? current;
    if (result > 0) {
      setState(() => _settings.cacheMaxBytes = result * 1024 * 1024);
    }
  }

  Future<void> _editSongLimit(BuildContext context) async {
    final text = await showTextInputDialog(
      context: context,
      title: '歌曲数量上限',
      initial: _settings.cacheSongLimit.toString(),
      numeric: true,
    );
    if (text == null || !mounted) return;
    final result = int.tryParse(text) ?? _settings.cacheSongLimit;
    if (result > 0) {
      setState(() => _settings.cacheSongLimit = result);
    }
  }

  static String _labelBytes(int bytes) =>
      formatBytes(bytes, zero: '0 MB', minUnit: ByteUnit.mb);
}
