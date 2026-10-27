import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/online_music/online_music_models.dart';
import 'package:selfmusic/services/online_music/online_music_service.dart';

void main() {
  test('normalizeBaseUrl adds scheme and trims slashes', () {
    expect(OnlineMusicService.normalizeBaseUrl('192.168.1.2:18090'),
        'http://192.168.1.2:18090');
    expect(OnlineMusicService.normalizeBaseUrl('https://host/online//'),
        'https://host/online');
    expect(OnlineMusicService.normalizeBaseUrl('  '), '');
  });

  test('OnlineTrack parses sidecar payload', () {
    final track = OnlineTrack.fromJson({
      'track_token': 't1',
      'source': 'QQMusicClient',
      'source_label': 'QQ音乐',
      'title': '晴天',
      'artist': '周杰伦',
      'album': '叶惠美',
      'duration_s': 269,
      'ext': 'flac',
      'size_bytes': 178320000,
      'lossless': true,
      'has_lyric': true,
    });
    expect(track.token, 't1');
    expect(track.lossless, isTrue);
    expect(track.sizeBytes, 178320000);
  });

  test('OnlineFetchJob parses status', () {
    final job = OnlineFetchJob.fromJson({
      'job_id': 'j1',
      'status': 'ready',
      'progress': 1,
      'filename': '晴天 - 周杰伦.flac',
      'ext': 'flac',
      'size_bytes': 1024,
      'has_lyric': true,
    });
    expect(job.isReady, isTrue);
    expect(job.isError, isFalse);
    expect(job.filename, '晴天 - 周杰伦.flac');
  });

  test('SSE parser emits sidecar search events', () async {
    const sse = 'retry: 10000\n\n'
        'event: source_start\n'
        'data: {"source":"QQMusicClient","source_label":"QQ音乐"}\n\n'
        'event: result\n'
        'data: {"track_token":"t1","source":"QQMusicClient",'
        '"source_label":"QQ音乐","title":"晴天","artist":"周杰伦",'
        '"album":"叶惠美","duration_s":269,"ext":"flac",'
        '"size_bytes":178320000,"lossless":true,"has_lyric":true}\n\n'
        'event: source_done\n'
        'data: {"source":"QQMusicClient","count":1,"timed_out":false}\n\n'
        'event: done\n'
        'data: {"count":1}\n\n';
    final events = await OnlineMusicService.parseSseStream(
      Stream<List<int>>.value(utf8.encode(sse)),
    ).toList();
    expect(events.length, 4);
    expect(events[0], isA<OnlineSourceStart>());
    expect(events[1], isA<OnlineTrackEvent>());
    expect((events[1] as OnlineTrackEvent).track.title, '晴天');
    expect(events[2], isA<OnlineSourceDone>());
    expect(events[3], isA<OnlineSearchDone>());
  });
}
