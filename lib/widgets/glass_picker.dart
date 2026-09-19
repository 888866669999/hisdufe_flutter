/// 通用「液态玻璃滚轮选择器」
///
/// ===== 为什么统一到一个组件 =====
/// 应用里原先有 4 处下拉框（课表学期、成绩学期、空教室学期/校区/教学楼/节次、
/// 课程编辑的起止周），样式与交互各不相同：有的贴边长列表、有的是系统菜单。
/// 现在全部换成同一个居中玻璃滚轮 —— 一致的外观、一致的交互，
/// 也只需要维护一份实现。
///
/// ===== 为什么用滚轮而不是下拉列表 =====
///   1. 选项多时（30 个周次、40 个学期）下拉列表翻起来很累；
///   2. 滚轮是「选一个值」最直接的表达，且不需要瞄准小三角；
///   3. 居中弹窗比贴边列表更容易点准。
library;

import 'package:flutter/material.dart';

import '../theme/glass_kit.dart';
import '../theme/theme.dart';

/// 一个可选项
class GlassOption<T> {
  const GlassOption(this.value, this.label);

  final T value;
  final String label;
}

/// 打开玻璃滚轮选择器；返回选中的值，取消时返回 null。
///
/// @param title    弹窗标题，如「选择周次」
/// @param options  选项列表（顺序即滚轮顺序）
/// @param current  当前值（用于定位初始位置）；不在列表里时落在第 0 项
/// @param markLabel 需要额外标注「当前」的项（如课表里的「本周」），
///                  返回非空字符串即在标签旁显示一个品牌色小字
Future<T?> showGlassPicker<T>(
  BuildContext context, {
  required String title,
  required List<GlassOption<T>> options,
  T? current,
  String Function(T value)? markLabel,
}) {
  if (options.isEmpty) {
    return Future<T?>.value();
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (BuildContext ctx) => _GlassPickerSheet<T>(
      title: title,
      options: options,
      current: current,
      markLabel: markLabel,
    ),
  );
}

class _GlassPickerSheet<T> extends StatefulWidget {
  const _GlassPickerSheet({
    required this.title,
    required this.options,
    required this.current,
    required this.markLabel,
  });

  final String title;
  final List<GlassOption<T>> options;
  final T? current;
  final String Function(T value)? markLabel;

  @override
  State<_GlassPickerSheet> createState() => _GlassPickerSheetState<T>();
}

class _GlassPickerSheetState<T> extends State<_GlassPickerSheet<T>> {
  /// 固定行高：滚轮必须知道行高才能算出选中项，不能随字体自适应
  static const double _itemH = 44;

  late final FixedExtentScrollController _ctrl;
  late int _index;

  @override
  void initState() {
    super.initState();
    final int found =
        widget.options.indexWhere((GlassOption<T> o) => o.value == widget.current);
    _index = found < 0 ? 0 : found;
    _ctrl = FixedExtentScrollController(initialItem: _index);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double h = MediaQuery.of(context).size.height;
    // 选项少时弹窗也矮一些，不必总是占 62% 屏高
    final int rows = widget.options.length.clamp(3, 5);
    final double pickerH = rows * _itemH;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 340, maxHeight: h * 0.7),
          child: GlassKit.surface(
            context,
            radius: 26,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(height: 18),
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: pickerH,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      // 选中行高亮：玻璃弹窗内不再叠玻璃，用半透明品牌色块
                      Container(
                        height: _itemH,
                        margin: const EdgeInsets.symmetric(horizontal: 22),
                        decoration: BoxDecoration(
                          color: context.brandSoftColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      ListWheelScrollView.useDelegate(
                        controller: _ctrl,
                        itemExtent: _itemH,
                        // 透视给一点立体感，但别夸张到读不清文字
                        perspective: 0.0022,
                        diameterRatio: 1.9,
                        physics: const FixedExtentScrollPhysics(),
                        onSelectedItemChanged: (int i) =>
                            setState(() => _index = i),
                        childDelegate: ListWheelChildBuilderDelegate(
                          childCount: widget.options.length,
                          builder: (BuildContext c, int i) {
                            final bool sel = i == _index;
                            final GlassOption<T> o = widget.options[i];
                            final String mark =
                                widget.markLabel?.call(o.value) ?? '';
                            return Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    o.label,
                                    style: TextStyle(
                                      fontSize: sel ? 17 : 15,
                                      fontWeight: sel
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                      color: sel
                                          ? context.brandColor
                                          : context.textSecondary,
                                    ),
                                  ),
                                  if (mark.isNotEmpty) ...<Widget>[
                                    const SizedBox(width: 6),
                                    Text(mark,
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: context.brandColor)),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text('上下滑动选择',
                    style:
                        TextStyle(fontSize: 11, color: context.textTertiary)),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: TextButton.styleFrom(
                            backgroundColor: context.surfaceVariant,
                            shape: const StadiumBorder(),
                            minimumSize: const Size(0, 44),
                          ),
                          child: Text('取消',
                              style: TextStyle(color: context.textPrimary)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(context)
                              .pop(widget.options[_index].value),
                          style: FilledButton.styleFrom(
                            shape: const StadiumBorder(),
                            minimumSize: const Size(0, 44),
                          ),
                          child: const Text('确定'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 三列日期滚轮（年 / 月 / 日）
// ============================================================================

/// 打开「年 / 月 / 日」三列玻璃滚轮（用于开学日期）。
///
/// 为什么不用系统 `showDatePicker`：它是 Material 日历对话框，
/// 与本应用已玻璃化的其余弹窗风格割裂；且用户明确要求
/// 「yy/mm/dd 上下滑动」的液态玻璃选择器。
///
/// 返回选中的日期（本地 DateTime），取消时返回 null。
Future<DateTime?> showGlassDatePicker(
  BuildContext context, {
  required DateTime initial,
  int firstYear = 2020,
  int lastYear = 2100,
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (BuildContext ctx) => _GlassDateSheet(
      initial: initial,
      firstYear: firstYear,
      lastYear: lastYear,
    ),
  );
}

class _GlassDateSheet extends StatefulWidget {
  const _GlassDateSheet({
    required this.initial,
    required this.firstYear,
    required this.lastYear,
  });

  final DateTime initial;
  final int firstYear;
  final int lastYear;

  @override
  State<_GlassDateSheet> createState() => _GlassDateSheetState();
}

class _GlassDateSheetState extends State<_GlassDateSheet> {
  static const double _itemH = 44;

  late int _year;
  late int _month;
  late int _day;

  late final FixedExtentScrollController _yc;
  late final FixedExtentScrollController _mc;
  late final FixedExtentScrollController _dc;

  List<int> get _years => <int>[
        for (int y = widget.firstYear; y <= widget.lastYear; y++) y,
      ];

  List<int> get _months => <int>[for (int m = 1; m <= 12; m++) m];

  /// 当月天数（按所选年月算，避免出现 2 月 30 日这种非法组合）
  int _daysInMonth(int y, int m) => DateTime(y, m + 1, 0).day;

  @override
  void initState() {
    super.initState();
    final DateTime d = widget.initial;
    _year = d.year.clamp(widget.firstYear, widget.lastYear);
    _month = d.month;
    _day = d.day.clamp(1, _daysInMonth(_year, _month));
    _yc = FixedExtentScrollController(initialItem: _year - widget.firstYear);
    _mc = FixedExtentScrollController(initialItem: _month - 1);
    _dc = FixedExtentScrollController(initialItem: _day - 1);
  }

  @override
  void dispose() {
    _yc.dispose();
    _mc.dispose();
    _dc.dispose();
    super.dispose();
  }

  /// 一列滚轮
  Widget _column({
    required String title,
    required List<int> values,
    required int selected,
    required FixedExtentScrollController ctrl,
    required ValueChanged<int> onChanged,
    String Function(int v)? fmt,
  }) {
    String f(int v) => fmt?.call(v) ?? '$v';
    // ===== 为什么要把标题的占位高度补到滚轮上 =====
    // 选中高亮带由外层 Stack 居中绘制，而 Stack 的「中心」是整个
    // 「标题 + 间距 + 滚轮」这一列的中心。标题占掉的高度（11vp 字号
    // 约 15vp + 间距 2vp）会把滚轮的几何中心往下推，导致**选中那一格
    // 的文字相对高亮带偏上**（用户反馈「选中的横条内文字不上下居中」）。
    //
    // 修法不是在文字上加偏移，而是让整列的**垂直重心**与滚轮中心重合：
    // 给标题包一个与滚轮等高的 SizedBox 并底部对齐不行（会撑高整列），
    // 因此改为在列**底部**补一段与标题等高的空白 —— 这样列的中心
    // 就回到了滚轮的中心。
    // 标题用**固定高度**包裹，而不是靠字号的自然行高 ——
    // 后者的实际像素值随字体与系统字号缩放变化，算出来的补偿量就不可靠。
    const double titleH = 18;
    const double titleGap = 2;
    return Column(
      children: <Widget>[
        SizedBox(
          height: titleH,
          child: Center(
            child: Text(title,
                style: TextStyle(fontSize: 11, color: context.textTertiary)),
          ),
        ),
        const SizedBox(height: titleGap),
        SizedBox(
          height: _itemH * 5,
          child: ListWheelScrollView.useDelegate(
            controller: ctrl,
            itemExtent: _itemH,
            perspective: 0.0022,
            diameterRatio: 1.9,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: (int i) => onChanged(values[i]),
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: values.length,
              builder: (BuildContext c, int i) {
                final bool sel = values[i] == selected;
                return Center(
                  child: Text(
                    f(values[i]),
                    style: TextStyle(
                      fontSize: sel ? 17 : 15,
                      fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
                      color: sel ? context.brandColor : context.textSecondary,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        // 与标题等高的尾部空白：把整列的垂直中心压回滚轮中心，
        // 选中文字因此与高亮带对齐（见上面的说明）
        const SizedBox(height: titleH + titleGap),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final double h = MediaQuery.of(context).size.height;
    final int dim = _daysInMonth(_year, _month);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 360, maxHeight: h * 0.7),
          child: GlassKit.surface(
            context,
            radius: 26,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(height: 18),
                Text('选择开学日期（第 1 周周一）',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    )),
                const SizedBox(height: 4),
                Text('上下滑动选择，会自动吸附到该周周一',
                    style:
                        TextStyle(fontSize: 11, color: context.textTertiary)),
                const SizedBox(height: 10),
                // 三列并排。选中行的高亮带跨列，因此由外层统一画一条，
                // 各列内部不再各画一段（那样会出现三段断开的色块）。
                Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    Container(
                      height: _itemH,
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: context.brandSoftColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _column(
                            title: '年',
                            values: _years,
                            selected: _year,
                            ctrl: _yc,
                            onChanged: (int v) => setState(() {
                              _year = v;
                              _clampDay();
                            }),
                          ),
                        ),
                        Expanded(
                          child: _column(
                            title: '月',
                            values: _months,
                            selected: _month,
                            ctrl: _mc,
                            fmt: (int v) => v < 10 ? '0$v' : '$v',
                            onChanged: (int v) => setState(() {
                              _month = v;
                              _clampDay();
                            }),
                          ),
                        ),
                        Expanded(
                          child: _column(
                            title: '日',
                            values: <int>[for (int i = 1; i <= dim; i++) i],
                            selected: _day,
                            ctrl: _dc,
                            fmt: (int v) => v < 10 ? '0$v' : '$v',
                            onChanged: (int v) => setState(() => _day = v),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: TextButton.styleFrom(
                            backgroundColor: context.surfaceVariant,
                            shape: const StadiumBorder(),
                            minimumSize: const Size(0, 44),
                          ),
                          child: Text('取消',
                              style: TextStyle(color: context.textPrimary)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(context)
                              .pop(DateTime(_year, _month, _day)),
                          style: FilledButton.styleFrom(
                            shape: const StadiumBorder(),
                            minimumSize: const Size(0, 44),
                          ),
                          child: const Text('确定'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 年月变化后把「日」夹到当月合法范围，并同步滚轮位置。
  /// 不这么做的话，从 1/31 切到 2 月会得到 2/31（非法的日期）。
  void _clampDay() {
    final int dmax = _daysInMonth(_year, _month);
    if (_day > dmax) {
      _day = dmax;
      _dc.jumpToItem(_day - 1);
    }
  }
}
