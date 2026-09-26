import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';

/// 装载重试与自动跳歌（改进.txt：切后台后还能播一两首，播完静默停住）。
///
/// 之前装载失败只弹一个 toast，既不重试也不跳下一首；just_audio 0.9.x 的平台
/// 错误又只从 playbackEventStream 的 onError 冒出来（此前无人监听），
/// 于是表现为「状态显示播放中、却没声音」。

Song _song() => Song(
      id: 0,
      sourceKey: 'webdav:d',
      title: '歌',
      source: 'webdav',
      sourceRef: 'a.mp3',
      fileSize: 0,
    );

class _FakeSource extends MusicSource {
  @override
  String get key => 'webdav:d';
  @override
  String get name => 'd';
  @override
  SourceKind get kind => SourceKind.webdav;
}

void main() {
  // AudioPlayer 构造时会碰 audio_session 的 MethodChannel，需要 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  final savedBackoff = PlayerProvider.loadBackoff;
  final src = _FakeSource();

  // 退避置零但保持与生产相同的档数（两次重试 = 三次尝试），测试不等真实时间。
  setUp(() => PlayerProvider.loadBackoff =
      const [Duration.zero, Duration.zero]);
  tearDown(() => PlayerProvider.loadBackoff = savedBackoff);

  test('生产退避是 1s/3s（两次重试，总共三次尝试）', () {
    expect(savedBackoff, const [Duration(seconds: 1), Duration(seconds: 3)]);
  });

  test('持续失败：重试到上限后抛出最后一个错误', () async {
    final p = PlayerProvider();
    var calls = 0;
    p.loadOverride = (s, source) async {
      calls++;
      throw PlayerException(1003, 'Source error', {'code': '404'});
    };

    await expectLater(
      p.debugLoadDirect(_song(), src, alive: () => true),
      throwsA(isA<PlayerException>()),
    );
    expect(calls, 3); // 首次 + 2 次退避重试
    p.dispose();
  });

  test('瞬时失败：重试后成功，不再抛错', () async {
    final p = PlayerProvider();
    var calls = 0;
    p.loadOverride = (s, source) async {
      calls++;
      if (calls < 3) throw PlayerException(1003, 'Source error');
    };

    await p.debugLoadDirect(_song(), src, alive: () => true);
    expect(calls, 3);
    p.dispose();
  });

  test('被更新的切歌接管（PlayerInterruptedException）不重试', () async {
    final p = PlayerProvider();
    var calls = 0;
    p.loadOverride = (s, source) async {
      calls++;
      throw PlayerInterruptedException('Audio source load interrupted');
    };

    await expectLater(
      p.debugLoadDirect(_song(), src, alive: () => true),
      throwsA(isA<PlayerInterruptedException>()),
    );
    expect(calls, 1);
    p.dispose();
  });

  test('令牌过期：立即放弃，不再触碰播放器', () async {
    final p = PlayerProvider();
    var calls = 0;
    p.loadOverride = (s, source) async {
      calls++;
      throw StateError('boom');
    };

    // alive 为假 → 一次都不尝试，且不抛错（由调用方的 alive 检查收尾）
    await p.debugLoadDirect(_song(), src, alive: () => false);
    expect(calls, 0);
    p.dispose();
  });

  test('重试途中令牌过期：不再发起下一次尝试', () async {
    final p = PlayerProvider();
    var calls = 0;
    var alive = true;
    p.loadOverride = (s, source) async {
      calls++;
      alive = false; // 模拟用户在这期间按了下一首
      throw StateError('boom');
    };

    await p.debugLoadDirect(_song(), src, alive: () => alive);
    expect(calls, 1); // 没有第二次重试
    p.dispose();
  });
}
