import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _tokenCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: 'linux-desktop');

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
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Text('输入服务器配对令牌（pairing_token）以完成配对。', style: TextStyle(fontSize: 14)),
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
    );
  }
}
