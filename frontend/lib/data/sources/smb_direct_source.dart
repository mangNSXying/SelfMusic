import 'dart:convert';
import 'music_source.dart';

/// SMB 直连源骨架（DESIGN §6.3，正式实现在阶段 4：Windows UNC / Android smbj 平台通道）。
///
/// 阶段 1 只要求"四实现骨架"存在；阶段 4 再补齐全平台直连通路。
/// 播放/扫描统一抛"暂未实现"，模式判定只认 server 源时不受影响。
class SmbDirectSource extends MusicSource {
  @override
  final String name;
  final String host;
  final String share;
  final String? username;
  final String? password;
  final String? path;

  SmbDirectSource({
    required this.name,
    required this.host,
    required this.share,
    this.username,
    this.password,
    this.path,
  });

  @override
  String get key => 'smb:$name';

  @override
  SourceKind get kind => SourceKind.smb;

  /// 配置的展示摘要。
  Map<String, String> get configJ {
    final c = <String, String>{
      'name': name,
      'host': host,
      'share': share,
    };
    if (path != null && path!.isNotEmpty) c['path'] = path!;
    if (username != null) c['username'] = username!;
    return c;
  }

  String get configJson => jsonEncode(configJ);
}
