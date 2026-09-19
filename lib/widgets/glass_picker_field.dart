/// 统一的「玻璃选择器」字段外观
///
/// 各页原先用 `DropdownButtonFormField`，样式与交互五花八门。
/// 现在全部改成「点开居中玻璃滚轮」（见 `glass_picker.dart`），
/// 而**显示当前值的那一行**统一用本组件，保证跨页一致。
library;

import 'package:flutter/material.dart';

import '../theme/glass_kit.dart';
import '../theme/theme.dart';

class GlassPickerField extends StatelessWidget {
  const GlassPickerField({
    required this.label,
    required this.value,
    required this.onTap,
    this.compact = false,
    this.dense = false,
    this.centered = false,
    this.mark,
    super.key,
  });

  /// 左侧标签（可为空）
  final String label;
  /// 当前值文案
  final String value;
  final VoidCallback onTap;
  /// 紧凑模式：用于筛选栏（高度小、无独立标签行）
  final bool compact;

  /// 顶栏模式：字号与高度与顶栏其它控件严格一致。
  ///
  /// 与 [compact] 分开是因为两者约束不同：compact 只管「矮一点」，
  /// 而顶栏要求「和旁边的周次框、校历按钮、设置按钮像素级对齐」。
  final bool dense;
  /// 是否把「值 + 下拉箭头」这一组水平**居中**。
  ///
  /// 为什么需要它：筛选栏里的选择器比旁边的搜索框窄（成绩页 flex 2 vs 3），
  /// 靠左排时值贴着左边、右侧空一大块，看起来像没对齐。
  ///
  /// 实现要点：要让 Container 的 `alignment` 真正生效，Row 必须是
  /// `MainAxisSize.min`（收缩到内容宽度）；否则 Row 自己占满宽度，
  /// 居中对齐也就无处施力（Flexible 的子节点默认左对齐）。
  final bool centered;

  /// 值旁边的小标注（如课表的「本周」）
  final String? mark;

  @override
  Widget build(BuildContext context) {
    final Widget row = Row(
      // 居中时必须收缩到内容宽度，否则 Container 的 alignment 无从生效
      mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
      children: <Widget>[
        if (label.isNotEmpty) ...<Widget>[
          Text(label,
              style: TextStyle(fontSize: 12, color: context.textTertiary)),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: dense
                  ? GlassKit.topBarControlFs
                  : (compact ? 14 : 15),
              fontWeight: dense ? FontWeight.w600 : FontWeight.w400,
              color: context.textPrimary,
            ),
          ),
        ),
        if ((mark ?? '').isNotEmpty) ...<Widget>[
          const SizedBox(width: 4),
          Text(mark!,
              style: TextStyle(fontSize: 10, color: context.brandColor)),
        ],
        const SizedBox(width: 2),
        Icon(Icons.unfold_more,
            size: dense ? GlassKit.topBarControlFs + 2 : 16,
            color: context.textSecondary),
      ],
    );

    // 药丸玻璃底衬：与顶栏里的输入框、设置按钮同一套外观。
    return GestureDetector(
      onTap: onTap,
      child: GlassKit.fieldBackdrop(
        context,
        child: Container(
          // dense（顶栏）用统一定高；其余场景沿用较大的行高
          height: dense
              ? GlassKit.topBarControlH
              : (compact ? 44 : 48),
          padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 14),
          alignment: centered ? Alignment.center : Alignment.centerLeft,
          child: row,
        ),
      ),
    );
  }
}
