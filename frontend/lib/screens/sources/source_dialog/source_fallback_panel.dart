import 'package:flutter/material.dart';

import '../../../data/sources/music_source.dart';
import '../../../widgets/single_choice_group.dart';

import 'source_form_fields.dart';
import 'source_form_model.dart';
import 'source_form_ops.dart';
import 'source_form_renderer.dart';
import 'source_form_widgets.dart';

/// 一个备用源槽位的状态：表单模型 + 展开态 + 自己的测试状态。
///
/// 原先 `SourceFallbackData` 的 9 个 controller 由 [SourceFormModel] 接管；
/// 这里只保留备用源独有的 UI 状态。
class SourceFallbackSlot {
  final SourceFormModel form;

  /// 是否展开（默认展开，便于直接编辑已有配置）。
  bool expanded;

  ConnectionStatus testStatus;
  SourceTestResult? testResult;

  /// 需要滚动/高亮到的出错字段（校验失败时由弹窗设置）。
  SourceFieldId? errorField;

  SourceFallbackSlot({
    required this.form,
    this.expanded = true,
    this.testStatus = ConnectionStatus.idle,
    this.testResult,
    this.errorField,
  });

  factory SourceFallbackSlot.empty() =>
      SourceFallbackSlot(form: SourceFormModel(kind: SourceKind.webdav));

  factory SourceFallbackSlot.fromRaw(Map<String, dynamic> raw) {
    final kind = switch ((raw['kind'] as String? ?? '').trim()) {
      'sftp' => SourceKind.sftp,
      'smb' => SourceKind.smb,
      _ => SourceKind.webdav,
    };
    return SourceFallbackSlot(form: SourceFormModel(kind: kind, cfg: raw));
  }

  void focusError(SourceFieldId? field) => errorField = field;

  /// 折叠时的摘要文案：「WebDAV · nas2.local」。
  String get summary {
    final kindLabel = switch (form.kind) {
      SourceKind.webdav => 'WebDAV',
      SourceKind.smb => 'SMB',
      SourceKind.sftp => 'SFTP',
      SourceKind.local => '本地',
    };
    final addr = switch (form.kind) {
      SourceKind.webdav => form.text(SourceFieldId.baseUrl),
      SourceKind.smb => form.text(SourceFieldId.host),
      SourceKind.sftp => form.text(SourceFieldId.host),
      SourceKind.local => '',
    };
    if (addr.isEmpty) return kindLabel;
    return '$kindLabel · $addr';
  }

  /// 是否已填了最低限度的配置（用于「未配置」占位）。
  bool get isConfigured => form.toRawMap().values.any(
        (v) => v is String && v.isNotEmpty && v != SourceKind.webdav.name,
      );

  void dispose() => form.dispose();
}

/// 备用源折叠面板：每个槽位一张可折叠卡片，展开后复用主表单的渲染器。
///
/// 与主源的唯一差别是：[SourceFormBuilder] 传 `isFallback: true`（无名称
/// 字段），以及卡头多一个类型单选与删除按钮。
class SourceFallbackPanel extends StatelessWidget {
  const SourceFallbackPanel({
    super.key,
    required this.slots,
    required this.enabled,
    required this.onAdd,
    required this.onRemove,
    required this.onChanged,
    required this.onPickKeyFile,
  });

  final List<SourceFallbackSlot> slots;
  final bool enabled;
  final VoidCallback onAdd;
  final void Function(int slot) onRemove;
  final VoidCallback onChanged;
  final void Function(int slot) onPickKeyFile;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '备用源',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              Text(
                '${slots.length} / $kMaxFallbacks',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.45),
                    ),
              ),
            ],
          ),
        ),
        Text(
          '主源失败自动按相对路径切备用；本地只可做主源，不可做备用',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < slots.length; i++) _card(context, i),
        if (slots.length < kMaxFallbacks)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: enabled ? onAdd : null,
              icon: const Icon(Icons.add, size: 18),
              label: Text(slots.isEmpty ? '添加备用源' : '再添加一个备用源'),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '已达上限（$kMaxFallbacks 个备用源）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
            ),
          ),
      ],
    );
  }

  Widget _card(BuildContext context, int i) {
    final cs = Theme.of(context).colorScheme;
    final slot = slots[i];
    final label = fallbackLabel(i);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SourceCollapsibleHeader(
            title: label,
            summary: slot.summary,
            expanded: slot.expanded,
            onTap: () => _toggle(slot),
            trailing: [
              if (slot.testStatus == ConnectionStatus.ok)
                const _MiniChip(text: '已验证', ok: true),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: '删除$label',
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? () => onRemove(i) : null,
              ),
            ],
          ),
          if (slot.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  SingleChoiceGroup<SourceKind>(
                    options: remoteKindOptions,
                    value: slot.form.kind,
                    expanded: true,
                    onChanged: enabled
                        ? (v) {
                            slot.form.changeKind(v);
                            slot.testStatus = ConnectionStatus.idle;
                            slot.testResult = null;
                            onChanged();
                          }
                        : null,
                  ),
                  const SizedBox(height: 12),
                  SourceFormBuilder(
                    model: slot.form,
                    isFallback: true,
                    enabled: enabled,
                    errors: slot.errorField == null
                        ? const {}
                        : {
                            slot.errorField!: '请检查该字段',
                          },
                    onChanged: () {
                      slot.testStatus = ConnectionStatus.idle;
                      slot.testResult = null;
                      onChanged();
                    },
                    onImportKeyFile: () => onPickKeyFile(i),
                    onClearKey: () {
                      slot.form[SourceFieldId.keyPem].clear();
                      slot.form.keyFileName = null;
                      onChanged();
                    },
                  ),
                  ConnectionTestRow(
                    status: slot.testStatus,
                    onTest: () => _test(context, i),
                    testLabel: '测试连接',
                    result: slot.testResult,
                    enabled: enabled,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _toggle(SourceFallbackSlot slot) {
    // 面板本身无状态，展开态存在 slot 上；改完通知外层重建。
    slot.expanded = !slot.expanded;
    onChanged();
  }

  Future<void> _test(BuildContext context, int i) async {
    final slot = slots[i];
    final result = await testSource(slot.form, allowSelfSigned: true);
    slot.testStatus =
        result.ok ? ConnectionStatus.ok : ConnectionStatus.failed;
    slot.testResult = result;
    onChanged();
  }
}

/// 卡头的小状态标签。
class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.text, this.ok = false});

  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = ok ? cs.primary : cs.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
