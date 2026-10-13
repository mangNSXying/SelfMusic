import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../data/sources/music_source.dart';
import '../data/sources/sftp_direct_source.dart';
import '../data/sources/smb_direct_source.dart';
import '../platform/harmonyos/ohos_bootstrap.dart';
import '../platform/harmonyos/ohos_platform_bridge.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../services/api_client.dart';
import '../utils/collection_sort.dart';
import '../utils/url_input.dart';
import '../widgets/app_toast.dart';
import '../widgets/corner_add_button.dart';
import '../widgets/count_header.dart';
import '../widgets/sort_menu_button.dart';
import '../widgets/row_list.dart';
import '../widgets/square_card.dart';
import '../widgets/view_mode_toggle.dart';

/// 播放源管理页：直连源（WebDAV / 本地文件夹）列表（支持列表/卡片切换）。
///
/// - 点击源卡片直接进入源内浏览（文件夹式导航）。
/// - 卡片右侧「三点」菜单承载 编辑、删除等设置。
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen>
    with AutomaticKeepAliveClientMixin, ViewModeState {
  /// 滑动档横滑时保持存活（与其余分组页一致）。
  @override
  bool get wantKeepAlive => true;

  @override
  ViewModeSlot get viewModeSlot => ViewModeSlot.sources;

  @override
  AppSettings Function() get appSettings =>
      () => context.read<DirectSourceManager>().settings;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final direct = context.watch<DirectSourceManager>();
    final scheme = Theme.of(context).colorScheme;
    final card = isCard;
    final sources = sortByCollection(direct.sources, direct.settings.sortSources,
        (s) => s.name, countOf: (s) => direct.countOf(s.key));

    return Stack(
      children: [
        Column(
          children: [
              CountHeader(
                count: sources.length,
                unit: '个播放源',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SortMenuButton(
                      value: direct.settings.sortSources,
                      scope: SortScope.collections,
                      onChanged: (v) =>
                          setState(() => direct.settings.sortSources = v),
                    ),
                    viewModeToggle(),
                  ],
                ),
              ),
              Expanded(
                child: sources.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text('尚未添加播放源，点右下角「+」添加',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      )
                    : card
                        ? SquareCardGrid(
                            itemCount: sources.length,
                            itemBuilder: (c, i) => _DirectSourceCard(
                                sourceKey: sources[i].key),
                          )
                        : RowList(
                            count: sources.length,
                            itemBuilder: (c, i) => _DirectSourceTile(
                                sourceKey: sources[i].key),
                          ),
              ),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: CornerAddButton(
              tooltip: '添加播放源',
              onPressed: () => showDialog<void>(
                  context: context, builder: (_) => const _SourceDialog()),
            ),
          ),
        ],
    );
  }
}

/// 新增/编辑播放源弹窗：按源类型切换字段（WebDAV / 本地文件夹 / SFTP / SMB）。
class _SourceDialog extends StatefulWidget {
  final String? editKey;
  const _SourceDialog({this.editKey});

  @override
  State<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<_SourceDialog> {
  late final TextEditingController _name;
  late final TextEditingController _path;
  late final TextEditingController _baseUrl;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _share;
  late final TextEditingController _keyPem;
  late final TextEditingController _keyPassphrase;
  late final FocusNode _baseUrlFocus;
  SourceKind _kind = SourceKind.webdav;
  SourceRoute _route = SourceRoute.direct;
  SftpAuthMethod _authMethod = SftpAuthMethod.password;
  String? _error;
  bool _testing = false;
  // 已导入的密钥文件名（仅展示用；密钥文本本身存在 _keyPem）。
  String? _keyFileName;

  bool get _isEdit => widget.editKey != null;

  @override
  void initState() {
    super.initState();
    Map<String, dynamic> cfg = const {};
    if (widget.editKey != null) {
      cfg = context.read<DirectSourceManager>().editableConfig(widget.editKey!);
      _kind = switch (cfg['kind'] as String?) {
        'local' => SourceKind.local,
        'sftp' => SourceKind.sftp,
        'smb' => SourceKind.smb,
        _ => SourceKind.webdav,
      };
    }
    _name = TextEditingController(text: cfg['name'] as String? ?? '');
    _path = TextEditingController(text: cfg['path'] as String? ?? '');
    _baseUrl = TextEditingController(text: cfg['baseUrl'] as String? ?? '');
    _username = TextEditingController(text: cfg['username'] as String? ?? '');
    _password = TextEditingController(text: cfg['password'] as String? ?? '');
    _host = TextEditingController(text: cfg['host'] as String? ?? '');
    _port = TextEditingController(
        text: (cfg['port'] as num?)?.toString() ?? '');
    _share = TextEditingController(text: cfg['share'] as String? ?? '');
    // SMB 密码走独立键回填（匿名源为空；WebDAV/SFTP 沿用上面的 password/三件套）。
    if (_kind == SourceKind.smb) {
      _password.text = cfg['smbPassword'] as String? ?? '';
    }
    _authMethod = parseSftpAuthMethod(cfg['authMethod']);
    _keyPem = TextEditingController(text: cfg['sftpKeyPem'] as String? ?? '');
    _keyPassphrase =
        TextEditingController(text: cfg['sftpPassphrase'] as String? ?? '');
    _route = parseSourceRoute(cfg['route']);
    // 仅走 HTTP 的 WebDAV 地址失焦时可视化补 `https://`；
    // SFTP/SMB/本地路径不走 HTTP，禁止挂此逻辑。
    _baseUrlFocus = FocusNode();
    _baseUrlFocus.addListener(() {
      if (!_baseUrlFocus.hasFocus && mounted && _kind == SourceKind.webdav) {
        if (autoCompleteUrlController(_baseUrl)) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _baseUrlFocus.dispose();
    _name.dispose();
    _path.dispose();
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _host.dispose();
    _port.dispose();
    _share.dispose();
    _keyPem.dispose();
    _keyPassphrase.dispose();
    super.dispose();
  }

  Future<void> _pickDirectory() async {
    if (isOhos) {
      // 鸿蒙：系统目录选择器走平台桥（file_selector_ohos 的 getDirectoryPath
      // 未实现、调用必抛异常）。选定目录 URI 直接写入 path 字段（源配置
      // 结构不变）；用户取消/选择失败不动表单。
      final picked = await OhosPlatformBridge.pickDirectory();
      if (picked != null && mounted) {
        setState(() => _path.text = picked.uri);
        if (!picked.persisted) {
          // 不阻断本次使用（会话内临时授权仍可用），但必须当场告知：
          // 否则重启后用户只会看到「目录授权已失效」，无从得知原因
          // （2026-10-06 bug 修复，此前 persisted=false 被静默忽略）。
          AppToast.show('目录持久化授权失败：应用重启后需重新选择目录');
        }
      }
      return;
    }
    final dir = await getDirectoryPath(confirmButtonText: '选择');
    if (dir != null && mounted) {
      setState(() => _path.text = dir);
    }
  }

  /// SFTP 表单校验（弹窗保存与测试连接共用）：通过返回连接参数，
  /// 失败置 [_error] 并返回 null。
  ({String host, int port, String username})? _readSftpForm() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '请填写 SSH 主机');
      return null;
    }
    final portRaw = _port.text.trim();
    final port = portRaw.isEmpty ? 22 : int.tryParse(portRaw);
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = '端口须为 1–65535 的数字（默认 22）');
      return null;
    }
    final username = _username.text.trim();
    if (username.isEmpty) {
      setState(() => _error = '请填写用户名');
      return null;
    }
    if (_authMethod == SftpAuthMethod.password) {
      if (_password.text.isEmpty) {
        setState(() => _error = '请填写密码');
        return null;
      }
    } else {
      if (!_keyPem.text.contains('PRIVATE KEY')) {
        setState(() => _error = '请粘贴 PEM 私钥文本（含 BEGIN/END 行）');
        return null;
      }
    }
    return (host: host, port: port, username: username);
  }

  /// SFTP 导入密钥文件：读文本 → 校验 PEM 标记 → 填入表单（存入 SecretStore
  /// 在保存时）。文件过大或读取失败置 [_error]。
  Future<void> _importKeyFile() async {
    try {
      final picked = await openFile();
      if (picked == null) return;
      final text = await picked.readAsString();
      if (!text.contains('PRIVATE KEY')) {
        if (!mounted) return;
        setState(() => _error = '不是有效的私钥文件（需含 PRIVATE KEY 的 PEM 文本）');
        return;
      }
      if (text.length > 65536) {
        if (!mounted) return;
        setState(() => _error = '密钥文件过大（>64KB），请确认选对了文件');
        return;
      }
      if (!mounted) return;
      setState(() {
        _keyPem.text = text.trim();
        _keyFileName = picked.name;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '读取密钥文件失败：${e.toString().replaceFirst(
            RegExp(r'^(Bad state: |StateError: )'), '')}');
    }
  }

  /// SFTP 测试连接 + TOFU：取指纹 → 未知则弹窗确认后钉住；失配则展示新旧
  /// 指纹并可更新；匹配直接提示成功。不保存源（保存走 [_submit]）。
  Future<void> _testSftpConnection() async {    final form = _readSftpForm();
    if (form == null || !mounted) return;
    final direct = context.read<DirectSourceManager>();
    setState(() {
      _testing = true;
      _error = null;
    });
    String fp;
    try {
      fp = await SftpDirectSource.fetchSftpFingerprint(
        host: form.host,
        port: form.port,
        username: form.username,
        authMethod: _authMethod,
        password: _password.text,
        keyPem: _keyPem.text,
        keyPassphrase: _keyPassphrase.text,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = e.toString().replaceFirst(
            RegExp(r'^(Bad state: |StateError: )'), '');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _testing = false);
    final hostPort = sftpHostPort(form.host, form.port);
    final pinned = direct.sshFingerprintOf(hostPort);
    if (pinned == null || pinned.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('确认主机指纹'),
          content: Text('首次连接该 SSH 主机，请确认指纹是你的服务器：\n\n$fp\n\n'
              '确认后才会钉住并允许连接。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(c).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(c).pop(true),
                child: const Text('确认并记住')),
          ],
        ),
      );
      if (ok == true && mounted) {
        await direct.pinSshHost(hostPort, fp);
        if (mounted) AppToast.show('已确认并记住主机指纹', isError: false);
      }
      return;
    }
    if (pinned != fp) {
      final update = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('主机指纹变更'),
          content: Text('已记住的指纹：\n$pinned\n\n实际指纹：\n$fp\n\n'
              '可能是中间人或服务器重装，核对无误后再更新。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(c).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(c).pop(true),
                child: const Text('确认更新',
                    style: TextStyle(color: Colors.red))),
          ],
        ),
      );
      if (update == true && mounted) {
        await direct.pinSshHost(hostPort, fp);
        if (mounted) AppToast.show('主机指纹已更新', isError: false);
      }
      return;
    }
    AppToast.show('连接成功，指纹匹配', isError: false);
  }

  /// SMB 表单校验（弹窗保存与测试连接共用）：用户名与密码双空即匿名。
  ({String host, String share, String username})? _readSmbForm() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '请填写 SMB 主机（IP 或主机名）');
      return null;
    }
    final share = _share.text.trim();
    if (share.isEmpty) {
      setState(() => _error = '请填写共享名（如 music）');
      return null;
    }
    return (host: host, share: share, username: _username.text.trim());
  }

  /// SMB 测试连接：连上并列出根目录即成功。ohos 走 smb_connect，
  /// 其余平台走 dart_smb2（与播放/扫描同后端）。不保存源（保存走 [_submit]）。
  Future<void> _testSmbConnection() async {
    final form = _readSmbForm();
    if (form == null || !mounted) return;
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      await SmbDirectSource.testConnection(
        host: form.host,
        share: form.share,
        username: form.username,
        password: _password.text,
        useSmbConnect: isOhos,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = e.toString().replaceFirst(
            RegExp(r'^(Bad state: |StateError: )'), '');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _testing = false);
    AppToast.show('连接成功', isError: false);
  }

  Future<void> _submit() async {
    final direct = context.read<DirectSourceManager>();
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    // 编辑前记下旧链路：仅 route 真变化时才重载当前曲，避免改密码/改名等
    // 无关编辑打断正在播放。
    final oldRoute = _isEdit
        ? direct.sourceByKey(widget.editKey!)?.route
        : null;
    try {
      if (_kind == SourceKind.local) {
        final path = _path.text.trim();
        if (path.isEmpty) {
          setState(() => _error = '请选择或填写本地目录');
          return;
        }
        if (_isEdit) {
          await direct.updateSource(widget.editKey!,
              name: name, path: path);
        } else {
          await direct.addLocal(name: name, path: path);
        }
      } else if (_kind == SourceKind.sftp) {
        final form = _readSftpForm();
        if (form == null) return;
        final root = _path.text.trim();
        if (_isEdit) {
          await direct.updateSource(widget.editKey!,
              name: name,
              host: form.host,
              port: form.port,
              username: form.username,
              authMethod: _authMethod,
              password: _authMethod == SftpAuthMethod.password
                  ? _password.text
                  : '',
              keyPem: _authMethod == SftpAuthMethod.key ? _keyPem.text : '',
              passphrase: _authMethod == SftpAuthMethod.key
                  ? _keyPassphrase.text
                  : '',
              path: root,
              route: _route);
        } else {
          await direct.addSftp(
              name: name,
              host: form.host,
              port: form.port,
              username: form.username,
              authMethod: _authMethod,
              password: _authMethod == SftpAuthMethod.password
                  ? _password.text
                  : '',
              keyPem: _authMethod == SftpAuthMethod.key ? _keyPem.text : '',
              passphrase: _authMethod == SftpAuthMethod.key
                  ? _keyPassphrase.text
                  : '',
              rootPath: root,
              route: _route);
        }
        if (!mounted) return;
        // 未钉指纹仍允许保存（离线等场景），首次扫描/播放会明确引导先确认。
        final pinned =
            direct.sshFingerprintOf(sftpHostPort(form.host, form.port));
        if (pinned == null || pinned.isEmpty) {
          AppToast.show('已保存；首次使用前请点「测试连接」确认主机指纹',
              isError: false);
        }
      } else if (_kind == SourceKind.smb) {
        final form = _readSmbForm();
        if (form == null) return;
        final root = _path.text.trim();
        if (_isEdit) {
          await direct.updateSource(widget.editKey!,
              name: name,
              host: form.host,
              share: form.share,
              username: form.username,
              password: _password.text,
              path: root,
              route: _route);
        } else {
          await direct.addSmb(
              name: name,
              host: form.host,
              share: form.share,
              username: form.username,
              password: _password.text,
              rootPath: root,
              route: _route);
        }
      } else {
        // WebDAV 走 HTTP：保存前先把补全写回输入框（可视化），再校验。
        // SFTP/SMB/本地不走 HTTP，不在此补 scheme。
        if (applyHttpsPrefixToController(_baseUrl)) {
          AppToast.show('已自动补全 https:// 前缀', isError: false);
          setState(() {});
        }
        final url = _baseUrl.text.trim();
        if (url.isEmpty) {
          setState(() => _error = '请填写 WebDAV 地址');
          return;
        }
        // 默认 HTTPS：显式 http:// 仅在「允许不安全 HTTP」开启后放行（settings.md §3.3）。
        // 一层校验 + 弹窗一键开启（url_input.ensureHttpAllowed），模型层归一化兜底。
        var err = ApiClient.validateEndpointUrl(url,
            allowHttp: direct.settings.allowInsecureHttp);
        if (err != null) {
          if (urlIsExplicitHttp(url)) {
            final ok = await ensureHttpAllowed(context, url);
            if (!mounted) return;
            if (!ok) {
              setState(() => _error = err);
              return;
            }
            setState(() => _error = null);
            err = ApiClient.validateEndpointUrl(url,
                allowHttp: direct.settings.allowInsecureHttp);
          }
          if (err != null) {
            setState(() => _error = err);
            return;
          }
        }
        if (_isEdit) {
          await direct.updateSource(widget.editKey!,
              name: name,
              baseUrl: url,
              username: _username.text.trim(),
              password: _password.text,
              route: _route);
        } else {
          await direct.addWebdav(
              name: name,
              baseUrl: url,
              username: _username.text.trim(),
              password: _password.text,
              route: _route);
        }
      }
      // 播放链路（直连↔代理）即时生效：若编辑的是正在播放的源且 route 变了，
      // 重载当前曲（保位置/保播放态），无需重启；已缓存歌曲内部自动跳过。
      if (_isEdit && oldRoute != null && oldRoute != _route) {
        if (!mounted) return;
        final player = context.read<PlayerProvider>();
        final curKey = player.current?.sourceKey;
        // 同名编辑 key 不变；改名时新 key 为 kind:name，两种都判。
        final newKey =
            '${_kind.name}:$name';
        if (curKey == widget.editKey || curKey == newKey) {
          // 先关弹窗再重载，避免 context 释放竞态。
          if (mounted) Navigator.of(context).pop();
          unawaited(player.reloadCurrentForPlaybackRoute().then((ok) {
            if (ok) AppToast.show('已切换到${_route == SourceRoute.proxy ? '代理' : '直连'}链路', isError: false);
          }));
          return;
        }
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst(
          RegExp(r'^(Bad state: |StateError: )'), ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = _kind == SourceKind.local;
    return AlertDialog(
      title: Text(_isEdit ? '编辑播放源' : '添加播放源'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_isEdit) ...[
              // 四段（WebDAV/本地/SFTP/SMB）总宽在手机窄屏上可能超出弹窗：
              // SegmentedButton 自身不可滚动，末尾的 SMB 段会被裁掉，故包一层
              // 横滑保证可达；宽屏下内容一次放下，无滚动、无视觉变化。
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<SourceKind>(
                  segments: const [
                    ButtonSegment(
                      value: SourceKind.webdav,
                      icon: Icon(Icons.cloud_outlined),
                      label: Text('WebDAV'),
                    ),
                    ButtonSegment(
                      value: SourceKind.local,
                      icon: Icon(Icons.folder_outlined),
                      label: Text('本地文件夹'),
                    ),
                    ButtonSegment(
                      value: SourceKind.sftp,
                      icon: Icon(Icons.storage_outlined),
                      label: Text('SFTP'),
                    ),
                    ButtonSegment(
                      value: SourceKind.smb,
                      icon: Icon(Icons.dns_outlined),
                      label: Text('SMB'),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) =>
                      setState(() => _kind = s.first),
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称（如 NAS / 本地音乐）'),
            ),
            if (isLocal) ...[
              TextField(
                controller: _path,
                decoration: InputDecoration(
                  labelText: '本地目录',
                  hintText: '/home/user/Music',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.folder_open),
                    tooltip: '选择目录',
                    onPressed: _pickDirectory,
                  ),
                ),
              ),
            ] else if (_kind == SourceKind.webdav) ...[
              TextField(
                controller: _baseUrl,
                focusNode: _baseUrlFocus,
                keyboardType: TextInputType.url,
                autocorrect: false,
                onSubmitted: (_) {
                  if (autoCompleteUrlController(_baseUrl)) setState(() {});
                },
                decoration: const InputDecoration(
                  labelText: 'WebDAV 地址',
                  hintText: 'https://192.168.1.10/dav/music',
                  helperText: '未填协议时自动补 https://；需明文请显式写 http://',
                ),
              ),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名（可空）'),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可空）'),
              ),
            ] else if (_kind == SourceKind.sftp) ...[
              TextField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'SSH 主机',
                  hintText: '192.168.1.10 或 nas.local',
                ),
              ),
              TextField(
                controller: _port,
                decoration: const InputDecoration(
                  labelText: '端口（默认 22）',
                  hintText: '22',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 8),
              SegmentedButton<SftpAuthMethod>(
                segments: const [
                  ButtonSegment(
                    value: SftpAuthMethod.password,
                    label: Text('密码'),
                  ),
                  ButtonSegment(
                    value: SftpAuthMethod.key,
                    label: Text('密钥'),
                  ),
                ],
                selected: {_authMethod},
                onSelectionChanged: (s) =>
                    setState(() => _authMethod = s.first),
              ),
              if (_authMethod == SftpAuthMethod.password)
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码'),
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _importKeyFile,
                        icon: const Icon(Icons.key_outlined, size: 18),
                        label: const Text('导入密钥文件'),
                      ),
                    ),
                    if (_keyPem.text.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: '清除已导入密钥',
                        onPressed: () => setState(() {
                          _keyPem.clear();
                          _keyFileName = null;
                        }),
                      ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _keyPem.text.isEmpty
                        ? '未导入（支持 OpenSSH / PKCS8 私钥）'
                        : _keyFileName != null
                            ? '已导入 $_keyFileName（${_keyPem.text.length} 字符）'
                            : '已保存密钥（${_keyPem.text.length} 字符）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextField(
                  controller: _keyPassphrase,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: '私钥口令（无则空）'),
                ),
              ],
              TextField(
                controller: _path,
                decoration: const InputDecoration(
                  labelText: '根目录（可空，空=登录目录）',
                  hintText: '/music',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _testing ? null : _testSftpConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_outlined, size: 18),
                label: const Text('测试连接'),
              ),
            ] else if (_kind == SourceKind.smb) ...[
              TextField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'SMB 主机',
                  hintText: '192.168.1.10 或 nas.local',
                ),
              ),
              TextField(
                controller: _share,
                decoration: const InputDecoration(
                  labelText: '共享名',
                  hintText: 'music',
                ),
              ),
              TextField(
                controller: _username,
                decoration: const InputDecoration(
                    labelText: '用户名（可空，空即匿名）'),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: '密码（可空，空即匿名）'),
              ),
              TextField(
                controller: _path,
                decoration: const InputDecoration(
                  labelText: '根目录（可空，空=共享根）',
                  hintText: 'music/flac',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _testing ? null : _testSmbConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_outlined, size: 18),
                label: const Text('测试连接'),
              ),
            ],
            if (!isLocal) ...[
              const SizedBox(height: 16),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('播放链路'),
              ),
              const SizedBox(height: 8),
              SegmentedButton<SourceRoute>(
                segments: const [
                  ButtonSegment(
                    value: SourceRoute.direct,
                    icon: Icon(Icons.bolt_outlined),
                    label: Text('直连'),
                  ),
                  ButtonSegment(
                    value: SourceRoute.proxy,
                    icon: Icon(Icons.cloud_outlined),
                    label: Text('代理'),
                  ),
                ],
                selected: {_route},
                onSelectionChanged: (s) =>
                    setState(() => _route = s.first),
              ),
              const SizedBox(height: 4),
              Text(
                '直连走原生地址（代理设置不生效）；代理经服务端（开关开时转码）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          onPressed: _submit,
          child: Text(_isEdit ? '保存' : '添加'),
        ),
      ],
    );
  }
}

class _DirectSourceTile extends StatelessWidget {
  final String sourceKey;
  const _DirectSourceTile({required this.sourceKey});

  @override
  Widget build(BuildContext context) =>
      _DirectSourceCard(sourceKey: sourceKey, plain: true);
}

class _DirectSourceCard extends StatelessWidget {
  final String sourceKey;

  /// true 时渲染为不走卡片的紧凑列表行。
  final bool plain;
  const _DirectSourceCard({required this.sourceKey, this.plain = false});

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final s = direct.sourceByKey(sourceKey);
    if (s == null) return const SizedBox.shrink();
    final count = direct.countOf(sourceKey);
    final isLocal = s.kind == SourceKind.local;
    final needsSecrets = direct.sourceNeedsSecrets(sourceKey);
    // 非本地源的播放链路（弹窗可配）：直连/代理二选一，互斥替换；
    // 本地源恒直连。代理才走服务端转码，直连恒原生地址。
    final routeLabel =
        isLocal || s.route == SourceRoute.direct ? '直连' : '代理';

    final tile = ListTile(
      leading: Icon(isLocal ? Icons.folder : Icons.cloud,
          color: Theme.of(context).colorScheme.primary),
      title: Text(s.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text(needsSecrets
          ? '待配置凭据 · 点击「编辑」补输后可用'
          : '$routeLabel · 已索引 $count 首'),
      trailing: _SourceMenu(sourceKey: sourceKey, direct: direct),
      onTap: () => context.read<NavigationProvider>().enterSource(sourceKey),
    );
    if (plain) return tile;
    // 卡片形态：与专辑/歌手共用方形卡片（SquareCard），菜单叠右上角。
    return SquareCard(
      title: s.name,
      subtitle: needsSecrets
          ? '待配置凭据 · 点击「编辑」补输后可用'
          : '$routeLabel · 已索引 $count 首',
      fallbackIcon: isLocal ? Icons.folder : Icons.cloud,
      onTap: () => context.read<NavigationProvider>().enterSource(sourceKey),
      cornerAction: _SourceMenu(sourceKey: sourceKey, direct: direct),
    );
  }
}

/// 播放源设置菜单（列表行 trailing / 方形卡片右上角共用）。
class _SourceMenu extends StatelessWidget {
  final String sourceKey;
  final DirectSourceManager direct;
  const _SourceMenu({required this.sourceKey, required this.direct});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '源设置',
      iconSize: 20,
      padding: EdgeInsets.zero,
      onSelected: (v) {
        switch (v) {
          case 'edit':
            showDialog<void>(
                context: context,
                builder: (_) => _SourceDialog(editKey: sourceKey));
          case 'delete':
            _confirmDelete(context, sourceKey, direct);
        }
      },
      itemBuilder: (c) => [
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: Text('删除源', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    );
  }
}

/// 删除源二次确认（列表/卡片共用）。
Future<void> _confirmDelete(
    BuildContext context, String key, DirectSourceManager direct) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除源'),
        content: const Text('确定删除该播放源吗？其本地索引也会一并清除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      direct.removeSource(key);
    }
  }
