import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/services/online_meta/netease_provider.dart';
import 'package:selfmusic/services/online_meta/online_meta_service.dart';
import 'package:selfmusic/services/online_meta/qq_provider.dart';
import 'package:sqlite3/open.dart';

DynamicLibrary _openSqlite() {
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

/// 按 `host+path` 路由的假网络层（JSON 走对象，图片走字节）。
class _FakeOnlineAdapter implements HttpClientAdapter {
  final Map<String, Object> routes;
  _FakeOnlineAdapter(this.routes);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final uri = options.uri;
    final body = routes['${uri.host}${uri.path}'];
    if (body == null) {
      return ResponseBody.fromString('{"code":404}', 404, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
    if (body is Uint8List) {
      return ResponseBody.fromBytes(body, 200, headers: {
        Headers.contentTypeHeader: ['image/jpeg'],
      });
    }
    if (body is String) {
      // 现实 QQ 口径：JSON 正文但 Content-Type 非 JSON（x-javascript/plain）。
      return ResponseBody.fromString(body, 200, headers: {
        Headers.contentTypeHeader: ['application/x-javascript;charset=utf-8'],
      });
    }
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioOf(Map<String, Object> routes) {
  final dio = Dio();
  dio.httpClientAdapter = _FakeOnlineAdapter(routes);
  return dio;
}

/// 最小 JPEG（SOI + JFIF 头 + EOI，12 字节，刚好过轻量头尾校验）。
Uint8List _miniJpeg() => Uint8List.fromList(
    [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9]);

/// QQ 主搜索口（search_for_qq_cp）路由体。
Map<String, Object> _qqSearchLegacy() => {
      'c.y.qq.com/soso/fcgi-bin/search_for_qq_cp': {
        'code': 0,
        'data': {
          'song': {
            'list': [
              {
                'songname': '海阔天空',
                'songmid': '001p7ZZ83R1M9z',
                'albumname': '海阔天空',
                'albummid': '002qvqEU1EU9CJ',
                'interval': 326,
                'singer': [
                  {'name': 'Beyond'}
                ],
              }
            ],
          }
        },
      },
    };

/// QQ musicu 备搜索口路由体（与 musicu 歌词同 host+path，勿同时挂）。
Map<String, Object> _qqSearchMusicu() => {
      'u.y.qq.com/cgi-bin/musicu.fcg': {
        'code': 0,
        'req': {
          'code': 0,
          'data': {
            'body': {
              'song': {
                'list': [
                  {
                    'mid': '001p7ZZ83R1M9z',
                    'name': '海阔天空',
                    'interval': 326,
                    'album': {'mid': '002qvqEU1EU9CJ', 'name': '海阔天空'},
                    'singer': [
                      {'name': 'Beyond'}
                    ],
                  }
                ],
              },
            },
          },
        },
      },
    };

/// QQ musicu 歌词路由体（lyric/trans 走 base64，同真实口径）。
Map<String, Object> _qqLyricMusicu({
  String lyric = '',
  String trans = '',
  int crypt = 0,
}) =>
    {
      'u.y.qq.com/cgi-bin/musicu.fcg': {
        'code': 0,
        'req': {
          'code': 0,
          'data': {
            'crypt': crypt,
            'lyric': lyric.isEmpty ? '' : base64.encode(utf8.encode(lyric)),
            'trans': trans.isEmpty ? '' : base64.encode(utf8.encode(trans)),
          },
        },
      },
    };

/// QQ 旧歌词口备胎路由体（nobase64=1：明文直出）。
Map<String, Object> _qqLyricLegacy({String lyric = '', String trans = ''}) => {
      'c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg': {
        'lyric': lyric,
        'trans': trans,
      },
    };

/// QQ 封面详情（album.mid）路由体。
Map<String, Object> _qqCoverDetail() => {
      'c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg': {
        'code': 0,
        'data': [
          {
            'album': {'mid': '002qvqEU1EU9CJ'}
          }
        ],
      },
    };

const String _qqCoverHostPath =
    'y.gtimg.cn/music/photo_new/T002R800x800M000002qvqEU1EU9CJ.jpg';

Map<String, Object> _qqCoverImage() => {_qqCoverHostPath: _miniJpeg()};

Map<String, Object> _neRoutes() => {
      'music.163.com/api/search/get/': {
        'code': 200,
        'result': {
          'songs': [
            {
              'id': 347230,
              'name': '海阔天空',
              'duration': 326000,
              'album': {'name': '海阔天空'},
              'artists': [
                {'name': 'Beyond'}
              ],
            }
          ],
          'songCount': 1,
        },
      },
      'music.163.com/api/song/lyric': {
        'code': 200,
        'lrc': {
          'lyric': '[00:18.466]今天我寒夜里看雪飘过\n',
        },
        'tlyric': {
          'lyric': 'test trans\n',
        },
      },
      'music.163.com/api/song/detail/': {
        'code': 200,
        'songs': [
          {
            'id': 347230,
            'album': {
              'name': '海阔天空',
              'picUrl': 'https://p2.music.126.net/xxx.jpg',
            }
          }
        ],
      },
      'p2.music.126.net/xxx.jpg': _miniJpeg(),
    };

Song _song() => Song.direct(
      id: 1,
      sourceKey: 'local:t',
      title: '海阔天空',
      artist: 'Beyond',
      albumName: '海阔天空',
      source: 'local',
      sourceRef: 'Beyond/海阔天空.mp3',
      fileSize: 1024,
      format: 'mp3',
      duration: 326,
    );

void main() {
  test('QQ 搜索：主口 search_for_qq_cp 解析', () async {
    final qq = QqProvider(dio: _dioOf(_qqSearchLegacy()));
    final list = await qq.searchTracks(title: '海阔天空', artist: 'Beyond');
    expect(list.length, 1);
    final c = list.first;
    expect(c.onlineId, '001p7ZZ83R1M9z');
    expect(c.trackName, '海阔天空');
    expect(c.artistName, 'Beyond');
    expect(c.albumName, '海阔天空');
    expect(c.durationSec, 326);
    // 搜索不带正文（懒取）。
    expect(c.hasContent, isFalse);
  });

  test('QQ 搜索：主口不可用自动换 musicu 备', () async {
    // 主口路由缺失 → 404 → 备胎接管。
    final qq = QqProvider(dio: _dioOf(_qqSearchMusicu()));
    final list = await qq.searchTracks(title: '海阔天空', artist: 'Beyond');
    expect(list.length, 1);
    expect(list.first.onlineId, '001p7ZZ83R1M9z');
    expect(list.first.durationSec, 326);
  });

  test('QQ 搜索：非 JSON Content-Type（x-javascript）手解一次', () async {
    final raw = jsonEncode(
        _qqSearchLegacy()['c.y.qq.com/soso/fcgi-bin/search_for_qq_cp']);
    final qq = QqProvider(
        dio: _dioOf({
      'c.y.qq.com/soso/fcgi-bin/search_for_qq_cp': raw,
    }));
    final list = await qq.searchTracks(title: '海阔天空', artist: 'Beyond');
    expect(list.length, 1);
    expect(list.first.onlineId, '001p7ZZ83R1M9z');
  });

  test('QQ 歌词：非 JSON Content-Type（text/plain）手解一次', () async {
    final raw = jsonEncode(_qqLyricMusicu(
        lyric: '[00:01.00]hi\n')['u.y.qq.com/cgi-bin/musicu.fcg']);
    final qq = QqProvider(
        dio: _dioOf({
      'u.y.qq.com/cgi-bin/musicu.fcg': raw,
    }));
    final r = await qq.fetchLyric('001p7ZZ83R1M9z');
    expect(r.syncedLyrics, contains('[00:01.00]hi'));
  });

  test('QQ 搜索：musicu 风控 2001 转中文错', () async {
    final qq = QqProvider(
        dio: _dioOf({
      'u.y.qq.com/cgi-bin/musicu.fcg': {
        'code': 0,
        'req': {'code': 2001, 'data': <String, Object>{}},
      },
    }));
    expect(
      () => qq.searchTracks(title: '海阔天空', artist: 'Beyond'),
      throwsA(isA<StateError>()),
    );
  });

  test('QQ 歌词：musicu base64 主路径（同步+译文）', () async {
    final qq = QqProvider(
        dio: _dioOf(_qqLyricMusicu(
            lyric: '[00:18.46]今天我寒夜里看雪飘过\n',
            trans: '[00:18.46]translation\n')));
    final r = await qq.fetchLyric('001p7ZZ83R1M9z');
    expect(r.syncedLyrics, contains('[00:18.46]今天我'));
    expect(r.plainLyrics, contains('translation'));
  });

  test('QQ 歌词：加密返回（crypt=1）回落旧接口', () async {
    final qq = QqProvider(
        dio: _dioOf({
      ..._qqLyricMusicu(lyric: '[00:01.00]garbled\n', crypt: 1),
      ..._qqLyricLegacy(lyric: '[00:02.00]fallback\n'),
    }));
    final r = await qq.fetchLyric('001p7ZZ83R1M9z');
    expect(r.syncedLyrics, contains('[00:02.00]fallback'));
  });

  test('QQ 歌词：主口失败回落旧接口（base64 自动解）', () async {
    final raw = base64.encode(utf8.encode('[00:01.00]hello\n'));
    final qq = QqProvider(dio: _dioOf(_qqLyricLegacy(lyric: raw)));
    final r = await qq.fetchLyric('001p7ZZ83R1M9z');
    expect(r.syncedLyrics, contains('[00:01.00]hello'));
  });

  test('QQ 封面：搜索缓存 albumMid 直连（免详情请求）', () async {
    // 只挂搜索口 + 图片口；若误走详情（2 步）会 404 抛错。
    final qq = QqProvider(
        dio: _dioOf({
      ..._qqSearchLegacy(),
      ..._qqCoverImage(),
    }));
    await qq.searchTracks(title: '海阔天空', artist: 'Beyond');
    final bytes = await qq.fetchCoverBytes('001p7ZZ83R1M9z');
    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(0));
  });

  test('QQ 封面：缓存未命中回落详情两步', () async {
    final qq = QqProvider(
        dio: _dioOf({
      ..._qqCoverDetail(),
      ..._qqCoverImage(),
    }));
    final bytes = await qq.fetchCoverBytes('001p7ZZ83R1M9z');
    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(0));
  });

  test('网易搜索解析：id/毫秒时长/多艺人拼接', () async {
    final ne = NeteaseProvider(dio: _dioOf(_neRoutes()));
    final list = await ne.searchTracks(title: '海阔天空', artist: 'Beyond');
    expect(list.length, 1);
    final c = list.first;
    expect(c.onlineId, '347230');
    expect(c.source, '网易云');
    expect(c.durationSec, 326.0);
    expect(c.artistName, 'Beyond');
  });

  test('网易歌词：lrc/tlyric 映射', () async {
    final ne = NeteaseProvider(dio: _dioOf(_neRoutes()));
    final r = await ne.fetchLyric('347230');
    expect(r.syncedLyrics, contains('[00:18.466]'));
    expect(r.plainLyrics, contains('test trans'));
  });

  test('网易反爬码（-460）转中文错', () async {
    final ne = NeteaseProvider(
        dio: _dioOf({
      'music.163.com/api/search/get/': {'code': -460},
    }));
    expect(
      () => ne.searchTracks(title: '海阔天空'),
      throwsA(isA<StateError>()),
    );
  });

  test('网易封面：picUrl 出字节', () async {
    final ne = NeteaseProvider(dio: _dioOf(_neRoutes()));
    final bytes = await ne.fetchCoverBytes('347230');
    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(0));
  });

  test('来源设置：默认值与解析', () async {
    open.overrideFor(OperatingSystem.linux, () => _openSqlite());
    final dir = await Directory.systemTemp.createTemp('selfmusic_src_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final settings = AppSettings(index);
    expect(settings.onlineMetaLyricSource, OnlineMetaLyricSource.lrclib);
    expect(settings.onlineMetaCoverSource, OnlineMetaCoverSource.mbCaa);
    settings.onlineMetaLyricSource = OnlineMetaLyricSource.qq;
    settings.onlineMetaCoverSource = OnlineMetaCoverSource.netease;
    expect(settings.onlineMetaLyricSource, OnlineMetaLyricSource.qq);
    expect(settings.onlineMetaCoverSource, OnlineMetaCoverSource.netease);
    expect(OnlineMetaLyricSource.parse('nope'), OnlineMetaLyricSource.lrclib);
    expect(OnlineMetaCoverSource.parse('nope'), OnlineMetaCoverSource.mbCaa);
    index.close();
    dir.deleteSync(recursive: true);
  });

  test('service 路由：QQ 歌词搜索+懒取+封面', () async {
    open.overrideFor(OperatingSystem.linux, () => _openSqlite());
    final dir = await Directory.systemTemp.createTemp('selfmusic_svcqq_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final settings = AppSettings(index);
    settings.onlineMetaLyricSource = OnlineMetaLyricSource.qq;
    settings.onlineMetaCoverSource = OnlineMetaCoverSource.qq;
    final svc = OnlineMetaService(
      index: index,
      settings: settings,
      qqProvider: QqProvider(
          dio: _dioOf({
        ..._qqSearchLegacy(),
        ..._qqLyricMusicu(
            lyric: '[00:18.46]今天我\n', trans: '[00:18.46]translation\n'),
        ..._qqCoverImage(),
      })),
    );
    final song = _song();
    final list = await svc.searchLyrics(song);
    expect(list.length, 1);
    expect(list.first.source, 'QQ音乐');
    expect(list.first.matchWeight, greaterThan(0));
    final full = await svc.ensureLyrics(list.first);
    expect(full.hasContent, isTrue);
    final tracks = await svc.searchCoverTracks(song);
    expect(tracks.length, 1);
    final cover = await svc.fetchTrackCover(tracks.first);
    expect(cover, isNotNull);
    expect(cover!.bytes.length, greaterThan(0));
    index.close();
    dir.deleteSync(recursive: true);
  });

  test('service 路由：网易歌词搜索+懒取+封面', () async {
    open.overrideFor(OperatingSystem.linux, () => _openSqlite());
    final dir = await Directory.systemTemp.createTemp('selfmusic_svcne_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final settings = AppSettings(index);
    settings.onlineMetaLyricSource = OnlineMetaLyricSource.netease;
    settings.onlineMetaCoverSource = OnlineMetaCoverSource.netease;
    final svc = OnlineMetaService(
      index: index,
      settings: settings,
      neteaseProvider: NeteaseProvider(dio: _dioOf(_neRoutes())),
    );
    final song = _song();
    final list = await svc.searchLyrics(song);
    expect(list.length, 1);
    expect(list.first.source, '网易云');
    final full = await svc.ensureLyrics(list.first);
    expect(full.saveContent, contains('[00:18.466]'));
    final cover = await svc.fetchTrackCover(list.first);
    expect(cover, isNotNull);
    index.close();
    dir.deleteSync(recursive: true);
  });
}
