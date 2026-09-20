package com.selfmusic.backend.sync;

/** 阶段5 同步事件类型（DESIGN.md §7.2；事件名即 sync_events.type）。 */
public final class SyncEventTypes {
    private SyncEventTypes() {}

    // 权重事件：服务端按 §7.1 做事件重算（非绝对值覆盖），天然可合并
    public static final String SONG_COMPLETE = "song.complete";
    public static final String SONG_SKIP = "song.skip";
    public static final String SONG_LIKED = "song.liked";
    public static final String SONG_UNFAVORITE = "song.unfavorite";
    public static final String SONG_DISLIKED = "song.disliked";
    public static final String SONG_RESET = "song.reset";

    // 歌单元数据：行级 LWW（以 last_event_at 为基准）
    public static final String PLAYLIST_CREATE = "playlist.create";
    public static final String PLAYLIST_UPDATE = "playlist.update";
    public static final String PLAYLIST_DELETE = "playlist.delete";

    // 歌单条目：按 seq 到达序重放（后到达胜出），天然收敛
    public static final String PLAYLIST_ITEM_ADD = "playlist.item_add";
    public static final String PLAYLIST_ITEM_REMOVE = "playlist.item_remove";
    public static final String PLAYLIST_ITEM_MOVE = "playlist.item_move";

    // 断点：行级 LWW（以 last_event_at 为基准）
    public static final String BREAKPOINT_SET = "breakpoint.set";
}
