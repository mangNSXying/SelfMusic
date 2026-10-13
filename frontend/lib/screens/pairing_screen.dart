import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/direct_source_manager.dart';
import '../services/api_client.dart';
import '../services/server_settings.dart';
import '../utils/platform_info.dart';
import '../utils/url_input.dart';
import '../widgets/app_toast.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _tokenCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: PlatformInfo.defaultDeviceName);
  String? _pairingToken;
  bool _showKey = false;
  bool _loading = false;
  bool _failed = false;

  /// 已发起过拉取的地址（地址变更时自动重拉）。
  String _fetchedUrl = '';

  @override
  void initState() {
    super.initState();
    // 先用本地保存的密钥，保证离线/配对后也能看到信息。
    final saved = context.read<ServerSettings>().pairingKey;
    _pairingToken = saved.isEmpty ? null : saved;
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  static String _mask(String token) {
    if (token.length <= 8) return '••••••••';
    return '${token.substring(0, 4)}••••••${token.substring(token.length - 4)}';
  }

  /// 从服务端拉取配对密钥；成功后落盘，失败保留本地缓存并提示可重试。
  Future<void> _fetchToken() async {
    final api = context.read<ApiClient>();
    final settings = context.read<ServerSettings>();
    if (api.dio.options.baseUrl.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    final t = await api.fetchPairingToken();
    if (!mounted) return;
    if (t != null && t.isNotEmpty) {
      await settings.setPairingKey(t);
      if (!mounted) return;
      setState(() {
        _pairingToken = t;
        _loading = false;
      });
    } else {
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _unpair(AuthProvider auth) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('取消配对'),
        content: const Text('取消后服务端功能不可用，直连模式不受影响。确定取消？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('保留')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('取消配对')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await auth.unpair();
    if (!mounted) return;
    AppToast.show('已取消配对', isError: false);
  }

  /// 密钥行副标题：加载中 / 已取到（离线时标注缓存来源）/ 获取失败。
  String _keySubtitle() {
    if (_loading) return '拉取中…';
    final t = _pairingToken;
    if (t == null) {
      return _failed ? '获取失败：请检查服务端地址与网络后重试' : '暂无可显示的配对密钥';
    }
    final shown = _showKey ? t : _mask(t);
    return _failed ? '$shown（离线，显示上次保存的密钥）' : shown;
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final settings = context.watch<ServerSettings>();
    final scheme = Theme.of(context).colorScheme;
    // 地址变化（如首次配置/改地址）后自动重拉；未配置地址则标记失败态。
    if (settings.baseUrl != _fetchedUrl) {
      _fetchedUrl = settings.baseUrl;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchToken();
      });
    }
    return Scaffold(
      appBar: AppBar(title: const Text('配对服务器')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (auth.isPaired) ...[
                Text('当前配对',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.verified_outlined),
                        title: const Text('已配对'),
                        subtitle: Text(settings.baseUrl.isEmpty
                            ? '服务端地址未配置'
                            : settings.baseUrl),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.key),
                        title: const Text('配对密钥'),
                        subtitle: Text(
                          _keySubtitle(),
                          style: _failed
                              ? TextStyle(color: scheme.error)
                              : null,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_pairingToken != null) ...[
                              IconButton(
                                icon: Icon(_showKey
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined),
                                tooltip: _showKey ? '隐藏' : '显示',
                                onPressed: () =>
                                    setState(() => _showKey = !_showKey),
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy_outlined),
                                tooltip: '复制',
                                onPressed: () {
                                  Clipboard.setData(
                                      ClipboardData(text: _pairingToken!));
                                  AppToast.show('已复制配对密钥', isError: false);
                                },
                              ),
                            ],
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              tooltip: '重新获取',
                              onPressed: _loading ? null : _fetchToken,
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.link_off,
                            color: Colors.redAccent),
                        title: const Text('取消配对',
                            style: TextStyle(color: Colors.redAccent)),
                        onTap: () => _unpair(auth),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text('重新配对',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
              ],
              const Text('输入服务器配对令牌（pairing_token）以完成配对。', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 16),
            _ServerAddressCard(),
            const SizedBox(height: 16),
            TextField(
              controller: _tokenCtrl,
              decoration: const InputDecoration(labelText: 'pairing_token', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'device_name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            if (auth.error != null)
              Text(auth.error!, style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: auth.loading
                    ? null
                    :                     () async {
                        // 配对前是否已有令牌：有=重新配对（本机可能是旧数据），无=首次配对。
                        final wasPaired = auth.isPaired;
                        final ok = await auth.pair(_tokenCtrl.text.trim(), _nameCtrl.text.trim());
                        if (!mounted) return;
                        if (ok && context.mounted) {
                          AppToast.show('配对成功', isError: false);
                          await _askPushExisting(context, wasPaired: wasPaired);
                        }
                      },
                child: auth.loading ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(auth.isPaired ? '重新配对' : '配对'),
              ),
            ),
            const SizedBox(height: 12),
            const Text('可在后端 .env 的 PAIRING_TOKEN_INIT 或 settings 表查看令牌。', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }

  /// 配对成功后询问是否推送配对前数据（首配/重配都问）：
  /// 选“是”→ 补推本机存量歌单与权重（补录事件只补服务端没有的数据，
  /// 现行数据不受影响），事件进 outbox 后自动上推；
  /// 选“否”→ 不推（本次配对不再问；重配会再问）。
  /// 重配（此前已配对过）默认“否”：本机可能是长期未同步的旧数据，
  /// 即使补录不覆盖现行行，不推也更稳。
  Future<void> _askPushExisting(BuildContext context,
      {required bool wasPaired}) async {
    final push = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('推送配对前的数据？'),
        content: Text(
          wasPaired
              ? '将本机在配对前创建的歌单、收藏与播放权重推送到服务端吗？这是重新配对：若本机数据比其它设备旧，建议选“否”（只补服务端没有的数据，现行数据不受影响，但不推更稳）。'
              : '将本机在配对前创建的歌单、收藏与播放权重推送到服务端吗？首台设备建议选“是”，其它设备随后会同步到这些数据（只补服务端没有的数据）。',
        ),
        actions: [
          if (wasPaired)
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('否')),
          if (wasPaired)
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('是')),
          if (!wasPaired)
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('否')),
          if (!wasPaired)
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('是')),
        ],
      ),
    );
    if (!context.mounted) return;
    if (push != true) return;
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

/// 配对页上的服务端地址配置入口：未配对且未配置地址时可在此填写后端地址。
class _ServerAddressCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ServerSettings>();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(Icons.dns_outlined, color: scheme.primary),
        title: const Text('服务端地址'),
        subtitle: Text(
          settings.baseUrl.isEmpty ? '未配置，请设置后端地址后再配对' : settings.baseUrl,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        trailing: TextButton(
          onPressed: () => _editServer(context),
          child: const Text('设置'),
        ),
      ),
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
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
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
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    focus.dispose();
  }
}
