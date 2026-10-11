package com.selfmusic.backend.transcode.smb;

import com.hierynomus.msdtyp.AccessMask;
import com.hierynomus.mssmb2.SMB2CreateDisposition;
import com.hierynomus.mssmb2.SMB2ShareAccess;
import com.hierynomus.smbj.SMBClient;
import com.hierynomus.smbj.auth.AuthenticationContext;
import com.hierynomus.smbj.connection.Connection;
import com.hierynomus.smbj.session.Session;
import com.hierynomus.smbj.share.DiskShare;
import com.hierynomus.smbj.share.File;
import com.hierynomus.smbj.share.Share;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.EnumSet;

/**
 * SMB 回源取流（转码代理的 smb:// origin 用；HTTP(S) 走原 HttpClient 路径，
 * SFTP 走 {@code SshOriginFetcher}）。
 *
 * <ul>
 *   <li>每请求独立短连接：连上 → NTLM 账密/匿名鉴权 → 打开文件 → 顺序读；
 *       流关闭时逐级释放（与 HTTP 取流同生命周期）；</li>
 *   <li>失败一律 {@code 502}（源侧失败，客户端回落直连），消息面向用户可直接展示；
 *       信封内容（用户名/密码值）绝不记日志；</li>
 *   <li>不整曲预下载：顺序流喂 ffmpeg stdin（与并发门控配合）。</li>
 * </ul>
 */
public final class SmbOriginFetcher {

    private static final Logger log = LoggerFactory.getLogger(SmbOriginFetcher.class);

    private SmbOriginFetcher() {
    }

    public static InputStream openStream(String host, int port, String shareName,
                                         String filePath, SmbEnvelope.Credentials creds) {
        SMBClient client = new SMBClient();
        Connection conn = null;
        boolean ok = false;
        try {
            try {
                conn = client.connect(host, port);
            } catch (IOException e) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                        "源不可达: " + e.getMessage());
            }
            Session session;
            try {
                AuthenticationContext auth = creds.anonymous()
                        ? AuthenticationContext.anonymous()
                        : new AuthenticationContext(
                                creds.username() == null ? "" : creds.username(),
                                creds.password() == null ? new char[0]
                                        : creds.password().toCharArray(),
                                "");
                session = conn.authenticate(auth);
            } catch (Exception e) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "源鉴权失败");
            }
            log.debug("smb connected host={} auth={}", host,
                    creds.anonymous() ? "anonymous" : "password");
            Share share;
            try {
                share = session.connectShare(shareName);
            } catch (Exception e) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                        "共享不存在或无权访问: " + shareName);
            }
            if (!(share instanceof DiskShare disk)) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                        "非磁盘共享: " + shareName);
            }
            File file;
            try {
                file = disk.openFile(filePath,
                        EnumSet.of(AccessMask.GENERIC_READ),
                        null,
                        SMB2ShareAccess.ALL,
                        SMB2CreateDisposition.FILE_OPEN,
                        null);
            } catch (Exception e) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "源文件打开失败");
            }
            InputStream in = file.getInputStream();
            ok = true;
            return new SmbReadStream(in, file, share, session, conn, client);
        } finally {
            if (!ok) {
                closeQuietly(null, null, null, conn, client);
            }
        }
    }

    /** 顺序读的 SMB 字节流；close 逐级释放（流→文件→共享→会话→连接→客户端）。 */
    static final class SmbReadStream extends FilterInputStream {
        private final File file;
        private final Share share;
        private final Session session;
        private final Connection conn;
        private final SMBClient client;
        private boolean closed = false;

        SmbReadStream(InputStream in, File file, Share share, Session session,
                      Connection conn, SMBClient client) {
            super(in);
            this.file = file;
            this.share = share;
            this.session = session;
            this.conn = conn;
            this.client = client;
        }

        @Override
        public void close() throws IOException {
            if (closed) return;
            closed = true;
            try {
                super.close();
            } catch (Exception ignored) {
            }
            closeQuietly(file, share, session, conn, client);
        }
    }

    static void closeQuietly(File file, Share share, Session session,
                             Connection conn, SMBClient client) {
        try {
            if (file != null) file.close();
        } catch (Exception ignored) {
        }
        try {
            if (share != null) share.close();
        } catch (Exception ignored) {
        }
        try {
            if (session != null) session.close();
        } catch (Exception ignored) {
        }
        try {
            if (conn != null) conn.close();
        } catch (Exception ignored) {
        }
        try {
            if (client != null) client.close();
        } catch (Exception ignored) {
        }
    }
}
