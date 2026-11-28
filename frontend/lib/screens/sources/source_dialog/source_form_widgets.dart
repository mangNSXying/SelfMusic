import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/sources/music_source.dart';
import '../../../platform/harmonyos/ohos_bootstrap.dart';
import '../../../widgets/inline_spinner.dart';

import 'source_form_ops.dart';

/// 密码框的键盘类型。
///
/// 鸿蒙 Flutter 引擎不会根据 `obscureText` 推断密码输入类型：它只把
/// `keyboardType` 透传给系统 IME，默认的 text 会被当作普通文本框，系统
/// 「安全键盘」不会拉起（安卓引擎会自动折算成密码类型）。显式指定
/// visiblePassword 后引擎映射为系统的 VISIBLE_PASSWORD，才会按密码框处理；
/// 其他平台返回 null 保持默认，避免 VISIBLE_PASSWORD 变体改变既有键盘行为。
TextInputType? get passwordKeyboardType =>
    isOhos ? TextInputType.visiblePassword : null;

/// 表单分组标题：沿用设置页组标题的视觉（主色 + w600）。
class SourceFormSection extends StatelessWidget {
  const SourceFormSection({
    super.key,
    required this.title,
    this.trailing,
    required this.children,
  });

  final String title;
  final Widget? trailing;
  final List<Widget> children;

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
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}

/// 字段标签行：左 label，右侧浅色说明（「可空」「默认 22」等）。
class SourceFieldLabel extends StatelessWidget {
  const SourceFieldLabel(this.label, {super.key, this.note});

  final String label;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: style?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          if (note != null) ...[
            const SizedBox(width: 8),
            // 窄屏下 note 可能比 label 还长（如「或改为选择音频文件」）：
            // 用 Flexible + 右对齐让它自己折行，而不是把整行撑溢出。
            Flexible(
              child: Text(
                note!,
                textAlign: TextAlign.right,
                style: style?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 密码 / 口令输入框：带显隐切换。
///
/// 全站唯一密码框实现——原先 8 处裸 `TextField(obscureText: true)` 都没有
/// 显隐切换，打错只能整段重输。
class SourceSecretField extends StatefulWidget {
  const SourceSecretField({
    super.key,
    required this.controller,
    required this.label,
    this.note,
    this.hint,
    this.helper,
    this.error,
    this.onChanged,
    this.enabled = true,
    this.trailing,
  });

  final TextEditingController controller;
  final String label;
  final String? note;
  final String? hint;
  final String? helper;
  final String? error;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  /// 显隐按钮左侧的额外控件（如 SFTP 认证方式切换）。
  final Widget? trailing;

  @override
  State<SourceSecretField> createState() => _SourceSecretFieldState();
}

class _SourceSecretFieldState extends State<SourceSecretField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SourceFieldLabel(widget.label, note: widget.note),
        TextField(
          controller: widget.controller,
          enabled: widget.enabled,
          keyboardType: passwordKeyboardType,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: widget.onChanged,
          decoration: InputDecoration(
            hintText: widget.hint,
            helperText: widget.helper,
            helperMaxLines: 2,
            errorText: widget.error,
            errorMaxLines: 2,
            suffixIcon: widget.trailing == null
                ? IconButton(
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                    ),
                    tooltip: _obscure ? '显示密码' : '隐藏密码',
                    onPressed: widget.enabled
                        ? () => setState(() => _obscure = !_obscure)
                        : null,
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      widget.trailing!,
                      IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 20,
                        ),
                        tooltip: _obscure ? '显示密码' : '隐藏密码',
                        onPressed: widget.enabled
                            ? () => setState(() => _obscure = !_obscure)
                            : null,
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// 普通文本输入框：标签 + hint/helper + 行内错误。
class SourceTextField extends StatelessWidget {
  const SourceTextField({
    super.key,
    required this.controller,
    required this.label,
    this.note,
    this.hint,
    this.helper,
    this.error,
    this.digitsOnly = false,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.suffix,
    this.enabled = true,
    this.focusNode,
  });

  final TextEditingController controller;
  final String label;
  final String? note;
  final String? hint;
  final String? helper;
  final String? error;
  final bool digitsOnly;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SourceFieldLabel(label, note: note),
        TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          keyboardType: keyboardType,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          inputFormatters:
              digitsOnly ? [FilteringTextInputFormatter.digitsOnly] : null,
          decoration: InputDecoration(
            hintText: hint,
            helperText: helper,
            helperMaxLines: 2,
            errorText: error,
            errorMaxLines: 2,
            suffixIcon: suffix,
          ),
        ),
      ],
    );
  }
}

/// 两个短字段并排；容器太窄时上下排列（不出现横向滚动）。
///
/// 是否并排由外层统一下发的 [compact] 决定，**不能**在这里用 `LayoutBuilder`：
/// `AlertDialog` 会把内容包进 `IntrinsicWidth`，而 `LayoutBuilder` 不支持
/// intrinsic 计算（会抛「does not support returning intrinsic dimensions」）。
class SourceFieldRow extends StatelessWidget {
  const SourceFieldRow({
    super.key,
    required this.left,
    required this.right,
    required this.compact,
  });

  final Widget left;
  final Widget right;

  /// 窄容器：两个字段上下排列。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [left, const SizedBox(height: 12), right],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 12),
        Expanded(child: right),
      ],
    );
  }
}

/// 连接状态（决定状态芯片的样式与文案）。
enum ConnectionStatus { idle, testing, ok, failed }

/// 测试连接行：按钮 + 状态芯片。
///
/// 原实现点了只弹一个 toast，结果一闪而过；这里把「待测 / 测试中 / 成功
/// （含耗时）/ 失败（含原因）」固定显示在按钮旁边。
class ConnectionTestRow extends StatelessWidget {
  const ConnectionTestRow({
    super.key,
    required this.status,
    required this.onTest,
    required this.testLabel,
    this.result,
    this.enabled = true,
  });

  final ConnectionStatus status;
  final VoidCallback onTest;
  final String testLabel;
  final SourceTestResult? result;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final busy = status == ConnectionStatus.testing;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: (!enabled || busy) ? null : onTest,
            icon: busy
                ? const InlineSpinner(size: 16)
                : const Icon(Icons.verified_outlined, size: 18),
            label: Text(busy ? '测试中…' : testLabel),
          ),
          if (status != ConnectionStatus.idle) _statusChip(context),
        ],
      ),
    );
  }

  Widget _statusChip(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (Color bg, Color fg, IconData icon, String text) =
        switch (status) {
      ConnectionStatus.testing => (
          cs.surfaceContainerHighest,
          cs.onSurfaceVariant,
          Icons.sync,
          '测试中',
        ),
      ConnectionStatus.ok => (
          cs.primary.withValues(alpha: 0.10),
          cs.primary,
          Icons.check_circle,
          result == null ? '连接成功' : '连接成功 · ${result!.elapsedMs} ms',
        ),
      _ => (
          cs.error.withValues(alpha: 0.10),
          cs.error,
          Icons.error_outline,
          result?.message ?? '连接失败',
        ),
    };
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 备用源折叠卡头：标题 + 摘要 + 展开箭头 + 尾部动作。
class SourceCollapsibleHeader extends StatelessWidget {
  const SourceCollapsibleHeader({
    super.key,
    required this.title,
    this.summary,
    required this.expanded,
    required this.onTap,
    this.trailing = const [],
    this.enabled = true,
  });

  final String title;
  final String? summary;
  final bool expanded;
  final VoidCallback onTap;
  final List<Widget> trailing;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (summary != null && summary!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  summary!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
              ),
            ] else
              const Spacer(),
            for (final w in trailing) ...[const SizedBox(width: 4), w],
          ],
        ),
      ),
    );
  }
}

/// 播放链路单选的说明文字（主源/备用源共用同一句）。
String playbackRouteNote(SourceRoute route) => route == SourceRoute.direct
    ? '直连走原生地址（代理设置不生效）；代理经服务端，开关开时转码'
    : '代理经服务端；直连走原生地址（代理设置不生效）';
