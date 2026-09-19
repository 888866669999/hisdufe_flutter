/// 外观材质：**液态玻璃** 与 **Material 3** 两套，用户可在设置里切换。
///
/// ===== 为什么做成可切换（而不是二选一）=====
/// 两者各有明确的适用场景，不是「新旧」关系：
///   - **Material 3**：实心面 + 层次色。文字对比度与可预期性最好，
///     长时间阅读（成绩、培养方案、通选明细）不容易累，也不吃 GPU；
///   - **液态玻璃**：折射、色散、内容透出。观感独特，但每块玻璃都要跑
///     模糊与折射着色器，成片列出时代价明显（这也是列表卡片一直用
///     最低档 `GlassQuality.minimal` 的原因）。
/// 让用户按设备性能与个人偏好选，比替他决定更合理。
///
/// ===== 哪些元素**不参与**切换 =====
/// 底部 dock 与顶部渐变模糊始终是液态玻璃：
///   - dock 是这套 UI 的视觉标识，也是「能看见被遮挡内容」这一诉求的实现；
///   - 顶部渐变模糊是滚动内容的可读性手段（内容滚过顶栏时渐隐），
///     换成实心顶栏会直接盖住内容、反而更差。
/// 因此它们不走本开关，见 `GlassKit.tabBarSettings` 与 `TopFadeBlur`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../common/constants.dart';
import '../data/pref_store.dart';

/// 内容区的材质
enum AppSurfaceStyle {
  /// Material 3：实心面（默认）
  m3,

  /// 液态玻璃：半透明折射
  glass;

  /// 存进 preferences 的值
  String get storageValue => this == AppSurfaceStyle.m3 ? 'm3' : 'glass';

  /// 设置页显示名
  String get label => this == AppSurfaceStyle.m3 ? '质感（Material 3）' : '液态玻璃';

  /// 设置页副标题
  String get subtitle => this == AppSurfaceStyle.m3
      ? '实心层次色，清晰省电'
      : '半透明折射，能透出下层内容';

  static AppSurfaceStyle fromStorage(String v) =>
      v == 'glass' ? AppSurfaceStyle.glass : AppSurfaceStyle.m3;
}

/// 当前材质的全局持有者。
///
/// 用 `ValueNotifier` 而不是 `AppState`：材质是**纯显示层**的状态，
/// 改它不需要碰会话、课表这些业务数据；而且 `main.dart` 要据此重建整棵树
/// （`MaterialApp` 的 theme 与各页面的构建都依赖它），
/// `ValueListenableBuilder` 正好表达「一变就整树重建」。
class SurfaceStyleController {
  SurfaceStyleController._();

  /// 当前材质。默认 M3 —— 主内容以 M3 为准，玻璃是可选加成。
  static final ValueNotifier<AppSurfaceStyle> style =
      ValueNotifier<AppSurfaceStyle>(AppSurfaceStyle.m3);

  /// 从持久化读一次（应用启动时调用）
  static void load() {
    final String raw = PrefStore.getText(kKeySurfaceStyle, 'm3');
    style.value = AppSurfaceStyle.fromStorage(raw);
  }

  /// 切换并落盘
  static Future<void> set(AppSurfaceStyle v) async {
    style.value = v;
    await PrefStore.putText(kKeySurfaceStyle, v.storageValue);
  }

  /// 当前是否液态玻璃。内容组件的分派都用它。
  static bool get isGlass => style.value == AppSurfaceStyle.glass;
}
