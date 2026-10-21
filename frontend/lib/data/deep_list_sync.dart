import 'dart:convert';

/// 断点深层列表同步的纯函数（客户端侧，与服务端 `SyncService` 合并口径镜像）。
///
/// 深层列表元素只为身份 `{source, source_ref}`；匹配以 `source_ref` 为准，
/// 与服务端及客户端镜像恢复（`_deepListFromMirror`）一致。
typedef DeepEntry = Map<String, dynamic>;

/// 解析任意来源（JSON 字符串/List）为去坏行的深层身份列表。
List<DeepEntry> parseDeepEntries(dynamic raw) {
  dynamic decoded = raw;
  if (raw is String) {
    if (raw.isEmpty) return const [];
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
  }
  if (decoded is! List) return const [];
  final out = <DeepEntry>[];
  for (final e in decoded) {
    if (e is! Map) continue;
    final ref = e['source_ref'];
    if (ref is! String || ref.isEmpty) continue;
    final m = <String, dynamic>{'source_ref': ref};
    final source = e['source'];
    if (source is String && source.isNotEmpty) m['source'] = source;
    out.add(m);
  }
  return out;
}

String? deepEntryRef(DeepEntry e) {
  final ref = e['source_ref'];
  return ref is String && ref.isNotEmpty ? ref : null;
}

List<String> deepEntryRefs(List<DeepEntry> list) => [
      for (final e in list)
        if (deepEntryRef(e) != null) deepEntryRef(e)!,
    ];

bool sameDeepList(List<DeepEntry> a, List<DeepEntry> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (deepEntryRef(a[i]) != deepEntryRef(b[i])) return false;
  }
  return true;
}

/// base 是否为 full 的前缀（按 source_ref 顺序）。
bool deepListStartsWith(List<DeepEntry> base, List<DeepEntry> full) {
  if (base.length > full.length) return false;
  for (var i = 0; i < base.length; i++) {
    if (deepEntryRef(base[i]) != deepEntryRef(full[i])) return false;
  }
  return true;
}

/// 去重保留最后出现项（最近播放在尾部），再按容量从头部裁剪。
List<DeepEntry> dedupeDeepEntries(List<DeepEntry> list, int capacity) {
  final byRef = <String, DeepEntry>{};
  for (final e in list) {
    final ref = deepEntryRef(e);
    if (ref == null) continue;
    byRef.remove(ref);
    byRef[ref] = e;
  }
  final out = byRef.values.toList();
  if (capacity > 0 && out.length > capacity) {
    return out.sublist(out.length - capacity);
  }
  if (capacity <= 0) return const [];
  return out;
}

/// 纯追加：服务端当前分支 + 设备新增后缀。
List<DeepEntry> appendDeepAdded(
    List<DeepEntry> server, List<DeepEntry> added, int capacity) {
  return dedupeDeepEntries([...server, ...added], capacity);
}

/// 三向列表合并：C=最长公共前缀，result=C + server[C:] + device[C:]。
///
/// 快路径与服务端一致：server==base → 设备分支胜（pop/replace/clear）；
/// device==base → 服务端分支胜（本设备没改历史）；server==device → 收敛。
List<DeepEntry> mergeDeepLists({
  required List<DeepEntry> base,
  required List<DeepEntry> server,
  required List<DeepEntry> device,
  required int capacity,
}) {
  if (sameDeepList(server, base)) {
    return dedupeDeepEntries(device, capacity);
  }
  if (sameDeepList(device, base)) {
    return dedupeDeepEntries(server, capacity);
  }
  if (sameDeepList(server, device)) {
    return dedupeDeepEntries(server, capacity);
  }
  final bk = deepEntryRefs(base);
  final sk = deepEntryRefs(server);
  final dk = deepEntryRefs(device);
  final max = [bk.length, sk.length, dk.length].reduce((a, b) => a < b ? a : b);
  var c = 0;
  while (c < max && bk[c] == sk[c] && bk[c] == dk[c]) {
    c++;
  }
  return dedupeDeepEntries([
    ...base.sublist(0, c),
    ...server.sublist(c),
    ...device.sublist(c),
  ], capacity);
}
