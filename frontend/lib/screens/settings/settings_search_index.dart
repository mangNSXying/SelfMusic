// 声明式索引：大量 const 可省，但条件项/目标函数调用使整表无法 const。
// ignore_for_file: prefer_const_constructors

import '../../platform/desktop_tray.dart';
import '../../theme/app_theme.dart';
import 'settings_focus.dart';

/// 设置搜索条目：标签 + 旧名/别名 + 目标锚点。
class SettingsSearchEntry {
  const SettingsSearchEntry({
    required this.section,
    required this.group,
    required this.label,
    this.aliases = const [],
    this.target,
    this.hint,
    this.visible,
  });

  final SettingsItem section;
  final String group;
  final String label;
  final List<String> aliases;

  /// 目标锚点；默认按「分区/标签」定位，条件项可指向父项。
  final String? target;

  /// 结果副标题里的补充说明（如“需先开启屏幕常亮”）。
  final String? hint;

  /// 平台/环境级可见性；条件项不隐藏，只给 hint。
  final bool Function()? visible;

  String get id => target ?? settingsAnchorId(section, label);
  bool get isVisible => visible?.call() ?? true;

  String get searchText => [
        label,
        group,
        section.label,
        ...aliases,
      ].join(' ').toLowerCase();
}

final List<SettingsSearchEntry> settingsSearchEntries = [
  // ── 界面 ──────────────────────────────────────────────────────────────
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '主题',
    label: '明暗模式',
    aliases: ['深色', '浅色', '跟随系统', '主题', '暗色'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '主题',
    label: '强调色',
    aliases: ['主题色', '配色', '颜色'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '主题',
    label: '背景色',
    aliases: ['背景', '底色'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '主题',
    label: '恢复默认',
    aliases: ['恢复默认主题', '重置主题', '重置'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '文字',
    label: '界面字体',
    aliases: ['字体', 'TTF', 'OTF', 'TTC', '自定义字体'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '文字',
    label: '歌词行数',
    aliases: ['歌词最大行数', '歌词字号', '歌词显示行数', '字号'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '显示',
    label: '标题格式',
    aliases: ['歌曲标题格式', '标题显示格式', '文件名', '歌手-歌名'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '显示',
    label: '简繁转换',
    aliases: ['简繁显示', '繁体', '简体', 'OpenCC'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '显示',
    label: '播放页显示权重',
    aliases: ['播放页权重信息显示', '权重信息'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '显示',
    label: '播放页控件隐藏',
    aliases: ['播放页控件自动隐藏', '自动隐藏', '控件'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '动效',
    label: '切换动画',
    aliases: ['页面切换动画', '过渡动画', '动画'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.appearance,
    group: '交互',
    label: '长按组头',
    aliases: ['长按展开', '折叠', '多选', '长按'],
  ),

  // ── 播放 ──────────────────────────────────────────────────────────────
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放行为',
    label: '默认模式',
    aliases: ['默认播放模式', '播放模式'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放行为',
    label: '断点续播',
    aliases: ['断点续播自动恢复', '续播', '恢复播放'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放行为',
    label: '预载下一首',
    aliases: ['预载', '下一首'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放行为',
    label: '定时行为',
    aliases: ['睡眠定时', '播完再暂停', '睡眠'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放行为',
    label: '歌词追焦',
    aliases: ['歌词追焦等待', '歌词跟随', '追焦'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放行为',
    label: '屏幕常亮',
    aliases: ['播放页屏幕常亮', '常亮', '熄屏'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放行为',
    label: '限定蓝牙',
    aliases: ['常亮限定蓝牙设备', '蓝牙设备', '蓝牙'],
    target: settingsAnchorId(SettingsItem.playback, '屏幕常亮'),
    hint: '需先开启屏幕常亮',
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '随机权重',
    label: '加权随机',
    aliases: ['随机', '权重', '随机播放'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '随机权重',
    label: '次数冷却',
    aliases: ['加权随机·次数冷却', '冷却'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '随机权重',
    label: '曲数冷却',
    aliases: ['加权随机·曲数冷却', '冷却'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '随机权重',
    label: '时长削弱',
    aliases: ['按时长削弱权重', '长歌', '削弱'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '随机权重',
    label: '权重曲线',
    aliases: ['权重-时长曲线', '曲线', '分段'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '音效',
    label: '淡入淡出',
    aliases: ['淡入', '淡出', '渐变'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '音效',
    label: '应用音量',
    aliases: ['应用内音量', '音量', '软件音量'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '音效',
    label: '均衡器',
    aliases: ['EQ', '均衡', '频段', '预设', '前级', '逐段'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放保护',
    label: '焦点自动暂停',
    aliases: ['音频焦点', '自动暂停恢复', '来电'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放保护',
    label: '静音暂停',
    aliases: ['媒体音量', '静音'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.playback,
    group: '播放保护',
    label: '断连暂停',
    aliases: ['蓝牙断开', '断开', '设备断开'],
  ),

  // ── 歌曲 ──────────────────────────────────────────────────────────────
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '扫描过滤',
    label: '时长过滤',
    aliases: ['忽略音频', '短音频', '时长'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '扫描过滤',
    label: '大小过滤',
    aliases: ['忽略音频', '小文件', '大小'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '扫描过滤',
    label: '仅 Wi-Fi',
    aliases: ['仅WiFi', 'Wi-Fi扫描', 'WiFi', '移动网络'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '扫描过滤',
    label: '扫描间隔',
    aliases: ['自动扫描间隔', '自动扫描', '扫描周期'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '元数据 · 在线来源',
    label: '歌词来源',
    aliases: ['歌词', 'LRCLIB', 'QQ', '网易'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '元数据 · 在线来源',
    label: '封面来源',
    aliases: ['封面', 'CAA', 'QQ', '网易'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '元数据',
    label: '保存方式',
    aliases: ['sidecar', '写回源目录', '内嵌', '缓存'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '元数据',
    label: '歌词目录',
    aliases: ['自定义歌词目录', 'LRC目录'],
    target: settingsAnchorId(SettingsItem.songs, '保存方式'),
    hint: '需保存方式为同时写回源目录',
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '元数据 · 歌手解析',
    label: '自动解析',
    aliases: ['自动后台解析', '歌手解析', 'MusicBrainz'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '元数据 · 歌手解析',
    label: '重试解析',
    aliases: ['解析重试', '歌手'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '元数据 · 歌手解析',
    label: '强制解析',
    aliases: ['全部解析', '歌手'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.songs,
    group: '播放源',
    label: '备用源同步',
    aliases: ['备用源自动补歌', '补歌', '备用源'],
  ),

  // ── 存储 ──────────────────────────────────────────────────────────────
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '离线缓存',
    label: '收藏自动缓存',
    aliases: ['收藏缓存', '自动缓存', '离线'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '缓存容量',
    label: '缓存容量',
    aliases: ['缓存上限', '缓存配置', '缓存'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '缓存容量',
    label: '上限来源',
    aliases: ['跟随服务端', '自定义缓存', '来源'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '缓存容量',
    label: '体积上限',
    aliases: ['缓存总上限', '缓存体积', '缓存上限', '字节上限'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '缓存容量',
    label: '首数上限',
    aliases: ['歌曲数量上限', '缓存歌曲数', '歌曲上限'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '缓存容量',
    label: '同步建议值',
    aliases: ['同步服务端建议值', '同步建议'],
    target: settingsAnchorId(SettingsItem.storage, '缓存容量'),
    hint: '点右上同步按钮',
  ),
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '缓存位置',
    label: '缓存目录',
    aliases: ['缓存路径', '存储位置', '更改目录'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '封面缓存',
    label: '压缩画质',
    aliases: ['压缩图像画质', '缩略图', '封面压缩'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '封面缓存',
    label: '清理缩略图',
    aliases: ['清理缩略图缓存', '清理缓存'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.storage,
    group: '备份与迁移',
    label: '备份与迁移',
    aliases: ['备份', '导出设置', '导入设置', '歌单备份', '本机备份'],
  ),

  // ── 网络 ──────────────────────────────────────────────────────────────
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '服务端',
    label: '配对服务端',
    aliases: ['配对服务器', '服务端', '后端地址', '配对密钥'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '多设备同步',
    label: '同步开关',
    aliases: ['多设备同步', '同步'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '多设备同步',
    label: '立即同步',
    aliases: ['同步'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '多设备同步',
    label: '同步设置',
    aliases: ['设置同步', '同步偏好', '同步播放偏好', '同步媒体库'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '多设备同步',
    label: '设备管理',
    aliases: ['已配对设备', '设备', '吊销'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '网络安全',
    label: '允许 HTTP',
    aliases: ['允许不安全HTTP', '明文HTTP', 'http'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '网络安全',
    label: '信任自签名',
    aliases: ['信任自签名证书', '自签名', '证书'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '转码代理',
    label: '转码省流',
    aliases: ['转码', '代理', '省流'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '转码代理',
    label: '码率',
    aliases: ['192', '256', '320', '比特率'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.network,
    group: '转码代理',
    label: '响度均衡',
    aliases: ['响度', 'loudnorm', '音量均衡'],
  ),

  // ── 系统 ──────────────────────────────────────────────────────────────
  SettingsSearchEntry(
    section: SettingsItem.system,
    group: '快捷键',
    label: '窗口内',
    aliases: ['窗口内快捷键', '快捷键'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.system,
    group: '快捷键',
    label: '全局',
    aliases: ['全局快捷键', '快捷键'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.system,
    group: '桌面和后台',
    label: '驻留托盘',
    aliases: ['关闭窗口', '托盘', '最小化到托盘', '关闭驻留'],
    visible: () => DesktopTray.isSupported,
  ),
  SettingsSearchEntry(
    section: SettingsItem.system,
    group: '桌面和后台',
    label: '通知栏控制',
    aliases: ['通知栏播放控制', '通知', '播放控制'],
  ),
  SettingsSearchEntry(
    section: SettingsItem.system,
    group: '诊断',
    label: '日志时长',
    aliases: ['日志', '诊断', '反馈'],
  ),
];

/// 按关键词搜索：多词全部命中；精确/前缀/别名依次排序。
List<SettingsSearchEntry> searchSettings(String rawQuery) {
  final query = rawQuery.trim().toLowerCase();
  if (query.isEmpty) return const [];
  final terms = query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (terms.isEmpty) return const [];

  final matches = <SettingsSearchEntry>[];
  for (final entry in settingsSearchEntries) {
    if (!entry.isVisible) continue;
    final haystack = entry.searchText;
    if (terms.every(haystack.contains)) matches.add(entry);
  }

  int score(SettingsSearchEntry entry) {
    final label = entry.label.toLowerCase();
    if (label == query) return 100;
    if (label.startsWith(query)) return 80;
    if (label.contains(query)) return 60;
    if (entry.aliases.any((a) => a.toLowerCase().contains(query))) return 40;
    return 20;
  }

  matches.sort((a, b) {
    final byScore = score(b).compareTo(score(a));
    if (byScore != 0) return byScore;
    final bySection = a.section.index.compareTo(b.section.index);
    if (bySection != 0) return bySection;
    return a.label.compareTo(b.label);
  });
  return matches;
}
