import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../services/api_client.dart';
import '../../services/server_settings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/settings_layout.dart';
import '../../widgets/settings_section_header.dart';
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final directSettings = context.read<DirectSourceManager>().settings;
    return SettingsPage(
      children: [
        const SettingsSectionHeader('服务端'),
        _anchor(
          '配对服务端',
          SettingsTile.value(
            title: '配对服务端',
            description: '配对后可多设备同步与转码',
            value: _pairingSubtitle(auth.isPaired),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PairingScreen()),
            ),
          ),
        ),
        const SettingsGroupDivider(),
        const SettingsSectionHeader('多设备同步'),
        const SyncSection(),
        const SettingsGroupDivider(),
        const SettingsSectionHeader('网络安全'),
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
        const SettingsGroupDivider(),
        const TranscodeSection(),
      ],
    );
  }
}
