import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/sftp_direct_source.dart';

void main() {
  group('SFTP 写守卫（与 WebDAV 同口径）', () {
    test('sftpGuardWriteName：禁分隔符与穿越', () {
      sftpGuardWriteName('a flac 01.mp3');
      expect(() => sftpGuardWriteName(''), throwsStateError);
      expect(() => sftpGuardWriteName('a/b.mp3'), throwsStateError);
      expect(() => sftpGuardWriteName(r'a\b.mp3'), throwsStateError);
      expect(() => sftpGuardWriteName('..'), throwsStateError);
      expect(() => sftpGuardWriteName('a..b'), throwsStateError);
    });

    test('sftpGuardWriteParent：各段禁 ./..', () {
      sftpGuardWriteParent('');
      sftpGuardWriteParent('music/flac');
      expect(() => sftpGuardWriteParent('../etc'), throwsStateError);
      expect(() => sftpGuardWriteParent('a/./b'), throwsStateError);
    });
  });

  group('SFTP 写开关', () {
    test('supportsWrite 为 true（看齐 WebDAV）', () {
      final sftp = SftpDirectSource(
          name: 'n', host: 'h', index: LocalIndex());
      expect(sftp.supportsWrite, isTrue);
      expect(sftp.supportsDirect, isTrue);
    });
  });
}
