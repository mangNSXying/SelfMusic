import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/backoff.dart';
import 'package:selfmusic/utils/duration_format.dart';
import 'package:selfmusic/utils/enum_parse.dart';
import 'package:selfmusic/utils/format_bytes.dart';
import 'package:selfmusic/utils/log_throttle.dart';
import 'package:selfmusic/utils/media_kinds.dart';
import 'package:selfmusic/utils/single_flight.dart';
import 'package:selfmusic/utils/song_key.dart';
import 'package:selfmusic/utils/source_ref.dart';

enum _Sample { alpha, beta }

void main() {
  group('media_kinds', () {
    test('音频后缀不区分大小写', () {
      expect(isAudioFileName('A.FLAC'), isTrue);
      expect(isAudioFileName('a.b.mp3'), isTrue);
      expect(isAudioFileName('a.lrc'), isFalse);
      expect(isAudioFileName('mp3'), isFalse);
    });

    test('扩展名与 MIME', () {
      expect(audioExtOf('dir/a.MP3'), 'mp3');
      expect(audioExtOf('noext'), '');
      expect(audioMimeOf('flac'), 'audio/flac');
      expect(audioMimeOf('m4a'), 'audio/mp4');
      expect(audioMimeOf('aifc'), 'audio/aiff');
      expect(audioMimeOf('unknown'), 'audio/mpeg');
    });
  });

  group('source_ref', () {
    test('父目录/文件名', () {
      expect(refParent('a/b/c.mp3'), 'a/b');
      expect(refParent('c.mp3'), '');
      expect(refParent(''), '');
      expect(refLeaf('a/b/c.mp3'), 'c.mp3');
      expect(refLeaf('c.mp3'), 'c.mp3');
    });

    test('去扩展名', () {
      expect(refStem('a/b/c.mp3'), 'c');
      expect(refStem('a/b/.hidden'), '.hidden');
      expect(refStem('a/b/c'), 'c');
      expect(refStemPath('a/b/c.mp3'), 'a/b/c');
      expect(refStemPath('a/b/c'), 'a/b/c');
      expect(refStemPathOrNull('a/b/c.mp3'), 'a/b/c');
      expect(refStemPathOrNull('a/b/c'), isNull);
      expect(refStemPathOrNull('a/b/.hidden'), isNull);
    });
  });

  group('song_key', () {
    test('身份键与 Song.uid 同口径', () {
      expect(songKeyOf('smb:nas', 'a/b.flac'), 'smb:nas\u0000a/b.flac');
      final song = Song.direct(
        id: 1,
        sourceKey: 'smb:nas',
        title: 't',
        source: 'smb',
        sourceRef: 'a/b.flac',
        fileSize: 1,
        format: 'flac',
      );
      expect(song.uid, songKeyOf('smb:nas', 'a/b.flac'));
    });
  });

  group('format_bytes', () {
    test('默认 KB/MB/GB 梯度', () {
      expect(formatBytes(0), '0 KB');
      expect(formatBytes(512), '1 KB');
      expect(formatBytes(1536), '2 KB');
      expect(formatBytes(1536, mbDecimals: 1), '2 KB');
      expect(formatBytes(1024 * 1024, mbDecimals: 1), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(
        formatBytes(2 * 1024 * 1024 * 1024, mbDecimals: 1, useGb: false),
        '2048.0 MB',
      );
    });

    test('minUnit 与 B 档', () {
      expect(formatBytes(10, minUnit: ByteUnit.mb), '0 MB');
      expect(formatBytes(512, minUnit: ByteUnit.b), '512 B');
      expect(formatBytes(1536, minUnit: ByteUnit.b, kbDecimals: 1), '1.5 KB');
      expect(formatBytes(-1, zero: '大小未知'), '大小未知');
    });
  });

  group('duration_format', () {
    test('时长梯度与分钟补零', () {
      expect(formatDuration(null), '');
      expect(formatDuration(0), '');
      expect(formatDuration(65), '01:05');
      expect(formatDuration(3665), '1:01:05');
      expect(formatDuration(65, padMinutes: false), '1:05');
      expect(formatDurationMs(65999), '01:05');
      expect(formatDurationMs(0, empty: '00:00'), '00:00');
    });

    test('时刻格式化', () {
      expect(formatHourMinute(9, 5), '09:05');
      expect(formatClockTime(DateTime(2026, 1, 1, 9, 5)), '09:05');
      expect(
          formatLogTimestamp(DateTime(2026, 1, 1, 9, 5, 6, 7)), '09:05:06.007');
    });
  });

  group('enum_parse', () {
    test('命中/未命中/非字符串', () {
      expect(enumByNameOrNull(_Sample.values, 'beta'), _Sample.beta);
      expect(enumByNameOrNull(_Sample.values, 'nope'), isNull);
      expect(enumByNameOrNull(_Sample.values, 1), isNull);
      expect(
          enumByNameOr(_Sample.values, 'nope', _Sample.alpha), _Sample.alpha);
    });
  });

  group('backoff', () {
    test('Retry-After 解析', () {
      expect(parseRetryAfter(' 5 '), const Duration(seconds: 5));
      expect(parseRetryAfter('0'), Duration.zero);
      expect(parseRetryAfter('-1'), isNull);
      expect(parseRetryAfter('abc'), isNull);
      expect(parseRetryAfter(null), isNull);
    });

    test('指数退避封顶', () {
      expect(exponentialBackoff(0), const Duration(seconds: 1));
      expect(exponentialBackoff(3), const Duration(seconds: 8));
      expect(exponentialBackoff(10), const Duration(seconds: 30));
      expect(
        exponentialBackoff(2,
            base: const Duration(seconds: 10),
            cap: const Duration(seconds: 30)),
        const Duration(seconds: 30),
      );
    });
  });

  group('log_throttle', () {
    test('同因去重直到 reset', () {
      final t = LogThrottle(sameReasonOnly: true);
      expect(t.shouldLog('a'), isTrue);
      expect(t.shouldLog('a'), isFalse);
      expect(t.shouldLog('b'), isTrue);
      t.reset();
      expect(t.shouldLog('b'), isTrue);
    });

    test('时间窗内任意原因只放行一条', () {
      final t = LogThrottle(window: const Duration(seconds: 60));
      expect(t.shouldLog('a'), isTrue);
      expect(t.shouldLog('b'), isFalse);
      final zero = LogThrottle(window: Duration.zero);
      expect(zero.shouldLog('a'), isTrue);
      expect(zero.shouldLog('b'), isTrue);
    });
  });

  group('single_flight', () {
    test('并发触发只跑一份并补跑 dirty', () async {
      final sf = SingleFlight();
      final gate = Completer<void>();
      var runs = 0;
      sf.run(() async {
        runs++;
        await gate.future;
      });
      sf.run(() async {
        runs++;
        await gate.future;
      });
      expect(runs, 1);
      gate.complete();
      await pumpEventQueue();
      expect(runs, 2);
      expect(sf.isRunning, isFalse);
    });
  });
}
