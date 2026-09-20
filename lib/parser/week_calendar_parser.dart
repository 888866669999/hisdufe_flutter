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

  /// 解析**当前显示**的学期代码（`<option selected>` 的那个）。
  ///
  /// 不能用「页面里第一个出现的学期代码」：下拉列表永远是「最新的学期在前」，
  /// 所以请求「2025-2026-2」时页面里第一个出现的仍是 2026-2027-1，
  /// 于是会出现**标题写着第一学期、下面画的却是第二学期的日历** ——
  /// 界面上看着完全正常，信息却是错的（实测踩到）。
  /// 服务端会把真正显示的那个学期标成 selected，以它为准。
  static String parseSelectedSemester(String html) {
    final RegExpMatch? select =
        RegExp(r'<select[^>]*xnxq01id[^>]*>([\s\S]*?)</select>', caseSensitive: false)
            .firstMatch(html);
    if (select == null) {
      return '';
    }
    final String body = select.group(1) ?? '';
    // option 的写法可能是 value="..."、value='...' 或无值（把代码写成显示文本）
    for (final RegExpMatch m
        in RegExp(r'<option[^>]*>', caseSensitive: false).allMatches(body)) {
      final String tag = m.group(0) ?? '';
      if (!tag.contains('selected')) {
        continue;
      }
      final String? v = _attrValue(tag, 'value');
      if (v != null && RegExp(r'^\d{4}-\d{4}-[123]$').hasMatch(v)) {
        return v;
      }
    }
    // 没有任何 option 被标 selected（服务端偶尔省略）→ 退化为第一个合法选项，
    // 这仍然是「列表里的学期」而非页面正文里随手出现的数字
    return parseSemesterOptions(html).isEmpty
        ? ''
        : parseSemesterOptions(html).first.value;
  }

  /// 取 `name="v"` / `name='v'` / `name=v` 形式的属性值
  static String? _attrValue(String tag, String name) {
    final RegExpMatch? m = RegExp(
      "(?<![A-Za-z0-9_-])$name\\s*=\\s*([\\x22\\x27]?)([^\\x22\\x27>\\s]*)\\1",
      caseSensitive: false,
    ).firstMatch(tag);
    if (m == null) {
      return null;
    }
    final String v = m.group(2) ?? '';
    return v.isEmpty ? null : v;
  }

  /// 解析学年学期，形如 `2026-2027-1`
  ///
  /// 注意这取的是页面里**第一次出现**的学期代码，通常就是下拉里最新的那个。
  /// 要判断「当前显示的是哪个学期」请用 [parseSelectedSemester]。
  static String parseSemester(String html) {
    final RegExpMatch? m = RegExp(r'(\d{4}-\d{4}-[123])').firstMatch(html);
    return m?.group(1) ?? '';
  }

  /// 解析「可选学期」下拉，返回服务端真正排过课的学期（新的在前）。
  ///
  /// 服务端的 `<select name="xnxq01id">` 只列出**有教学周历的学期**，
  /// 因此这份列表是「哪些学期看得到校历」的权威答案 ——
  /// 比自己按当前年份推算可靠：推算出来的学期很可能点进去什么都没有。
  ///
  /// 只用 select 内 `<option>` 的 value，不用它的显示文本：
  /// 文本形如 `2026-2027-1`，与 value 相同，但 value 才是提交用的键。
  static List<ChoiceItem> parseSemesterOptions(String html) {
    final RegExpMatch? select =
        RegExp(r'<select[^>]*xnxq01id[^>]*>([\s\S]*?)</select>', caseSensitive: false)
            .firstMatch(html);
    if (select == null) {
      return <ChoiceItem>[];
    }
    final List<ChoiceItem> out = <ChoiceItem>[];
    // 引号用 \x22/\x27：单个原始字符串里不能同时放两种引号，
    // 而这里必须两种都容忍（同一个 CMS 的不同页面写法不一致）
    final RegExp optRe = RegExp(
      r"<option[^>]*value\s*=\s*[\x22\x27]?([^\x22\x27>\s]+)[\x22\x27]?[^>]*>",
      caseSensitive: false,
    );
    for (final RegExpMatch m in optRe.allMatches(select.group(1) ?? '')) {
      final String code = (m.group(1) ?? '').trim();
      // 只收形如 2026-2027-1 的代码：选项里混进「全部」之类的占位值时，
      // 它会变成一个切不过去的空学期
      if (!RegExp(r'^\d{4}-\d{4}-[123]$').hasMatch(code)) {
        continue;
      }
      if (out.any((ChoiceItem c) => c.value == code)) {
        continue;
      }
      out.add(ChoiceItem(_semesterLabel(code), code));
    }
    return out;
  }

  /// `2026-2027-1` → `2026-2027 学年第一学期`
  static String _semesterLabel(String code) {
    final List<String> seg = code.split('-');
    if (seg.length != 3) {
      return code;
    }
    final String term = seg[2] == '1'
        ? '第一学期'
        : seg[2] == '2'
            ? '第二学期'
            : '第三学期';
    return '${seg[0]}-${seg[1]} 学年$term';
  }

  /// 按真实日期判断今天是第几周。
  ///
  /// 必须比较**真实日期**，不能比较 `MM-dd` 字符串 ——
  /// 后者在跨年时（12 月 → 1 月）必然算出错误结果。
  ///
  /// 返回 0 表示「不在这个学期的教学周内」（还没开学、或已经放完假）。
  /// 这一点很关键：只看「周一不晚于今天」的话，学期结束后会一直返回
  /// 最后一周（21），于是寒暑假里界面上会显示「第 21 周」——
  /// 一个看起来正常、实则完全错误的数字。
  static int currentWeek(List<WeekDate> weeks, DateTime today) {
    if (weeks.isEmpty) {
      return 0;
    }
    final DateTime t = DateTime(today.year, today.month, today.day);
    int best = 0;
    for (final WeekDate w in weeks) {
      final DateTime? monday = mondayOf(w.monday);
      if (monday == null) {
        continue;
      }
      // 该周覆盖 [周一, 周日]；今天落在这一周里才算数
      final DateTime sunday = monday.add(const Duration(days: 6));
      if (!monday.isAfter(t) && !t.isAfter(sunday) && w.week > best) {
        best = w.week;
      }
    }
    return best;
  }

  /// `YYYY-MM-DD` → DateTime；非法返回 null
  static DateTime? mondayOf(String ymd) {
    final List<String> parts = ymd.split('-');
    if (parts.length != 3) {
      return null;
    }
    final int? y = int.tryParse(parts[0]);
    final int? mo = int.tryParse(parts[1]);
    final int? d = int.tryParse(parts[2]);
    if (y == null || mo == null || d == null) {
      return null;
    }
    if (mo < 1 || mo > 12 || d < 1 || d > 31) {
      return null;
    }
    return DateTime(y, mo, d);
  }
}
