import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'music_source.dart';
import 'sftp_common.dart';

/// 旧路径：SSH/SFTP 连接与纯 Dart 解密全部在当前 isolate（通常是 UI
/// isolate）。保留它作为 worker 启动失败自动降级与编译期开关
/// （`SFTP_WORKER_DIRECT=true`）的降级目标。
///
/// 注意：这里的 `maxPendingRequests: 1` / 16KB 块只把单次同步块压小，**没有
/// 把解密移出 UI isolate**；worker 路径才是根治。
class SftpDirectTransport implements SftpTransport {
  final String host;
  final int port;
  final String username;
  final SftpAuthMethod authMethod;
  final String password;
  final String keyPem;
  final String keyPassphrase;
  final String pinnedFp;

  SftpDirectTransport({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    required this.password,
    required this.keyPem,
    required this.keyPassphrase,
    required this.pinnedFp,
  });

  SSHClient? _client;
  SftpClient? _sftp;

  /// 共享连接（懒建连；操作失败疑似掉线时重建一次再试）。
  Future<SftpClient> _sftpClient() async {
    Future<SftpClient> connect() async {
      await close();
      final opened = await SftpConnection.open(
        host: host,
        port: port,
        username: username,
        authMethod: authMethod,
        password: password,
        keyPem: keyPem,
        keyPassphrase: keyPassphrase,
        pinnedFp: pinnedFp,
      );
      _client = opened.client;
      _sftp = opened.sftp;
      return opened.sftp;
    }

    final cur = _sftp;
    if (cur != null) return cur;
    try {
      return await connect();
    } on SourceAuthException {
      rethrow;
    } on StateError {
      rethrow;
    } on SshHostKeyMismatch {
      rethrow;
    } catch (e) {
      throw SftpStatusException(shortSftpError(e, 'SFTP 连接失败'));
    }
  }

  /// 疑似掉线时重建一次再试（鉴权/指纹类错误直接抛，不重试）。
  ///
  /// **业务性状态错误不重连**（2026-10-11 真机取证）：同目录图片回退会逐个
  /// open 不存在的候选路径，服务端回 `SftpStatusCode.noSuchFile`——这是正常
  /// 探测结果而非掉线；旧实现对任何异常都 `close()` + 重连，每个候选白付一次
  /// SSH 握手（纯 Dart KEX/验签跑在主线程，实测单次 ~600ms stall，一首无内嵌
  /// 封面的歌最多 11 个候选 → 5~7s 连续卡顿的主要来源）。只有连接类状态错误
  /// （noConnection / connectionLost）与未知异常才走重建。
  Future<T> _withSftp<T>(Future<T> Function(SftpClient sftp) fn) async {
    try {
      return await fn(await _sftpClient());
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noConnection ||
          e.code == SftpStatusCode.connectionLost) {
        return _reconnectAndRetry(fn);
      }
      throw SftpStatusException(shortSftpError(e, 'SFTP 请求失败'), code: e.code);
    } on SourceAuthException {
      rethrow;
    } on StateError {
      rethrow;
    } on SshHostKeyMismatch {
      rethrow;
    } catch (_) {
      return _reconnectAndRetry(fn);
    }
  }

  /// 重建连接后重试一次；鉴权/指纹类错误直接抛（重连也无意义）。
  Future<T> _reconnectAndRetry<T>(
      Future<T> Function(SftpClient sftp) fn) async {
    await close();
    try {
      return await fn(await _sftpClient());
    } on SftpStatusError catch (e) {
      throw SftpStatusException(shortSftpError(e, 'SFTP 请求失败'), code: e.code);
    } catch (e) {
      if (e is SourceAuthException ||
          e is StateError ||
          e is SshHostKeyMismatch) {
        rethrow;
      }
      throw SftpStatusException(shortSftpError(e, 'SFTP 请求失败'));
    }
  }

  @override
  Future<void> probe(String path) async {
    await _withSftp((sftp) async {
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      try {
        await file.read(length: 1, offset: 0).first;
      } finally {
        try {
          await file.close();
        } catch (_) {}
      }
    });
  }

  @override
  Future<SftpOpenResult> open(
    String path, {
    int? start,
    int? length,
    int fallbackTotal = 0,
  }) {
    return _withSftp((sftp) async {
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      int total;
      try {
        total = (await file.stat()).size ?? fallbackTotal;
      } catch (_) {
        // stat 失败回退索引大小（可能为 0，即未知）。
        total = fallbackTotal;
      }
      final begin = start ?? 0;
      int? endExclusive;
      if (length != null) {
        endExclusive = begin + length;
        if (total > 0 && endExclusive > total) endExclusive = total;
      } else if (total > 0) {
        endExclusive = total;
      }
      final contentLength = endExclusive == null
          ? 0
          : (endExclusive - begin < 0 ? 0 : endExclusive - begin);
      // 主线程让出纪律（2026-10-11 真机取证）：dartssh2 的纯 Dart AES-GCM 解密
      // 跑在 UI isolate；`read()` 默认 64 并发 × 16KB 扇出会把整段 Range（补读
      // 可达 16MB）灌成一条微任务链，实测单次同步块 9~11s（THREAD_BLOCK_6S 强杀
      // 与全局卡顿的直接来源，冻结堆栈：SSHTransport._consumeAeadPacket →
      // pointycastle GCMBlockCipher）。限「单请求在飞 + 64KB 块」后，解密与网络
      // 事件交替推进，单次同步块收敛到几十 ms；LAN 吞吐仍受解密速率上限约束，
      // 不额外损失。**勿放开 maxPendingRequests**，除非把解密移出 UI isolate。
      final src = file.read(
        length: contentLength <= 0 ? null : contentLength,
        offset: begin,
        chunkSize: 16 * 1024,
        maxPendingRequests: 1,
      );
      // 句柄随流走：结束/出错/取消都关（seek 取消不留服务器句柄）。
      var closed = false;
      Future<void> closeFile() async {
        if (closed) return;
        closed = true;
        try {
          await file.close();
        } catch (_) {}
      }

      late final StreamController<List<int>> controller;
      late StreamSubscription<Uint8List> sub;
      controller = StreamController<List<int>>(
        onListen: () {
          sub = src.listen(
            controller.add,
            onError: (Object e) async {
              controller.addError(e);
              await controller.close();
              await closeFile();
            },
            onDone: () async {
              await controller.close();
              await closeFile();
            },
            cancelOnError: false,
          );
        },
        onCancel: () async {
          await sub.cancel();
          await closeFile();
        },
      );
      return SftpOpenResult(
        contentLength: contentLength,
        totalLength: total > 0 ? total : null,
        stream: controller.stream,
      );
    });
  }

  @override
  Future<void> upload(String path, Stream<List<int>> bytes, int length) async {
    await _withSftp((sftp) async {
      SftpFile? file;
      try {
        file = await sftp.open(
          path,
          mode: SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate,
        );
        final writer = file.write(
          bytes.map((c) => c is Uint8List ? c : Uint8List.fromList(c)),
        );
        await writer.done;
      } finally {
        try {
          await file?.close();
        } catch (_) {}
      }
    });
  }

  @override
  Future<void> remove(String path) async {
    await _withSftp((sftp) => sftp.remove(path));
  }

  @override
  Future<void> mkdir(String path) async {
    await _withSftp((sftp) => sftp.mkdir(path));
  }

  @override
  Future<bool> isDirectory(String path) async {
    return _withSftp((sftp) async => (await sftp.stat(path)).isDirectory);
  }

  @override
  Future<void> close() async {
    try {
      await _sftp?.close();
    } catch (_) {}
    try {
      _client?.close();
    } catch (_) {}
    _sftp = null;
    _client = null;
  }
}
