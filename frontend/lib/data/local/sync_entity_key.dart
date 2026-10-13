/// 同步实体键（阶段5 本机优先）：与服务端 `SyncService.entityKeyOf`
/// 同一规则的 Dart 翻版，用于 pull 落库时跳过“本地还有未推事件”的实体。
///
/// 键形态：
/// - `song|<source_id>|<ref>`（无 source_id 时按协议回退 `legacy:<协议>`，
///   `server` 占位/空按 `''`，与服务端 `sourceIdOf` 同规则）
/// - `source|<uuid>` / `playlist|<uuid>` / `breakpoint|<uuid>`
/// 无法识别的载荷返回 null——调用方视为无 guard，直接应用快照。
String? syncEntityKey(String type, Map<String, dynamic> payload) {
  if (type.startsWith('song.')) {
    final ref = payload['source_ref'];
    if (ref is! String || ref.isEmpty) return null;
    return 'song|${_songSourceIdOf(payload)}|$ref';
  }
  if (type.startsWith('source.')) {
    final uuid = payload['client_uuid'];
    if (uuid is! String || uuid.isEmpty) return null;
    return 'source|$uuid';
  }
  if (type.startsWith('playlist.')) {
    final uuid = _playlistUuidOf(payload);
    if (uuid == null) return null;
    return 'playlist|$uuid';
  }
  if (type == 'breakpoint.set') {
    final uuid = payload['playlist_uuid'];
    if (uuid is! String || uuid.isEmpty) return null;
    return 'breakpoint|$uuid';
  }
  return null;
}

/// 歌曲源实例身份：`source_id` 优先；缺省按协议回退 `legacy:<协议>`；
/// `server` 占位/空返回 `''`（与服务端 `sourceIdOf` 的空键语义对齐，
/// 仅用于 guard 比较，不用于建行）。
String _songSourceIdOf(Map<String, dynamic> p) {
  final sid = p['source_id'];
  if (sid is String && sid.isNotEmpty) return sid;
  final source = p['source'];
  if (source is String &&
      source.isNotEmpty &&
      source != 'server') {
    return 'legacy:$source';
  }
  return '';
}

/// 歌单实体 uuid：`client_uuid` 优先，`playlist_uuid` 兜底
/// （条目事件只带后者；与服务端 `entityKeyOf` 同规则）。
String? _playlistUuidOf(Map<String, dynamic> p) {
  final uuid = p['client_uuid'];
  if (uuid is String && uuid.isNotEmpty) return uuid;
  final legacy = p['playlist_uuid'];
  if (legacy is String && legacy.isNotEmpty) return legacy;
  return null;
}
