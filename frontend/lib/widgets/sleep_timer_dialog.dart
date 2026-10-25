import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import 'app_dialog_actions.dart';
import 'app_toast.dart';
import 'row_action_button.dart';

Future<void> showSleepTimerDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SleepTimerDialog(
      playThroughDefault:
          context.read<DirectSourceManager>().settings.sleepPlayThroughDefault,
    ),
  );
}

class _SleepTimerDialog extends StatefulWidget {
  final bool playThroughDefault;

  const _SleepTimerDialog({required this.playThroughDefault});

  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  late SleepTimerKind? _mode;
  TimeOfDay? _time;
  late int _minutes;
  late int _count;
  late bool _playThrough;
  late bool _exitApp;

  @override
  void initState() {
    super.initState();
    final p = context.read<PlayerProvider>();
    _mode = p.sleepMode;
    if (_mode == SleepTimerKind.time && p.sleepUntilTime != null) {
      final t = p.sleepUntilTime!;
      _time = TimeOfDay(hour: t.hour, minute: t.minute);
    }
    final s = context.read<DirectSourceManager>().settings;
    _minutes =
        p.sleepMinutes > 0 ? p.sleepMinutes : s.sleepDefaultDurationMinutes;
    _count = p.sleepCountLeft > 0 ? p.sleepCountLeft : s.sleepDefaultCount;
    _playThrough =
        p.sleepTimerActive ? p.sleepPlayThrough : widget.playThroughDefault;
    _exitApp = p.sleepTimerActive ? p.sleepExitApp : false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hintColor = cs.onSurface.withValues(alpha: 0.6);
    final hint = TextStyle(fontSize: 13, color: hintColor);
    return AlertDialog(
      title: const Text('睡眠定时', style: TextStyle(fontSize: 21)),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RadioGroup<SleepTimerKind>(
                groupValue: _mode,
                onChanged: (v) {
                  if (v != null) setState(() => _mode = v);
                },
                child: Column(
                  children: [
                    RadioListTile<SleepTimerKind>(
                      value: SleepTimerKind.time,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text('指定时间', style: TextStyle(fontSize: 15)),
                      subtitle: _timeSubtitle(),
                      secondary: _mode == SleepTimerKind.time
                          ? RowActionIconButton(
                              icon: Icons.schedule,
                              tooltip: '选择时间',
                              onPressed: _pickTime,
                            )
                          : null,
                    ),
                    RadioListTile<SleepTimerKind>(
                      value: SleepTimerKind.duration,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text('指定时长', style: TextStyle(fontSize: 15)),
                      subtitle: Text('倒计时 ${_fmtMinutes(_minutes)}后自动停止',
                          style: hint),
                      secondary: _mode == SleepTimerKind.duration
                          ? RowActionIconButton(
                              icon: Icons.av_timer,
                              tooltip: '选择时长',
                              onPressed: _pickDurationWheel,
                            )
                          : null,
                    ),
                    RadioListTile<SleepTimerKind>(
                      value: SleepTimerKind.count,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text('指定曲数', style: TextStyle(fontSize: 15)),
                      subtitle: Text('再播放 $_count 首后停止', style: hint),
                      secondary: _mode == SleepTimerKind.count
                          ? RowActionIconButton(
                              icon: Icons.format_list_numbered,
                              tooltip: '选择曲数',
                              onPressed: _pickCountWheel,
                            )
                          : null,
                    ),
                    RadioListTile<SleepTimerKind>(
                      value: SleepTimerKind.endOfList,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text('列表结尾', style: TextStyle(fontSize: 15)),
                      subtitle: Text('播完队列最后一首即停止', style: hint),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('播放完最后的曲目', style: TextStyle(fontSize: 15)),
                subtitle: Text('到点不中断当前歌曲，放完这曲再暂停', style: hint),
                value: _playThrough || _mode == SleepTimerKind.endOfList,
                onChanged: _mode == SleepTimerKind.endOfList
                    ? null
                    : (v) => setState(() => _playThrough = v),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('播放结束退出软件', style: TextStyle(fontSize: 15)),
                subtitle: Text('定时结束后自动退出 App，不再驻留后台', style: hint),
                value: _exitApp,
                onChanged: (v) => setState(() => _exitApp = v),
              ),
            ],
          ),
        ),
      ),
      actions: appDialogActions(
        context,
        cancelLabel: '关闭',
        confirmLabel: '确定',
        confirmEnabled: !_invalid,
        onCancel: _close,
        onConfirm: _apply,
      ),
    );
  }

  Widget _timeSubtitle() {
    final hintColor =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    final hint = TextStyle(fontSize: 13, color: hintColor);
    if (_time == null) {
      return Text('选择停止时刻', style: hint);
    }
    return Row(children: [
      Text(_fmtTime(_time!), style: hint),
      const SizedBox(width: 4),
      RowActionTextButton(
        label: '选择',
        onPressed: _pickTime,
        color: hintColor,
      ),
    ]);
  }

  bool get _invalid =>
      _mode == null ||
      (_mode == SleepTimerKind.time && _time == null) ||
      (_mode == SleepTimerKind.duration && _minutes <= 0) ||
      (_mode == SleepTimerKind.count && _count <= 0);

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 22, minute: 0),
    );
    if (t == null || !mounted) return;
    setState(() {
      _time = t;
      _mode = SleepTimerKind.time;
    });
  }

  Future<void> _pickDurationWheel() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => _WheelDialog(
        title: '选择时长',
        columns: [
          [for (var h = 0; h <= 12; h++) '$h 小时'],
          [for (var m = 0; m <= 59; m++) '$m 分'],
        ],
        initial: [_minutes ~/ 60, _minutes % 60],
        resultOf: (idx) => idx[0] * 60 + idx[1],
        valid: (v) => v > 0,
      ),
    );
    if (picked != null && picked > 0 && mounted) {
      setState(() => _minutes = picked);
    }
  }

  Future<void> _pickCountWheel() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => _WheelDialog(
        title: '选择曲数',
        columns: [
          [for (var n = 1; n <= 200; n++) '$n 首'],
        ],
        initial: [(_count - 1).clamp(0, 199)],
        resultOf: (idx) => idx[0] + 1,
        valid: (v) => v > 0,
      ),
    );
    if (picked != null && picked > 0 && mounted) {
      setState(() => _count = picked);
    }
  }

  static String _fmtMinutes(int total) {
    if (total < 60) return '$total 分钟';
    final h = total ~/ 60;
    final m = total % 60;
    return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
  }

  void _apply() {
    final p = context.read<PlayerProvider>();
    final now = DateTime.now();
    switch (_mode) {
      case SleepTimerKind.time:
        final t = _time;
        if (t == null) return;
        p.setSleepTime(
          DateTime(now.year, now.month, now.day, t.hour, t.minute),
          playThrough: _playThrough,
          exitApp: _exitApp,
        );
      case SleepTimerKind.duration:
        p.setSleepDuration(Duration(minutes: _minutes),
            playThrough: _playThrough, exitApp: _exitApp);
      case SleepTimerKind.count:
        p.setSleepCount(_count, playThrough: _playThrough, exitApp: _exitApp);
      case SleepTimerKind.endOfList:
        p.setSleepEndOfList(exitApp: _exitApp);
      case null:
        return;
    }
    final s = context.read<DirectSourceManager>().settings;
    if (_mode == SleepTimerKind.duration) {
      s.sleepDefaultDurationMinutes = _minutes;
    } else if (_mode == SleepTimerKind.count) {
      s.sleepDefaultCount = _count;
    }
    final summary = '睡眠定时：${p.sleepSummaryText ?? '已设置'}';
    Navigator.of(context).pop();
    AppToast.show(summary, isError: false);
  }

  void _close() {
    context.read<PlayerProvider>().cancelSleepTimer();
    Navigator.of(context).pop();
  }

  static String _fmtTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _WheelDialog extends StatefulWidget {
  final String title;
  final List<List<String>> columns;
  final List<int> initial;
  final int Function(List<int>) resultOf;
  final bool Function(int) valid;
  const _WheelDialog({
    required this.title,
    required this.columns,
    required this.initial,
    required this.resultOf,
    required this.valid,
  });

  @override
  State<_WheelDialog> createState() => _WheelDialogState();
}

class _WheelDialogState extends State<_WheelDialog> {
  late List<int> _idx;
  late List<FixedExtentScrollController> _ctrls;

  @override
  void initState() {
    super.initState();
    _idx = List.of(widget.initial);
    _ctrls = [
      for (var c = 0; c < widget.columns.length; c++)
        FixedExtentScrollController(initialItem: widget.initial[c]),
    ];
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.resultOf(_idx);
    final ok = widget.valid(value);
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: 20)),
      content: SizedBox(
        width: 320,
        height: 200,
        child: Row(
          children: [
            for (var c = 0; c < widget.columns.length; c++)
              Expanded(
                child: CupertinoPicker(
                  scrollController: _ctrls[c],
                  itemExtent: 40,
                  magnification: 1.15,
                  onSelectedItemChanged: (i) => setState(() => _idx[c] = i),
                  children: [
                    for (final label in widget.columns[c])
                      Center(
                        child:
                            Text(label, style: const TextStyle(fontSize: 17)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: appDialogActions(
        context,
        confirmLabel: '确定',
        confirmEnabled: ok,
        onCancel: () => Navigator.of(context).pop(),
        onConfirm: () => Navigator.of(context).pop(value),
      ),
    );
  }
}
