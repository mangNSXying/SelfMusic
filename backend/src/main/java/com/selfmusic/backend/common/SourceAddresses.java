package com.selfmusic.backend.common;

/**
 * 播放源同步地址归一化（源同步与转码强校验共用，避免两处漂移）。
 *
 * <p>客户端的 WebDAV 源地址可以直接输入无 scheme 形态（如
 * {@code webdav.example.com/data}），客户端请求时会默认补 {@code https://}；
 * 该原始形态历史上经源同步落到了 {@code sync_sources.address}。
 * 服务端解析/去重前统一归一化：WebDAV 缺 scheme 补 https、去首尾空白。
 */
public final class SourceAddresses {

    private SourceAddresses() {
    }

    /** 按源类型归一化地址；空白返回原（供调用方判空）。 */
    public static String normalize(String kind, String address) {
        if (address == null) return null;
        String s = address.trim();
        if (s.isEmpty()) return s;
        if ("webdav".equalsIgnoreCase(kind) && !s.contains("://")) {
            s = "https://" + s;
        }
        return s;
    }
}
