import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_client.dart';
import '../services/server_settings.dart';
import '../utils/platform_info.dart';

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

  @override
  void initState() {
    super.initState();
    context.read<ApiClient>().fetchPairingToken().then((t) {
      if (mounted) setState(() => _pairingToken = t);
    });
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
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已取消配对')));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final settings = context.watch<ServerSettings>();
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
                        subtitle: Text(_pairingToken == null
                            ? '拉取中…'
                            : _showKey
                                ? _pairingToken!
                                : _mask(_pairingToken!)),
                        trailing: _pairingToken == null
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(_showKey
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined),
                                    tooltip: _showKey ? '隐藏' : '显示',
                                    onPressed: () => setState(
                                        () => _showKey = !_showKey),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.copy_outlined),
                                    tooltip: '复制',
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(
                                          text: _pairingToken!));
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(const SnackBar(
                                              content:
                                                  Text('已复制配对密钥')));
                                    },
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
                    : () async {
                        final ok = await auth.pair(_tokenCtrl.text.trim(), _nameCtrl.text.trim());
                        if (!mounted) return;
                        if (ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('配对成功')));
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
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('服务端地址'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '后端地址',
            hintText: 'http://192.168.1.10:18089',
            helperText: '含协议与端口，留空表示未配置',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              await settings.setBaseUrl(ctrl.text.trim());
              api.setBaseUrl(settings.baseUrl);
              if (c.mounted) Navigator.of(c).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
