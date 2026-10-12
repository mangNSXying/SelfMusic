import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../data/local/app_settings.dart';
import '../data/local/backup_service.dart';
import '../platform/harmonyos/ohos_bootstrap.dart';
import '../providers/auth_provider.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../services/api_client.dart';
import '../services/artist_resolver.dart';
import '../services/bluetooth_service.dart';
import '../services/server_settings.dart';
import '../services/sync_engine.dart';
import '../utils/url_input.dart';
import '../theme/app_theme.dart';
import '../theme/theme_provider.dart';
import '../utils/cover_thumb.dart';
import '../widgets/app_toast.dart';
import 'devices_screen.dart';
import 'pairing_screen.dart';

/// 设置页：根据侧边栏选中的分区渲染对应设置面板。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T010）：设置页只关注当前设置分区；区段/搜索/播放页等变更
    // 不再重建设置页。
    final item =
        context.select<NavigationProvider, SettingsItem?>((n) => n.settings);
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
  late final FocusNode _urlFocus;
  late String _saved;
  bool _saving = false;
  String _pairingToken = '';

  @override
  void initState() {
    super.initState();
    final settings = context.read<ServerSettings>();
    _saved = settings.baseUrl;
    _controller = TextEditingController(text: settings.baseUrl);
    _urlFocus = FocusNode();
    _urlFocus.addListener(() {
      if (!_urlFocus.hasFocus && mounted) {
        if (autoCompleteUrlController(_controller)) setState(() {});
      }
    });
    // 先展示本地保存的密钥（离线也能看到），再尝试向服务端刷新。
    _pairingToken = settings.pairingKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchPairingKey();
    });
  }

  @override
  void dispose() {
    _urlFocus.dispose();
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
    // 后端地址走 HTTP：保存前先把补全写回输入框（可视化），再校验。
    if (applyHttpsPrefixToController(_controller)) {
      AppToast.show('已自动补全 https:// 前缀', isError: false);
      setState(() {});
    }
    final entered = _controller.text.trim();
    // 默认 HTTPS：显式 http:// 仅在「允许不安全 HTTP」开启后放行（settings.md §3.3）。
    // 弹窗一键开启（url_input.ensureHttpAllowed），模型层 setBaseUrl 归一化兜底。
    final directSettings = context.read<DirectSourceManager>().settings;
    var err = ApiClient.validateEndpointUrl(entered,
        allowHttp: directSettings.allowInsecureHttp);
    if (err != null) {
      if (urlIsExplicitHttp(entered)) {
        final ok = await ensureHttpAllowed(context, entered);
        if (!mounted) return;
        if (!ok) {
          setState(() => _saving = false);
          AppToast.show(err);
          return;
        }
        err = ApiClient.validateEndpointUrl(entered,
            allowHttp:
                context.read<DirectSourceManager>().settings.allowInsecureHttp);
      }
      if (err != null) {
        setState(() => _saving = false);
        if (!mounted) return;
        AppToast.show(err);
        return;
      }
    }
    // 空表示清空（未配置）
    await settings.setBaseUrl(entered);
    api.setBaseUrl(settings.baseUrl);
    if (!mounted) return;
    setState(() {
      _saved = settings.baseUrl;
      _saving = false;
      // 归一化结果（二重保险：去尾斜杠等）写回输入框，保证所见即所得。
      if (_controller.text.trim() != _saved) {
        _controller.text = _saved;
        _controller.selection =
            TextSelection.collapsed(offset: _saved.length);
      }
    });
    // 地址变化后刷新配对密钥展示。
    await _fetchPairingKey();
    if (!mounted) return;
    AppToast.show('已保存服务端地址：${_saved.isEmpty ? "（未配置）" : _saved}',
        isError: false);
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
          Text('配置后端地址与配对；多设备同步与设备管理在此',
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
            focusNode: _urlFocus,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onSubmitted: (_) {
              if (autoCompleteUrlController(_controller)) setState(() {});
            },
            decoration: const InputDecoration(
              labelText: '后端地址',
              hintText: 'https://192.168.1.10:18443',
              helperText: '含协议与端口，留空表示未配置；未填协议自动补 https://',
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
          const SizedBox(height: 16),
          const Divider(),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('多设备同步',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 4),
          const _SyncSection(),
          const SizedBox(height: 32),
          const Divider(),
          const _CacheConfigSection(),
          const Divider(height: 24),
          const _CacheDirTile(),
          const SizedBox(height: 16),
          const Divider(),
          const _TranscodeSection(),
          const SizedBox(height: 16),
          const Divider(),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('网络与安全',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许不安全 HTTP'),
            subtitle: const Text('默认关闭，收不到明文 http:// 地址；缺省协议默认补 https://。后端地址与 WebDAV 地址均受此开关约束'),
            value: context
                .read<DirectSourceManager>()
                .settings
                .allowInsecureHttp,
            onChanged: (v) {
              context.read<DirectSourceManager>().settings.allowInsecureHttp = v;
              setState(() {});
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('信任自签名证书'),
            subtitle: const Text('默认关闭；开启后 API、直连 WebDAV 与鸿蒙播放器(fvp/mdk)跳过证书校验'),
            value: context
                .read<DirectSourceManager>()
                .settings
                .allowSelfSigned,
            onChanged: (v) {
              final settings =
                  context.read<DirectSourceManager>().settings;
              settings.allowSelfSigned = v;
              context.read<DirectSourceManager>().applySecuritySettings();
              context.read<ApiClient>().setSelfSignedPolicy(v);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

/// 服务端 → 多设备同步（阶段5，DEVELOPER.md「播放算法与同步协议」）：总开关 + 立即同步 + 设备管理入口。
class _SyncSection extends StatefulWidget {
  const _SyncSection();

  @override
  State<_SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<_SyncSection> {
  bool _syncing = false;

  /// 待上推事件数缓存（同步后台化：COUNT 走写隔离异步取，不在 build 里同步查库）。
  int _pending = 0;

  @override
  void initState() {
    super.initState();
    _refreshPending();
  }

  Future<void> _refreshPending() async {
    final n = await context.read<DirectSourceManager>().index.pendingOutboxCount();
    if (!mounted) return;
    setState(() => _pending = n);
  }

  String _subtitle() {
    final settings = context.read<DirectSourceManager>().settings;
    final engine = context.read<SyncEngine>();
    final parts = <String>[];
    if (_pending > 0) parts.add('待上推 $_pending');
    final last = settings.lastSyncAt;
    parts.add(last.isEmpty ? '尚未同步成功' : '上次 ${_shortTime(last)}');
    if (engine.lastError.isNotEmpty) parts.add('错误：${engine.lastError}');
    return parts.join(' · ');
  }

  static String _shortTime(String iso) {
    final s = iso.replaceFirst('T', ' ');
    return s.length > 16 ? s.substring(0, 16) : s;
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    await context.read<SyncEngine>().syncNow(force: true);
    if (!mounted) return;
    setState(() => _syncing = false);
    await _refreshPending();
    if (!mounted) return;
    final err = context.read<SyncEngine>().lastError;
    AppToast.show(err.isEmpty ? '同步完成' : '同步失败：$err',
        isError: err.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<DirectSourceManager>().settings;
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('多设备同步'),
          subtitle: const Text('权重 / 收藏 / 歌单 / 断点经服务端在设备间收敛（连着服务器时直连歌曲同样参与；关闭=仅本地）'),
          value: settings.syncEnabled,
          onChanged: (v) {
            settings.syncEnabled = v;
            setState(() {});
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _syncing
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sync),
          title: const Text('立即同步'),
          subtitle: Text(_subtitle()),
          onTap: _syncing ? null : _syncNow,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.devices),
          title: const Text('已配对设备'),
          subtitle: const Text('查看 / 改名 / 吊销'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DevicesScreen()),
          ),
        ),
      ],
    );
  }
}

/// 服务端 → 缓存目录：展示真实路径与当前占用；复制路径 / 更改目录（含迁移）。
class _CacheDirTile extends StatefulWidget {
  const _CacheDirTile();

  @override
  State<_CacheDirTile> createState() => _CacheDirTileState();

  static String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

class _CacheDirTileState extends State<_CacheDirTile> {
  var _moving = false;

  Future<void> _changeDir() async {
    if (isOhos) {
      // 缓存迁移为 dart:io 直写，URI 授权目录不可写（且 file_selector_ohos
      // 的 getDirectoryPath 未实现必抛异常）——明确降级提示，不拉起选择器。
      AppToast.show('鸿蒙端暂不支持自定义缓存目录', isError: false);
      return;
    }
    final dir = await getDirectoryPath(confirmButtonText: '选择');
    if (dir == null || !mounted) return;
    setState(() => _moving = true);
    try {
      final index = context.read<DirectSourceManager>().index;
      final moved = await index.migrateCacheDir(dir);
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
    final count = index.listCache().length;
    final custom = index.customCacheDir;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_open),
      title: const Text('缓存目录'),
      subtitle: Text(
          '${index.cacheDir}${custom == null ? '（默认）' : '（自定义）'}\n已缓存 $count 首 · 占用 ${_CacheDirTile._fmtBytes(index.cacheTotalBytes())}'),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: '复制路径',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: index.cacheDir));
              AppToast.show('已复制缓存目录路径', isError: false);
            },
          ),
          _moving
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  icon: const Icon(Icons.edit_outlined),
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
class _TranscodeSection extends StatefulWidget {
  const _TranscodeSection();

  @override
  State<_TranscodeSection> createState() => _TranscodeSectionState();
}

class _TranscodeSectionState extends State<_TranscodeSection> {
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
                ? '经服务端代理播放：按需转码为 MP3（FLAC 源省流量）+ 可选响度均衡；正在探测服务端能力…'
                : canUse
                    ? '经服务端代理播放：按需转码为 MP3（FLAC 源省流量${_version == null ? '' : ' · 服务端 $_version'}）+ 可选响度均衡；缓存仍存原文件'
                    : '服务端不可用或无 ffmpeg（或未配对/旧服务端），开关不可用；播放自动走直连原文件',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('播放时代理转码'),
          subtitle: const Text('仅代理生效；失败回落直连（转码 seek 精度 ±2s）'),
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
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 192, label: Text('192k')),
            ButtonSegment(value: 256, label: Text('256k')),
            ButtonSegment(value: 320, label: Text('320k')),
          ],
          selected: {settings.transcodeBitrate},
          onSelectionChanged: !canUse
              ? null
              : (s) {
                  setState(() => settings.transcodeBitrate = s.first);
                  _applyTranscodeNow();
                },
        ),
        const SizedBox(height: 8),
        Text('响度均衡（LUFS，仅代理转码时生效）',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6))),
        const SizedBox(height: 4),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'off', label: Text('关')),
            ButtonSegment(value: '14', label: Text('-14')),
            ButtonSegment(value: '16', label: Text('-16')),
            ButtonSegment(value: '23', label: Text('-23')),
          ],
          selected: {settings.transcodeLoudnorm},
          onSelectionChanged: !(canUse && settings.transcodeEnabled)
              ? null
              : (s) {
                  setState(() => settings.transcodeLoudnorm = s.first);
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
class _CacheConfigSection extends StatefulWidget {
  const _CacheConfigSection();
  @override
  State<_CacheConfigSection> createState() => _CacheConfigSectionState();
}

class _CacheConfigSectionState extends State<_CacheConfigSection> {
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
      if (mounted) setState(() => _serverReachable = _settings.serverCacheMaxBytes != null);
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
              const SizedBox(
                  width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            else
              IconButton(
                tooltip: '同步服务端建议值',
                icon: const Icon(Icons.sync, size: 20),
                onPressed: () => _refreshServerConfig(),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text('离线缓存与预载共用；超出后按 LRU 淘汰（当前播放/预载受保护）',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'custom', label: Text('自定义')),
            ButtonSegment(value: 'follow_server', label: Text('跟随服务端')),
          ],
          selected: {follow ? 'follow_server' : 'custom'},
          onSelectionChanged: (s) async {
            final want = s.first;
            if (want == 'follow_server' && !canFollow) {
              // 先拉一次，成功才允许切换。
              await _refreshServerConfig();
              if (!mounted) return;
              if (!(_serverReachable || _settings.serverCacheMaxBytes != null)) {
                AppToast.show('服务端不可达，请检查后端连接', isError: true);
                return;
              }
            }
            setState(() => _settings.cacheConfigMode = want);
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('当前生效：${_labelBytes(_settings.effectiveCacheMaxBytes)} · ${_settings.effectiveCacheSongLimit} 首',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.primary, fontWeight: FontWeight.w600)),
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
  late AppSettings _settings;
  bool _clearingThumbs = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.read<DirectSourceManager>().settings;
    _transition = s.playerTransition;
    _settings = s;
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

          // 明暗模式：跟随系统 / 浅色 / 深色
          Text('明暗模式', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('跟随系统'), icon: Icon(Icons.brightness_auto)),
              ButtonSegment(value: ThemeMode.light, label: Text('浅色'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('深色'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {theme.themeMode},
            onSelectionChanged: (s) => theme.setThemeMode(s.first),
          ),
          const SizedBox(height: 8),
          Text(theme.themeMode == ThemeMode.system
              ? '随手机 / 电脑系统自动切换明暗'
              : '固定使用当前所选明暗，不跟随系统',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.6))),
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('播放页滑动手势'),
            subtitle: const Text('横滑切换播放页与歌词页、下滑返回列表（关闭后仅用按钮操作）'),
            value: _settings.playerGestureSwipe,
            onChanged: (v) => setState(() => _settings.playerGestureSwipe = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('播放页显示权重信息'),
            subtitle: const Text('播放页展示当前歌曲喜欢 / 权重状态'),
            value: _settings.playerShowWeight,
            onChanged: (v) => setState(() => _settings.playerShowWeight = v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.title),
            title: const Text('标题显示格式'),
            subtitle: Text('当前：${_settings.songTitleFormat.label}'
                '（补读元数据后按此格式展示，不修改存储字段）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickTitleFormat(context),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.timer_outlined),
            title: const Text('播放页控件自动隐藏'),
            subtitle: Text(_settings.playerAutoHideIdleSec > 0
                ? '播放页无操作 ${_settings.playerAutoHideIdleSec} 秒后自动隐藏左上返回与右上更多按钮，触摸即恢复'
                : '关闭（控制按钮常驻显示）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickPlayerAutoHide(context),
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 封面画质：压缩开关 + 手动清理（默认关=原图优先）。
          Text('封面画质', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('压缩图像画质'),
            subtitle: const Text('开：列表/卡片用 768 长边 JPEG 缩略图，滑动更省；关：直接显示封面原图，画质无损（播放页恒用原图）'),
            value: _settings.compressCoverImage,
            onChanged: (v) async {
              setState(() => _settings.compressCoverImage = v);
              await context.read<DirectSourceManager>().applyCoverThumbSetting();
              if (context.mounted) setState(() {});
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清理缩略图缓存'),
            subtitle: const Text('删除已生成的缩略图文件（*.thumb.jpg），显示即回原图；开关关闭时也可清理省磁盘'),
            trailing: _clearingThumbs
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: _clearingThumbs ? null : () => _clearCoverThumbs(context),
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

  /// 标题显示格式选择（从 设置>歌曲 迁入 设置>界面，改进.txt UI4）。
  Future<void> _pickTitleFormat(BuildContext context) async {
    final chosen = await showDialog<SongTitleFormat>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('标题显示格式'),
        children: [
          for (final f in SongTitleFormat.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(c).pop(f),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(f.label)),
                    if (f == _settings.songTitleFormat)
                      Icon(Icons.check, color: Theme.of(c).colorScheme.primary),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !context.mounted) return;
    setState(() => _settings.songTitleFormat = chosen);
    // 设置写入后通知全局重建（AppSettings 非 ChangeNotifier）。
    context.read<DirectSourceManager>().refresh();
  }

  /// 播放页控件静置自动隐藏秒数（0=不隐藏）。
  Future<void> _pickPlayerAutoHide(BuildContext context) async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('播放页控件自动隐藏'),
        children: [
          for (final sec in AppSettings.playerAutoHideIdleOptions)
            SimpleDialogOption(
              onPressed: () => Navigator.of(c).pop(sec),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(sec == 0 ? '不自动隐藏' : '$sec 秒')),
                    if (sec == _settings.playerAutoHideIdleSec)
                      Icon(Icons.check, color: Theme.of(c).colorScheme.primary),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !context.mounted) return;
    setState(() => _settings.playerAutoHideIdleSec = chosen);
    context.read<DirectSourceManager>().refresh();
  }

  /// 清理缩略图缓存：二次确认后删 `*.thumb.jpg`（开关状态不变）。
  Future<void> _clearCoverThumbs(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清理缩略图缓存？'),
        content: const Text('将删除已生成的封面缩略图文件，列表即回原图显示。\n'
            '压缩开关保持不变：开时后续滚动会重新生成，关时不再生成。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('清理')),
        ],
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
      AppToast.show(
          removed == 0 ? '没有可清理的缩略图' : '已清理 $removed 张缩略图',
          isError: false);
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _clearingThumbs = false);
      AppToast.error(e, '清理缩略图失败');
    }
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
              ? '补读到时长后忽略短于 ${_settings.scanIgnoreMinDurationSec} 秒的音频（首扫只建索引，不读文件，此时不生效）'
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
        const ListTile(
          title: Text('扫描方式'),
          subtitle: Text('快速：只建索引（文件名建索引，不读音频内容）。'
              '元数据与封面由播放时和后台补读补齐'),
          trailing: Icon(Icons.check, size: 20),
          enabled: false,
        ),
        ListTile(
          title: const Text('自动扫描间隔'),
          subtitle: Text(_settings.scanAutoIntervalMin > 0
              ? '每 ${_settings.scanAutoIntervalMin} 分钟增量扫描一次（本地目录变化也会立即触发）'
              : '关闭（手动扫描 / 打开源页触发）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editScanInterval(context),
        ),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('权重·时长削弱',
              style: TextStyle(
                  color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        SwitchListTile(
          title: const Text('时长削弱'),
          subtitle: const Text('开启后加权随机按歌曲时长乘削弱系数（长歌权重降低；抽样即时生效，不落库）'),
          value: _settings.weightCurveEnabled,
          onChanged: (v) {
            setState(() => _settings.weightCurveEnabled = v);
          },
        ),
        ListTile(
          title: const Text('权重-时长曲线'),
          subtitle: Text(_weightCurveSummary(_settings.weightCurveSegments)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editWeightCurve(context),
        ),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('歌手解析',
              style: TextStyle(
                  color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        SwitchListTile(
          title: const Text('自动后台解析'),
          subtitle: const Text('向 MusicBrainz 查询歌手身份（需联网；限流 1 次/秒，'
              '失败自动退避重试）。关闭后仅保留本地归一去重'),
          value: _settings.artistResolveAuto,
          onChanged: (v) {
            setState(() => _settings.artistResolveAuto = v);
            if (v) {
              context.read<ArtistResolver>().wake();
            }
          },
        ),
        ListTile(
          title: const Text('重试解析'),
          subtitle: const Text('把未命中/待确认的歌手重置为重试解析'),
          trailing: const Icon(Icons.refresh),
          onTap: () async {
            await context.read<ArtistResolver>().retryAll();
            if (context.mounted) {
              AppToast.show('已开始重试解析歌手', isError: false);
            }
          },
        ),
        ListTile(
          title: const Text('强制解析'),
          subtitle: const Text('连已解析的歌手一起按 MB 重新拉取，成员也会重新展开；受 MB 限流，逐个顺序进行'),
          trailing: const Icon(Icons.playlist_add_check),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('强制解析全部歌手？'),
                content: const Text('会把所有歌手（含已解析成功的）重新拉取一遍，并重新展开组合成员。请求受 MusicBrainz 限流，歌手多时需要跑一阵。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(c).pop(false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.of(c).pop(true),
                      child: const Text('开始')),
                ],
              ),
            );
            if (ok != true || !context.mounted) return;
            await context.read<ArtistResolver>().forceRetryAll();
            if (context.mounted) {
              AppToast.show('已开始强制解析歌手', isError: false);
            }
          },
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
    if (result != null && result >= 0 && context.mounted) {
      setState(() => _settings.scanIgnoreMinDurationSec = result);
      // 忽略规则变更：让已入库歌曲按新规则过滤（喜欢/歌曲/专辑/歌手/源浏览即时生效）。
      context.read<DirectSourceManager>().settingsChanged();
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
    if (result != null && result >= 0 && context.mounted) {
      setState(() => _settings.scanIgnoreMinSizeBytes = result * 1024 * 1024);
      // 忽略规则变更：让已入库歌曲按新规则过滤（喜欢/歌曲/专辑/歌手/源浏览即时生效）。
      context.read<DirectSourceManager>().settingsChanged();
    }
  }

  static double? _segNum(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static String _weightCurveSummary(List<Map<String, Object?>> segs) {
    if (segs.isEmpty) return '未配置（不削弱）';
    return '${segs.length} 段区间；按时长乘系数抽样';
  }

  static String _segmentLabel(Map<String, Object?> m) {
    final min = _segNum(m['min_sec']);
    final max = _segNum(m['max_sec']);
    final f = _segNum(m['factor']);
    final range = max == null
        ? '≥ ${min?.toStringAsFixed(0) ?? '?'} 秒'
        : '${min?.toStringAsFixed(0) ?? '?'} - ${max.toStringAsFixed(0)} 秒';
    return '$range → ×${f == null ? '?' : f.toStringAsFixed(2)}';
  }

  Future<void> _editWeightCurve(BuildContext context) async {
    final working = List<Map<String, Object?>>.from(_settings.weightCurveSegments);
    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialog) => AlertDialog(
          title: const Text('权重-时长曲线'),
          content: SizedBox(
            width: 380,
            child: working.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('尚未配置区间：所有歌曲权重按 1.0（不削弱）。'),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (var i = 0; i < working.length; i++) ...[
                        ListTile(
                          dense: true,
                          leading: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.redAccent),
                            onPressed: () => setDialog(() => working.removeAt(i)),
                          ),
                          title: Text(_segmentLabel(working[i])),
                          onTap: () async {
                            final edited =
                                await _editWeightSegment(c, working[i]);
                            if (edited != null) setDialog(() => working[i] = edited);
                          },
                        ),
                      ],
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => setDialog(() => working.add(
                  const {'min_sec': 300.0, 'max_sec': null, 'factor': 0.5})),
              child: const Text('+ 添加区间'),
            ),
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _settings.weightCurveSegments = working);
    }
  }

  Future<Map<String, Object?>?> _editWeightSegment(
      BuildContext c, Map<String, Object?> current) async {
    final minC =
        TextEditingController(text: _segNum(current['min_sec'])?.toStringAsFixed(0) ?? '');
    final maxC =
        TextEditingController(text: _segNum(current['max_sec'])?.toStringAsFixed(0) ?? '');
    final fC =
        TextEditingController(text: _segNum(current['factor'])?.toStringAsFixed(2) ?? '');
    const kt = TextInputType.numberWithOptions(decimal: true);
    final result = await showDialog<bool>(
      context: c,
      builder: (d) => AlertDialog(
        title: const Text('编辑区间'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: minC,
                keyboardType: kt,
                decoration: const InputDecoration(labelText: '起始时长（秒，必填）')),
            TextField(
                controller: maxC,
                keyboardType: kt,
                decoration:
                    const InputDecoration(labelText: '结束时长（秒，留空=无上限）')),
            TextField(
                controller: fC,
                keyboardType: kt,
                decoration:
                    const InputDecoration(labelText: '系数（0.5 - 1.5）')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(d).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(d).pop(true),
              child: const Text('保存')),
        ],
      ),
    );
    if (result != true) return null;
    final min = double.tryParse(minC.text.trim());
    final max = maxC.text.trim().isEmpty
        ? null
        : double.tryParse(maxC.text.trim());
    final f = double.tryParse(fC.text.trim());
    if (min == null || min <= 0 || f == null || f <= 0) return current;
    if (max != null && max <= min) return current;
    return {'min_sec': min, 'max_sec': max, 'factor': f.clamp(0.5, 1.5)};
  }

  static String _labelBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
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

/// 播放设置（settings.md §3.2）：默认播放模式 / 加权随机削峰（次数·曲数冷却）/
/// 断点续播 / 淡入淡出 / 均衡器。
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
        ListTile(
          leading: const Icon(Icons.waves),
          title: const Text('加权随机·次数冷却'),
          subtitle: Text(_drawCooldownSummary(_settings.weightedDrawCooldown)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickDrawCooldown,
        ),
        ListTile(
          leading: const Icon(Icons.timeline),
          title: const Text('加权随机·曲数冷却'),
          subtitle: Text(_countCooldownSummary(_settings.weightedCountCooldownRatio)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editCountCooldown,
        ),
        SwitchListTile(
          title: const Text('断点续播自动恢复'),
          subtitle: const Text('启动时恢复上次队列与位置（恢复为暂停态，不自动播放）'),
          value: _settings.resumeOnStartup,
          onChanged: (v) => setState(() => _settings.resumeOnStartup = v),
        ),
        SwitchListTile(
          title: const Text('预载下一首'),
          subtitle: const Text('播放时按播放顺序算法确定下一首并后台缓存（加权随机也先抽样确定并复用；开关只决定是否预载）'),
          value: _settings.preloadNext,
          onChanged: (v) => setState(() => _settings.preloadNext = v),
        ),
        SwitchListTile(
          title: const Text('睡眠定时默认播完最后曲目'),
          subtitle: const Text('到点不中断当前歌曲，放完这曲再暂停（弹窗内可单独调整）'),
          value: _settings.sleepPlayThroughDefault,
          onChanged: (v) => setState(() => _settings.sleepPlayThroughDefault = v),
        ),
        ListTile(
          leading: const Icon(Icons.lyrics_outlined),
          title: const Text('歌词追焦等待'),
          subtitle: Text(
              '拖动歌词后 ${_settings.lyricFocusIdleSec} 秒无操作恢复自动追焦并回中当前行'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickLyricIdle(context),
        ),
        SwitchListTile(
          title: const Text('播放页屏幕常亮'),
          subtitle: const Text('打开播放页期间不熄屏；可限定仅在指定蓝牙设备连接时生效'),
          value: _settings.playerKeepScreenOn,
          onChanged: (v) => setState(() => _settings.playerKeepScreenOn = v),
        ),
        if (_settings.playerKeepScreenOn)
          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: const Text('常亮限定蓝牙设备'),
            subtitle: Text(_keepAwakeDeviceLabel()),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickKeepAwakeDevice,
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
                  // 有效域 [500, 2000]ms（读取已钳制）：0.5~2.0s、0.1s 步进
                  //（divisions 15，16 档），标签一位小数实时预览。
                  value: (_settings.fadeDurationMs / 1000).clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  label:
                      '${(_settings.fadeDurationMs / 1000).toStringAsFixed(1)} 秒',
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
        const Divider(height: 24),
        SwitchListTile(
          title: const Text('自动暂停/恢复'),
          subtitle: const Text('通话等音频焦点抢占时自动暂停，结束后恢复（Android 生效）'),
          value: _settings.audioFocusEnabled,
          onChanged: (v) {
            setState(() => _settings.audioFocusEnabled = v);
            context.read<PlayerProvider>().applyAudioConfig();
          },
        ),
        SwitchListTile(
          title: const Text('静音暂停'),
          subtitle: const Text('媒体音量归零时自动暂停（Android/鸿蒙生效）'),
          value: _settings.pauseOnZeroVolume,
          onChanged: (v) {
            setState(() => _settings.pauseOnZeroVolume = v);
            context.read<PlayerProvider>().refreshPlaybackGuard();
          },
        ),
        SwitchListTile(
          title: const Text('断连暂停'),
          subtitle: const Text('当前播放设备（如蓝牙音箱）断开时自动暂停；从蓝牙切到扬声器不暂停（Android/鸿蒙生效）'),
          value: _settings.pauseOnDeviceDisconnect,
          onChanged: (v) {
            setState(() => _settings.pauseOnDeviceDisconnect = v);
            context.read<PlayerProvider>().refreshPlaybackGuard();
          },
        ),
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

  static String _drawCooldownSummary(WeightedDrawCooldown cd) =>
      cd == WeightedDrawCooldown.off
          ? '关（不启用次数冷却）'
          : '${cd.label}（factor>1.0 抛弃 ${cd.highLimit} 次 / 其余抛弃 ${cd.lowLimit} 次）';

  static String _countCooldownSummary(double ratio) => ratio <= 0
      ? '关（不启用曲数冷却）'
      : '列表长度 × ${(ratio * 100).toStringAsFixed(0)}%';

  Future<void> _pickDrawCooldown() async {
    final current = _settings.weightedDrawCooldown;
    final picked = await showDialog<WeightedDrawCooldown>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('加权随机·次数冷却'),
        children: [
          RadioGroup<WeightedDrawCooldown>(
            groupValue: current,
            onChanged: (v) {
              if (v != null) Navigator.of(c).pop(v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final cd in WeightedDrawCooldown.values)
                  RadioListTile<WeightedDrawCooldown>(
                    title: Text(cd.label),
                    subtitle: Text(_drawCooldownSummary(cd)),
                    value: cd,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null || picked == current || !mounted) return;
    setState(() => _settings.weightedDrawCooldown = picked);
  }

  Future<void> _editCountCooldown() async {
    final current = _settings.weightedCountCooldownRatio;
    final controller = TextEditingController(text: current.toStringAsFixed(2));
    final result = await showDialog<double>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('加权随机·曲数冷却比例'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '0 ~ 1.00',
            helperText: '距上次播放不超过「列表长度 × 比例」时重抽；0=关闭',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c)
                  .pop(double.tryParse(controller.text) ?? current),
              child: const Text('确定')),
        ],
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _settings.weightedCountCooldownRatio = result);
  }

  /// 常亮限定设备展示名（未限定=全局常亮）。
  String _keepAwakeDeviceLabel() {
    final ds = btDevicesFromSetting(_settings.keepScreenOnDevice);
    if (ds.isEmpty) return '不限定（打开播放页即常亮）';
    if (ds.length == 1) return '${ds.first.name}（仅连接时生效）';
    return '${ds.map((d) => d.name).join('、')}（任一连接时生效）';
  }

  Future<void> _pickKeepAwakeDevice() async {
    final svc = BluetoothService();
    final granted = await svc.ensurePermission();
    if (!mounted) return;
    if (!granted) {
      // ohos 两次拒绝后系统弹窗不再出现，只能去系统设置手动开启
      // （ArkTS 三段式已含设置弹框兜底，仍被拒即引导）。
      AppToast.show(
          isOhos ? '未授予蓝牙权限，可在 设置 > 应用和元服务 > SelfMusic 中开启' : '未授予蓝牙权限，无法读取已配对设备',
          isError: true);
      return;
    }
    final devices = await svc.bondedDevices();
    if (!mounted) return;
    if (devices.isEmpty) {
      AppToast.show('未找到已配对设备（请先在系统设置中配对）', isError: true);
      return;
    }
    if (isOhos) {
      // 2026-10-06 曾加「endOfFrame + 150ms」延迟规避「只出遮罩无内容」，
      // 2026-10-07 VM service 取证证伪该假设（延迟后仍复现；真因在对话框
      // 内容结构，见 _KeepAwakeDeviceDialog），故移除。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final selected = {
      for (final d in btDevicesFromSetting(_settings.keepScreenOnDevice)) d.address
    };
    final picked = await showDialog<List<BtDevice>>(
      context: context,
      builder: (c) =>
          _KeepAwakeDeviceDialog(devices: devices, selected: selected),
    );
    if (picked == null || !mounted) return;
    setState(() =>
        _settings.keepScreenOnDevice = btDevicesToSetting(picked));
  }

  Future<void> _pickLyricIdle(BuildContext context) async {
    final current = _settings.lyricFocusIdleSec;
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('歌词追焦等待'),
        children: [
          RadioGroup<int>(
            groupValue: current,
            onChanged: (v) {
              if (v != null) Navigator.of(c).pop(v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in AppSettings.lyricFocusIdleOptions)
                  RadioListTile<int>(title: Text('$s 秒'), value: s),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null || picked == current || !context.mounted) return;
    setState(() => _settings.lyricFocusIdleSec = picked);
  }
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
    final file = await _service(direct).exportSettings();
    _refresh();
    if (!mounted) return;
    AppToast.show('已导出：${file.path.split('/').last}（不含令牌与源凭据）',
        isError: false);
  }

  Future<void> _doExportPlaylists() async {
    final direct = context.read<DirectSourceManager>();
    final file = await _service(direct).exportPlaylists();
    _refresh();
    if (!mounted) return;
    AppToast.show('已导出：${file.path.split('/').last}', isError: false);
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
      if (mounted) return _toast('打开文件失败：$e', isError: true);
      return;
    }
    if (picked == null) return;
    if (!mounted) return;
    final f = File(picked.path);
    if (!f.existsSync()) {
      _toast('所选文件不存在：${picked.path}', isError: true);
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
      _toast('导入失败：$e', isError: true);
    }
  }

  void _toast(String msg, {bool isError = false}) {
    AppToast.show(msg, isError: isError);
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
      AppToast.show(summaries.join('；'), isError: false);
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

/// 通知设置（settings.md §3.6）：通知栏控制/后台播放（Android）。
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
              '通知栏播放控制 / 后台播放基于 just_audio_background，'
              '仅 Android 生效；Linux 桌面忽略这些开关。',
              style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        SwitchListTile(
          title: const Text('通知栏播放控制'),
          subtitle: const Text(
              '在通知栏/播控中心显示播放控制按钮（修改后重启生效）。关闭只隐藏'
              '按钮——后台播放所需的保活（前台服务/长时任务）始终保持，不受影响。'),
          value: _settings.notificationControls,
          onChanged: (v) {
            setState(() => _settings.notificationControls = v);
            AppToast.show('通知栏播放控制将在重启应用后生效', isError: false);
          },
        ),
      ],
    );
  }
}

/// 常亮限定蓝牙设备多选弹窗：复选框支持选多个设备；
/// 所选设备任一处于连接状态即保持常亮；一个都不勾 = 不限定。
class _KeepAwakeDeviceDialog extends StatefulWidget {
  const _KeepAwakeDeviceDialog(
      {required this.devices, required this.selected});

  final List<BtDevice> devices;
  final Set<String> selected;

  @override
  State<_KeepAwakeDeviceDialog> createState() => _KeepAwakeDeviceDialogState();
}

class _KeepAwakeDeviceDialogState extends State<_KeepAwakeDeviceDialog> {
  late final Set<String> _sel = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('常亮限定蓝牙设备'),
      content: SizedBox(
        // double.maxFinite：AlertDialog 内容占满弹窗宽（官方推荐形态）；
        // 固定 320 在窄屏/异常窗口度量下有布局风险（2026-10-06 真机
        // 「仅遮罩无内容」bug 一并调整）。
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('可多选：所选设备任一处于连接状态时保持常亮；都不勾 = 不限定',
                  style: TextStyle(fontSize: 12)),
            ),
            Flexible(
              // 不能用 ListView(shrinkWrap:true)：shrinkWrap 视口会进入
              // AlertDialog 内置 IntrinsicWidth 的固有宽度计算路径，ohos
              // fork 在该组合下布局静默失败——脏标志被清却从不布局，弹窗
              // 只渲染灰遮罩（2026-10-07 VM service render dump 取证：
              // 卡片子树已挂载但 size MISSING）。改用普通 Column +
              // SingleChildScrollView（无 shrinkWrap 视口），固有宽度
              // 计算走安全路径。
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final d in widget.devices)
                      CheckboxListTile(
                        dense: true,
                        title: Text(d.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle:
                            Text(d.address, style: const TextStyle(fontSize: 11)),
                        value: _sel.contains(d.address),
                        onChanged: (v) => setState(() {
                          if (v ?? false) {
                            _sel.add(d.address);
                          } else {
                            _sel.remove(d.address);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop([
            for (final d in widget.devices)
              if (_sel.contains(d.address)) d,
          ]),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
