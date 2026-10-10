package com.selfmusic.backend.transcode.ssh;

import net.schmizz.sshj.SSHClient;
import net.schmizz.sshj.sftp.OpenMode;
import net.schmizz.sshj.sftp.RemoteFile;
import net.schmizz.sshj.sftp.SFTPClient;
import net.schmizz.sshj.transport.verification.HostKeyVerifier;
import net.schmizz.sshj.userauth.keyprovider.KeyProvider;
import net.schmizz.sshj.userauth.password.PasswordUtils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

import java.io.IOException;
import java.io.InputStream;
import java.util.EnumSet;

/**
 * SFTP 回源取流（转码代理的 sftp:// origin 用；HTTP(S) 走原 HttpClient 路径）。
 *
 * <ul>
 *   <li>每请求独立短连接：连上 → 验主机密钥（对信封指纹）→ 密码/私钥二选一鉴权 →
 *       打开文件 → 顺序分块读；流关闭时逐级释放（与 HTTP 取流同生命周期）；</li>
 *   <li>失败一律 {@code 502}（源侧失败，客户端回落直连），消息面向用户可直接展示；
 *       信封内容（密码/私钥/指纹值）绝不记日志；</li>
 *   <li>不整曲预下载：256KB 分块读喂 ffmpeg stdin（与并发门控配合）。</li>
 * </ul>
 */
public final class SshOriginFetcher {

    private static final Logger log = LoggerFactory.getLogger(SshOriginFetcher.class);

    /** SFTP 单次读块（喂 ffmpeg stdin 的粒度）。 */
    static final int CHUNK = 256 * 1024;

    private SshOriginFetcher() {
    }

    /** 主机密钥与信封指纹不一致（转 502「指纹失配」，提示用户重认）。 */
    static final class HostKeyMismatchException extends RuntimeException {
    }

    /** cause 链里是否裹着指纹失配（sshj 可能包装 verifier 抛出的异常）。 */
    static boolean causedByMismatch(Throwable e) {
        for (Throwable t = e; t != null; t = t.getCause()) {
            if (t instanceof HostKeyMismatchException) return true;
        }
        return false;
    }

    public static InputStream openStream(String host, int port, String path,
                                         SshEnvelope.Credentials creds) {
        SSHClient ssh = new SSHClient();
        boolean ok = false;
        try {
            ssh.addHostKeyVerifier(new HostKeyVerifier() {
                @Override
                public boolean verify(String hostname, int p,
                                      java.security.PublicKey key) {
                    if (!SshEnvelope.fingerprintMatches(
                            creds.hostFingerprint(), key)) {
                        throw new HostKeyMismatchException();
                    }
                    return true;
                }

                @Override
                public java.util.List<String> findExistingAlgorithms(
                        String hostname, int p) {
                    return java.util.Collections.emptyList();
                }
            });
            ssh.setConnectTimeout(15_000);
            ssh.setTimeout(15_000);
            try {
                ssh.connect(host, port);
            } catch (HostKeyMismatchException e) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                        "主机密钥指纹失配（可能中间人或服务器重装），请在客户端重认指纹");
            } catch (IOException e) {
                if (causedByMismatch(e)) {
                    throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                            "主机密钥指纹失配（可能中间人或服务器重装），请在客户端重认指纹");
                }
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY,
                        "源不可达: " + e.getMessage());
            }
            log.debug("sftp connected host={} auth={}", host,
                    creds.useKey() ? "key" : "password");
            try {
                if (creds.useKey()) {
                    KeyProvider kp = ssh.loadKeys(creds.keyPem(), null,
                            creds.passphrase() == null ? null
                                    : PasswordUtils.createOneOff(
                                            creds.passphrase().toCharArray()));
                    ssh.authPublickey(creds.username(), kp);
                } else {
                    ssh.authPassword(creds.username(), creds.password());
                }
            } catch (Exception e) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "源鉴权失败");
            }
            SFTPClient sftp;
            RemoteFile file;
            try {
                sftp = ssh.newSFTPClient();
                file = sftp.open(path, EnumSet.of(OpenMode.READ));
            } catch (IOException e) {
                throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "源文件打开失败");
            }
            ok = true;
            return new SshReadStream(ssh, sftp, file);
        } finally {
            if (!ok) {
                try {
                    ssh.disconnect();
                } catch (Exception ignored) {
                }
            }
        }
    }

    /** 顺序分块读的 SFTP 字节流；close 逐级释放（文件→子系统→连接）。 */
    static final class SshReadStream extends InputStream {
        private final SSHClient ssh;
        private final SFTPClient sftp;
        private final RemoteFile file;
        private long pos = 0;
        private boolean eof = false;

        SshReadStream(SSHClient ssh, SFTPClient sftp, RemoteFile file) {
            this.ssh = ssh;
            this.sftp = sftp;
            this.file = file;
        }

        @Override
        public int read(byte[] b, int off, int len) throws IOException {
            if (eof) return -1;
            int n = file.read(pos, b, off, Math.min(len, CHUNK));
            if (n < 0) {
                eof = true;
                return -1;
            }
            pos += n;
            return n;
        }

        @Override
        public int read() throws IOException {
            byte[] b = new byte[1];
            int n = read(b, 0, 1);
            return n < 0 ? -1 : (b[0] & 0xff);
        }

        @Override
        public void close() throws IOException {
            try {
                file.close();
            } catch (Exception ignored) {
            }
            try {
                sftp.close();
            } catch (Exception ignored) {
            }
            try {
                ssh.disconnect();
            } catch (Exception ignored) {
            }
        }
    }
}
