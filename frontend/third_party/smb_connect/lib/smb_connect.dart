library smb_connect;

export 'src/connect/smb_connect.dart' show SmbConnect;
export 'src/connect/smb_file.dart' show SmbFile;
// SelfMusic 补丁：ohos 后端直连需自建匿名/账密配置（上游 example 只走 connectAuth），
// 公开这三个类，避免主工程 import `src/` 私有路径（implementation_imports）。
export 'src/connect/impl/base_configuration.dart' show BaseConfiguration;
export 'src/dialect_version.dart' show DialectVersion;
export 'src/smb/ntlm_password_authenticator.dart'
    show NtlmPasswordAuthenticator;
// SelfMusic 补丁：错误映射需要识别「账密错误」类型（SmbAuthException）。
export 'src/exceptions.dart' show SmbAuthException, SmbException;
