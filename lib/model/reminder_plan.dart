/// 上课提醒排期（纯逻辑）
///
/// 从鸿蒙版 `model/ReminderPlan.ets` 移植。
///
/// ===== 为什么只看未来 7 天 =====
/// 整学期的提醒有几百条，远超系统通知的合理容量，而且课表随时可能改。
/// 7 天窗口既够用又便于重建 —— 每次课表变化或应用启动都重排一遍，
/// 代价很小，也就不会出现「改了课表但提醒还是旧的」。
///
/// ===== 逐日各自计算周次 =====
/// 早期实现是「算一次本周周次，然后推导后 7 天」。
/// 这在**跨周**时是错的（周日到周一是下一周），会导致单双周课在边界那几天
/// 提醒错位。因此这里对每一天单独算周次。
library;

import '../common/constants.dart';
import '../common/week_calc.dart';
import '../model/models.dart';

/// 待提醒的一条
class PendingNotice {
  PendingNotice({
    required this.at,
    required this.title,
    required this.content,
    required this.key,
  });

  /// 触发时刻（毫秒）
  final int at;
  final String title;
  final String content;

  /// 去重键。重建排期时按它合并，避免同一节课被排两次。
  final String key;
}

/// 节次起始时刻
class SectionStart {
  SectionStart(this.label, this.start, this.startMinutes);

  final String label;
  final String start;
  final int startMinutes;
}

class ReminderPlan {
  /// 排期窗口
  static const int windowDays = 7;

  /// 把 `HH:mm` 转成分钟数；非法返回 -1
  static int toMinutes(String hhmm) {
    final List<String> p = hhmm.split(':');
    if (p.length != 2) {
      return -1;
    }
    final int? h = int.tryParse(p[0]);
    final int? m = int.tryParse(p[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return -1;
    }
    return h * 60 + m;
  }

  /// 生成未来 7 天的提醒列表
  ///
  /// @param sections 节次作息（行 → 起始时刻）
  static List<PendingNotice> buildUpcoming(
    Timetable? tt,
    String startMonday,
    int advanceMinutes,
    int maxWeeks,
    List<SectionStart> sections,
    DateTime now,
  ) {
    final List<PendingNotice> out = <PendingNotice>[];
    if (tt == null || startMonday.isEmpty || sections.isEmpty) {
      return out;
    }

    for (int off = 0; off < windowDays; off++) {
      final DateTime day = DateTime(now.year, now.month, now.day)
          .add(Duration(days: off));
      // 每一天各自算周次（跨周时不能复用同一个值）
      final int week = WeekCalc.weekNumber(startMonday, day, maxWeeks);
      final int col = day.weekday - 1; // Dart: 1=Mon..7=Sun

      for (int row = 0; row < kSectionRows && row < sections.length; row++) {
        final CellData? cell = tt.findCell(row, col);
        if (cell == null) {
          continue;
        }
        final SectionStart st = sections[row];
        for (final CourseEntry e in cell.entries) {
          if (!e.isActiveInWeek(week)) {
            continue;
          }
          // 提前 N 分钟提醒
          final int atMs = WeekCalc.dayStartMs(day) +
              (st.startMinutes - advanceMinutes) * 60000;
          if (atMs <= now.millisecondsSinceEpoch) {
            continue;
          }
          final String place = e.campus.isEmpty
              ? e.room
              : (e.room.isEmpty ? '' : '${e.room}(${e.campus})');
          final StringBuffer content = StringBuffer()
            ..write(st.start)
            ..write(' ')
            ..write(st.label);
          if (place.isNotEmpty) {
            content.write(' · $place');
          }
          if (e.teacher.isNotEmpty) {
            content.write(' · ${e.teacher}');
          }
          out.add(PendingNotice(
            at: atMs,
            title: e.courseName,
            content: content.toString(),
            key: '${WeekCalc.format(DateParts(day.year, day.month, day.day))}|$row|${e.courseName}',
          ));
        }
      }
    }

    out.sort((PendingNotice a, PendingNotice b) => a.at.compareTo(b.at));
    return out;
  }

  /// 从 [kSections] 构造默认节次作息
  static List<SectionStart> defaultSections() {
    return kSections
        .map((SectionDef s) =>
            SectionStart(s.label, s.start, toMinutes(s.start)))
        .toList();
  }
}
