import 'dart:async';

import 'package:file_selector/file_selector.dart';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../../data/sources/local_file_direct_source.dart';
import '../../../data/sources/music_source.dart';
import '../../../data/sources/sftp_direct_source.dart';
import '../../../data/sources/smb_common.dart';
import '../../../data/sources/smb_direct_source.dart';
import '../../../data/sources/webdav_direct_source.dart';
import '../../../platform/harmonyos/ohos_bootstrap.dart';
import '../../../platform/harmonyos/ohos_platform_bridge.dart';
import '../../../providers/direct_source_manager.dart';
import '../../../providers/player_provider.dart';
import '../../../services/api_client.dart';
import '../../../utils/format_bytes.dart';
import '../../../utils/url_input.dart';
import '../../../widgets/app_dialog_actions.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/inline_spinner.dart';
import '../../../widgets/row_action_button.dart';
import '../../../widgets/single_choice_group.dart';

import 'source_dialog_fallback.dart';

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

/// 密码框的键盘类型。
///
/// 鸿蒙 Flutter 引擎不会根据 `obscureText` 推断密码输入类型：它只把
/// `keyboardType` 透传给系统 IME，默认的 text 会被当作普通文本框，系统
/// 「安全键盘」不会拉起（安卓引擎会自动折算成密码类型）。显式指定
/// visiblePassword 后引擎映射为系统的 VISIBLE_PASSWORD，才会按密码框处理；
/// 其他平台返回 null 保持默认，避免 VISIBLE_PASSWORD 变体改变既有键盘行为。
TextInputType? get _passwordKeyboardType =>
    isOhos ? TextInputType.visiblePassword : null;

/// 新增/编辑播放源弹窗：按源类型切换字段（本地 / SMB / WebDAV / SFTP）。
class SourceDialog extends StatefulWidget {
  final String? editKey;
  const SourceDialog({this.editKey});

  @override
  State<SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<SourceDialog> {
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
  SourceKind _kind = SourceKind.local;
  SourceRoute _route = SourceRoute.direct;
  SftpAuthMethod _authMethod = SftpAuthMethod.password;
  String? _error;
  bool _testing = false;
  // 已导入的密钥文件名（仅展示用；密钥文本本身存在 _keyPem）。
  String? _keyFileName;
  // 备用源（至多 kMaxFallbacks 个，本地不可做备）。
  final List<SourceFallbackData> _fbs = [];

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
      _fbs.add(SourceFallbackData(kind: kind, from: fb));
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
    setState(() => _fbs.add(SourceFallbackData()));
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
      int slot, SourceFallbackData fb) {
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
      _readFbSmbForm(int slot, SourceFallbackData fb) {
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

  Future<void> _importFbKeyFile(int slot, SourceFallbackData fb) async {
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

  Future<void> _testFbSftpConnection(int slot, SourceFallbackData fb) async {
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

  Future<void> _testFbSmbConnection(int slot, SourceFallbackData fb) async {
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

  Future<void> _testFbWebdavConnection(int slot, SourceFallbackData fb) async {
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
            const SizedBox(height: 12),
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
              const SizedBox(height: 12),
              TextField(
                controller: fb.username,
                decoration: const InputDecoration(labelText: '用户名（可空）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: fb.password,
                keyboardType: _passwordKeyboardType,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可空）'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed:
                    _testing ? null : () => _testFbWebdavConnection(i, fb),
                icon: _testing
                    ? const InlineSpinner(size: 16)
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
              const SizedBox(height: 12),
              TextField(
                controller: fb.port,
                decoration: const InputDecoration(
                  labelText: '端口（默认 22）',
                  hintText: '22',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: fb.username,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 12),
              SingleChoiceGroup<SftpAuthMethod>(
                options: _sftpAuthOptions,
                value: fb.authMethod,
                onChanged: (v) => setState(() => fb.authMethod = v),
              ),
              const SizedBox(height: 12),
              if (fb.authMethod == SftpAuthMethod.password)
                TextField(
                  controller: fb.password,
                  keyboardType: _passwordKeyboardType,
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
                const SizedBox(height: 12),
                TextField(
                  controller: fb.keyPassphrase,
                  keyboardType: _passwordKeyboardType,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '私钥口令（无则空）'),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: fb.path,
                decoration: const InputDecoration(
                  labelText: '根目录（可空，空=登录目录）',
                  hintText: '/music',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _testing ? null : () => _testFbSftpConnection(i, fb),
                icon: _testing
                    ? const InlineSpinner(size: 16)
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
              const SizedBox(height: 12),
              TextField(
                controller: fb.smbPath,
                decoration: const InputDecoration(
                  labelText: '路径',
                  hintText: 'music 或 music/flac',
                  helperText: '首个「/」前为共享名，其余为共享内目录',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: fb.username,
                decoration: const InputDecoration(labelText: '用户名（可空，空即匿名）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: fb.password,
                keyboardType: _passwordKeyboardType,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可空，空即匿名）'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _testing ? null : () => _testFbSmbConnection(i, fb),
                icon: _testing
                    ? const InlineSpinner(size: 16)
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
                  ? const InlineSpinner(size: 16)
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

  String _formatBytes(int bytes) => formatBytes(
        bytes,
        zero: '大小未知',
        minUnit: ByteUnit.b,
        kbDecimals: 1,
        mbDecimals: 1,
        gbDecimals: 2,
      );

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
            const SizedBox(height: 12),
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
              const SizedBox(height: 12),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名（可空）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                keyboardType: _passwordKeyboardType,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可空）'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _testing ? null : _testWebdavConnection,
                icon: _testing
                    ? const InlineSpinner(size: 16)
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
              const SizedBox(height: 12),
              TextField(
                controller: _port,
                decoration: const InputDecoration(
                  labelText: '端口（默认 22）',
                  hintText: '22',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 12),
              SingleChoiceGroup<SftpAuthMethod>(
                options: _sftpAuthOptions,
                value: _authMethod,
                onChanged: (v) => setState(() => _authMethod = v),
              ),
              const SizedBox(height: 12),
              if (_authMethod == SftpAuthMethod.password)
                TextField(
                  controller: _password,
                  keyboardType: _passwordKeyboardType,
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
                const SizedBox(height: 12),
                TextField(
                  controller: _keyPassphrase,
                  keyboardType: _passwordKeyboardType,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '私钥口令（无则空）'),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _path,
                decoration: const InputDecoration(
                  labelText: '根目录（可空，空=登录目录）',
                  hintText: '/music',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _testing ? null : _testSftpConnection,
                icon: _testing
                    ? const InlineSpinner(size: 16)
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
              const SizedBox(height: 12),
              TextField(
                controller: _smbPath,
                decoration: const InputDecoration(
                  labelText: '路径',
                  hintText: 'music 或 music/flac',
                  helperText: '首个「/」前为共享名，其余为共享内目录',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名（可空，空即匿名）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                keyboardType: _passwordKeyboardType,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可空，空即匿名）'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _testing ? null : _testSmbConnection,
                icon: _testing
                    ? const InlineSpinner(size: 16)
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
