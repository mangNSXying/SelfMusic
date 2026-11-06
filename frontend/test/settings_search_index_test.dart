import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/screens/settings/settings_search_index.dart';
import 'package:selfmusic/theme/app_theme.dart';

void main() {
  test('旧名与别名命中', () {
    expect(searchSettings('应用内音量').first.label, '应用音量');
    expect(searchSettings('自签名').first.label, '信任自签名');
    expect(searchSettings('配对服务器').first.label, '配对服务端');
    expect(searchSettings('通知栏播放控制').first.label, '通知栏控制');
    expect(
      searchSettings('缓存上限').any((e) => e.label == '体积上限'),
      isTrue,
    );
  });

  test('多词全部命中', () {
    final results = searchSettings('播放 音量');
    expect(results, isNotEmpty);
    expect(results.every((e) => e.section == SettingsItem.playback), isTrue);
    expect(results.any((e) => e.label == '应用音量'), isTrue);
  });

  test('精确标签优先', () {
    expect(searchSettings('音量').first.label, '应用音量');
    expect(searchSettings('信任自签名').first.label, '信任自签名');
  });

  test('空词与无匹配返回空', () {
    expect(searchSettings(''), isEmpty);
    expect(searchSettings('   '), isEmpty);
    expect(searchSettings('zzzz-not-found'), isEmpty);
  });

  test('索引字段完整且目标使用分区前缀', () {
    for (final entry in settingsSearchEntries) {
      expect(entry.label, isNotEmpty);
      expect(entry.group, isNotEmpty);
      expect(entry.id, startsWith('${entry.section.name}/'));
    }
  });
}
