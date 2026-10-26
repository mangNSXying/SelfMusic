-- Flyway V4：每首歌的播放进度直方图（0..100 共 101 桶，JSON 整数数组）。
--
-- 升权中位闸门的数据源；无样本时 NULL。直方图只由 song.complete/song.skip/
-- song.progress 事件累加（baseline 基线按桶取 max），song.state 不携带。
-- 执行方式：后端启动时由 Flyway 自动执行。
-- 幂等：按 information_schema 判断列是否已存在，重复执行安全。
SET @exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'song_states'
       AND COLUMN_NAME = 'progress_hist'
);
SET @sql := IF(@exists = 0,
    'ALTER TABLE song_states ADD COLUMN progress_hist TEXT NULL COMMENT ''播放进度直方图 JSON（101 桶，0..100%）''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
