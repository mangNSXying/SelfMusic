import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../services/api_client.dart';
import '../../services/server_settings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/settings_tile.dart';
import 'pairing_screen.dart';
import 'settings_focus.dart';
import 'storage_sections.dart';
import 'sync_section.dart';

/// 网络设置：服务端配对 / 多设备同步 / 网络安全 / 转码代理。
class NetworkSection extends StatefulWidget {
  const NetworkSection();

  @override
  State<NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends State<NetworkSection> {
  String _pairingToken = '';

  @override
  void initState() {
    super.initState();
    // 先展示本地保存的密钥（离线也能看到），再尝试向服务端刷新。
    _pairingToken = context.read<ServerSettings>().pairingKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchPairingKey();
    });
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

  /// 配对服务端副标题：配对态 + 同一份配对密钥（与配对页一致）。
  String _pairingSubtitle(bool paired) {
    final state = paired ? '已配对' : '未配对';
    if (_pairingToken.isEmpty) return state;
    final t = _pairingToken;
    final masked = t.length <= 8
        ? '••••••••'
        : '${t.substring(0, 4)}••••••${t.substring(t.length - 4)}';
    return '$state · 密钥 $masked';
  }

  Widget _anchor(String label, Widget child) => SettingsFocusAnchor(
        id: settingsAnchorId(SettingsItem.network, label),
        child: child,
      );

  Widget _groupTitle(String title) => Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    final directSettings = context.read<DirectSourceManager>().settings;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('网络',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('配置服务端、多设备同步与转码代理',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 24),
            _groupTitle('服务端'),
            const SizedBox(height: 4),
            _anchor(
              '配对服务端',
              SettingsTile(
                title: '配对服务端',
                description: '配对后可多设备同步与转码',
                trailing: SettingsValueText(
                  _pairingSubtitle(auth.isPaired),
                  maxWidth: 200,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const PairingScreen()),
                ),
              ),
            ),
            const Divider(height: 32),
            _groupTitle('多设备同步'),
            const SizedBox(height: 4),
            const SyncSection(),
            const Divider(height: 32),
            _groupTitle('网络安全'),
            const SizedBox(height: 4),
            _anchor(
              '允许 HTTP',
              SettingsTile.toggle(
                title: '允许 HTTP',
                description: '默认关闭；开启后才能连接 http://',
                value: directSettings.allowInsecureHttp,
                onChanged: (v) {
                  directSettings.allowInsecureHttp = v;
                  setState(() {});
                },
              ),
            ),
            _anchor(
              '信任自签名',
              SettingsTile.toggle(
                title: '信任自签名',
                description: '默认关闭；仅自签名证书需要',
                value: directSettings.allowSelfSigned,
                onChanged: (v) {
                  directSettings.allowSelfSigned = v;
                  context.read<DirectSourceManager>().applySecuritySettings();
                  context.read<ApiClient>().setSelfSignedPolicy(v);
                  setState(() {});
                },
              ),
            ),
            const Divider(height: 32),
            const TranscodeSection(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
