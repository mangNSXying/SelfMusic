import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:sqlite3/open.dart';

/// 生命周期回调：退后台要把在途的本地累计结清、回前台要补写断点。
///
/// 关键背景：Android 上进程被杀时经常**根本不给 detached**（系统直接回收），
/// 原来只有 detached 分支，于是「退后台到被杀」这段之间攒的播放时长与断点
/// 全部丢失——用户下次打开发现少算了 listening time、位置也退回去了。
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalIndex index;
  late Directory tmp;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    tmp = Directory.systemTemp.createTempSync('selfmusic_lifecycle_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    index = LocalIndex();
    await index.open();
  });

  tearDown(() {
    index.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('无播放现场时退后台/回前台：不抛，也不构造播放器', () {
    final p = PlayerProvider();
    addTearDown(p.dispose);

    // 未 attachPersistence（_index 为 null）且队列为空：
    // 这两个回调必须安静返回，不能为了读 position 把 AudioPlayer 建出来。
    p.didChangeAppLifecycleState(AppLifecycleState.paused);
    p.didChangeAppLifecycleState(AppLifecycleState.hidden);
    p.didChangeAppLifecycleState(AppLifecycleState.resumed);
  });

  test('inactive（通知栏下拉/来电）不打断播放路径', () {
    final p = PlayerProvider();
    addTearDown(p.dispose);

    // inactive 前后都不该触发落库或停播——切后台继续播是本项目的主诉求。
    p.didChangeAppLifecycleState(AppLifecycleState.inactive);
  });

  test('退后台/回前台：结清写入，但不为读 position 白建播放器', () async {
    final p = PlayerProvider();
    addTearDown(p.dispose);
    p.attachPersistence(
      index: index,
      weight: SongWeightStore(index, serverAvailable: () => false),
    );

    expect(p.debugPlayerBuilt, isFalse);

    p.didChangeAppLifecycleState(AppLifecycleState.paused);
    p.didChangeAppLifecycleState(AppLifecycleState.resumed);
    // 回调是 fire-and-forget，等它把 flush 走完。
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // 没有播放现场时必须安静返回：写 _saveState(player.position) 会先求值
    // player.position，从而把 AudioPlayer 建出来——冷启动纯白做，且在无平台
    // 通道的环境里直接抛。
    expect(p.debugPlayerBuilt, isFalse,
        reason: '无播放现场不应为了读一次 position 而构造播放器');
  });

  test('dispose 后迟到回调被挡住，不抛', () async {
    final p = PlayerProvider();
    p.attachPersistence(
      index: index,
      weight: SongWeightStore(index, serverAvailable: () => false),
    );
    p.dispose();

    p.didChangeAppLifecycleState(AppLifecycleState.paused);
    p.didChangeAppLifecycleState(AppLifecycleState.resumed);
    p.didChangeAppLifecycleState(AppLifecycleState.detached);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
}