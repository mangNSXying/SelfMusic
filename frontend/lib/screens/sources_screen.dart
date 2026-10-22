import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../data/sources/local_file_direct_source.dart';
import '../data/sources/music_source.dart';
import '../data/sources/sftp_direct_source.dart';
import '../data/sources/smb_common.dart';
import '../data/sources/smb_direct_source.dart';
import '../data/sources/webdav_direct_source.dart';
import '../platform/harmonyos/ohos_bootstrap.dart';
import '../platform/harmonyos/ohos_platform_bridge.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../services/api_client.dart';
import '../utils/collection_sort.dart';
import '../utils/url_input.dart';
import '../widgets/app_dialog_actions.dart';
import '../widgets/app_toast.dart';
import '../widgets/corner_add_button.dart';
import '../widgets/count_header.dart';
import '../widgets/sort_menu_button.dart';
import '../widgets/row_action_button.dart';
import '../widgets/row_list.dart';
import '../widgets/single_choice_group.dart';
import '../widgets/square_card.dart';
import '../widgets/view_mode_toggle.dart';

const _remoteKindOptions = <SingleChoiceOption<SourceKind>>[
  SingleChoiceOption(
    value: SourceKind.smb,
    label: 'SMB',
    icon: Icons.dns_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.webdav,
    label: 'WebDAV',
    icon: Icons.cloud_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.sftp,
    label: 'SFTP',
    icon: Icons.storage_outlined,
  ),
];

const _mainKindOptions = <SingleChoiceOption<SourceKind>>[
  SingleChoiceOption(
    value: SourceKind.local,
    label: '本地',
    icon: Icons.folder_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.smb,
    label: 'SMB',
    icon: Icons.dns_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.webdav,
    label: 'WebDAV',
    icon: Icons.cloud_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.sftp,
    label: 'SFTP',
    icon: Icons.storage_outlined,
  ),
];

const _sftpAuthOptions = <SingleChoiceOption<SftpAuthMethod>>[
  SingleChoiceOption(value: SftpAuthMethod.password, label: '密码'),
  SingleChoiceOption(value: SftpAuthMethod.key, label: '密钥'),
];

const _routeOptions = <SingleChoiceOption<SourceRoute>>[
  SingleChoiceOption(
    value: SourceRoute.direct,
    label: '直连',
    icon: Icons.bolt_outlined,
  ),
  SingleChoiceOption(
    value: SourceRoute.proxy,
    label: '代理',
    icon: Icons.cloud_outlined,
  ),
];

/// 播放源管理页：直连源（本地 / SMB / WebDAV / SFTP）列表（支持列表/卡片切换）。
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
    final sources = sortByCollection(
        direct.sources, direct.settings.sortSources, (s) => s.name,
        countOf: (s) => direct.countOf(s.key));

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
                          itemBuilder: (c, i) =>
                              _DirectSourceCard(sourceKey: sources[i].key),
                        )
                      : RowList(
                          count: sources.length,
                          itemBuilder: (c, i) =>
                              _DirectSourceTile(sourceKey: sources[i].key),
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

/// 备用源表单数据（本地不可做备用，故 kind 仅 webdav/sftp/smb）。
class _FallbackData {
  SourceKind kind;
  SourceRoute route = SourceRoute.direct;
  SftpAuthMethod authMethod = SftpAuthMethod.password;
  late TextEditingController baseUrl;
  late TextEditingController host;
  late TextEditingController port;
  late TextEditingController smbPath;
  late TextEditingController username;
  late TextEditingController password;
  late TextEditingController path;
  late TextEditingController keyPem;
  late TextEditingController keyPassphrase;
  String? keyFileName;

  _FallbackData({
    this.kind = SourceKind.webdav,
    Map<String, dynamic>? from,
  }) {
    final m = from ?? const {};
    baseUrl = TextEditingController(text: m['baseUrl'] as String? ?? '');
    host = TextEditingController(text: m['host'] as String? ?? '');
    port = TextEditingController(text: (m['port'] as num?)?.toString() ?? '');
    smbPath = TextEditingController(
        text: kind == SourceKind.smb
            ? smbJoinInputPath(
                share: m['share'] as String? ?? '',
                rootPath: m['path'] as String? ?? '')
            : '');
    username = TextEditingController(text: m['username'] as String? ?? '');
    password = TextEditingController(text: m['password'] as String? ?? '');
    path = TextEditingController(text: m['path'] as String? ?? '');
    keyPem = TextEditingController(text: m['keyPem'] as String? ?? '');
    keyPassphrase =
        TextEditingController(text: m['passphrase'] as String? ?? '');
    route = parseSourceRoute(m['route']);
    authMethod = parseSftpAuthMethod(m['authMethod']);
    if (kind == SourceKind.webdav && from != null) {
      // editableConfig 回填的 password 已在上。
    }
  }

  Map<String, dynamic> toRawMap() {
    // SMB 弹窗只填一个「路径」：落库前拆回 share/path 两键（存储结构不变）。
    var shareOut = '';
    var pathOut = path.text.trim();
    if (kind == SourceKind.smb) {
      final parsed = smbParseInputPath(smbPath.text);
      shareOut = parsed.share;
      pathOut = parsed.rootPath;
    }
    final m = <String, dynamic>{
      'kind': kind.name,
      'baseUrl': baseUrl.text.trim(),
      'host': host.text.trim(),
      'port': int.tryParse(port.text.trim()) ?? 22,
      'share': shareOut,
      'username': username.text.trim(),
      'password': password.text,
      'keyPem': keyPem.text,
      'passphrase': keyPassphrase.text,
      'authMethod': authMethod.name,
      'path': pathOut,
      'route': route.name,
    };
    return m;
  }

  void dispose() {
    baseUrl.dispose();
    host.dispose();
    port.dispose();
    smbPath.dispose();
    username.dispose();
    password.dispose();
    path.dispose();
    keyPem.dispose();
    keyPassphrase.dispose();
  }
}

/// 新增/编辑播放源弹窗：按源类型切换字段（本地 / SMB / WebDAV / SFTP）。
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
  late final TextEditingController _smbPath;
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
  // 备用源（至多 kMaxFallbacks 个，本地不可做备）。
  final List<_FallbackData> _fbs = [];

  // 文件级本地源（鸿蒙 6 手机/平板降级形态）。
  List<LocalFileEntry> _localFiles = [];
  bool _filesMode = false;
  bool _pickingFiles = false;

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
    _port =
        TextEditingController(text: (cfg['port'] as num?)?.toString() ?? '');
    _smbPath = TextEditingController(
        text: _kind == SourceKind.smb
            ? smbJoinInputPath(
                share: cfg['share'] as String? ?? '',
                rootPath: cfg['path'] as String? ?? '')
            : '');
    // SMB 密码走独立键回填（匿名源为空；WebDAV/SFTP 沿用上面的 password/三件套）。
    if (_kind == SourceKind.smb) {
      _password.text = cfg['smbPassword'] as String? ?? '';
    }
    _authMethod = parseSftpAuthMethod(cfg['authMethod']);
    _keyPem = TextEditingController(text: cfg['sftpKeyPem'] as String? ?? '');
    _keyPassphrase =
        TextEditingController(text: cfg['sftpPassphrase'] as String? ?? '');
    _route = parseSourceRoute(cfg['route']);
    _localFiles = parseLocalFileEntries(cfg);
    _filesMode = cfg['mode'] == 'files' || _localFiles.isNotEmpty;
    // 备用回填（editableConfig 已回填各槽位敏感字段）。
    final rawFbs = parseFallbackConfigs(cfg['fallbacks']);
    for (final fb in rawFbs) {
      final kind = switch ((fb['kind'] as String? ?? '').trim()) {
        'sftp' => SourceKind.sftp,
        'smb' => SourceKind.smb,
        _ => SourceKind.webdav,
      };
      _fbs.add(_FallbackData(kind: kind, from: fb));
    }
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
    _smbPath.dispose();
    _keyPem.dispose();
    _keyPassphrase.dispose();
    for (final fb in _fbs) {
      fb.dispose();
    }
    super.dispose();
  }

  void _addFallback() {
    if (_fbs.length >= kMaxFallbacks) return;
    setState(() => _fbs.add(_FallbackData()));
  }

  void _removeFallback(int i) {
    setState(() {
      _fbs[i].dispose();
      _fbs.removeAt(i);
    });
  }

  void _onKindChanged(SourceKind kind) {
    setState(() => _kind = kind);
  }

  Future<void> _pickAudioFiles() async {
    if (_pickingFiles) return;
    setState(() => _pickingFiles = true);
    try {
      final picked = await OhosPlatformBridge.pickAudioFiles();
      if (!mounted || picked == null) return;
      if (picked.isEmpty) {
        AppToast.show('未选择可读取的音频文件');
        return;
      }
      final merged = mergePickedLocalFiles(
        existing: _localFiles,
        picked: picked,
      );
      setState(() {
        _localFiles = merged;
        _filesMode = true;
        _path.clear();
      });
      final unreadable = picked.where((f) => !f.readable).length;
      final unpersisted = picked.where((f) => !f.persisted).length;
      if (unpersisted > 0) {
        AppToast.show('部分文件持久化授权失败：应用重启后需重新选择文件', ms: 4000);
      } else if (unreadable > 0) {
        AppToast.show('部分文件当前不可读取，请确认文件仍存在且未移动');
      } else {
        AppToast.show('已导入 ${picked.length} 个音频文件', isError: false);
      }
    } on PlatformException catch (e) {
      if (mounted) AppToast.show('选择音频文件失败：${e.message ?? e.code}');
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] pickAudioFiles 桥未装配: $e');
      if (mounted) AppToast.show('当前平台不支持音频文件导入');
    } finally {
      if (mounted) setState(() => _pickingFiles = false);
    }
  }

  Future<void> _pickDirectory() async {
    if (isOhos) {
      // 点击时才校验 FOLDER 能力：进入本地类型不再预检/自动降级，
      // 避免用户刚选“本地文件夹”就被 toast 打断。
      final supported = await OhosPlatformBridge.supportsFolderSelection();
      if (!mounted) return;
      if (!supported) {
        AppToast.show('当前系统不支持选择文件夹，已改为选择音频文件', ms: 3000);
        await _pickAudioFiles();
        return;
      }
      // 鸿蒙：系统目录选择器走平台桥（file_selector_ohos 的 getDirectoryPath
      // 未实现、调用必抛异常）。选定目录 URI 直接写入 path 字段（源配置
      // 结构不变）；用户取消/选择失败不动表单。
      final picked = await OhosPlatformBridge.pickDirectory();
      if (picked != null && mounted) {
        setState(() {
          _path.text = picked.uri;
          _filesMode = false;
          _localFiles = [];
        });
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
      setState(() {
        _path.text = dir;
        _filesMode = false;
        _localFiles = [];
      });
    }
  }

  /// WebDAV 地址校验（保存与测试连接共用）：补 `https://`、校验端点格式，
  /// 显式 `http://` 走「允许不安全 HTTP」闸门。通过返回 URL，失败置
  /// [_error]（可按 [label] 加备用源前缀）并返回 null。
  Future<String?> _readWebdavUrl(TextEditingController ctrl,
      {String? label, bool notifyPrefix = false}) async {
    final prefix = label == null ? '' : '$label：';
    final direct = context.read<DirectSourceManager>();
    if (applyHttpsPrefixToController(ctrl)) {
      setState(() {});
      if (notifyPrefix) {
        AppToast.show('已自动补全 https:// 前缀', isError: false);
      }
    }
    final url = ctrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '$prefix请填写 WebDAV 地址');
      return null;
    }
    // 默认 HTTPS：显式 http:// 仅在「允许不安全 HTTP」开启后放行
    // （settings.md §3.3）；一层校验 + 弹窗一键开启，模型层归一化兜底。
    var err = ApiClient.validateEndpointUrl(url,
        allowHttp: direct.settings.allowInsecureHttp);
    if (err != null) {
      if (urlIsExplicitHttp(url)) {
        final ok = await ensureHttpAllowed(context, url);
        if (!mounted) return null;
        if (!ok) {
          setState(() => _error = '$prefix$err');
          return null;
        }
        setState(() => _error = null);
        err = ApiClient.validateEndpointUrl(url,
            allowHttp: direct.settings.allowInsecureHttp);
      }
      if (err != null) {
        setState(() => _error = '$prefix$err');
        return null;
      }
    }
    return url;
  }

  /// WebDAV 测试连接：PROPFIND 探测根目录，验证地址、鉴权与目录可访问。
  /// 不保存源（保存走 [_submit]）。
  Future<void> _testWebdavConnection() async {
    final url = await _readWebdavUrl(_baseUrl);
    if (url == null || !mounted) return;
    final direct = context.read<DirectSourceManager>();
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      await WebdavDirectSource.testConnection(
        baseUrl: url,
        username: _username.text.trim(),
        password: _password.text,
        allowSelfSigned: direct.settings.allowSelfSigned,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = e
            .toString()
            .replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _testing = false);
    AppToast.show('连接成功', isError: false);
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
      setState(() => _error =
          '读取密钥文件失败：${e.toString().replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '')}');
    }
  }

  /// SFTP 测试连接 + TOFU：取指纹 → 未知则弹窗确认后钉住；失配则展示新旧
  /// 指纹并可更新；匹配直接提示成功。不保存源（保存走 [_submit]）。
  Future<void> _testSftpConnection() async {
    final form = _readSftpForm();
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
        _error = e
            .toString()
            .replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '');
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
          actions: appDialogActions(
            c,
            confirmLabel: '确认并记住',
            onCancel: () => Navigator.of(c).pop(false),
            onConfirm: () => Navigator.of(c).pop(true),
          ),
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
          actions: appDialogActions(
            c,
            confirmLabel: '确认更新',
            destructive: true,
            onCancel: () => Navigator.of(c).pop(false),
            onConfirm: () => Navigator.of(c).pop(true),
          ),
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

  /// SMB 表单校验（弹窗保存与测试连接共用）：「路径」按首段拆成
  /// 共享名/根目录（见 [smbParseInputPath]）；用户名与密码双空即匿名。
  ({String host, String share, String rootPath, String username})?
      _readSmbForm() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '请填写 SMB 主机（IP 或主机名）');
      return null;
    }
    final (:share, :rootPath) = smbParseInputPath(_smbPath.text);
    if (share.isEmpty) {
      setState(() => _error = '请填写路径（共享名或 共享名/子目录，如 music/flac）');
      return null;
    }
    return (
      host: host,
      share: share,
      rootPath: rootPath,
      username: _username.text.trim()
    );
  }

  /// SMB 测试连接：连上并列出填写的「路径」即成功（带子目录时一并验证）。
  /// ohos 走 smb_connect，其余平台走 dart_smb2（与播放/扫描同后端）。
  /// 不保存源（保存走 [_submit]）。
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
        rootPath: form.rootPath,
        username: form.username,
        password: _password.text,
        useSmbConnect: false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = e
            .toString()
            .replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _testing = false);
    AppToast.show('连接成功', isError: false);
  }

  // ---------- 备用源表单校验/测试（与主表单同口径，错误带备用序号） ----------

  ({String host, int port, String username})? _readFbSftpForm(
      int slot, _FallbackData fb) {
    final label = fallbackLabel(slot);
    final host = fb.host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '$label：请填写 SSH 主机');
      return null;
    }
    final portRaw = fb.port.text.trim();
    final port = portRaw.isEmpty ? 22 : int.tryParse(portRaw);
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = '$label：端口须为 1–65535 的数字（默认 22）');
      return null;
    }
    final username = fb.username.text.trim();
    if (username.isEmpty) {
      setState(() => _error = '$label：请填写用户名');
      return null;
    }
    if (fb.authMethod == SftpAuthMethod.password) {
      if (fb.password.text.isEmpty) {
        setState(() => _error = '$label：请填写密码');
        return null;
      }
    } else {
      if (!fb.keyPem.text.contains('PRIVATE KEY')) {
        setState(() => _error = '$label：请粘贴 PEM 私钥文本（含 BEGIN/END 行）');
        return null;
      }
    }
    return (host: host, port: port, username: username);
  }

  ({String host, String share, String rootPath, String username})?
      _readFbSmbForm(int slot, _FallbackData fb) {
    final label = fallbackLabel(slot);
    final host = fb.host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '$label：请填写 SMB 主机（IP 或主机名）');
      return null;
    }
    final (:share, :rootPath) = smbParseInputPath(fb.smbPath.text);
    if (share.isEmpty) {
      setState(() => _error = '$label：请填写路径（共享名或 共享名/子目录，如 music/flac）');
      return null;
    }
    return (
      host: host,
      share: share,
      rootPath: rootPath,
      username: fb.username.text.trim()
    );
  }

  Future<void> _importFbKeyFile(int slot, _FallbackData fb) async {
    try {
      final picked = await openFile();
      if (picked == null) return;
      final text = await picked.readAsString();
      if (!text.contains('PRIVATE KEY')) {
        if (!mounted) return;
        setState(() => _error = '${fallbackLabel(slot)}：不是有效的私钥文件');
        return;
      }
      if (text.length > 65536) {
        if (!mounted) return;
        setState(() => _error = '${fallbackLabel(slot)}：密钥文件过大（>64KB）');
        return;
      }
      if (!mounted) return;
      setState(() {
        fb.keyPem.text = text.trim();
        fb.keyFileName = picked.name;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          '${fallbackLabel(slot)}：读取密钥文件失败：${e.toString().replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '')}');
    }
  }

  Future<void> _testFbSftpConnection(int slot, _FallbackData fb) async {
    final form = _readFbSftpForm(slot, fb);
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
        authMethod: fb.authMethod,
        password: fb.password.text,
        keyPem: fb.keyPem.text,
        keyPassphrase: fb.keyPassphrase.text,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error =
            '${fallbackLabel(slot)}：${e.toString().replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '')}';
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
          title: Text('确认主机指纹（${fallbackLabel(slot)}）'),
          content: Text('首次连接该 SSH 主机，请确认指纹是你的服务器：\n\n$fp\n\n'
              '确认后才会钉住并允许连接。'),
          actions: appDialogActions(
            c,
            confirmLabel: '确认并记住',
            onCancel: () => Navigator.of(c).pop(false),
            onConfirm: () => Navigator.of(c).pop(true),
          ),
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
          actions: appDialogActions(
            c,
            confirmLabel: '确认更新',
            destructive: true,
            onCancel: () => Navigator.of(c).pop(false),
            onConfirm: () => Navigator.of(c).pop(true),
          ),
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

  Future<void> _testFbSmbConnection(int slot, _FallbackData fb) async {
    final form = _readFbSmbForm(slot, fb);
    if (form == null || !mounted) return;
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      await SmbDirectSource.testConnection(
        host: form.host,
        share: form.share,
        rootPath: form.rootPath,
        username: form.username,
        password: fb.password.text,
        useSmbConnect: false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error =
            '${fallbackLabel(slot)}：${e.toString().replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '')}';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _testing = false);
    AppToast.show('连接成功', isError: false);
  }

  Future<void> _testFbWebdavConnection(int slot, _FallbackData fb) async {
    final url = await _readWebdavUrl(fb.baseUrl, label: fallbackLabel(slot));
    if (url == null || !mounted) return;
    final direct = context.read<DirectSourceManager>();
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      await WebdavDirectSource.testConnection(
        baseUrl: url,
        username: fb.username.text.trim(),
        password: fb.password.text,
        allowSelfSigned: direct.settings.allowSelfSigned,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error =
            '${fallbackLabel(slot)}：${e.toString().replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '')}';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _testing = false);
    AppToast.show('连接成功', isError: false);
  }

  Widget _buildFallbackCard(int i) {
    final fb = _fbs[i];
    final label = fallbackLabel(i);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                RowActionIconButton(
                  icon: Icons.close,
                  tooltip: '删除$label',
                  onPressed: () => _removeFallback(i),
                ),
              ],
            ),
            SingleChoiceGroup<SourceKind>(
              options: _remoteKindOptions,
              value: fb.kind,
              onChanged: (v) => setState(() => fb.kind = v),
            ),
            const SizedBox(height: 8),
            if (fb.kind == SourceKind.webdav) ...[
              TextField(
                controller: fb.baseUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '备用 WebDAV 地址',
                  hintText: 'https://192.168.1.11/dav/music',
                ),
              ),
              TextField(
                controller: fb.username,
                decoration: const InputDecoration(labelText: '用户名（可空）'),
              ),
              TextField(
                controller: fb.password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可空）'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed:
                    _testing ? null : () => _testFbWebdavConnection(i, fb),
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_outlined, size: 18),
                label: const Text('测试连接'),
              ),
            ] else if (fb.kind == SourceKind.sftp) ...[
              TextField(
                controller: fb.host,
                decoration: const InputDecoration(
                  labelText: '备用 SSH 主机',
                  hintText: '192.168.1.11 或 nas2.local',
                ),
              ),
              TextField(
                controller: fb.port,
                decoration: const InputDecoration(
                  labelText: '端口（默认 22）',
                  hintText: '22',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              TextField(
                controller: fb.username,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 8),
              SingleChoiceGroup<SftpAuthMethod>(
                options: _sftpAuthOptions,
                value: fb.authMethod,
                onChanged: (v) => setState(() => fb.authMethod = v),
              ),
              if (fb.authMethod == SftpAuthMethod.password)
                TextField(
                  controller: fb.password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码'),
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _importFbKeyFile(i, fb),
                        icon: const Icon(Icons.key_outlined, size: 18),
                        label: const Text('导入密钥文件'),
                      ),
                    ),
                    if (fb.keyPem.text.isNotEmpty)
                      RowActionIconButton(
                        icon: Icons.clear,
                        tooltip: '清除已导入密钥',
                        onPressed: () => setState(() {
                          fb.keyPem.clear();
                          fb.keyFileName = null;
                        }),
                      ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    fb.keyPem.text.isEmpty
                        ? '未导入（支持 OpenSSH / PKCS8 私钥）'
                        : fb.keyFileName != null
                            ? '已导入 ${fb.keyFileName}（${fb.keyPem.text.length} 字符）'
                            : '已保存密钥（${fb.keyPem.text.length} 字符）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextField(
                  controller: fb.keyPassphrase,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '私钥口令（无则空）'),
                ),
              ],
              TextField(
                controller: fb.path,
                decoration: const InputDecoration(
                  labelText: '根目录（可空，空=登录目录）',
                  hintText: '/music',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _testing ? null : () => _testFbSftpConnection(i, fb),
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_outlined, size: 18),
                label: const Text('测试连接'),
              ),
            ] else if (fb.kind == SourceKind.smb) ...[
              TextField(
                controller: fb.host,
                decoration: const InputDecoration(
                  labelText: '备用 SMB 主机',
                  hintText: '192.168.1.11 或 nas2.local',
                ),
              ),
              TextField(
                controller: fb.smbPath,
                decoration: const InputDecoration(
                  labelText: '路径',
                  hintText: 'music 或 music/flac',
                  helperText: '首个「/」前为共享名，其余为共享内目录',
                ),
              ),
              TextField(
                controller: fb.username,
                decoration: const InputDecoration(labelText: '用户名（可空，空即匿名）'),
              ),
              TextField(
                controller: fb.password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可空，空即匿名）'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _testing ? null : () => _testFbSmbConnection(i, fb),
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
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('备用播放链路'),
            ),
            const SizedBox(height: 8),
            SingleChoiceGroup<SourceRoute>(
              options: _routeOptions,
              value: fb.route,
              onChanged: (v) => setState(() => fb.route = v),
            ),
          ],
        ),
      ),
    );
  }

  /// 备用原始 Map（含敏感明文，供 manager 收敛）：失败置 [_error] 返回 null。
  List<Map<String, dynamic>>? _readFallbackMaps() {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < _fbs.length; i++) {
      final fb = _fbs[i];
      final label = fallbackLabel(i);
      if (fb.kind == SourceKind.local) {
        setState(() => _error = '$label：本地只可做主源，不可做备用源');
        return null;
      }
      if (fb.kind == SourceKind.webdav) {
        if (applyHttpsPrefixToController(fb.baseUrl)) setState(() {});
        final url = fb.baseUrl.text.trim();
        if (url.isEmpty) {
          setState(() => _error = '$label：请填写 WebDAV 地址');
          return null;
        }
        final direct = context.read<DirectSourceManager>();
        final err = ApiClient.validateEndpointUrl(url,
            allowHttp: direct.settings.allowInsecureHttp);
        if (err != null) {
          setState(() => _error = '$label：$err');
          return null;
        }
      } else if (fb.kind == SourceKind.sftp) {
        if (_readFbSftpForm(i, fb) == null) return null;
      } else if (fb.kind == SourceKind.smb) {
        if (_readFbSmbForm(i, fb) == null) return null;
      }
      out.add(fb.toRawMap());
    }
    return out;
  }

  Future<void> _submit() async {
    final direct = context.read<DirectSourceManager>();
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    // 备用先校验（主配置校验失败时不弹备用错误，顺序：主 → 备用 → 去重）。
    // 这里只做格式校验，去重在主配置就绪后统一做。
    List<Map<String, dynamic>> fbMaps = const [];
    if (_fbs.isNotEmpty) {
      final parsed = _readFallbackMaps();
      if (parsed == null) return;
      fbMaps = parsed;
    }
    // 编辑前记下旧链路：仅 route 真变化时才重载当前曲，避免改密码/改名等
    // 无关编辑打断正在播放。
    final oldRoute =
        _isEdit ? direct.sourceByKey(widget.editKey!)?.route : null;
    // 主 + 备用去重（与 manager 同口径，提前报错避免半落库）。
    String? fbErr;
    try {
      final smbProbe =
          _kind == SourceKind.smb ? smbParseInputPath(_smbPath.text) : null;
      final primaryProbe = <String, dynamic>{
        'baseUrl': _baseUrl.text.trim(),
        'host': _host.text.trim(),
        'port': int.tryParse(_port.text.trim()) ?? 22,
        'share': smbProbe?.share ?? '',
        'path': smbProbe?.rootPath ?? _path.text.trim(),
      };
      fbErr = direct.validateFallbacks(_kind.name, primaryProbe, fbMaps);
    } catch (_) {}
    if (fbErr != null) {
      setState(() => _error = fbErr);
      return;
    }
    try {
      if (_kind == SourceKind.local) {
        if (_filesMode) {
          if (_localFiles.isEmpty) {
            setState(() => _error = '请至少选择一个音频文件');
            return;
          }
          if (_isEdit) {
            await direct.updateSource(widget.editKey!,
                name: name, localFiles: _localFiles, fallbacks: fbMaps);
          } else {
            await direct.addLocalFiles(
                name: name, files: _localFiles, fallbacks: fbMaps);
          }
        } else {
          final path = _path.text.trim();
          if (path.isEmpty) {
            setState(() => _error = '请选择或填写本地目录');
            return;
          }
          if (_isEdit) {
            await direct.updateSource(widget.editKey!,
                name: name, path: path, fallbacks: fbMaps);
          } else {
            await direct.addLocal(name: name, path: path, fallbacks: fbMaps);
          }
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
              password:
                  _authMethod == SftpAuthMethod.password ? _password.text : '',
              keyPem: _authMethod == SftpAuthMethod.key ? _keyPem.text : '',
              passphrase:
                  _authMethod == SftpAuthMethod.key ? _keyPassphrase.text : '',
              path: root,
              route: _route,
              fallbacks: fbMaps);
        } else {
          await direct.addSftp(
              name: name,
              host: form.host,
              port: form.port,
              username: form.username,
              authMethod: _authMethod,
              password:
                  _authMethod == SftpAuthMethod.password ? _password.text : '',
              keyPem: _authMethod == SftpAuthMethod.key ? _keyPem.text : '',
              passphrase:
                  _authMethod == SftpAuthMethod.key ? _keyPassphrase.text : '',
              rootPath: root,
              route: _route,
              fallbacks: fbMaps);
        }
        if (!mounted) return;
        // 未钉指纹仍允许保存（离线等场景），首次扫描/播放会明确引导先确认。
        final pinned =
            direct.sshFingerprintOf(sftpHostPort(form.host, form.port));
        if (pinned == null || pinned.isEmpty) {
          AppToast.show('已保存；首次使用前请点「测试连接」确认主机指纹', isError: false);
        }
      } else if (_kind == SourceKind.smb) {
        final form = _readSmbForm();
        if (form == null) return;
        if (_isEdit) {
          await direct.updateSource(widget.editKey!,
              name: name,
              host: form.host,
              share: form.share,
              username: form.username,
              password: _password.text,
              path: form.rootPath,
              route: _route,
              fallbacks: fbMaps);
        } else {
          await direct.addSmb(
              name: name,
              host: form.host,
              share: form.share,
              username: form.username,
              password: _password.text,
              rootPath: form.rootPath,
              route: _route,
              fallbacks: fbMaps);
        }
      } else {
        // WebDAV 走 HTTP：保存前先补全 scheme 并校验（与测试连接同口径）。
        // SFTP/SMB/本地不走 HTTP，不在此补 scheme。
        final url = await _readWebdavUrl(_baseUrl, notifyPrefix: true);
        if (url == null) return;
        if (_isEdit) {
          await direct.updateSource(widget.editKey!,
              name: name,
              baseUrl: url,
              username: _username.text.trim(),
              password: _password.text,
              route: _route,
              fallbacks: fbMaps);
        } else {
          await direct.addWebdav(
              name: name,
              baseUrl: url,
              username: _username.text.trim(),
              password: _password.text,
              route: _route,
              fallbacks: fbMaps);
        }
      }
      // 播放链路（直连↔代理）即时生效：若编辑的是正在播放的源且 route 变了，
      // 重载当前曲（保位置/保播放态），无需重启；已缓存歌曲内部自动跳过。
      if (_isEdit && oldRoute != null && oldRoute != _route) {
        if (!mounted) return;
        final player = context.read<PlayerProvider>();
        final curKey = player.current?.sourceKey;
        // 同名编辑 key 不变；改名时新 key 为 kind:name，两种都判。
        final newKey = '${_kind.name}:$name';
        if (curKey == widget.editKey || curKey == newKey) {
          // 先关弹窗再重载，避免 context 释放竞态。
          if (mounted) Navigator.of(context).pop();
          unawaited(player.reloadCurrentForPlaybackRoute().then((ok) {
            if (ok) {
              AppToast.show(
                  '已切换到${_route == SourceRoute.proxy ? '代理' : '直连'}链路',
                  isError: false);
            }
          }));
          return;
        }
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e
          .toString()
          .replaceFirst(RegExp(r'^(Bad state: |StateError: )'), ''));
    }
  }

  Widget _buildLocalFilesSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('已选择 ${_localFiles.length} 个音频文件',
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
            TextButton.icon(
              onPressed: _pickingFiles ? null : _pickAudioFiles,
              icon: _pickingFiles
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add, size: 18),
              label: Text(_pickingFiles ? '选择中…' : '选择音频文件'),
            ),
          ],
        ),
        if (_localFiles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '还没有选择文件。支持 mp3 / flac / m4a / aac / ogg / wav / aiff，单次最多 500 个。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _localFiles.length,
              itemBuilder: (context, index) {
                final f = _localFiles[index];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.audio_file_outlined, size: 20),
                  title: Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    f.size > 0 ? _formatBytes(f.size) : '大小未知',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: RowActionIconButton(
                    tooltip: '移除',
                    icon: Icons.close,
                    onPressed: () => setState(() {
                      _localFiles.removeWhere((e) => e.ref == f.ref);
                      if (_localFiles.isEmpty) _filesMode = false;
                    }),
                  ),
                );
              },
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _localFiles.isEmpty
                  ? null
                  : () => setState(() {
                        _localFiles = [];
                        _filesMode = false;
                      }),
              icon: const Icon(Icons.clear_all, size: 18),
              label: const Text('清空'),
            ),
          ),
        ],
        Text(
          '提示：保存后请点该源「扫描」建立索引；同目录歌词/封面不在授权范围，不会自动关联。',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '大小未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
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
              // 四个源类型在窄屏自动换行（2+2），不再横向滚动。
              // 选择本地源时仍走 _onKindChanged（鸿蒙需探测文件夹选择能力）。
              SingleChoiceGroup<SourceKind>(
                options: _mainKindOptions,
                value: _kind,
                onChanged: _onKindChanged,
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称（如 NAS / 本地音乐）'),
            ),
            if (isLocal) ...[
              if (_filesMode)
                _buildLocalFilesSection(context)
              else
                TextField(
                  controller: _path,
                  decoration: InputDecoration(
                    labelText: '本地文件夹',
                    hintText: '/home/user/Music',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.folder_open),
                      tooltip: '选择文件夹',
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
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _testing ? null : _testWebdavConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_outlined, size: 18),
                label: const Text('测试连接'),
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
              SingleChoiceGroup<SftpAuthMethod>(
                options: _sftpAuthOptions,
                value: _authMethod,
                onChanged: (v) => setState(() => _authMethod = v),
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
                      RowActionIconButton(
                        icon: Icons.clear,
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
                  decoration: const InputDecoration(labelText: '私钥口令（无则空）'),
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
                controller: _smbPath,
                decoration: const InputDecoration(
                  labelText: '路径',
                  hintText: 'music 或 music/flac',
                  helperText: '首个「/」前为共享名，其余为共享内目录',
                ),
              ),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名（可空，空即匿名）'),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可空，空即匿名）'),
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
              SingleChoiceGroup<SourceRoute>(
                options: _routeOptions,
                value: _route,
                onChanged: (v) => setState(() => _route = v),
              ),
              const SizedBox(height: 4),
              Text(
                '直连走原生地址（代理设置不生效）；代理经服务端（开关开时转码）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            const Divider(height: 16),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('备用源（至多 2 个）',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '主源失败自动按相对路径切备用；本地只可做主源，不可做备用',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _fbs.length; i++) _buildFallbackCard(i),
            if (_fbs.length < kMaxFallbacks)
              OutlinedButton.icon(
                onPressed: _addFallback,
                icon: const Icon(Icons.add, size: 18),
                label: Text(_fbs.isEmpty ? '添加备用源' : '再添加一个备用源'),
              )
            else
              Text(
                '已达上限（2 个备用源）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
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
      actions: appDialogActions(
        context,
        confirmLabel: _isEdit ? '保存' : '添加',
        onCancel: () => Navigator.of(context).pop(),
        onConfirm: _submit,
      ),
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

/// 播放源类型图标（一类一图标）：本地=存储图标，远端=协议文字徽标。
/// [framed] 为 true 时套 tinted 圆角徽标盒（列表行 leading 用），
/// false 时只渲染裸图标/文字（方形卡片占位用，卡片底已自带 tint）。
class _SourceKindIcon extends StatelessWidget {
  final SourceKind kind;
  final double size;
  final bool framed;
  const _SourceKindIcon(
      {required this.kind, this.size = 40, this.framed = true});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final Widget content;
    if (kind == SourceKind.local) {
      content = Icon(Icons.storage_outlined,
          size: framed ? size * 0.6 : size,
          color: primary.withValues(alpha: framed ? 1.0 : 0.6));
    } else {
      final label = switch (kind) {
        SourceKind.webdav => 'WebDAV',
        SourceKind.sftp => 'SFTP',
        SourceKind.smb => 'SMB',
        SourceKind.local => '',
      };
      content = FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label,
            maxLines: 1,
            style: TextStyle(
                color: primary.withValues(alpha: framed ? 1.0 : 0.6),
                fontWeight: FontWeight.w800,
                fontSize: framed ? size * 0.3 : size * 0.42)),
      );
    }
    if (!framed) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(child: content),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(size * 0.25),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: size * 0.1),
        child: content,
      ),
    );
  }
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
    final fbCount = direct.fallbackCountOf(sourceKey);
    final fbNeeds = fbCount > 0 && direct.fallbackNeedsSecrets(sourceKey);
    final linePref = direct.linePrefOf(sourceKey);
    // 非本地源的播放链路（弹窗可配）：直连/代理二选一，互斥替换；
    // 本地源恒直连。代理才走服务端转码，直连恒原生地址。
    final routeLabel = isLocal || s.route == SourceRoute.direct ? '直连' : '代理';
    final fbLabel = fbCount > 0 ? ' · 备×$fbCount' : '';
    final lineLabel = linePref == SourceLine.auto
        ? ''
        : linePref == SourceLine.primary
            ? ' · 线路:主用'
            : linePref == SourceLine.fb0
                ? ' · 线路:备用1'
                : ' · 线路:备用2';

    final tile = ListTile(
      leading: _SourceKindIcon(kind: s.kind),
      title: Text(s.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text(needsSecrets
          ? '待配置凭据 · 点击「编辑」补输后可用'
          : fbNeeds
              ? '$routeLabel$fbLabel$lineLabel · 备用待配凭据 · 已索引 $count 首'
              : '$routeLabel$fbLabel$lineLabel · 已索引 $count 首'),
      trailing: _SourceMenu(sourceKey: sourceKey, direct: direct),
      onTap: () => context.read<NavigationProvider>().enterSource(sourceKey),
    );
    if (plain) return tile;
    // 卡片形态：与专辑/歌手共用方形卡片（SquareCard），菜单叠右上角。
    return SquareCard(
      title: s.name,
      subtitle: needsSecrets
          ? '待配置凭据 · 点击「编辑」补输后可用'
          : fbNeeds
              ? '$routeLabel$fbLabel$lineLabel · 备用待配凭据 · 已索引 $count 首'
              : '$routeLabel$fbLabel$lineLabel · 已索引 $count 首',
      fallback: _SourceKindIcon(kind: s.kind, size: 44, framed: false),
      onTap: () => context.read<NavigationProvider>().enterSource(sourceKey),
      cornerAction: _SourceMenu(sourceKey: sourceKey, direct: direct),
    );
  }
}

/// 播放源设置菜单（列表行 trailing / 方形卡片右上角共用）。
/// 含线路切换（自动/主用/备用1/备用2，与播放页三点菜单同功能）。
class _SourceMenu extends StatelessWidget {
  final String sourceKey;
  final DirectSourceManager direct;
  const _SourceMenu({required this.sourceKey, required this.direct});

  @override
  Widget build(BuildContext context) {
    final fbCount = direct.fallbackCountOf(sourceKey);
    final linePref = direct.linePrefOf(sourceKey);
    String lineLabel(SourceLine l) {
      final cur = linePref == l ? ' ✓' : '';
      return switch (l) {
        SourceLine.auto => '线路：自动$cur',
        SourceLine.primary => '线路：主用$cur',
        SourceLine.fb0 => '线路：备用1$cur',
        SourceLine.fb1 => '线路：备用2$cur',
      };
    }

    return PopupMenuButton<String>(
      tooltip: '源设置',
      iconSize: 20,
      padding: EdgeInsets.zero,
      onSelected: (v) async {
        switch (v) {
          case 'edit':
            showDialog<void>(
                context: context,
                builder: (_) => _SourceDialog(editKey: sourceKey));
          case 'delete':
            _confirmDelete(context, sourceKey, direct);
          case 'line_auto':
          case 'line_primary':
          case 'line_fb0':
          case 'line_fb1':
            final line = switch (v) {
              'line_primary' => SourceLine.primary,
              'line_fb0' => SourceLine.fb0,
              'line_fb1' => SourceLine.fb1,
              _ => SourceLine.auto,
            };
            await direct.setLinePref(sourceKey, line);
            if (context.mounted) {
              AppToast.show(
                  line == SourceLine.auto
                      ? '已切到自动线路（主→备 Failover）'
                      : line == SourceLine.primary
                          ? '已锁定主用线路'
                          : line == SourceLine.fb0
                              ? '已锁定备用1线路'
                              : '已锁定备用2线路',
                  isError: false);
              // 若正在播该源，重载当前曲使线路即时生效。
              try {
                final player = context.read<PlayerProvider>();
                if (player.current?.sourceKey == sourceKey) {
                  unawaited(player.reloadCurrentForPlaybackRoute());
                }
              } catch (_) {}
            }
        }
      },
      itemBuilder: (c) => [
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        if (fbCount > 0) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
              value: 'line_auto', child: Text(lineLabel(SourceLine.auto))),
          PopupMenuItem(
              value: 'line_primary',
              child: Text(lineLabel(SourceLine.primary))),
          PopupMenuItem(
              value: 'line_fb0', child: Text(lineLabel(SourceLine.fb0))),
          if (fbCount > 1)
            PopupMenuItem(
                value: 'line_fb1', child: Text(lineLabel(SourceLine.fb1))),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: Text('删除源', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    );
  }
}

/// 播放页/任意处共用的线路切换菜单项构造（与 [_SourceMenu] 同文案/同行为）。
List<PopupMenuEntry<String>> buildLineMenuItems(
    DirectSourceManager direct, String sourceKey) {
  final fbCount = direct.fallbackCountOf(sourceKey);
  if (fbCount == 0) return const [];
  final linePref = direct.linePrefOf(sourceKey);
  String label(SourceLine l) {
    final cur = linePref == l ? ' ✓' : '';
    return switch (l) {
      SourceLine.auto => '线路：自动$cur',
      SourceLine.primary => '线路：主用$cur',
      SourceLine.fb0 => '线路：备用1$cur',
      SourceLine.fb1 => '线路：备用2$cur',
    };
  }

  return [
    const PopupMenuDivider(),
    PopupMenuItem(value: 'line_auto', child: Text(label(SourceLine.auto))),
    PopupMenuItem(
        value: 'line_primary', child: Text(label(SourceLine.primary))),
    PopupMenuItem(value: 'line_fb0', child: Text(label(SourceLine.fb0))),
    if (fbCount > 1)
      PopupMenuItem(value: 'line_fb1', child: Text(label(SourceLine.fb1))),
  ];
}

/// 线路切换选中后的统一处理（源卡片与播放页共用）。
Future<void> handleLineMenuSelected(
    BuildContext context, String sourceKey, String v) async {
  final direct = context.read<DirectSourceManager>();
  final line = switch (v) {
    'line_primary' => SourceLine.primary,
    'line_fb0' => SourceLine.fb0,
    'line_fb1' => SourceLine.fb1,
    _ => SourceLine.auto,
  };
  await direct.setLinePref(sourceKey, line);
  if (context.mounted) {
    AppToast.show(
        line == SourceLine.auto
            ? '已切到自动线路（主→备 Failover）'
            : line == SourceLine.primary
                ? '已锁定主用线路'
                : line == SourceLine.fb0
                    ? '已锁定备用1线路'
                    : '已锁定备用2线路',
        isError: false);
    try {
      final player = context.read<PlayerProvider>();
      if (player.current?.sourceKey == sourceKey) {
        unawaited(player.reloadCurrentForPlaybackRoute());
      }
    } catch (_) {}
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
        actions: appDialogActions(
          c,
          confirmLabel: '删除',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok == true) {
      direct.removeSource(key);
    }
  }
