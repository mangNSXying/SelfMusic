-- =====================================================================
-- 【历史归档】自 Flyway 接管后，新部署/升级请勿手工执行本文件。
-- 服务端表结构唯一事实源：backend/src/main/resources/db/migration/V*.sql
-- =====================================================================
-- 同步事件载荷扩容：sync_events.payload 与 play_states.deep_list_json
-- TEXT → MEDIUMTEXT。
--
-- 背景：breakpoint.set 的载荷随断点携带完整 deep_list（歌单当前条目数上限），
-- 上千首的大歌单会超过 TEXT 的 64 KiB 上限。MySQL 插入报
--   ERROR 1406 (22001): Data too long for column 'payload'
-- 而 push 是整批事务，单条超限会让整批事件回滚并以 500 重试，同步彻底卡住。
-- 服务端接受事件后还要把 deep_list 原样写进 play_states.deep_list_json，
-- 两列都必须扩到 MEDIUMTEXT（上限 16 MiB），否则只是在下一处继续报 1406。
-- 无需改客户端协议。
--
-- 本文件已归档，对应 Flyway V2__sync_payload_mediumtext.sql；新部署/升级勿手工执行。
-- 幂等性保留说明：MODIFY COLUMN 可重复执行。
ALTER TABLE sync_events
    MODIFY COLUMN payload MEDIUMTEXT NULL
        COMMENT 'JSON 载荷（breakpoint.set 的 deep_list 可能超过 TEXT 64 KiB 上限）';

ALTER TABLE play_states
    MODIFY COLUMN deep_list_json MEDIUMTEXT NULL
        COMMENT '深层列表（播放历史）JSON 数组，跨设备续播重建队列用（大歌单可超 TEXT 64 KiB）';

