import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/data/sources/smb_common.dart';
import 'package:selfmusic/data/sources/smb_connect_backend.dart';

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
    test('smb_connect：LOGON_FAILURE → SourceAuthException', () {
      final e = mapSmbConnectError(
          StateError('NT_STATUS_LOGON_FAILURE'), 'SMB 读取');
      expect(e, isA<SourceAuthException>());
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
