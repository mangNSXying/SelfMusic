import 'package:flutter/material.dart';

/// 页面级统一动效口径（2026-10-11 收敛：播放页/内容页/侧边栏/队列统一 300ms）。
///
/// - [kPageMotion]：播放页开/关、内容区切换、宽屏侧边栏/队列伸缩、统一拖拽窗口开/关共用。
/// - [kPageMotionCurve]：统一用 `easeOutCubic`（播放页/内容页原曲线；弹层原先线性一并收敛）。
/// - 窄屏 Drawer 例外：Scaffold Drawer 时长由框架写死 246ms（`_kBaseSettleDuration`），
///   无对外配置口，暂保持（46ms 差异体感可接受）。
const Duration kPageMotion = Duration(milliseconds: 300);
const Curve kPageMotionCurve = Curves.easeOutCubic;
