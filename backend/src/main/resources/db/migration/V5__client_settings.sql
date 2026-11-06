-- Flyway V5：客户端设置同步（阶段5 设置同步 v1）。
--
-- 只存播放偏好 + 媒体库规则白名单内的键；服务端按 last_event_at 做逐键 LWW。
-- 设备本地项（缓存路径、音量、均衡器、网络凭据、快捷键等）不会进入本表。
-- 执行方式：后端启动时由 Flyway 自动执行。
CREATE TABLE IF NOT EXISTS client_settings (
    setting_key       VARCHAR(64)  NOT NULL,
    setting_value     MEDIUMTEXT   NOT NULL,
    updated_at        DATETIME(6)  NOT NULL,
    last_event_at     DATETIME(6)  NOT NULL,
    device_client_id  VARCHAR(64)  NULL,
    PRIMARY KEY (setting_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
