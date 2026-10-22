-- Flyway V3：断点协议 v2，把「当前播放头」与「深层历史」拆开。
--
-- head_rev/head_clock/head_* 由 HLC 操作时钟仲裁（最后一次真实播放操作赢）；
-- history_rev 只随深层列表变化递增，head 输了历史仍可合并。
-- last_event_at 仅保留给旧客户端/旧协议兼容与诊断。
--
-- 执行方式：后端启动时由 Flyway 自动执行。
-- 幂等：按 information_schema 判断列/索引是否已存在。已手工执行过 010 的库
-- 也能安全执行，不会重复 ALTER；只有本次真正新增 head_rev 时才回填旧行，
-- 不会把 v2 时代正常产生的新行（head_rev=0）误标成 legacy head。
SET @exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'play_states'
       AND COLUMN_NAME = 'head_rev'
);
SET @sql := IF(@exists = 0,
    'ALTER TABLE play_states ADD COLUMN head_rev BIGINT NOT NULL DEFAULT 0 COMMENT ''播放头版本：head 被接受时 +1''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
SET @head_rev_added := (@exists = 0);

SET @exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'play_states'
       AND COLUMN_NAME = 'head_clock'
);
SET @sql := IF(@exists = 0,
    'ALTER TABLE play_states ADD COLUMN head_clock VARCHAR(80) NULL COMMENT ''最后接受的 head 操作时钟（HLC wall-counter-device）''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'play_states'
       AND COLUMN_NAME = 'head_device'
);
SET @sql := IF(@exists = 0,
    'ALTER TABLE play_states ADD COLUMN head_device VARCHAR(64) NULL COMMENT ''最后接受的 head 来源设备''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'play_states'
       AND COLUMN_NAME = 'head_op_id'
);
SET @sql := IF(@exists = 0,
    'ALTER TABLE play_states ADD COLUMN head_op_id VARCHAR(64) NULL COMMENT ''最后接受的 head 操作 id''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'play_states'
       AND COLUMN_NAME = 'head_session'
);
SET @sql := IF(@exists = 0,
    'ALTER TABLE play_states ADD COLUMN head_session VARCHAR(64) NULL COMMENT ''播放会话 id（progress 只接受同会话）''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'play_states'
       AND COLUMN_NAME = 'head_playing'
);
SET @sql := IF(@exists = 0,
    'ALTER TABLE play_states ADD COLUMN head_playing BOOLEAN NOT NULL DEFAULT FALSE COMMENT ''服务端 head 是否处于播放态''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'play_states'
       AND COLUMN_NAME = 'head_updated_at'
);
SET @sql := IF(@exists = 0,
    'ALTER TABLE play_states ADD COLUMN head_updated_at DATETIME(3) NULL COMMENT ''服务端接受 head 的时间（全局最近歌单排序用）''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'play_states'
       AND COLUMN_NAME = 'history_rev'
);
SET @sql := IF(@exists = 0,
    'ALTER TABLE play_states ADD COLUMN history_rev BIGINT NOT NULL DEFAULT 0 COMMENT ''深层历史版本：历史变化时 +1''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- 旧数据回填：让 v2 客户端首次拉取时能正常比较版本。
-- 仅当本次刚刚新增 head_rev 时执行，避免重复运行 V3 时误改已有数据。
UPDATE play_states
   SET head_rev = 1,
       history_rev = 1,
       head_clock = CONCAT(
           CAST(UNIX_TIMESTAMP(COALESCE(last_event_at, updated_at)) * 1000 AS UNSIGNED),
           '-0-legacy'),
       head_device = COALESCE(device_client_id, 'legacy'),
       head_op_id = CONCAT('legacy-', playlist_id),
       head_updated_at = COALESCE(last_event_at, updated_at)
 WHERE @head_rev_added = 1
   AND head_rev = 0
   AND (source_ref IS NOT NULL OR deep_list_json IS NOT NULL);

SET @exists := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'play_states'
       AND INDEX_NAME = 'idx_play_states_head_updated'
);
SET @sql := IF(@exists = 0,
    'CREATE INDEX idx_play_states_head_updated ON play_states (head_updated_at)',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- 服务端数据代次：客户端据此在 DB 重建后重置本地 revision。
INSERT INTO settings (skey, svalue) VALUES ('sync.server_epoch', UUID())
ON DUPLICATE KEY UPDATE skey = skey;
