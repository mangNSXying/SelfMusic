/// 阶段5 同步事件类型（DESIGN.md §7.2；与服务端 `SyncEventTypes` 同名对应）。
///
/// 出队载荷统一含歌曲身份（`source` + `source_ref`，服务端按 songs.uk_source_ref
/// 解析；`source` 为 legacy 空/`server` 占位时服务端按 source_ref 兜底）。
abstract final class SyncEventTypes {
  // 权重事件（服务端事件重算，两设备并发不互抹）
  static const songComplete = 'song.complete';
  static const songSkipped = 'song.skip';
  static const songLiked = 'song.liked';
  static const songUnfavorite = 'song.unfavorite';
  static const songDisliked = 'song.disliked';
  static const songReset = 'song.reset';

  // 歌单元数据（行级 LWW）
  static const playlistCreate = 'playlist.create';
  static const playlistUpdate = 'playlist.update';
  static const playlistDelete = 'playlist.delete';

  // 歌单条目（到达序重放）
  static const playlistItemAdd = 'playlist.item_add';
  static const playlistItemRemove = 'playlist.item_remove';
  static const playlistItemMove = 'playlist.item_move';

  // 断点（行级 LWW）
  static const breakpointSet = 'breakpoint.set';
}
