import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:sqlite3/open.dart';

/// 播放器构造时机（改进.txt：播放设置冷启动不生效）。
///
/// 之前 PlayerProvider 构造时就建 AudioPlayer，而设置是构造之后才注入的，
/// 于是音频焦点/均衡器只能读到默认值——「忽略音频焦点」必须进设置页手动切一次
/// 开关才真正生效。

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

void main() {
  late Directory dir;
  late LocalIndex index;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_audiocfg_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
  });

  tearDown(() {
    index.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('设置注入前不建播放器；建时读到的就是真实设置', (tester) async {
    final settings = AppSettings(index)..audioFocusEnabled = false;
    final p = PlayerProvider();
    expect(p.debugPlayerBuilt, isFalse, reason: '构造器不应建播放器');

    p.attachAppSettings(settings);
    expect(p.debugPlayerBuilt, isFalse, reason: '注入设置也不该建');

    // 首次使用才构造，且此刻设置已就位：套用用户选的「忽略音频焦点」。
    expect(p.player.playing, isFalse);
    expect(p.debugBuiltAudioFocus, isFalse);
  });

  testWidgets('播放器已建但设置后注入且与构造时不同 → 立即重建', (tester) async {
    final p = PlayerProvider();
    final first = p.player; // 此刻还没设置，按默认（音频焦点开）建
    expect(p.debugBuiltAudioFocus, isTrue);

    p.attachAppSettings(AppSettings(index)..audioFocusEnabled = false);
    expect(identical(p.player, first), isFalse, reason: '应重建播放器');
    expect(p.debugBuiltAudioFocus, isFalse);
  });

  testWidgets('设置与构造时一致 → 不重建', (tester) async {
    final p = PlayerProvider();
    final first = p.player;
    p.attachAppSettings(AppSettings(index)); // 默认音频焦点开 = 构造时的值
    expect(identical(p.player, first), isTrue);
  });
}
