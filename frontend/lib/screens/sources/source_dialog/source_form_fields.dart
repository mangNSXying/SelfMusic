import 'package:flutter/widgets.dart';

import '../../../data/sources/music_source.dart';
import '../../../data/sources/sftp_common.dart';

/// 文本字段的身份（承载 TextEditingController 的那些）。
///
/// 选择型控件（认证方式 / 播放链路 / 文件清单）不是文本，各自有独立的行类型。
enum SourceFieldId {
  name,
  path,
  baseUrl,
  host,
  port,
  share,
  username,
  password,
  keyPem,
  keyPassphrase,
}

/// 字段在弹窗里占的横向档位。
///
/// [half] 用于短字段（主机+端口、用户名+密码），宽屏两列并排；容器变窄时
/// 由渲染器降级成单列，不出现横向滚动。
enum SourceFieldSpan { full, half }

/// 一个文本字段的声明（纯数据，无 Widget、无状态）。
///
/// 文案沿用原弹窗的 label/hint；`note` 是标签行右侧的浅色说明（原先把
/// 「（可空）」直接拼进 label）。
class SourceFieldSpec {
  final SourceFieldId id;
  final String label;
  final String? hint;
  final String? helper;
  final String? note;
  final bool secret;
  final bool digitsOnly;
  final SourceFieldSpan span;

  /// 字段旁的内联控件（渲染在输入框右侧的同一行）。
  ///
  /// SFTP 的「密码 / 密钥」切换用它：认证方式是密码字段的修饰，不该单开一行。
  final SourceInlineControl? inline;

  const SourceFieldSpec(
    this.id, {
    required this.label,
    this.hint,
    this.helper,
    this.note,
    this.secret = false,
    this.digitsOnly = false,
    this.span = SourceFieldSpan.full,
    this.inline,
  });

  TextInputType? get keyboardType {
    if (digitsOnly) return TextInputType.number;
    if (id == SourceFieldId.baseUrl) return TextInputType.url;
    return null;
  }
}

/// 字段旁的内联控件类型。
enum SourceInlineControl {
  /// SFTP 认证方式（密码 / 密钥）。
  sftpAuthMethod,
}

/// 表单里的一行：文本字段或某种选择控件。
sealed class SourceRowSpec {
  const SourceRowSpec();
}

class SourceTextFieldRow extends SourceRowSpec {
  final SourceFieldSpec spec;
  const SourceTextFieldRow(this.spec);
}

/// SFTP 密钥导入块（导入按钮 + 状态文字 + 清除）。
class SourceKeyImportRow extends SourceRowSpec {
  const SourceKeyImportRow();
}

/// 本地源的文件清单块（摘要 + 可展开列表）。
class SourceLocalFilesRow extends SourceRowSpec {
  const SourceLocalFilesRow();
}

/// 远端源的播放链路单选（直连 / 代理）。
class SourceRouteRow extends SourceRowSpec {
  const SourceRouteRow();
}

/// 一个分组（视觉上的小节）。
///
/// [trailing] 标记该分组的组头是否承载「连接测试」——目前只有「连接」组用它，
/// 把测试按钮与连接状态从表单底部挪到组头，省一整行。
class SourceSectionSpec {
  final String title;
  final List<SourceRowSpec> rows;
  final bool trailing;

  const SourceSectionSpec(this.title, this.rows, {this.trailing = false});
}

const _nameField = SourceTextFieldRow(
  SourceFieldSpec(SourceFieldId.name, label: '名称', hint: '如 NAS / 本地音乐'),
);

/// 每种协议的表单结构——主源与备用源共用的唯一事实源。
///
/// 主源与备用源的差别只有两点，都由参数表达：
/// - [isFallback]：备用源没有名称字段（名称继承主源），也永远不是本地源；
/// - 备用源没有「类型」分组（类型由它自己的卡头切换）。
///
/// 新增一种协议时只改本函数（加一个 `case`）与 `source_form_ops.dart` 的
/// 校验/测试分支，不再需要在主表单、备用卡片里各写一遍。
List<SourceSectionSpec> sourceSectionsOf(
  SourceKind kind, {
  required bool isFallback,
  SftpAuthMethod authMethod = SftpAuthMethod.password,
  bool filesMode = false,
}) {
  final head = isFallback ? const <SourceRowSpec>[] : const [_nameField];

  switch (kind) {
    case SourceKind.local:
      // 文件级本地源（鸿蒙 6 降级形态）：只有文件清单，没有目录字段。
      if (filesMode) {
        return [
          const SourceSectionSpec('目录', [SourceLocalFilesRow()]),
        ];
      }
      return [
        SourceSectionSpec('基本信息', head),
        SourceSectionSpec('目录', const [
          SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.path,
            label: '本地文件夹',
            hint: '/home/user/Music',
            note: '或改为选择音频文件',
          )),
          SourceLocalFilesRow(),
        ]),
      ];

    case SourceKind.webdav:
      return [
        SourceSectionSpec('基本信息', head),
        const SourceSectionSpec('连接', [
          SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.baseUrl,
            label: '地址',
            hint: 'https://192.168.1.10/dav/music',
            note: '智能补写 https://',
          )),
          SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.username,
            label: '用户名',
            note: '可空',
            span: SourceFieldSpan.half,
          )),
          SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.password,
            label: '密码',
            note: '可空',
            secret: true,
            span: SourceFieldSpan.half,
          )),
        ], trailing: true),
        const SourceSectionSpec('', [SourceRouteRow()]),
      ];

    case SourceKind.smb:
      // SMB 只填一个「路径」：首个「/」前为共享名，落库时再拆成
      // share/path 两键（见 SourceFormModel.toRawMap）。
      return [
        SourceSectionSpec('基本信息', head),
        const SourceSectionSpec('连接', [
          SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.host,
            label: '主机',
            hint: '192.168.1.10 或 nas.local',
          )),
          SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.share,
            label: '路径',
            hint: 'music 或 music/flac',
            note: '格式：共享名/目录',
          )),
          SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.username,
            label: '用户名',
            note: '空即匿名',
            span: SourceFieldSpan.half,
          )),
          SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.password,
            label: '密码',
            note: '空即匿名',
            secret: true,
            span: SourceFieldSpan.half,
          )),
        ], trailing: true),
        const SourceSectionSpec('', [SourceRouteRow()]),
      ];

    case SourceKind.sftp:
      return [
        SourceSectionSpec('基本信息', head),
        SourceSectionSpec('连接', [
          const SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.host,
            label: '主机',
            hint: '192.168.1.10 或 nas.local',
            span: SourceFieldSpan.half,
          )),
          const SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.port,
            label: '端口',
            note: '默认 22',
            hint: '22',
            digitsOnly: true,
            span: SourceFieldSpan.half,
          )),
          const SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.username,
            label: '用户名',
            span: SourceFieldSpan.half,
          )),
          // 认证方式是密码 / 密钥字段的修饰，内联在输入框右侧，不单开一行。
          if (authMethod == SftpAuthMethod.password)
            const SourceTextFieldRow(SourceFieldSpec(
              SourceFieldId.password,
              label: '密码',
              secret: true,
              inline: SourceInlineControl.sftpAuthMethod,
            ))
          else ...[
            const SourceKeyImportRow(),
            const SourceTextFieldRow(SourceFieldSpec(
              SourceFieldId.keyPassphrase,
              label: '私钥口令',
              note: '无则空',
              secret: true,
              inline: SourceInlineControl.sftpAuthMethod,
            )),
          ],
          const SourceTextFieldRow(SourceFieldSpec(
            SourceFieldId.path,
            label: '根目录',
            note: '空 = 登录目录',
            hint: '/music',
          )),
        ], trailing: true),
        const SourceSectionSpec('', [SourceRouteRow()]),
      ];
  }
}

/// 该协议的可编辑文本字段 id 全集（含按认证方式隐藏的），供表单模型建立
/// controller —— 隐藏字段的值也必须能回填与提交（切回密码认证时不能丢）。
Set<SourceFieldId> editableFieldIdsOf(SourceKind kind) => switch (kind) {
      SourceKind.local => {SourceFieldId.name, SourceFieldId.path},
      SourceKind.webdav => {
          SourceFieldId.name,
          SourceFieldId.baseUrl,
          SourceFieldId.username,
          SourceFieldId.password,
        },
      SourceKind.smb => {
          SourceFieldId.name,
          SourceFieldId.host,
          SourceFieldId.share,
          SourceFieldId.username,
          SourceFieldId.password,
        },
      SourceKind.sftp => {
          SourceFieldId.name,
          SourceFieldId.host,
          SourceFieldId.port,
          SourceFieldId.username,
          SourceFieldId.password,
          SourceFieldId.keyPem,
          SourceFieldId.keyPassphrase,
          SourceFieldId.path,
        },
    };
