/// 节次作息编辑弹窗（液态玻璃）
///
/// ===== 为什么不用 AlertDialog =====
/// 它自带 Material 的**不透明灰底**与直角阴影，浮在玻璃界面上像另一个应用
/// （用户反馈「UI 与整个系统风格不统一」）。这里与课程编辑器用同一套做法：
/// `Dialog(backgroundColor: transparent)` + `GlassKit.surface` 自绘面板，
/// 内部控件全部用药丸玻璃，与全局风格一致。
///
/// 为什么用 Dialog 而不是「AlertDialog 外面套玻璃」：AlertDialog 自身铺满
/// 整个路由区域（靠 insetPadding 居中面板），套在外面会让玻璃盖住整屏，
/// 而不是只包住面板。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/section_time_store.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';

class SectionTimeDialog extends StatelessWidget {
  const SectionTimeDialog({
    required this.draft,
    required this.start,
    required this.end,
    super.key,
  });

  final List<SectionTime> draft;
  final List<TextEditingController> start;
  final List<TextEditingController> end;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: GlassKit.surface(
          context,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('节次作息时间',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary,
                          )),
                      const SizedBox(height: 6),
                      Text(
                        '教务课表只给出节次名称、不含时刻；请按实际作息填写，提醒时间据此计算。',
                        style: TextStyle(
                            fontSize: 12, color: context.textSecondary),
                      ),
                      const SizedBox(height: 14),
                      for (int i = 0; i < draft.length; i++) ...<Widget>[
                        _row(context, i),
                        if (i != draft.length - 1)
                          const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
              ),
              // 操作行固定在底部（不随内容滚动），保证「保存」始终可见
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    _pillButton(
                      context,
                      label: '取消',
                      onTap: () => Navigator.pop(context, false),
                    ),
                    const SizedBox(width: 10),
                    _pillButton(
                      context,
                      label: '保存',
                      primary: true,
                      onTap: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 96,
          child: Text(draft[i].label,
              style: TextStyle(fontSize: 12, color: context.textPrimary)),
        ),
        Expanded(
          child: _flatPill(context, child: _timeField(context, start[i])),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('—',
              style: TextStyle(fontSize: 14, color: context.textSecondary)),
        ),
        Expanded(
          child: _flatPill(context, child: _timeField(context, end[i])),
        ),
      ],
    );
  }

  /// 平坦的半透明药丸底衬。
  ///
  /// ===== 为什么不用 [GlassKit.fieldBackdrop] =====
  /// 那是一块 10vp 厚的「透镜」（thickness 10 + 菲涅尔高光）。在课程编辑器
  /// 里它没问题——那里的输入框高 44+、整行宽，透镜边缘被摊平了；而这里的
  /// 字段只有 36 高，上下两道透镜边缘在正中相遇，形成一条横贯药丸的
  /// **亮白高光带**（用户反馈的「白道」）。
  ///
  /// 更根本的是：弹窗字段的背后只有弹窗自己的玻璃面 —— 一片**均匀底色**。
  /// 折射与模糊对均匀底色没有任何可表现的内容，留下的只有那条带子。
  /// 所以这里刻意用平底色 + 发丝描边：无带、干净，且仍与玻璃面板同族
  /// （半透明浅色，不是不透明色块）。
  Widget _flatPill(
    BuildContext context, {
    required Widget child,
    double? height,
  }) {
    // 形状与颜色都走 GlassKit.flatPill：这样两种材质下都是药丸，
    // 且 M3 下会用与其它输入框同一档的 surfaceContainerHighest。
    return GlassKit.flatPill(
      context,
      height: height ?? GlassKit.topBarControlH + 4,
      child: child,
    );
  }

  /// 时刻输入框。
  ///
  /// 文字水平居中：时刻是等宽的 HH:MM，在短药丸里贴左会显得空一大块；
  /// 数字用表格数字（tabular figures），逐位输入时宽度不抖。
  ///
  /// ===== 垂直居中的正确做法 =====
  /// 光写 `textAlignVertical: TextAlignVertical.center` **不够**：
  /// `isDense` 只是「变小」，`InputDecorator` 仍按自己的行高去撑盒子，
  /// 与外面 36 高的药丸对不齐，实测文字整体**偏高约 6 逻辑像素**。
  ///
  /// 因此这里换一条更稳的路：用 `isCollapsed: true` 让输入框**精确收缩到
  /// 文字自身的高度**（它会把装饰器额外的上下内边距与最小高度全去掉），
  /// 再由外层的 [Center] 把这个盒子放在药丸正中间 ——
  /// 居中由布局保证，不依赖装饰器的内部算法。
  Widget _timeField(BuildContext context, TextEditingController c) {
    return Center(
      child: TextField(
        controller: c,
        keyboardType: TextInputType.datetime,
        textAlign: TextAlign.center,
        // 长度用 formatter 限制，**不用 `maxLength`**：后者会让
        // InputDecorator 额外排一行计数器（即使 `counterText` 置空，
        // 那一行的高度仍在），把输入区挤向顶部。
        inputFormatters: <TextInputFormatter>[
          // 时刻之外没有合法输入，从源头挡掉，而不是等保存时校验
          FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
          LengthLimitingTextInputFormatter(5),
        ],
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: context.textPrimary,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
        cursorColor: context.brandColor,
        decoration: InputDecoration(
          // ===== 「白道」的解药 =====
          // 全局主题给所有 TextField 设了 `filled: true` +
          // 浅色 fillColor（见 theme.dart 的 inputDecorationTheme）。
          // 对课程编辑器那种又高又宽的输入框，这层填充正好铺满、看着就是个
          // 白底输入框；但这里字段矮，填充只有文字行高 —— 于是药丸中间浮出
          // 一条方角白带。关掉它，让药丸自己的半透明底成为唯一背景。
          filled: false,
          // 收缩到内容高度（见方法文档），使上面的 Center 能真正居中
          isCollapsed: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: 'HH:MM',
          hintStyle: TextStyle(
            fontSize: 13,
            color: context.textSecondary.withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }

  /// 药丸按钮：主按钮实心品牌色、次按钮玻璃（与课程编辑器一致）
  Widget _pillButton(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    if (primary) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 26),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onPrimary,
              )),
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      // 与输入框同一套平底药丸（见 _flatPill 的说明）：
      // 「取消」若是透镜玻璃，与旁边平了的输入框不是一个材质，
      // 白道也会在按钮上重现。
      child: _flatPill(
        context,
        height: 42,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 21),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(fontSize: 14, color: context.textPrimary)),
        ),
      ),
    );
  }
}
