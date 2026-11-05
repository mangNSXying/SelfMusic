import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../services/api_client.dart';
import '../../services/server_settings.dart';
import '../../utils/url_input.dart';
import '../../widgets/app_toast.dart';
import 'pairing_screen.dart';
import 'sync_section.dart';
import 'storage_sections.dart';

/// 「服务端」设置：后端地址（运行时可改，替代编译期 --dart-define）。
class ServerSettingsSection extends StatefulWidget {
  const ServerSettingsSection();

  @override
  State<ServerSettingsSection> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<ServerSettingsSection> {
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
        _controller.selection = TextSelection.collapsed(offset: _saved.length);
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
//           const Divider(height: 24),
//           TextField(
//             controller: _controller,
//             focusNode: _urlFocus,
//             keyboardType: TextInputType.url,
//             autocorrect: false,
//             onSubmitted: (_) {
//               if (autoCompleteUrlController(_controller)) setState(() {});
//             },
//             decoration: const InputDecoration(
//               labelText: '后端地址',
//               hintText: 'https://192.168.1.10:18443',
//               helperText: '含协议与端口，留空表示未配置；未填协议自动补 https://',
//               border: OutlineInputBorder(),
//               prefixIcon: Icon(Icons.dns_outlined),
//             ),
//           ),
//           const SizedBox(height: 12),
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
            child: Text('多设备同步', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 4),
          const SyncSection(),
          const SizedBox(height: 32),
          const Divider(),
          const CacheConfigSection(),
          const Divider(height: 24),
          const CacheDirTile(),
          const SizedBox(height: 16),
          const Divider(),
          const TranscodeSection(),
          const SizedBox(height: 16),
          const Divider(),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('网络与安全', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许不安全 HTTP'),
            subtitle: const Text('默认关闭，屏蔽 http:// 地址'),
            value:
                context.read<DirectSourceManager>().settings.allowInsecureHttp,
            onChanged: (v) {
              context.read<DirectSourceManager>().settings.allowInsecureHttp =
                  v;
              setState(() {});
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('信任自签名证书'),
            subtitle: const Text(
                '默认关闭；开启后 API 与直连 WebDAV 的扫描/探测跳过证书校验（鸿蒙播放器不校验证书，自签可直接播放）'),
            value: context.read<DirectSourceManager>().settings.allowSelfSigned,
            onChanged: (v) {
              final settings = context.read<DirectSourceManager>().settings;
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
