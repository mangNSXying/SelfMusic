-- =====================================================================
-- 【历史归档】自 Flyway 接管后，新部署/升级请勿手工执行本文件。
-- 服务端表结构唯一事实源：backend/src/main/resources/db/migration/V*.sql
-- =====================================================================
-- =====================================================================
-- SelfMusic Schema v3（服务端无曲库 / 阶段5 全量合并）
-- 设计文档：DEVELOPER.md「数据模型」
-- 变更摘要（相对 v2）：
--   彻底移除服务端曲库（songs / albums / covers / scan_tasks，见 migration_004）
--   歌曲身份改由 (source_id, source_ref) 承载；权重/收藏迁入新表 song_states
--   devices 增加 access 过期 + refresh token（migration_002）
--   playlists 增加 client_uuid / deleted / last_event_at（migration_003）
--   新增 sync_events 事件流水（migration_003）
--   新增 sync_sources 播放源同步（migration_005）
--   play_states 增加 deep_list_json（migration_006）
--   song_states 增加 play_sec（migration_007）
--   事件日志压缩支撑：devices.last_pull_cursor + sync_events.entity_key（migration_008）
--   sync_events.payload / play_states.deep_list_json 扩为 MEDIUMTEXT，容纳大歌单的 deep_list 断点载荷（migration_009）
--   play_states 增加 head_rev/head_clock/head_device/head_op_id/head_session/head_playing/head_updated_at/history_rev（migration_010，断点协议 v2）
-- 注意：本文件是归档快照（已内含 migration_002…010 的结果），新部署/升级请勿执行；
--   后端启动时由 Flyway 自动建表并补齐版本。
-- =====================================================================

SET NAMES utf8mb4;

-- ---------------------------------------------------------------------
-- 全局设置（键值）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS settings (
    skey       VARCHAR(50) PRIMARY KEY,
    svalue     VARCHAR(500) NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 已配对设备（单用户多设备准入，DEVELOPER.md「身份与设备配对」）
-- access 24h / refresh 30d；两者均只存哈希
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
    id                 BIGINT AUTO_INCREMENT PRIMARY KEY,
    client_id          VARCHAR(36) NOT NULL COMMENT 'UUID，配对时生成',
    name               VARCHAR(100) NOT NULL COMMENT '设备昵称，可改',
    platform           VARCHAR(50) NULL COMMENT 'linux/android/windows/harmony/...',
    token_hash         VARCHAR(64) NOT NULL COMMENT 'SHA-256(access_token 初值)',
    revoked            BOOLEAN DEFAULT FALSE,
    paired_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at       DATETIME NULL,
    last_pull_cursor   BIGINT NULL COMMENT '设备最近一次 pull 返回的 cursor（事件日志压缩水位）',
    token_expires_at   DATETIME NULL COMMENT 'access token 过期时间',
    refresh_token_hash VARCHAR(64) NULL COMMENT 'SHA-256(refresh_token)',
    refresh_expires_at DATETIME NULL COMMENT 'refresh token 过期时间（30d）',
    renewed_at         DATETIME NULL COMMENT '最近一次续签时间',
    UNIQUE KEY uk_client_id (client_id),
    INDEX idx_token_hash (token_hash)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 播放列表（单用户，无 user 维度；多设备同步 LWW）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS playlists (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    description   TEXT NULL,
    mode          ENUM('normal','shuffle_weighted') DEFAULT 'shuffle_weighted',
    client_uuid   VARCHAR(36) NULL COMMENT '多设备同步全局标识（创建端生成）',
    deleted       BOOLEAN DEFAULT FALSE COMMENT '删除墓碑：true=已删，LWW 合并时与更新比时间戳',
    last_event_at DATETIME(3) NULL COMMENT '最后一次应用的同步事件 occurred_at',
    sync_ver      BIGINT DEFAULT 0 COMMENT '乐观锁版本号（多设备同步）',
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_name (name),
    UNIQUE KEY uk_playlist_uuid (client_uuid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 列表条目（自持歌曲身份与展示快照，无曲库外键）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS playlist_items (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    playlist_id BIGINT NOT NULL,
    source_id   VARCHAR(100) NOT NULL COMMENT '源实例 uuid；旧数据 legacy:<协议>',
    source      VARCHAR(20)  NULL COMMENT '协议名 webdav/local/smb（展示/兜底）',
    source_ref  VARCHAR(500) NOT NULL COMMENT '源内相对路径/URL路径',
    title       VARCHAR(200) NULL,
    artist      VARCHAR(200) NULL,
    album       VARCHAR(200) NULL,
    duration    INT          NULL COMMENT '秒',
    sort_order  INT DEFAULT 0,
    added_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_item_identity (playlist_id, source_id, source_ref),
    INDEX idx_playlist_sort (playlist_id, sort_order),
    CONSTRAINT fk_item_playlist FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 断点续播状态（每歌单一列）：自持歌曲身份，无曲库外键
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS play_states (
    playlist_id      BIGINT PRIMARY KEY,
    source_id        VARCHAR(100) NULL COMMENT '源实例 uuid；旧数据 legacy:<协议>',
    source           VARCHAR(20)  NULL COMMENT '协议名（展示/兜底）',
    source_ref       VARCHAR(500) NULL COMMENT '源内路径',
    device_client_id VARCHAR(36)  NULL COMMENT '上报设备 client_id（跨设备续播提示用）',
    position_ms      INT DEFAULT 0,
    deep_list_json   MEDIUMTEXT NULL COMMENT '深层列表（播放历史）JSON，跨设备续播重建队列用（大歌单可超 TEXT 64 KiB）',
    head_rev         BIGINT NOT NULL DEFAULT 0 COMMENT '播放头版本：head 被接受时 +1',
    head_clock       VARCHAR(80) NULL COMMENT '最后接受的 head 操作时钟（HLC wall-counter-device）',
    head_device      VARCHAR(64) NULL COMMENT '最后接受的 head 来源设备',
    head_op_id       VARCHAR(64) NULL COMMENT '最后接受的 head 操作 id',
    head_session     VARCHAR(64) NULL COMMENT '播放会话 id（progress 只接受同会话）',
    head_playing     BOOLEAN NOT NULL DEFAULT FALSE COMMENT '服务端 head 是否处于播放态',
    head_updated_at  DATETIME(3) NULL COMMENT '服务端接受 head 的时间（全局最近歌单排序用）',
    history_rev      BIGINT NOT NULL DEFAULT 0 COMMENT '深层历史版本：历史变化时 +1',
    last_event_at    DATETIME(3) NULL COMMENT '旧协议 LWW 兼容字段（v2 新客户端不再用于正确性比较）',
    updated_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_play_states_head_updated (head_updated_at),
    CONSTRAINT fk_state_playlist FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 直连歌曲权重/收藏状态（取代原 songs 的状态承载职责，DEVELOPER.md「播放算法与同步协议」）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS song_states (
    id             BIGINT AUTO_INCREMENT PRIMARY KEY,
    source_id      VARCHAR(100) NOT NULL COMMENT '源实例 uuid；旧数据 legacy:<协议>',
    source         VARCHAR(20)  NULL COMMENT '协议名 webdav/local/smb（展示/兜底）',
    source_ref     VARCHAR(500) NOT NULL COMMENT '源内相对路径/URL路径',
    title          VARCHAR(200) NULL COMMENT '兜底标题（载荷/文件名）',
    like_streak    INT DEFAULT 0,
    dislike_streak INT DEFAULT 0,
    weight         DECIMAL(6,4) DEFAULT 1.0000 COMMENT '相对权重因子 0.5~1.5',
    frozen         BOOLEAN DEFAULT FALSE COMMENT '手动固定概率',
    is_favorite    BOOLEAN DEFAULT FALSE,
    play_sec       INT DEFAULT 0 COMMENT '累计播放时长（秒）；播放次数由其÷歌曲时长派生',
    last_event_at  DATETIME(3) NULL COMMENT '最后一次应用的同步事件 occurred_at',
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_source_state (source_id, source_ref),
    INDEX idx_state_ref (source_ref),
    INDEX idx_state_favorite (is_favorite)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 同步事件流水：seq 全局单调 cursor + event_uuid 幂等键（DEVELOPER.md「播放算法与同步协议」）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_events (
    seq              BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '全局单调 cursor（pull 的 since_cursor 比较基准）',
    event_uuid       VARCHAR(36) NOT NULL COMMENT '客户端生成，幂等键',
    device_client_id VARCHAR(36) NOT NULL COMMENT '来源设备 client_id（须与认证身份一致）',
    type             VARCHAR(30) NOT NULL COMMENT 'song.complete/skip/complete_manual/liked/unfavorite/disliked/reset/state，playlist.*，playlist.item_*，source.*，breakpoint.set',
    payload          MEDIUMTEXT NULL COMMENT 'JSON 载荷（breakpoint.set 的 deep_list 可能超过 TEXT 64 KiB 上限）',
    occurred_at      DATETIME(3) NULL COMMENT '客户端发生时间（毫秒精度，LWW 比较用）',
    entity_key       VARCHAR(200) NULL COMMENT '事件实体键（压缩锚点：song|source_id|ref / source|uuid / playlist|uuid / breakpoint|uuid；null 不参与压缩）',
    arrived_at       TIMESTAMP(3) DEFAULT CURRENT_TIMESTAMP(3) COMMENT '服务端仲裁时钟（occurred_at 缺失或打平时用）',
    UNIQUE KEY uk_event_uuid (event_uuid),
    INDEX idx_seq (seq),
    INDEX idx_device (device_client_id),
    INDEX idx_type_seq (type, seq),
    INDEX idx_entity_seq (entity_key, seq)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 播放源同步（远端类型源 client_uuid 收敛；本地文件夹源不参与）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_sources (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    client_uuid   VARCHAR(36) NOT NULL COMMENT '源实例全局标识（创建端生成）',
    kind          VARCHAR(20) NOT NULL COMMENT 'webdav/smb/onedrive…（local 不同步）',
    name          VARCHAR(100) NULL,
    address       VARCHAR(500) NOT NULL COMMENT '去重地址：WebDAV=baseUrl；SMB=host/share',
    config_json   TEXT NULL COMMENT '非敏感配置 JSON（不含密码）',
    enabled       BOOLEAN DEFAULT TRUE,
    deleted       BOOLEAN DEFAULT FALSE COMMENT '删除墓碑（LWW）',
    last_event_at DATETIME(3) NULL COMMENT '最后一次应用的同步事件 occurred_at',
    sync_ver      BIGINT DEFAULT 0,
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_sync_source_uuid (client_uuid),
    UNIQUE KEY uk_sync_source_identity (kind, address)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 默认设置项
-- ---------------------------------------------------------------------
INSERT INTO settings (skey, svalue) VALUES
    ('cache_max_bytes', '5368709120'),
    ('cache_song_limit', '200'),
    ('sync.server_epoch', UUID())
ON DUPLICATE KEY UPDATE skey = skey;
-- pairing_token 由应用首次启动生成写入（权威源 env PAIRING_TOKEN），不在此预置

-- =====================================================================
-- 归档说明：
--   下列手工迁移已全部合并进 Flyway 的 V1/V2/V3，保留仅供追溯：
--   历史升级顺序（每步之间保持顺序，006/007 断言的列依赖前序迁移）：
--       migration_002_devices_refresh.sql
--       migration_003_sync.sql
--       migration_004_remove_library.sql
--       migration_005_source_sync.sql
--       migration_006_deep_list.sql
--       migration_007_play_sec.sql
--       migration_008_event_compaction.sql
--       migration_009_sync_payload_mediumtext.sql
--       migration_010_breakpoint_head_v2.sql
--   风险：migration_004 不可逆（删除 songs/albums/covers/scan_tasks），执行前备份。
-- =====================================================================