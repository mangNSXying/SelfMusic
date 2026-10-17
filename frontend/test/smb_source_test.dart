import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/data/sources/smb_common.dart';
import 'package:selfmusic/data/sources/smb_connect_backend.dart';
import 'package:smb_connect/smb_connect.dart' show SmbAuthException, SmbException;

void main() {
  group('SMB 路径', () {
    test('smbRemotePath：root+ref 拼接并过滤穿越', () {
      expect(smbRemotePath('', 'a/b.mp3'), 'a/b.mp3');
      expect(smbRemotePath('music/flac', 'a/b.mp3'), 'music/flac/a/b.mp3');
      expect(smbRemotePath('/music/', '/a.mp3'), 'music/a.mp3');
      expect(smbRemotePath('music', '../etc/passwd'), 'music/etc/passwd');
      expect(smbRemotePath('music', './a.mp3'), 'music/a.mp3');
      expect(smbRemotePath('', ''), '');
    });

    test('smbRelRef：远端路径折回源内 ref', () {
      expect(smbRelRef('', 'music/a.mp3'), 'music/a.mp3');
      expect(smbRelRef('music', 'music/flac/a.mp3'), 'flac/a.mp3');
      expect(smbRelRef('music/flac', 'music/flac/a.mp3'), 'a.mp3');
      // 对不上 root 时原样返回（不丢数据）。
      expect(smbRelRef('music', 'other/a.mp3'), 'other/a.mp3');
    });

    test('音频后缀与 MIME（与 SFTP 同集合）', () {
      expect(isSmbAudioFile('a.MP3'), isTrue);
      expect(isSmbAudioFile('a.flac'), isTrue);
      expect(isSmbAudioFile('a.txt'), isFalse);
      expect(isSmbAudioFile('a.lrc'), isFalse);
      expect(smbMimeOf(smbExtOf('a.flac')), 'audio/flac');
      expect(smbMimeOf(smbExtOf('a.mp3')), 'audio/mpeg');
    });
  });

  group('SMB 代理 origin 与信封', () {
    test('smbOriginUrl：逐段编码、无 userinfo', () {
      expect(
        smbOriginUrl(host: 'nas.local', share: 'music', remote: 'flac/a b.mp3'),
        'smb://nas.local/music/flac/a%20b.mp3',
      );
    });

    test('buildSmbEnvelope：base64url(JSON)，匿名无 p', () {
      final anon = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(buildSmbEnvelope(username: ''))))) as Map;
      expect(anon, {'u': ''});
      final auth = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(buildSmbEnvelope(username: 'u', password: 'p'))))) as Map;
      expect(auth, {'u': 'u', 'p': 'p'});
    });
  });

  group('SMB 错误映射', () {
    test('smb_connect：SmbAuthException → SourceAuthException', () {
      final e = mapSmbConnectError(
          SmbAuthException('Logon failure: unknown user name or bad password.'),
          'SMB 连接失败');
      expect(e, isA<SourceAuthException>());
    });

    test('smb_connect：LOGON_FAILURE → SourceAuthException', () {
      final e = mapSmbConnectError(
          StateError('NT_STATUS_LOGON_FAILURE'), 'SMB 读取');
      expect(e, isA<SourceAuthException>());
    });

    test('smb_connect：NOT_SUPPORTED → 方言提示', () {
      final e =
          mapSmbConnectError(SmbException('Not supported'), 'SMB 连接失败');
      expect(e, isA<SmbStatusException>());
      expect(e.toString(), contains('SMB 方言'));
    });

    test('smb_connect：Not compatible → 方言提示', () {
      final e = mapSmbConnectError(SmbException(
          'This client is not compatible with the server.'), 'SMB 连接失败');
      expect(e, isA<SmbStatusException>());
      expect(e.toString(), contains('SMB 方言'));
    });

    test('SmbException.toString 返回 message（不再 Instance of）', () {
      expect(SmbException('Not supported').toString(), 'Not supported');
    });

    test('smb_connect：NOT_FOUND → StateError', () {
      final e = mapSmbConnectError(
          StateError('NT_STATUS_OBJECT_NAME_NOT_FOUND'), 'SMB 读取');
      expect(e, isA<StateError>());
    });

    test('smb_connect：未知错误 → SmbStatusException（toString 无堆栈）', () {
      final e = mapSmbConnectError(Exception('boom'), 'SMB 读取');
      expect(e, isA<SmbStatusException>());
      expect(e.toString(), contains('SMB 读取'));
    });

    test('SmbStatusException toString 即消息', () {
      expect(const SmbStatusException('连不上').toString(), '连不上');
    });
  });

  group('SMB 弹窗「路径」一字段（拆共享名/根目录）', () {
    test('smbParseInputPath：首个斜杠前为共享名，其余为根目录', () {
      expect((smbParseInputPath('Music/jaychou').share), 'Music');
      expect((smbParseInputPath('Music/jaychou').rootPath), 'jaychou');
      // 无斜杠：整串为共享名，根目录为空（=共享根）。
      expect((smbParseInputPath('Music').share), 'Music');
      expect((smbParseInputPath('Music').rootPath), '');
      expect((smbParseInputPath('').share), '');
      // 多段根目录 / 斜杠容错 / 穿越段过滤（与运行期同口径）。
      final c = smbParseInputPath('/Music//jaychou/2000/');
      expect((c.share, c.rootPath), ('Music', 'jaychou/2000'));
      final d = smbParseInputPath(r'Music\jaychou');
      expect((d.share, d.rootPath), ('Music', 'jaychou'));
      expect((smbParseInputPath('Music/../etc').rootPath), 'etc');
    });

    test('smbJoinInputPath：编辑回填（无根目录只有共享名）', () {
      expect(smbJoinInputPath(share: 'Music', rootPath: 'jaychou'),
          'Music/jaychou');
      expect(smbJoinInputPath(share: 'Music', rootPath: ''), 'Music');
      expect(smbJoinInputPath(share: '', rootPath: ''), '');
    });

    test('往返一致：parse(join(x)) == x；join(parse(s)) == 规范化 s', () {
      final a = smbParseInputPath(
          smbJoinInputPath(share: 'Music', rootPath: 'jaychou/2000'));
      expect((a.share, a.rootPath), ('Music', 'jaychou/2000'));
      expect(smbJoinInputPath(
              share: smbParseInputPath('Music/jaychou').share,
              rootPath: smbParseInputPath('Music/jaychou').rootPath),
          'Music/jaychou');
    });

    test('回归：walk 折前缀后的 ref 拼回不产生双重前缀', () {
      // 病态（修复前）：walk 返回共享相对 "jaychou/可爱女人.flac"，
      // 播放/展示再拼 rootPath → `\\host\share\jaychou\jaychou\可爱女人.flac`。
      const rootPath = 'jaychou';
      final ref = smbRelRef(rootPath, 'jaychou/可爱女人.flac');
      expect(ref, '可爱女人.flac');
      expect(smbRemotePath(rootPath, ref), 'jaychou/可爱女人.flac');
    });
  });

  group('SMB 同步地址（既有口径回归）', () {
    test('sourceAddressOf smb = host/share；smb 参与同步', () {
      expect(sourceAddressOf('smb', {'host': 'nas', 'share': 'music'}),
          'nas/music');
      expect(isSyncableKind('smb'), isTrue);
    });
  });

  group('SMB 写守卫（与 WebDAV/SFTP 同口径）', () {
    test('smbGuardWriteName：禁分隔符与穿越', () {
      smbGuardWriteName('a flac 01.mp3');
      expect(() => smbGuardWriteName(''), throwsStateError);
      expect(() => smbGuardWriteName('a/b.mp3'), throwsStateError);
      expect(() => smbGuardWriteName(r'a\b.mp3'), throwsStateError);
      expect(() => smbGuardWriteName('..'), throwsStateError);
      expect(() => smbGuardWriteName('a..b'), throwsStateError);
    });

    test('smbGuardWriteParent：各段禁 ./..', () {
      smbGuardWriteParent('');
      smbGuardWriteParent('music/flac');
      expect(() => smbGuardWriteParent('../etc'), throwsStateError);
      expect(() => smbGuardWriteParent('a/./b'), throwsStateError);
    });
  });
}
