-- =====================================================================
-- SelfMusic Schema v2
-- 设计文档：DESIGN.md §3.1
-- 变更摘要（相对 v1）：
--   删除 users、playlist_songs
--   重构 songs；新增 albums / covers / play_states / scan_tasks / settings / devices
--   playlists 去 user 化；playlist_items 取代 playlist_songs
-- 注意：应用到已有库需先 DROP 旧表（见文末注释的迁移段）
-- =====================================================================

SET NAMES utf8mb4;

-- ---------------------------------------------------------------------
-- 封面（内容寻址落盘）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS covers (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    storage_ref   VARCHAR(500) NOT NULL COMMENT '服务端落盘相对路径',
    content_hash  VARCHAR(64) NOT NULL,
    width         INT DEFAULT 0,
    height        INT DEFAULT 0,
    size_bytes    BIGINT DEFAULT 0,
    content_type  VARCHAR(50) DEFAULT 'image/jpeg',
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_content_hash (content_hash)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 专辑
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS albums (
    id             BIGINT AUTO_INCREMENT PRIMARY KEY,
    artist         VARCHAR(200) NOT NULL,
    album          VARCHAR(200) NOT NULL,
    year           SMALLINT NULL,
    genre          VARCHAR(100) NULL,
    cover_id       BIGINT NULL,
    track_count    INT DEFAULT 0,
    total_duration INT DEFAULT 0 COMMENT '秒',
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_artist_album (artist, album),
    INDEX idx_artist (artist),
    CONSTRAINT fk_album_cover FOREIGN KEY (cover_id) REFERENCES covers(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 歌曲（核心表：元数据 + 源定位 + 权重状态）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS songs (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    album_id        BIGINT NULL,
    title           VARCHAR(200) NOT NULL,
    artist          VARCHAR(200) NULL,
    track_no        SMALLINT NULL,
    year            SMALLINT NULL,
    genre           VARCHAR(100) NULL,
    duration        INT DEFAULT 0 COMMENT '秒',

    -- 源定位
    source          ENUM('local','smb','webdav') NOT NULL,
    source_ref      VARCHAR(500) NOT NULL COMMENT '源内相对路径/URL路径',
    file_size       BIGINT NOT NULL DEFAULT 0,
    file_mtime      DATETIME NULL COMMENT '增量扫描依据',
    checksum        VARCHAR(32) NULL COMMENT '预留 MD5',
    format          VARCHAR(20) NULL,

    cover_id        BIGINT NULL,

    -- 加权播放状态（DESIGN.md §7.1）
    like_streak     INT DEFAULT 0,
    dislike_streak  INT DEFAULT 0,
    weight          DECIMAL(6,4) DEFAULT 1.0000 COMMENT '相对权重因子 0.5~1.5',
    frozen          BOOLEAN DEFAULT FALSE COMMENT '手动固定概率',
    is_favorite     BOOLEAN DEFAULT FALSE,

    -- 生命周期
    is_hidden       BOOLEAN DEFAULT FALSE,
    missing_since   DATETIME NULL,
    play_count      INT DEFAULT 0,
    last_played_at  DATETIME NULL,

    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY uk_source_ref (source, source_ref),
    INDEX idx_title (title),
    INDEX idx_artist (artist),
    INDEX idx_album (album_id),
    INDEX idx_favorite (is_favorite),
    CONSTRAINT fk_song_album FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE SET NULL,
    CONSTRAINT fk_song_cover FOREIGN KEY (cover_id) REFERENCES covers(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 播放列表（单用户，无 user 维度）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS playlists (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    description TEXT NULL,
    cover_id    BIGINT NULL,
    mode        ENUM('normal','shuffle_weighted') DEFAULT 'shuffle_weighted',
    sync_ver    BIGINT DEFAULT 0 COMMENT '乐观锁版本号（多设备同步）',
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 列表条目
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS playlist_items (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    playlist_id BIGINT NOT NULL,
    song_id     BIGINT NOT NULL,
    sort_order  INT DEFAULT 0,
    added_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_playlist_song (playlist_id, song_id),
    INDEX idx_playlist_sort (playlist_id, sort_order),
    CONSTRAINT fk_item_playlist FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
    CONSTRAINT fk_item_song FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 断点续播状态（每列表一行）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS play_states (
    playlist_id BIGINT PRIMARY KEY,
    song_id     BIGINT NULL,
    position_ms INT DEFAULT 0,
    updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_state_playlist FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
    CONSTRAINT fk_state_song FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 扫描任务
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS scan_tasks (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    trigger_type  ENUM('manual','scheduled') NOT NULL DEFAULT 'manual',
    status        ENUM('running','done','failed') NOT NULL DEFAULT 'running',
    total_count   INT DEFAULT 0,
    added_count   INT DEFAULT 0,
    updated_count INT DEFAULT 0,
    missing_count INT DEFAULT 0,
    started_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    finished_at   DATETIME NULL,
    error_msg     TEXT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 全局设置（键值）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS settings (
    skey       VARCHAR(50) PRIMARY KEY,
    svalue     VARCHAR(500) NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 已配对设备（单用户多设备准入，DESIGN.md §2）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
    id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    client_id    VARCHAR(36) NOT NULL COMMENT 'UUID',
    name         VARCHAR(100) NOT NULL,
    platform     VARCHAR(50) NULL COMMENT 'android/windows/harmony...',
    token_hash   VARCHAR(64) NOT NULL COMMENT 'SHA-256(device_token)',
    revoked      BOOLEAN DEFAULT FALSE,
    paired_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at DATETIME NULL,
    UNIQUE KEY uk_client_id (client_id),
    INDEX idx_token_hash (token_hash)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 默认设置项
-- ---------------------------------------------------------------------
INSERT INTO settings (skey, svalue) VALUES
    ('cache_max_bytes', '1073741824'),
    ('cache_song_limit', '500'),
    ('scan_interval_min', '0'),
    ('transcode_max_concurrency', '2'),
    ('upload_dir', 'Uploads')
ON DUPLICATE KEY UPDATE skey = skey;
-- pairing_token 由应用首次启动生成写入，不在此预置

-- =====================================================================
-- 迁移参考（从 v1 升级时手工执行；确认后再跑！）：
--   USE selfmusic;
--   SET FOREIGN_KEY_CHECKS = 0;
--   DROP TABLE IF EXISTS playlist_songs, playlists, songs, users;
--   SET FOREIGN_KEY_CHECKS = 1;
--   然后执行本脚本。
-- =====================================================================
