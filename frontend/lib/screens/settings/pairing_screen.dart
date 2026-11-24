import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../services/api_client.dart';
import '../../services/haptics.dart';
import '../../services/server_settings.dart';
import '../../theme/app_metrics.dart';
import '../../utils/pairing_key_format.dart';
import '../../utils/platform_info.dart';
import '../../utils/url_input.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/inline_spinner.dart';
import '../../widgets/row_action_button.dart';
import '../../widgets/settings_layout.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_tile.dart';
import 'devices_screen.dart';

/// 服务端配对页：
/// - 「本机配对」：状态 + 地址入口 + 配对/重新配对表单 + 取消配对；
/// - 「其它设备」：配对密钥（供其它设备使用）与已配对设备入口。
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  static const double _contentMaxWidth = 640;

  final _tokenCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: PlatformInfo.defaultDeviceName);

  /// 本地缓存的配对密钥（先展示，再尝试向服务端刷新）。
  String? _pairingToken;

  bool _showKey = false;
  bool _loadingKey = false;
  bool _keyFailed = false;

  /// 已配对时配对表单默认收起；展开后复用同一份表单。
  bool _showPairForm = false;

  DateTime? _keyFetchedAt;

  /// 已发起过拉取的地址（地址变更时自动重拉）。
  String _fetchedUrl = '';

  @override
  void initState() {
    super.initState();
    _pairingToken = context.read<ServerSettings>().pairingKey;
    if (_pairingToken!.isEmpty) _pairingToken = null;
    _tokenCtrl.addListener(_onTokenChanged);
  }

  @override
  void dispose() {
    _tokenCtrl.removeListener(_onTokenChanged);
    _tokenCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  /// 令牌输入变化只影响配对按钮可用态；页面其余部分无需重建。
  void _onTokenChanged() {
    if (mounted) setState(() {});
  }

  /// 从服务端拉取配对密钥；成功后落盘，失败保留本地缓存并提示可重试。
  Future<void> _fetchKey({bool manual = false}) async {
    final api = context.read<ApiClient>();
    final settings = context.read<ServerSettings>();
    if (settings.baseUrl.isEmpty) {
      setState(() {
        _loadingKey = false;
        _keyFailed = false;
      });
      return;
    }
    setState(() {
      _loadingKey = true;
      _keyFailed = false;
    });
    final t = await api.fetchPairingToken();
    if (!mounted) return;
    if (t != null && t.isNotEmpty) {
      await settings.setPairingKey(t);
      if (!mounted) return;
      setState(() {
        _pairingToken = t;
        _loadingKey = false;
        _keyFetchedAt = DateTime.now();
      });
    } else {
      setState(() {
        _keyFailed = true;
        _loadingKey = false;
      });
      if (manual) AppToast.show('获取配对密钥失败，请检查服务端地址与网络');
    }
  }

  Future<void> _pasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty || !mounted) return;
    _tokenCtrl.text = text;
    _tokenCtrl.selection = TextSelection.collapsed(offset: text.length);
  }

  Future<void> _pair(AuthProvider auth) async {
    if (auth.loading) return;
    final wasPaired = auth.isPaired;
    final ok = await auth.pair(_tokenCtrl.text.trim(), _nameCtrl.text.trim());
    if (!mounted || !ok) return;
    _tokenCtrl.clear();
    setState(() => _showPairForm = false);
    AppToast.show('配对成功', isError: false);
    // 源配置不在这里自动补推：用户在本弹窗选「不推送」就是不推，「先加源后
    // 配对」的源要靠源菜单里的「推送到服务端」显式推上去（见
    // DirectSourceManager.pushSourceToServer）。
    await _askPushExisting(context, wasPaired: wasPaired);
  }

  Future<void> _unpair(AuthProvider auth) async {
    final ok = await showConfirmDialog(
      context,
      title: '取消配对',
      content: '取消后服务端功能不可用，直连模式不受影响。确定取消？',
      cancelLabel: '保留',
      confirmLabel: '取消配对',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await auth.unpair();
    if (!mounted) return;
    _tokenCtrl.clear();
    setState(() => _showPairForm = false);
    AppToast.show('已取消配对', isError: false);
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// 密钥行副标题：未配置 / 拉取中 / 已获取 / 离线缓存 / 获取失败。
  String _keyStatusText(ServerSettings settings) {
    if (settings.baseUrl.isEmpty) return '未配置服务端地址';
    if (_loadingKey) return '拉取中…';
    final t = _pairingToken;
    if (t == null) {
      return _keyFailed ? '获取失败，点刷新重试' : '暂无可显示的配对密钥';
    }
    final shown = _showKey ? t : maskPairingKey(t);
    if (_keyFailed) return '$shown · 离线，显示上次保存的密钥';
    final at = _keyFetchedAt;
    return at == null ? shown : '$shown · 已获取 ${_hhmm(at)}';
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final settings = context.watch<ServerSettings>();
    final scheme = Theme.of(context).colorScheme;

    // 地址变化（首次配置/改地址）后自动重拉；未配置地址则保持空态。
    if (settings.baseUrl != _fetchedUrl) {
      _fetchedUrl = settings.baseUrl;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchKey();
      });
    }

    final expired = auth.sessionExpired;
    final paired = auth.isPaired;
    final showPairForm = !paired || _showPairForm || expired;
    final showOtherDevices =
        settings.baseUrl.isNotEmpty || _pairingToken != null;

    final statusColor = expired
        ? scheme.error
        : (paired ? scheme.primary : scheme.onSurfaceVariant);
    final statusIcon = expired
        ? Icons.error_outline
        : (paired ? Icons.verified_outlined : Icons.link_off);
    final statusTitle = expired ? '会话已过期，请重新配对' : (paired ? '已配对' : '未配对');

    return Scaffold(
      appBar: AppBar(title: const Text('配对服务端')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            key: const ValueKey('pairingContent'),
            constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
            child: SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SettingsSectionHeader('本机配对'),
                    SettingsTile(
                      leading: Icon(statusIcon, color: statusColor, size: 22),
                      title: statusTitle,
                      description: settings.baseUrl.isEmpty
                          ? '未配置服务端地址'
                          : settings.baseUrl,
                      trailing: RowActionTextButton(
                        label: '设置',
                        onPressed: () => _editServer(context),
                      ),
                      onTap: () => _editServer(context),
                    ),
                    if (showPairForm)
                      _buildPairForm(
                        auth: auth,
                        settings: settings,
                        paired: paired,
                      )
                    else
                      SettingsTile(
                        leading: Icon(Icons.sync_alt,
                            color: scheme.onSurfaceVariant, size: 22),
                        title: '重新配对',
                        description: '本机已连接，如需更换服务端可重新配对',
                        trailing: const SettingsActionText('重新配对'),
                        onTap: () => setState(() => _showPairForm = true),
                      ),
                    if (paired) _buildUnpairRow(auth, scheme),
                    if (showOtherDevices) ...[
                      const SettingsGroupDivider(),
                      const SettingsSectionHeader('其它设备'),
                      SettingsTile(
                        leading: Icon(Icons.key, color: statusColor, size: 22),
                        title: '配对密钥',
                        description: _keyStatusText(settings),
                        descriptionColor: _keyFailed ? scheme.error : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_pairingToken != null) ...[
                              RowActionIconButton(
                                icon: _showKey
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                tooltip: _showKey ? '隐藏' : '显示',
                                onPressed: () =>
                                    setState(() => _showKey = !_showKey),
                              ),
                              RowActionIconButton(
                                icon: Icons.copy_outlined,
                                tooltip: '复制',
                                onPressed: () {
                                  Clipboard.setData(
                                      ClipboardData(text: _pairingToken!));
                                  AppToast.show('已复制配对密钥', isError: false);
                                },
                              ),
                            ],
                            RowActionIconButton(
                              icon: Icons.refresh,
                              tooltip: '重新获取',
                              onPressed:
                                  (_loadingKey || settings.baseUrl.isEmpty)
                                      ? null
                                      : () => _fetchKey(manual: true),
                            ),
                          ],
                        ),
                      ),
                      if (paired)
                        SettingsTile(
                          leading: Icon(Icons.devices_outlined,
                              color: scheme.onSurfaceVariant, size: 22),
                          title: '已配对设备',
                          description: '查看、改名或吊销',
                          trailing: const SettingsActionText('查看'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const DevicesScreen(),
                            ),
                          ),
                        ),
                      const SettingsGroupNote(
                        '该密钥用于在其它设备上完成配对，请勿分享给不可信的设备。',
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPairForm({
    required AuthProvider auth,
    required ServerSettings settings,
    required bool paired,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final hasAddress = settings.baseUrl.isNotEmpty;
    final canPair =
        hasAddress && _tokenCtrl.text.trim().isNotEmpty && !auth.loading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _tokenCtrl,
            enabled: hasAddress && !auth.loading,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (canPair) _pair(auth);
            },
            decoration: InputDecoration(
              labelText: '配对令牌',
              hintText: '从服务端读取的 pairing_token',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste, size: kRowActionIconSize),
                tooltip: '粘贴',
                onPressed: hasAddress ? _pasteToken : null,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameCtrl,
            enabled: hasAddress && !auth.loading,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (canPair) _pair(auth);
            },
            decoration: const InputDecoration(
              labelText: '设备名称',
              helperText: '用于在设备列表里识别本机',
              border: OutlineInputBorder(),
            ),
          ),
          if (auth.error != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(kButtonRadius),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      auth.error!,
                      style: TextStyle(fontSize: 13, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: kButtonHeight,
            child: FilledButton(
              onPressed: canPair ? () => _pair(auth) : null,
              child: auth.loading
                  ? const InlineSpinner()
                  : Text(paired ? '重新配对' : '配对'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '令牌可在后端 .env 的 PAIRING_TOKEN_INIT 或 settings 表查看。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnpairRow(AuthProvider auth, ColorScheme scheme) {
    return Column(
      children: [
        const SettingsGroupDivider(),
        InkWell(
          onTap: () {
            Haptics.fire(HapticStrength.light);
            _unpair(auth);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.link_off, size: 22, color: scheme.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '取消配对',
                        style: TextStyle(
                          fontSize: 16,
                          color: scheme.error,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '服务端功能将不可用；直连模式不受影响',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _editServer(BuildContext context) async {
    final settings = context.read<ServerSettings>();
    final api = context.read<ApiClient>();
    final ctrl = TextEditingController(text: settings.baseUrl);
    final focus = FocusNode();
    focus.addListener(() {
      if (!focus.hasFocus) autoCompleteUrlController(ctrl);
    });
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('服务端地址'),
        content: TextField(
          controller: ctrl,
          focusNode: focus,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onSubmitted: (_) => autoCompleteUrlController(ctrl),
          decoration: const InputDecoration(
            labelText: '后端地址',
            hintText: 'https://192.168.1.10:18443',
            helperText: '含协议与端口，留空表示未配置；未填协议自动补 https://',
            border: OutlineInputBorder(),
          ),
        ),
        actions: appDialogActions(
          c,
          confirmLabel: '保存',
          onCancel: () => Navigator.of(c).pop(),
          onConfirm: () async {
            // 后端地址走 HTTP：保存前先把补全写回输入框（可视化）。
            if (applyHttpsPrefixToController(ctrl)) {
              AppToast.show('已自动补全 https:// 前缀', isError: false);
            }
            final entered = ctrl.text.trim();
            var err = ApiClient.validateEndpointUrl(entered,
                allowHttp: context
                    .read<DirectSourceManager>()
                    .settings
                    .allowInsecureHttp);
            if (err != null) {
              if (urlIsExplicitHttp(entered)) {
                final ok = await ensureHttpAllowed(context, entered);
                if (!context.mounted) return;
                if (ok) {
                  err = ApiClient.validateEndpointUrl(entered,
                      allowHttp: context
                          .read<DirectSourceManager>()
                          .settings
                          .allowInsecureHttp);
                } else {
                  AppToast.show(err);
                  return;
                }
              }
              if (err != null) {
                AppToast.show(err);
                return;
              }
            }
            await settings.setBaseUrl(entered);
            api.setBaseUrl(settings.baseUrl);
            if (c.mounted) Navigator.of(c).pop();
          },
        ),
      ),
    );
    ctrl.dispose();
    focus.dispose();
  }

  /// 配对成功后询问是否推送配对前数据（首配/重配都问）：
  /// 选「推送」→ 补推本机存量歌单与权重（补录事件只补服务端没有的数据，
  /// 现行数据不受影响），事件进 outbox 后自动上推；
  /// 选「不推送」→ 不推（本次配对不再问；重配会再问）。
  /// 重配（此前已配对过）不设默认：本机可能是长期未同步的旧数据，若比
  /// 其它设备旧，不推送更稳。
  Future<void> _askPushExisting(BuildContext context,
      {required bool wasPaired}) async {
    final push = await showConfirmDialog(
      context,
      title: '推送配对前的数据？',
      content: wasPaired
          ? '将本机在配对前创建的歌单、收藏与播放权重推送到服务端吗？这是重新配对：只补服务端没有的数据，现行数据不受影响；若本机数据比其它设备旧，不推送更稳。'
          : '将本机在配对前创建的歌单、收藏与播放权重推送到服务端吗？首台设备建议推送，其它设备随后会同步到这些数据（只补服务端没有的数据）。',
      cancelLabel: '不推送',
      confirmLabel: '推送',
    );
    if (!context.mounted) return;
    if (!push) return;
    try {
      final r = await context.read<DirectSourceManager>().backfillNow();
      if (!context.mounted) return;
      AppToast.show(
          '已补推 ${r['playlists']} 个歌单 ${r['items']} 条目 ${r['songs']} 首权重，稍后自动上推',
          isError: false);
    } catch (e) {
      if (!context.mounted) return;
      AppToast.show('补推失败：$e', isError: true);
    }
  }
}
