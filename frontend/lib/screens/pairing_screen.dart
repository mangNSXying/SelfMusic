import 'package:flutter/material.dart';
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

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('配对 SelfMusic')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
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
                child: auth.loading ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('配对'),
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
