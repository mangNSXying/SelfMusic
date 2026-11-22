import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/db_writer.dart';

/// 源配置合并回归：
///
/// 同步落库旧实现是「远端 config 整份覆盖」，会让本机备用线路（fallbacks）
/// 与凭据配置被对端旧快照抹掉——表现正是“某段时间后备源消失、切线路
/// 没有候选”。这里锁定合并规则。
void main() {
  test('远端缺失 fallbacks 时保留本机备用线路', () {
    final local = <String, dynamic>{
      'name': 'NAS',
      'baseUrl': 'https://dav.example.com',
      'fallbacks': [
        {'kind': 'webdav', 'baseUrl': 'https://backup.example.com'},
      ],
    };
    final remote = <String, dynamic>{
      'name': 'NAS',
      'baseUrl': 'https://dav.example.com',
    };

    final merged = mergeSourceConfig(local: local, remote: remote);
    expect(merged['fallbacks'], isNotNull);
    expect((merged['fallbacks'] as List), hasLength(1));
  });

  test('远端给了新 fallbacks 时以远端为准，但保留本机多余槽位', () {
    final local = <String, dynamic>{
      'fallbacks': [
        {'kind': 'webdav', 'baseUrl': 'https://a.example.com'},
        {'kind': 'sftp', 'host': 'b.example.com'},
      ],
    };
    final remote = <String, dynamic>{
      'fallbacks': [
        {'kind': 'webdav', 'baseUrl': 'https://a2.example.com'},
      ],
    };

    final merged = mergeSourceConfig(local: local, remote: remote);
    final list = merged['fallbacks'] as List;
    expect(list, hasLength(2), reason: '远端只给 1 个槽位时不得抹掉本机第 2 个');
    expect((list[0] as Map)['baseUrl'], 'https://a2.example.com',
        reason: '远端存在的槽位以远端为准');
    expect((list[1] as Map)['host'], 'b.example.com');
  });

  test('远端空密码不覆盖本机已有密码', () {
    final local = <String, dynamic>{'password': 'secret', 'username': 'u'};
    final remote = <String, dynamic>{'password': '', 'username': 'u'};

    final merged = mergeSourceConfig(local: local, remote: remote);
    expect(merged['password'], 'secret');
  });

  test('远端缺失密码时保留本机密码', () {
    final local = <String, dynamic>{'password': 'secret'};
    final remote = <String, dynamic>{'username': 'u'};

    final merged = mergeSourceConfig(local: local, remote: remote);
    expect(merged['password'], 'secret');
  });

  test('远端新密码可覆盖本机旧密码', () {
    final local = <String, dynamic>{'password': 'old'};
    final remote = <String, dynamic>{'password': 'new'};

    final merged = mergeSourceConfig(local: local, remote: remote);
    expect(merged['password'], 'new');
  });

  test('普通字段以远端为准', () {
    final local = <String, dynamic>{'baseUrl': 'https://old', 'name': 'A'};
    final remote = <String, dynamic>{'baseUrl': 'https://new'};

    final merged = mergeSourceConfig(local: local, remote: remote);
    expect(merged['baseUrl'], 'https://new');
    expect(merged['name'], 'A', reason: '远端未提供的键保留本机值');
  });
}
