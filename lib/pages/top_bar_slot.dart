/// 顶栏插槽：让当前页面把自己的控件挂到 AppBar 那一行上。
///
/// ===== 为什么需要它 =====
/// 课表页的「周次 / 学期 / 校历」原本自成一行，压在里面内容的上方；
/// 结果是底部备注被挤到只剩两行。把它们移到顶栏、与「课表」标题和设置
/// 按钮同一行后，纵向空间就还给了课表与备注。
///
/// 但 AppBar 归 `AppShell` 所有（它要负责跨页面的一致性），而这三个控件的
/// 状态与弹窗逻辑在 `SchedulePage` 里。于是需要一条「页面把自己的顶栏控件
/// 交出去」的通道 —— 就是这里。
///
/// ===== 为什么用 ValueNotifier 而不是把状态提升到 AppState =====
/// 要提升的不只是「选了哪一周」，还有三个控件的构建、点击后弹哪个滚轮、
/// 以及它们依赖的课表数据（学期列表）。全搬进 AppState 等于把页面逻辑
/// 摊到全局状态里，后续每加一个筛选条件都要动 AppState。
/// 用一个只传 Widget 的插槽，页面仍然是这些控件唯一的所有者。
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

class TopBarSlot {
  /// 当前的顶栏控件。为空表示当前页面不需要占用顶栏（多数页面如此）。
  static final ValueNotifier<Widget?> controls = ValueNotifier<Widget?>(null);

  /// 由页面提交自己的顶栏控件。
  ///
  /// ===== 为什么必须区分调度阶段 =====
  /// 页面是在 `build()` 里提交的，而 `build()` 运行在
  /// `SchedulerPhase.persistentCallbacks` 阶段 —— 此时同步写 notifier 会让
  /// AppShell 在「正在构建」的过程中被要求重建，Flutter 直接抛
  /// `setState() or markNeedsBuild() called during build`。
  /// 因此构建期间必须延到帧后。
  ///
  /// 反过来，**帧空闲时**（测试、或页面在事件回调里提交）直接用同步赋值：
  /// 一是语义更直白；二是 `addPostFrameCallback` 在测试绑定的手动驱动下
  /// 时机不确定（实测「提交后泵一帧」读到的仍是旧值），
  /// 会给测试写出「碰巧通过」的假绿灯。
  static void submit(Widget? w) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      if (!identical(controls.value, w)) {
        controls.value = w;
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(controls.value, w)) {
        controls.value = w;
      }
    });
  }

  /// 页面销毁时清空，避免离开课表后顶栏还挂着它的控件。
  static void clear() => submit(null);
}
