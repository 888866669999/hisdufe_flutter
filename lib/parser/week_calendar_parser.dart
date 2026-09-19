/// 教学周历解析（周次 ↔ 日期对照）
///
/// 从鸿蒙版 `parser/WeekCalendarParser.ets` 移植。
///
/// ===== 这个页面有个坑，早期版本整整错位了 6 周 =====
/// 直觉做法是「把页面上所有 `MM月dd日` 按每 7 个一组切分」。
/// 但真实页面**只给周六周日写完整日期**，其它单元格只有一个日号。
/// 按 7 个一组切出来的第一组落在周六，于是整体偏移 6 天。
///
/// 真实结构是（已逐行核实）：
///   `<tr><td>1</td><td title='2026年08月24'>24</td>…`
/// 即：行首单元格是**周次**，第一个带 `title` 属性的单元格是**周一**。
/// 所以必须按行解析并读 `title` 属性 —— 这也是 `HtmlCell.openTag` 存在的原因。
library;

import '../model/models.dart';
import 'html_lite.dart';

class WeekCalendarParser {
  /// 找出周历表：前 3 行里含「星期一」的那张
  static HtmlTable? _findCalendarTable(String html) {
    for (final HtmlTable t in HtmlLite.parseTables(html)) {
      final int limit = t.rows.length < 3 ? t.rows.length : 3;
      for (int r = 0; r < limit; r++) {
        if (t.rows[r].text.contains('星期一')) {
          return t;
        }
      }
    }
    return null;
  }

  /// 解析「周次 → 周一日期」，monday 形如 `YYYY-MM-DD`
  static List<WeekDate> parseWeekDates(String html) {
    final List<WeekDate> out = <WeekDate>[];
    HtmlTable? table = _findCalendarTable(html);
    table ??= HtmlLite.findTableByHeader(html, '星期一');
    if (table == null) {
      return out;
    }

    final Map<int, String> byWeek = <int, String>{};
    for (final HtmlRow row in table.rows) {
      final List<HtmlCell> cells = row.cells;
      if (cells.isEmpty) {
        continue;
      }
      // 行首必须是周次数字
      final String head = cells[0].text.trim();
      if (!RegExp(r'^\d{1,2}$').hasMatch(head)) {
        continue;
      }
      final int? week = int.tryParse(head);
      if (week == null || week < 1) {
        continue;
      }
      // 第一个带 title 的单元格 = 周一
      for (int i = 1; i < cells.length; i++) {
        final String title = cells[i].attr('title');
        if (title.isEmpty) {
          continue;
        }
        final String? monday = _dateFromTitle(title);
        if (monday != null) {
          byWeek[week] = monday;
          break;
        }
      }
    }

    final List<int> weeks = byWeek.keys.toList()..sort();
    for (final int w in weeks) {
      out.add(WeekDate(w, byWeek[w]!));
    }
    return out;
  }

  /// `2026年08月24` → `2026-08-24`
  static String? _dateFromTitle(String title) {
    final RegExpMatch? m =
        RegExp(r'(\d{4})年(\d{1,2})月(\d{1,2})').firstMatch(title);
    if (m == null) {
      return null;
    }
    final int y = int.parse(m.group(1)!);
    final int mo = int.parse(m.group(2)!);
    final int d = int.parse(m.group(3)!);
    final String ms = mo < 10 ? '0$mo' : '$mo';
    final String ds = d < 10 ? '0$d' : '$d';
    return '$y-$ms-$ds';
  }

  /// 解析学年学期，形如 `2026-2027-1`
  static String parseSemester(String html) {
    final RegExpMatch? m = RegExp(r'(\d{4}-\d{4}-[123])').firstMatch(html);
    return m?.group(1) ?? '';
  }

  /// 按真实日期判断今天是第几周。
  ///
  /// **必须比较真实日期**（毫秒），不能比较 `MM-dd` 字符串 ——
  /// 后者在跨年时（12 月 → 1 月）必然算出错误结果。
  static int currentWeek(List<WeekDate> weeks, DateTime today) {
    if (weeks.isEmpty) {
      return 0;
    }
    final DateTime t = DateTime(today.year, today.month, today.day);
    int best = 0;
    for (final WeekDate w in weeks) {
      final List<String> parts = w.monday.split('-');
      if (parts.length != 3) {
        continue;
      }
      final int? y = int.tryParse(parts[0]);
      final int? mo = int.tryParse(parts[1]);
      final int? d = int.tryParse(parts[2]);
      if (y == null || mo == null || d == null) {
        continue;
      }
      final DateTime monday = DateTime(y, mo, d);
      if (!monday.isAfter(t)) {
        // 周一不晚于今天
        if (w.week > best) {
          best = w.week;
        }
      }
    }
    return best;
  }
}
