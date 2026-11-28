import 'package:flutter/widgets.dart';

import '../../../data/sources/local_file_direct_source.dart';
import '../../../data/sources/music_source.dart';
import '../../../data/sources/sftp_common.dart';
import '../../../data/sources/smb_common.dart';

import 'source_form_fields.dart';

/// 一个播放源表单的全部可编辑状态。
///
/// 主源与备用源用**同一个类**：原先 `_SourceDialogState` 的 9 个 controller
/// 与 `SourceFallbackData` 的 9 个 controller 是同一批字段的两份声明，现在
/// 收敛成这里的 `Map<SourceFieldId, TextEditingController>`。
///
/// 按类型隐藏的字段（如密钥认证下的密码）也保留 controller：切回密码认证
/// 时不能丢已填内容，保存时按当前认证方式取用。
class SourceFormModel {
  final Map<SourceFieldId, TextEditingController> _fields;

  SourceKind kind;
  SourceRoute route;

  /// SFTP 认证方式（其他协议忽略）。
  SftpAuthMethod authMethod;

  /// 文件级本地源的文件清单（`mode=files`）。
  List<LocalFileEntry> localFiles;

  /// 已导入的私钥文件名（仅展示；密钥文本本身在 `keyPem` 字段）。
  String? keyFileName;

  SourceFormModel({
    required this.kind,
    Map<String, dynamic> cfg = const {},
  })  : route = parseSourceRoute(cfg['route']),
        authMethod = parseSftpAuthMethod(cfg['authMethod']),
        localFiles = parseLocalFileEntries(cfg),
        _fields = {
          for (final id in editableFieldIdsOf(kind))
            id: TextEditingController(text: _initialText(kind, id, cfg)),
        };

  /// 从已存配置回填。`cfg` 是 `DirectSourceManager.editableConfig` 的结果
  /// （含各协议已解密的密码/密钥），也接受备用源的原始 Map。
  factory SourceFormModel.fromConfig(
    Map<String, dynamic> cfg, {
    required SourceKind kind,
  }) =>
      SourceFormModel(kind: kind, cfg: cfg);

  static String _initialText(
      SourceKind kind, SourceFieldId id, Map<String, dynamic> cfg) {
    switch (id) {
      case SourceFieldId.name:
        return (cfg['name'] as String?) ?? '';
      case SourceFieldId.path:
        return (cfg['path'] as String?) ?? '';
      case SourceFieldId.baseUrl:
        return (cfg['baseUrl'] as String?) ?? '';
      case SourceFieldId.host:
        return (cfg['host'] as String?) ?? '';
      case SourceFieldId.port:
        return (cfg['port'] as num?)?.toString() ?? '';
      case SourceFieldId.share:
        // 存储是 share/path 两键，弹窗只有一个「路径」输入，回填时合成。
        return kind == SourceKind.smb
            ? smbJoinInputPath(
                share: cfg['share'] as String? ?? '',
                rootPath: cfg['path'] as String? ?? '',
              )
            : '';
      case SourceFieldId.username:
        return (cfg['username'] as String?) ?? '';
      case SourceFieldId.password:
        // SMB 的密码走独立键（匿名源为空）；WebDAV/SFTP 用 password /
        // sftpPassword（后者由 editableConfig 回填）。
        return kind == SourceKind.smb
            ? (cfg['smbPassword'] as String?) ?? ''
            : kind == SourceKind.sftp
                ? (cfg['sftpPassword'] as String?) ?? ''
                : (cfg['password'] as String?) ?? '';
      case SourceFieldId.keyPem:
        return (cfg['sftpKeyPem'] as String?) ?? (cfg['keyPem'] as String?) ?? '';
      case SourceFieldId.keyPassphrase:
        return (cfg['sftpPassphrase'] as String?) ??
            (cfg['passphrase'] as String?) ??
            '';
    }
  }

  TextEditingController operator [](SourceFieldId id) => _fields[id]!;

  /// 该字段在当前类型下是否存在（备用源没有名称字段）。
  bool has(SourceFieldId id) => _fields.containsKey(id);

  String text(SourceFieldId id) => (_fields[id]?.text ?? '').trim();

  /// 原始明文（密码/密钥不 trim：口令里的首尾空格语义上合法）。
  String raw(SourceFieldId id) => _fields[id]?.text ?? '';

  /// 按当前类型重建 controller 集合（切换源类型时调用）。
  ///
  /// 保留用户已填的、新旧类型都存在的字段值，避免切来切去丢输入。
  void changeKind(SourceKind next) {
    if (next == kind) return;
    final keep = <SourceFieldId, String>{
      for (final id in _fields.keys) id: _fields[id]!.text,
    };
    for (final c in _fields.values) {
      c.dispose();
    }
    _fields.clear();
    for (final id in editableFieldIdsOf(next)) {
      _fields[id] = TextEditingController(text: keep[id] ?? '');
    }
    kind = next;
    // 本地源恒直连，不保留代理选择。
    if (next == SourceKind.local) route = SourceRoute.direct;
    // 新类型下没有文件清单就清掉，避免把文件源的内容带进远程源。
    if (next != SourceKind.local) localFiles = const [];
  }

  /// 本地源：是否处于「文件清单」形态。
  bool get filesMode => localFiles.isNotEmpty;

  /// 表单 → 落库用的原始 Map（可含敏感明文，由 manager 收敛到 SecretStore）。
  ///
  /// SMB 的单「路径」输入在这里拆回 share/path 两键（存储结构不变）。
  Map<String, dynamic> toRawMap() {
    var shareOut = '';
    var pathOut = text(SourceFieldId.path);
    if (kind == SourceKind.smb) {
      final parsed = smbParseInputPath(text(SourceFieldId.share));
      shareOut = parsed.share;
      pathOut = parsed.rootPath;
    }
    return <String, dynamic>{
      'kind': kind.name,
      'name': text(SourceFieldId.name),
      'baseUrl': text(SourceFieldId.baseUrl),
      'host': text(SourceFieldId.host),
      'port': int.tryParse(text(SourceFieldId.port)) ?? 22,
      'share': shareOut,
      'username': text(SourceFieldId.username),
      'password': raw(SourceFieldId.password),
      'keyPem': raw(SourceFieldId.keyPem),
      'passphrase': raw(SourceFieldId.keyPassphrase),
      'authMethod': authMethod.name,
      'path': pathOut,
      'route': route.name,
    };
  }

  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _fields.clear();
  }
}
