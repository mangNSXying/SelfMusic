-- Flyway V2：同步事件载荷扩容 TEXT → MEDIUMTEXT。
--
-- 背景：breakpoint.set 的载荷随断点携带完整 deep_list（歌单当前条目数上限），
-- 上千首的大歌单会超过 TEXT 的 64 KiB 上限。MySQL 插入报
--   ERROR 1406 (22001): Data too long for column 'payload'
-- 而 push 是整批事务，单条超限会让整批事件回滚并以 500 重试，同步彻底卡住。
-- 服务端接受事件后还要把 deep_list 原样写进 play_states.deep_list_json，
-- 两列都必须扩到 MEDIUMTEXT（上限 16 MiB），否则只是在下一处继续报 1406。
--
-- 执行方式：后端启动时由 Flyway 自动执行。MODIFY COLUMN 幂等，既覆盖
-- 尚未执行 009 的存量库，也兼容 V1 基线已经含 MEDIUMTEXT 的全新库。
ALTER TABLE sync_events
    MODIFY COLUMN payload MEDIUMTEXT NULL
        COMMENT 'JSON 载荷（breakpoint.set 的 deep_list 可能超过 TEXT 64 KiB 上限）';

ALTER TABLE play_states
    MODIFY COLUMN deep_list_json MEDIUMTEXT NULL
        COMMENT '深层列表（播放历史）JSON 数组，跨设备续播重建队列用（大歌单可超 TEXT 64 KiB）';
