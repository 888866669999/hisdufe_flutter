/// 自绘月历：把「周次表」画成日历的样子
///
/// ===== 为什么要有它 =====
/// 学校官网的校历是**图片**，一年一换。App 里内置图片有两个死结：
///   1. 换学年后内置图就过期了，而界面上完全看不出来 —— 用户会照着
///      去年的日期安排行程，这比「没有校历」更糟；
///   2. 图片里的信息（第几周、哪天开学、假期边界）没法参与计算。
///
/// 教务系统的「教学周历」给的是结构化的「第 N 周 ←→ 周一日期」，
/// 每学期由学校录入，因此换学年会自动更新。本组件把它渲染成月历网格：
///   每个教学日标出**教学周次**，非教学日（寒暑假、报到前的日子）留白。
/// 这样用户既能看到「这一周是第几周」，也能一眼看出学期边界 ——
/// 与官方校历图所承载的信息一致（日期 + 周次 + 边界），
/// 而且是**可随年份更新的数据**，不依赖任何随包图片。
library;

import 'package:flutter/material.dart';

import '../data/semester_calendar_service.dart';
import '../theme/theme.dart';

/// 一个月的月历卡片
class SemesterMonthGrid extends StatelessWidget {
  const SemesterMonthGrid({
    required this.year,
    required this.month,
    required this.info,
    this.today,
    super.key,
  });

  final int year;
  final int month;
  final SemesterInfo info;

  /// 今天（用于高亮）。测试可传固定值。
  final DateTime? today;

  /// 星期表头：周一起（中国习惯）
  static const List<String> _weekdayLabels = <String>['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final Map<String, int> byDay = info.weekIndexByDay();
    final DateTime first = DateTime(year, month, 1);
    final int daysInMonth = DateTime(year, month + 1, 0).day;
    // 周一为 0（DateTime.weekday：周一=1）
    final int leading = first.weekday - 1;
    final DateTime now = today ?? DateTime.now();

    // 行数按需算，不预先固定 6 行：很多月份只需要 5 行，
    // 固定 6 行会多出一条空白行，视觉上像是数据缺失
    final int totalCells = leading + daysInMonth;
    final int rows = (totalCells / 7).ceil();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('$year 年 $month 月',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              )),
        ),
        Row(
          children: <Widget>[
            for (final String w in _weekdayLabels)
              Expanded(
                child: Center(
                  child: Text(w,
                      style: TextStyle(
                          fontSize: 10, color: context.textTertiary)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        for (int r = 0; r < rows; r++)
          Row(
            children: <Widget>[
              for (int c = 0; c < 7; c++)
                Expanded(
                  child: _cell(
                    context,
                    dayNum: _dayAt(r, c, leading, daysInMonth),
                    byDay: byDay,
                    today: now,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  static int _dayAt(int row, int col, int leading, int daysInMonth) {
    final int n = row * 7 + col - leading + 1;
    return (n < 1 || n > daysInMonth) ? 0 : n;
  }

  bool _isToday(DateTime now, int dayNum) =>
      now.year == year && now.month == month && now.day == dayNum;

  Widget _cell(
    BuildContext context, {
    required int dayNum,
    required Map<String, int> byDay,
    required DateTime today,
  }) {
    if (dayNum == 0) {
      // 上月/下月的空格：不画任何东西（不画灰日期，避免与教学日混淆）
      return const SizedBox(height: 40);
    }
    final String key = _key(dayNum);
    final int week = byDay[key] ?? 0;
    final bool teaching = week > 0;
    final bool isToday = _isToday(today, dayNum);
    return Container(
      height: 40,
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: teaching ? context.brandSoftColor : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        // 今天描一圈：月历里「今天在哪」是要找的第一个信息
        border: isToday ? Border.all(color: context.brandColor, width: 1.5) : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            '$dayNum',
            style: TextStyle(
              fontSize: 12,
              fontWeight: teaching ? FontWeight.w600 : FontWeight.w400,
              // 非教学日弱化：它们是假期或尚未开学，与教学日不是一回事
              color: teaching ? context.textPrimary : context.textTertiary,
            ),
          ),
          if (teaching)
            Text('$week周',
                style: TextStyle(fontSize: 8, color: context.brandColor)),
        ],
      ),
    );
  }

  String _key(int day) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '$year-${two(month)}-${two(day)}';
  }
}
