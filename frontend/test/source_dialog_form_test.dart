import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/local_file_direct_source.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/data/sources/sftp_common.dart';
import 'package:selfmusic/screens/sources/source_dialog/source_form_fields.dart';
import 'package:selfmusic/screens/sources/source_dialog/source_form_model.dart';
import 'package:selfmusic/screens/sources/source_dialog/source_form_ops.dart';

/// 取表单里所有文本字段 id（按声明顺序）。
List<SourceFieldId> fieldIdsOf(
  SourceKind kind, {
  required bool isFallback,
  SftpAuthMethod authMethod = SftpAuthMethod.password,
  bool filesMode = false,
}) =>
    [
      for (final s in sourceSectionsOf(kind,
          isFallback: isFallback, authMethod: authMethod, filesMode: filesMode))
        for (final r in s.rows)
          if (r is SourceTextFieldRow) r.spec.id,
    ];

void main() {
  group('sourceSectionsOf', () {
    test('主源四种协议都含名称字段', () {
      for (final kind in SourceKind.values) {
        expect(fieldIdsOf(kind, isFallback: false), contains(SourceFieldId.name),
            reason: '$kind');
      }
    });

    test('备用源没有名称字段（名称继承主源）', () {
      for (final kind in SourceKind.values) {
        expect(fieldIdsOf(kind, isFallback: true),
            isNot(contains(SourceFieldId.name)),
            reason: '$kind');
      }
    });

    test('WebDAV 字段集合与顺序', () {
      expect(fieldIdsOf(SourceKind.webdav, isFallback: false), const [
        SourceFieldId.name,
        SourceFieldId.baseUrl,
        SourceFieldId.username,
        SourceFieldId.password,
      ]);
    });

    test('SMB 只有一个合并的「路径」字段，不拆 share/path', () {
      final ids = fieldIdsOf(SourceKind.smb, isFallback: false);
      expect(ids, contains(SourceFieldId.share));
      expect(ids, isNot(contains(SourceFieldId.path)));
    });

    test('SFTP 密码认证与密钥认证的字段差异', () {
      final pwd = fieldIdsOf(SourceKind.sftp, isFallback: false);
      expect(pwd, contains(SourceFieldId.password));
      expect(pwd, isNot(contains(SourceFieldId.keyPassphrase)));

      final key = [
        for (final s in sourceSectionsOf(SourceKind.sftp,
            isFallback: false, authMethod: SftpAuthMethod.key))
          for (final r in s.rows)
            if (r is SourceTextFieldRow) r.spec.id,
      ];
      expect(key, contains(SourceFieldId.keyPassphrase));
      expect(key, isNot(contains(SourceFieldId.password)));
      expect(key, contains(SourceFieldId.path));
    });

    test('本地文件模式只有文件清单，没有目录字段', () {
      final ids =
          fieldIdsOf(SourceKind.local, isFallback: false, filesMode: true);
      // filesMode 下只有文件清单行，没有文本字段。
      expect(ids, isEmpty);
    });
  });

  group('SourceFormModel 往返', () {
    test('WebDAV 配置往返保真', () {
      final cfg = {
        'name': 'NAS',
        'baseUrl': 'https://192.168.1.10/dav',
        'username': 'u',
        'password': 'p',
        'route': 'proxy',
      };
      final m = SourceFormModel.fromConfig(cfg, kind: SourceKind.webdav);
      final raw = m.toRawMap();
      expect(raw['name'], 'NAS');
      expect(raw['baseUrl'], 'https://192.168.1.10/dav');
      expect(raw['username'], 'u');
      expect(raw['password'], 'p');
      expect(raw['route'], 'proxy');
      m.dispose();
    });

    test('SMB 的 share/path 合并成一个输入再拆回两键', () {
      final cfg = {
        'name': 'nas1',
        'host': '192.168.1.10',
        'share': 'music',
        'path': 'flac',
      };
      final m = SourceFormModel.fromConfig(cfg, kind: SourceKind.smb);
      // 回填：合成单一路径输入。
      expect(m.text(SourceFieldId.share), 'music/flac');
      final raw = m.toRawMap();
      // 落库：拆回两键。
      expect(raw['share'], 'music');
      expect(raw['path'], 'flac');
      m.dispose();
    });

    test('SFTP 的密码/密钥从 editableConfig 的独立键回填', () {
      final m = SourceFormModel.fromConfig({
        'name': 'sftp1',
        'host': 'nas.local',
        'port': 2222,
        'username': 'u',
        'authMethod': 'key',
        'sftpKeyPem': '-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----',
        'sftpPassphrase': 'pp',
      }, kind: SourceKind.sftp);
      expect(m.text(SourceFieldId.port), '2222');
      expect(m.authMethod, SftpAuthMethod.key);
      expect(m.raw(SourceFieldId.keyPem), contains('PRIVATE KEY'));
      expect(m.raw(SourceFieldId.keyPassphrase), 'pp');
      m.dispose();
    });

    test('本地文件源回填文件清单', () {
      final m = SourceFormModel.fromConfig({
        'name': 'files',
        'mode': 'files',
        'files': [
          LocalFileEntry(
            ref: 'a.mp3',
            uri: 'file:///a.mp3',
            name: 'a.mp3',
            size: 1,
            mtime: 0,
          ).toJson(),
        ],
      }, kind: SourceKind.local);
      expect(m.localFiles.length, 1);
      expect(m.filesMode, isTrue);
      m.dispose();
    });

    test('changeKind 保留同名已填字段', () {
      final m = SourceFormModel(kind: SourceKind.webdav);
      m[SourceFieldId.name].text = 'keep';
      m[SourceFieldId.username].text = 'u';
      m.changeKind(SourceKind.smb);
      expect(m.text(SourceFieldId.name), 'keep');
      expect(m.text(SourceFieldId.username), 'u');
      m.dispose();
    });

    test('本地源切换后恒直连、清空文件清单', () {
      final m = SourceFormModel(kind: SourceKind.webdav);
      m.route = SourceRoute.proxy;
      m.changeKind(SourceKind.local);
      expect(m.route, SourceRoute.direct);
      expect(m.localFiles, isEmpty);
      m.dispose();
    });
  });

  group('validateSource', () {
    SourceFormModel webdav({String url = 'https://a/b'}) {
      final m = SourceFormModel(kind: SourceKind.webdav);
      m[SourceFieldId.name].text = 'n';
      m[SourceFieldId.baseUrl].text = url;
      return m;
    }

    test('名称为空报在 name 字段', () {
      final m = webdav();
      m[SourceFieldId.name].clear();
      final r = validateSource(m, allowInsecureHttp: true);
      expect(r, isA<SourceInvalid>());
      expect((r as SourceInvalid).field, SourceFieldId.name);
      m.dispose();
    });

    test('WebDAV 空地址报在 baseUrl 字段', () {
      final m = webdav(url: '');
      final r = validateSource(m, allowInsecureHttp: true);
      expect((r as SourceInvalid).field, SourceFieldId.baseUrl);
      m.dispose();
    });

    test('WebDAV 缺协议时自动补 https://', () {
      final m = webdav(url: '192.168.1.10/dav');
      final r = validateSource(m, allowInsecureHttp: true);
      expect(r, isA<SourceValid>());
      expect(m.text(SourceFieldId.baseUrl), 'https://192.168.1.10/dav');
      m.dispose();
    });

    test('显式 http:// 且未放行 → 需要用户确认', () {
      final m = webdav(url: 'http://192.168.1.10/dav');
      expect(validateSource(m, allowInsecureHttp: false),
          isA<SourceNeedsHttpConsent>());
      expect(validateSource(m, allowInsecureHttp: true), isA<SourceValid>());
      m.dispose();
    });

    test('SFTP 端口越界与空值', () {
      for (final port in ['0', '70000', 'abc']) {
        final m = SourceFormModel(kind: SourceKind.sftp);
        m[SourceFieldId.name].text = 'n';
        m[SourceFieldId.host].text = 'h';
        m[SourceFieldId.username].text = 'u';
        m[SourceFieldId.password].text = 'p';
        m[SourceFieldId.port].text = port;
        final r = validateSource(m, allowInsecureHttp: true);
        expect((r as SourceInvalid).field, SourceFieldId.port, reason: port);
        m.dispose();
      }
    });

    test('SFTP 空端口按默认 22 通过', () {
      final m = SourceFormModel(kind: SourceKind.sftp);
      m[SourceFieldId.name].text = 'n';
      m[SourceFieldId.host].text = 'h';
      m[SourceFieldId.username].text = 'u';
      m[SourceFieldId.password].text = 'p';
      final r = validateSource(m, allowInsecureHttp: true);
      expect(r, isA<SourceValid>());
      expect((r as SourceValid).raw['port'], 22);
      m.dispose();
    });

    test('SFTP 密码认证空密码报错', () {
      final m = SourceFormModel(kind: SourceKind.sftp);
      m[SourceFieldId.host].text = 'h';
      m[SourceFieldId.username].text = 'u';
      final r = validateSource(m, allowInsecureHttp: true);
      expect((r as SourceInvalid).field, SourceFieldId.password);
      m.dispose();
    });

    test('SFTP 密钥认证无 PEM 报在 keyPem', () {
      final m = SourceFormModel(kind: SourceKind.sftp);
      m[SourceFieldId.host].text = 'h';
      m[SourceFieldId.username].text = 'u';
      m.authMethod = SftpAuthMethod.key;
      final r = validateSource(m, allowInsecureHttp: true);
      expect((r as SourceInvalid).field, SourceFieldId.keyPem);
      m.dispose();
    });

    test('SMB 空共享名报在 share 字段', () {
      final m = SourceFormModel(kind: SourceKind.smb);
      m[SourceFieldId.name].text = 'n';
      m[SourceFieldId.host].text = 'h';
      final r = validateSource(m, allowInsecureHttp: true);
      expect((r as SourceInvalid).field, SourceFieldId.share);
      m.dispose();
    });

    test('本地源目录与文件清单都空时报 path', () {
      final m = SourceFormModel(kind: SourceKind.local);
      final r = validateSource(m, allowInsecureHttp: true);
      expect((r as SourceInvalid).field, SourceFieldId.path);
      m.dispose();
    });

    test('本地文件源有文件即通过', () {
      final m = SourceFormModel(kind: SourceKind.local);
      m[SourceFieldId.name].text = 'n';
      m.localFiles = const [
        LocalFileEntry(
            ref: 'a.mp3', uri: 'file:///a.mp3', name: 'a.mp3', size: 1, mtime: 0),
      ];
      expect(validateSource(m, allowInsecureHttp: true), isA<SourceValid>());
      m.dispose();
    });
  });

  group('normalizeSourceError', () {
    test('剥掉 StateError / Bad state 前缀', () {
      expect(normalizeSourceError(StateError('端口错误')), '端口错误');
      expect(normalizeSourceError('Bad state: 连接失败'), '连接失败');
      expect(normalizeSourceError('普通错误'), '普通错误');
    });
  });
}
