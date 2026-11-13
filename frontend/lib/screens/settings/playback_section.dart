import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../platform/harmonyos/ohos_bootstrap.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/player_provider.dart';
import '../../services/bluetooth_service.dart';
import '../../services/equalizer/equalizer_service.dart';
import '../../services/equalizer/equalizer_types.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/app_volume_control.dart';
import '../../widgets/eq_curve_editor.dart';
import '../../widgets/settings_layout.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_tile.dart';
import '../../widgets/single_choice_dialog.dart';
import '../../widgets/wheel_picker_dialog.dart';
import 'keep_awake_device_dialog.dart';
import 'settings_focus.dart';

/// 播放设置（settings.md §3.2）：播放行为 / 随机权重 / 音效 / 播放保护。
class PlaybackSection extends StatefulWidget {
  const PlaybackSection();
  @override
  State<PlaybackSection> createState() => _PlaybackSettingsState();
}

class _PlaybackSettingsState extends State<PlaybackSection> {
  late AppSettings _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
  }

  Widget _anchor(String label, Widget child) => SettingsFocusAnchor(
        id: settingsAnchorId(SettingsItem.playback, label),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final current = PlayModeParse.fromStored(_settings.playModeDefault);
    final eqBands = _settings.eqBands;
    final eqPreampDb = _settings.eqPreampDb;

    return SettingsPage(
      children: [
        const SettingsSectionHeader('播放行为'),
        _anchor(
          '默认模式',
          SettingsTile.value(
            title: '默认模式',
            description: '启动后进入的播放模式',
            value: _modeSubtitle(current),
            onTap: () => _pickMode(context, current),
          ),
        ),
        _anchor(
          '断点续播',
          SettingsTile.toggle(
            title: '断点续播',
            description: '启动时恢复上次位置，保持暂停',
            value: _settings.resumeOnStartup,
            onChanged: (v) => setState(() => _settings.resumeOnStartup = v),
          ),
        ),
        _anchor(
          '预载下一首',
          SettingsTile.toggle(
            title: '预载下一首',
            description: '提前缓存下一首，切歌更快',
            value: _settings.preloadNext,
            onChanged: (v) => setState(() => _settings.preloadNext = v),
          ),
        ),
        _anchor(
          '定时行为',
          SettingsTile.toggle(
            title: '定时行为',
            description: '睡眠定时默认播完当前曲再暂停',
            value: _settings.sleepPlayThroughDefault,
            onChanged: (v) =>
                setState(() => _settings.sleepPlayThroughDefault = v),
          ),
        ),
        _anchor(
          '歌词追焦',
          SettingsTile.value(
            title: '歌词追焦',
            description: '拖动后多久回到当前行',
            value: '${_settings.lyricFocusIdleSec} 秒',
            onTap: () => _pickLyricIdle(context),
          ),
        ),
        _anchor(
          '屏幕常亮',
          SettingsTile.toggle(
            title: '屏幕常亮',
            description: '打开播放页期间不熄屏',
            value: _settings.playerKeepScreenOn,
            onChanged: (v) => setState(() => _settings.playerKeepScreenOn = v),
          ),
        ),
        if (_settings.playerKeepScreenOn)
          SettingsTile.value(
            title: '限定蓝牙',
            description: '仅在指定设备连接时保持常亮',
            value: _keepAwakeDeviceLabel(),
            onTap: _pickKeepAwakeDevice,
          ),
        const SettingsGroupDivider(),
        const SettingsSectionHeader('随机权重'),
        _anchor(
          '加权随机',
          SettingsTile.toggle(
            title: '加权随机',
            description: '按权重抽歌；关闭为普通随机',
            value: _settings.weightedRandomEnabled,
            onChanged: (v) {
              setState(() => _settings.weightedRandomEnabled = v);
              context.read<PlayerProvider>().onRandomAlgorithmChanged();
            },
          ),
        ),
        _anchor(
          '次数冷却',
          SettingsTile.value(
            title: '次数冷却',
            description: '刚播过的歌连续抽中时先跳过',
            value: _drawCooldownValue(_settings.weightedDrawCooldown),
            enabled: _settings.weightedRandomEnabled,
            onTap: _settings.weightedRandomEnabled ? _pickDrawCooldown : null,
          ),
        ),
        _anchor(
          '曲数冷却',
          SettingsTile.value(
            title: '曲数冷却',
            description: '最近播过的一段不进候选池',
            value: _countCooldownValue(_settings.weightedCountCooldownRatio),
            enabled: _settings.weightedRandomEnabled,
            onTap: _settings.weightedRandomEnabled ? _editCountCooldown : null,
          ),
        ),
        _anchor(
          '时长削弱',
          SettingsTile.toggle(
            title: '时长削弱',
            description: '长歌权重低（仅加权随机）',
            value: _settings.weightCurveEnabled,
            onChanged: (v) => setState(() => _settings.weightCurveEnabled = v),
          ),
        ),
        _anchor(
          '权重曲线',
          SettingsTile.value(
            title: '权重曲线',
            description: '按歌曲时长分段的权重系数',
            value: _weightCurveSummary(_settings.weightCurveSegments),
            onTap: () => _editWeightCurve(context),
          ),
        ),
        const SettingsGroupDivider(),
        const SettingsSectionHeader('音效'),
        _anchor(
          '淡入淡出',
          SettingsTile.toggle(
            title: '淡入淡出',
            description: '播放与暂停时音量渐变',
            value: _settings.fadeEnabled,
            onChanged: (v) => setState(() => _settings.fadeEnabled = v),
          ),
        ),
        SettingsControlBlock(
          child: Row(
            children: [
              const Text('时长', style: TextStyle(fontSize: 13)),
              Expanded(
                child: Slider(
                  key: const ValueKey('fade-duration-slider'),
                  // 有效域 [500, 2000]ms（读取已钳制）：0.5~2.0s、0.1s 步进
                  //（divisions 15，16 档），标签一位小数实时预览。
                  value: (_settings.fadeDurationMs / 1000).clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  label:
                      '${(_settings.fadeDurationMs / 1000).toStringAsFixed(1)} 秒',
                  onChanged: (v) => setState(
                      () => _settings.fadeDurationMs = (v * 1000).round()),
                ),
              ),
            ],
          ),
        ),
        _anchor(
          '应用音量',
          SettingsTile.value(
            title: '应用音量',
            description: '独立于系统音量的应用内增益',
            value: '${_settings.appVolume}%',
          ),
        ),
        SettingsControlBlock(
          child: Row(
            children: [
              IconButton(
                tooltip: _settings.appVolume == 0 ? '取消静音' : '静音',
                icon: AppVolumeIcon(volume: _settings.appVolume),
                onPressed: () {
                  setState(() =>
                      context.read<PlayerProvider>().toggleAppVolumeMute());
                },
              ),
              Expanded(
                child: Slider(
                  key: const ValueKey('app-volume-slider'),
                  value: _settings.appVolume.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 100,
                  label: '${_settings.appVolume}%',
                  onChanged: (v) {
                    setState(() {
                      context.read<PlayerProvider>().setAppVolume(v.round());
                    });
                  },
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${_settings.appVolume}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        _anchor('均衡器', _buildEqualizer(context, eqBands, eqPreampDb)),
        const SettingsGroupDivider(),
        const SettingsSectionHeader('播放保护'),
        const SettingsGroupNote('以下功能仅安卓 / 鸿蒙生效'),
        _anchor(
          '焦点自动暂停',
          SettingsTile.toggle(
            title: '焦点自动暂停',
            description: '来电或其他应用抢占时自动暂停与恢复',
            value: _settings.audioFocusEnabled,
            onChanged: (v) {
              setState(() => _settings.audioFocusEnabled = v);
              context.read<PlayerProvider>().applyAudioConfig();
            },
          ),
        ),
        _anchor(
          '静音暂停',
          SettingsTile.toggle(
            title: '静音暂停',
            description: '系统音量归零时自动暂停',
            value: _settings.pauseOnZeroVolume,
            onChanged: (v) {
              setState(() => _settings.pauseOnZeroVolume = v);
              context.read<PlayerProvider>().refreshPlaybackGuard();
            },
          ),
        ),
        _anchor(
          '断连暂停',
          SettingsTile.toggle(
            title: '断连暂停',
            description: '输出设备断开时自动暂停',
            value: _settings.pauseOnDeviceDisconnect,
            onChanged: (v) {
              setState(() => _settings.pauseOnDeviceDisconnect = v);
              context.read<PlayerProvider>().refreshPlaybackGuard();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEqualizer(
    BuildContext context,
    List<double> eqBands,
    double eqPreampDb,
  ) {
    final supported = EqualizerService.supportedOnThisPlatform;
    final enabled = supported && _settings.equalizerEnabled;
    if (!supported) {
      return SettingsTile.toggle(
        title: '均衡器',
        description: EqualizerService.unsupportedNote,
        value: false,
        onChanged: null,
      );
    }
    final switchTile = SettingsTile.toggle(
      title: '均衡器',
      description: '调整各频段增益与整体音色',
      value: enabled,
      onChanged: (v) {
        context.read<PlayerProvider>().setEqualizerEnabled(v);
        setState(() {});
      },
    );
    if (!enabled) return switchTile;
    final player = context.read<PlayerProvider>();
    return Column(
      children: [
        switchTile,
        ValueListenableBuilder<EqualizerCapabilities?>(
          valueListenable: player.equalizerCapabilities,
          builder: (context, caps, _) {
            return Column(
              children: [
                if (caps?.note != null) _eqNote(caps!.note!),
                _buildEqControls(context, eqBands, eqPreampDb),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _eqNote(String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEqControls(
    BuildContext context,
    List<double> eqBands,
    double eqPreampDb,
  ) {
    final cs = Theme.of(context).colorScheme;
    final preset = matchingEqPreset(eqBands);
    final player = context.read<PlayerProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
          child: Row(
            children: [
              Text('预设',
                  style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
              if (preset == null)
                Text('自定义', style: TextStyle(fontSize: 12, color: cs.primary)),
              const Spacer(),
              TextButton(
                onPressed: () {
                  player.setEqPreset(kDefaultEqBands);
                  player.setEqPreamp(0);
                  setState(() {});
                },
                child: const Text('重置'),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final p in kEqPresets)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.name),
                    selected: preset?.name == p.name,
                    onSelected: (_) {
                      player.setEqPreset(p.gains);
                      setState(() {});
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: EqCurveEditor(
            key: const ValueKey('eq-curve'),
            gains: eqBands,
            onChanged: (i, db) {
              player.setEqBand(i, db);
              setState(() {});
            },
            onCommit: player.flushEqualizer,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(
            children: [
              const Icon(Icons.tune, size: 18),
              const SizedBox(width: 8),
              const Text('前级', style: TextStyle(fontSize: 13)),
              Expanded(
                child: Slider(
                  key: const ValueKey('eq-preamp-slider'),
                  value: eqPreampDb.clamp(kEqPreampMinDb, kEqPreampMaxDb),
                  min: kEqPreampMinDb,
                  max: kEqPreampMaxDb,
                  divisions: 24,
                  label: '${eqPreampDb.toStringAsFixed(1)} dB',
                  onChanged: (v) {
                    player.setEqPreamp(v);
                    setState(() {});
                  },
                  onChangeEnd: (_) => player.flushEqualizer(),
                ),
              ),
              SizedBox(
                width: 60,
                child: Text(
                  '${eqPreampDb.toStringAsFixed(1)} dB',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            '前级衰减用于抵消正增益叠加造成的削波，默认 0 dB',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
        ExpansionTile(
          key: const ValueKey('eq-band-sliders'),
          title: const Text('逐段微调', style: TextStyle(fontSize: 14)),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            for (var i = 0; i < kEqBandCount; i++)
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16),
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Text(kEqFrequencyLabels[i],
                          style: const TextStyle(fontSize: 12)),
                    ),
                    Expanded(
                      child: Slider(
                        key: ValueKey('eq-band-$i'),
                        value: eqBands[i].clamp(kEqMinDb, kEqMaxDb),
                        min: kEqMinDb,
                        max: kEqMaxDb,
                        divisions: 240,
                        label: '${eqBands[i].toStringAsFixed(1)} dB',
                        onChanged: (v) {
                          player.setEqBand(i, v);
                          setState(() {});
                        },
                        onChangeEnd: (_) => player.flushEqualizer(),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: Text(
                        '${eqBands[i] >= 0 ? '+' : ''}${eqBands[i].toStringAsFixed(1)}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickMode(BuildContext context, PlayMode current) async {
    final picked = await showSingleChoiceDialog<PlayMode>(
      context: context,
      title: '默认播放模式',
      values: PlayMode.values,
      current: current,
      labelOf: _modeLabel,
      asRadio: true,
    );
    if (picked == null || picked == current || !context.mounted) return;
    setState(() => _settings.playModeDefault = picked.name);
    context.read<PlayerProvider>().setMode(picked);
  }

  static String _modeLabel(PlayMode m) => switch (m) {
        PlayMode.sequence => '顺序播放',
        PlayMode.loopList => '列表循环',
        PlayMode.loopOne => '单曲循环',
        PlayMode.weighted => '随机播放',
      };

  String _modeSubtitle(PlayMode m) {
    if (m != PlayMode.weighted) return _modeLabel(m);
    return _settings.weightedRandomEnabled ? '随机（加权）' : '随机（不放回）';
  }

  static String _drawCooldownValue(WeightedDrawCooldown cd) =>
      cd == WeightedDrawCooldown.off ? '关' : cd.label;

  static String _drawCooldownSummary(WeightedDrawCooldown cd) => cd ==
          WeightedDrawCooldown.off
      ? '关（不启用次数冷却）'
      : '${cd.label}（factor>1.0 抛弃 ${cd.highLimit} 次 / 其余抛弃 ${cd.lowLimit} 次）';

  static String _countCooldownValue(double ratio) =>
      ratio <= 0 ? '关' : '${(ratio * 100).toStringAsFixed(0)}%';

  Future<void> _pickDrawCooldown() async {
    final current = _settings.weightedDrawCooldown;
    final picked = await showSingleChoiceDialog<WeightedDrawCooldown>(
      context: context,
      title: '次数冷却',
      values: WeightedDrawCooldown.values,
      current: current,
      labelOf: (cd) => cd.label,
      subtitleOf: _drawCooldownSummary,
      asRadio: true,
    );
    if (picked == null || picked == current || !mounted) return;
    setState(() => _settings.weightedDrawCooldown = picked);
  }

  Future<void> _editCountCooldown() async {
    final currentPercent = (_settings.weightedCountCooldownRatio * 100)
        .round()
        .clamp(0, 100)
        .toInt();
    final picked = await showNumberWheelDialog(
      context: context,
      title: '曲数冷却比例',
      value: currentPercent,
      values: wheelRange(0, 100, 1),
      labelOf: (v) => v == 0 ? '关' : '$v%',
      hint: '播放历史末尾该比例内的歌不参与随机；0=关闭',
    );
    if (picked == null || !mounted) return;
    setState(() => _settings.weightedCountCooldownRatio = picked / 100);
  }

  static double? _segNum(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static String _weightCurveSummary(List<Map<String, Object?>> segs) {
    if (segs.isEmpty) return '未设置';
    return '${segs.length} 段';
  }

  static String _segmentLabel(Map<String, Object?> m) {
    final min = _segNum(m['min_sec']);
    final max = _segNum(m['max_sec']);
    final f = _segNum(m['factor']);
    final range = max == null
        ? '≥ ${min?.toStringAsFixed(0) ?? '?'} 秒'
        : '${min?.toStringAsFixed(0) ?? '?'} - ${max.toStringAsFixed(0)} 秒';
    return '$range → ×${f == null ? '?' : f.toStringAsFixed(2)}';
  }

  Future<void> _editWeightCurve(BuildContext context) async {
    final working =
        List<Map<String, Object?>>.from(_settings.weightCurveSegments);
    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialog) => AlertDialog(
          title: const Text('权重曲线'),
          content: SizedBox(
            width: 380,
            child: working.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('尚未配置区间：所有歌曲权重按 1.0（不削弱）。'),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (var i = 0; i < working.length; i++) ...[
                        ListTile(
                          dense: true,
                          leading: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.redAccent),
                            tooltip: '删除区间',
                            onPressed: () =>
                                setDialog(() => working.removeAt(i)),
                          ),
                          title: Text(_segmentLabel(working[i])),
                          onTap: () async {
                            final edited =
                                await _editWeightSegment(c, working[i]);
                            if (edited != null) {
                              setDialog(() => working[i] = edited);
                            }
                          },
                        ),
                      ],
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => setDialog(() => working.add(
                  const {'min_sec': 300.0, 'max_sec': null, 'factor': 0.5})),
              child: const Text('+ 添加区间'),
            ),
            ...appDialogActions(
              c,
              confirmLabel: '保存',
              onCancel: () => Navigator.of(c).pop(false),
              onConfirm: () => Navigator.of(c).pop(true),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _settings.weightCurveSegments = working);
    }
  }

  static List<int> get _weightSecValues => [
        ...wheelRange(1, 60, 1),
        ...wheelRange(65, 3600, 5),
      ];

  Future<Map<String, Object?>?> _editWeightSegment(
      BuildContext c, Map<String, Object?> current) async {
    var minSec =
        (_segNum(current['min_sec']) ?? 300).clamp(1.0, 3600.0).toDouble();
    var maxSec = _segNum(current['max_sec']);
    var factor = (_segNum(current['factor']) ?? 0.5).clamp(0.5, 1.5).toDouble();

    final result = await showDialog<bool>(
      context: c,
      builder: (d) => StatefulBuilder(
        builder: (d, setDialog) {
          final valid = minSec > 0 &&
              factor >= 0.5 &&
              factor <= 1.5 &&
              (maxSec == null || maxSec! > minSec);
          Widget row(String label, String value, Future<void> Function() pick) {
            return SettingsTile.value(
              title: label,
              value: value,
              onTap: pick,
            );
          }

          return AlertDialog(
            title: const Text('编辑区间'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row('起始时长', '${minSec.toStringAsFixed(0)} 秒', () async {
                  final picked = await showNumberWheelDialog(
                    context: d,
                    title: '起始时长',
                    value: minSec.round(),
                    values: _weightSecValues,
                    labelOf: (sec) => '$sec 秒',
                  );
                  if (picked != null && d.mounted) {
                    setDialog(() => minSec = picked.toDouble());
                  }
                }),
                row('结束时长',
                    maxSec == null ? '无上限' : '${maxSec!.toStringAsFixed(0)} 秒',
                    () async {
                  final picked = await showNumberWheelDialog(
                    context: d,
                    title: '结束时长',
                    value: maxSec?.round() ?? 0,
                    values: [0, ..._weightSecValues],
                    labelOf: (sec) => sec == 0 ? '无上限' : '$sec 秒',
                  );
                  if (picked != null && d.mounted) {
                    setDialog(
                        () => maxSec = picked == 0 ? null : picked.toDouble());
                  }
                }),
                row('系数', '×${factor.toStringAsFixed(2)}', () async {
                  final picked = await showNumberWheelDialog(
                    context: d,
                    title: '系数',
                    value: (factor * 100).round(),
                    values: wheelRange(50, 150, 1),
                    labelOf: (v) => '×${(v / 100).toStringAsFixed(2)}',
                  );
                  if (picked != null && d.mounted) {
                    setDialog(() => factor = picked / 100);
                  }
                }),
              ],
            ),
            actions: appDialogActions(
              d,
              confirmLabel: '保存',
              confirmEnabled: valid,
              onCancel: () => Navigator.of(d).pop(false),
              onConfirm: () => Navigator.of(d).pop(true),
            ),
          );
        },
      ),
    );
    if (result != true) return null;
    return {'min_sec': minSec, 'max_sec': maxSec, 'factor': factor};
  }

  /// 常亮限定设备展示名（未限定=全局常亮）。
  String _keepAwakeDeviceLabel() {
    final ds = btDevicesFromSetting(_settings.keepScreenOnDevice);
    if (ds.isEmpty) return '所有设备';
    return '仅 ${ds.map((d) => d.name).join('、')}';
  }

  Future<void> _pickKeepAwakeDevice() async {
    final svc = BluetoothService();
    final granted = await svc.ensurePermission();
    if (!mounted) return;
    if (!granted) {
      // ohos 两次拒绝后系统弹窗不再出现，只能去系统设置手动开启
      // （ArkTS 三段式已含设置弹框兜底，仍被拒即引导）。
      AppToast.show(
          isOhos
              ? '未授予蓝牙权限，可在 设置 > 应用和元服务 > SelfMusic 中开启'
              : '未授予蓝牙权限，无法读取已配对设备',
          isError: true);
      return;
    }
    final devices = await svc.bondedDevices();
    if (!mounted) return;
    if (devices.isEmpty) {
      AppToast.show('未找到已配对设备（请先在系统设置中配对）', isError: true);
      return;
    }
    if (isOhos) {
      // 2026-10-06 曾加「endOfFrame + 150ms」延迟规避「只出遮罩无内容」，
      // 2026-10-07 VM service 取证证伪该假设（延迟后仍复现；真因在对话框
      // 内容结构，见 KeepAwakeDeviceDialog），故移除。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final selected = {
      for (final d in btDevicesFromSetting(_settings.keepScreenOnDevice))
        d.address
    };
    final picked = await showDialog<List<BtDevice>>(
      context: context,
      builder: (c) =>
          KeepAwakeDeviceDialog(devices: devices, selected: selected),
    );
    if (picked == null || !mounted) return;
    setState(() => _settings.keepScreenOnDevice = btDevicesToSetting(picked));
  }

  Future<void> _pickLyricIdle(BuildContext context) async {
    final current = _settings.lyricFocusIdleSec;
    final picked = await showNumberWheelDialog(
      context: context,
      title: '歌词追焦',
      value: current,
      values: wheelRange(1, 60, 1),
      labelOf: (s) => '$s 秒',
    );
    if (picked == null || picked == current || !context.mounted) return;
    setState(() => _settings.lyricFocusIdleSec = picked);
  }
}
