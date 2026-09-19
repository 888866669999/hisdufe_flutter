/// 教室课表解析
///
/// 从鸿蒙版 `parser/ClassroomParser.ets` 移植。
///
/// ===== 表头列数不固定 =====
/// 同一个结果表可能是 **8 列**（单节次查询：教室 + 7 天），
/// 也可能是 **36 列**（多节次：教室 + 5 节次 × 7 天）。
/// 因此**不能按列下标映射星期**，必须按表头文本里出现的
/// `星期一…星期日` 动态建映射，并且每天只取第一次出现。
///
/// ===== 两种占用形态 =====
///   - 课程：`课程名 教师\n(3-18周)\n班级`
///   - 借用：`被借用( 第(2周)(01-04节)周,王超,学生活动 )`
/// 借用形态是**字符串拼接**的结果，逗号分隔且带多余括号，
/// 需要把人物/事由拆出来单独展示。
library;

import '../model/classroom_models.dart';
import 'html_lite.dart';

class ClassroomParser {
  /// 读校区下拉。值形如 `3|章丘校区`（value|label），便于直接回传给接口。
  static List<String> parseCampuses(String html) {
    return HtmlLite.findSelect(html, 'xqid')
        .where((HtmlOption o) => o.value.isNotEmpty)
        .map((HtmlOption o) => '${o.value}|${o.label}')
        .toList();
  }

  /// 读学期下拉
  static List<String> parseSemesters(String html) {
    return HtmlLite.findSelect(html, 'xnxqh')
        .map((HtmlOption o) => o.value)
        .where((String v) => v.isNotEmpty)
        .toList();
  }

  /// 解析结果片段。
  ///
  /// @param sectionRow 查询的是第几个节次（用于多节次表时挑对应块）
  static ClassroomResult parseResult(String html, int sectionRow) {
    final ClassroomResult result = ClassroomResult(sectionRow: sectionRow);
    final HtmlTable? table = HtmlLite.findTableById(html, 'kbtable');
    if (table == null || table.rows.isEmpty) {
      return result;
    }

    // 1) 建「列 → 星期」映射
    final Map<int, int> dayOfCol = <int, int>{};
    final List<HtmlCell> header = table.rows[0].cells;
    for (int c = 0; c < header.length; c++) {
      final int d = _dayIndex(header[c].text);
      if (d >= 0 && !dayOfCol.containsValue(d)) {
        dayOfCol[c] = d;
      }
    }
    // 表头识别失败时退回「第 1 列起依次为周一到周日」
    if (dayOfCol.isEmpty) {
      for (int c = 1; c < header.length && c <= 7; c++) {
        dayOfCol[c] = c - 1;
      }
    }

    // 2) 数据行从第 2 行开始（第 1 行是节次标签）
    for (int r = 1; r < table.rows.length; r++) {
      final List<HtmlCell> cells = table.rows[r].cells;
      if (cells.isEmpty) {
        continue;
      }
      final String room = cells[0].text.trim();
      if (room.isEmpty || room.contains('教室')) {
        continue;
      }
      final RoomSlot slot = RoomSlot(room);
      for (final MapEntry<int, int> e in dayOfCol.entries) {
        if (e.key >= cells.length) {
          continue;
        }
        _parseCell(cells[e.key].inner, slot.days[e.value]);
      }
      result.rooms.add(slot);
    }
    return result;
  }

  /// `星期一` / `周一` 都认
  static int _dayIndex(String text) {
    const List<String> full = <String>[
      '星期一',
      '星期二',
      '星期三',
      '星期四',
      '星期五',
      '星期六',
      '星期日',
    ];
    const List<String> short = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    for (int i = 0; i < 7; i++) {
      if (text.contains(full[i]) || text.contains(short[i])) {
        return i;
      }
    }
    return -1;
  }

  /// 一个格子里可能有多条（`<br>` 分隔）
  static void _parseCell(String inner, List<RoomBooking> out) {
    if (inner.trim().isEmpty) {
      return;
    }
    final List<String> parts =
        inner.split(RegExp(r'<br\s*/?>', caseSensitive: false));
    bool any = false;
    for (final String part in parts) {
      final RoomBooking? b = _parseBooking(part);
      if (b != null) {
        out.add(b);
        any = true;
      }
    }
    if (!any) {
      // 有文本但没解析出结构：保守判为占用（宁可少报空闲，不要误报）
      final String text = HtmlLite.toText(inner).trim();
      if (text.isNotEmpty) {
        final WeekSpec? spec = WeekSpecParser.first(text);
        out.add(RoomBooking(
          label: text.split('\n').first,
          spec: spec ?? WeekSpec(<List<int>>[], 0, ''),
        ));
      }
    }
  }

  static RoomBooking? _parseBooking(String raw) {
    final String text = HtmlLite.toText(raw).trim();
    if (text.isEmpty) {
      return null;
    }

    // ---- 借用形态 ----
    if (text.contains('被借用')) {
      // 借用( 第(2周)(01-04节)周,王超,学生活动 )
      final String after = text.substring(text.indexOf('被借用') + 3);
      final RegExpMatch? m = RegExp(r'\(\s*([^)]*)\s*\)').firstMatch(after);
      final String inner = m?.group(1)?.trim() ?? '';
      final List<String> segs = inner
          .split(RegExp(r'[,，]'))
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      String person = '';
      String label = '被借用';
      if (segs.length >= 2 && !segs[1].contains('第')) {
        person = segs[1];
      }
      if (segs.length >= 3) {
        label = '借用：${segs[2].replaceAll(RegExp(r'[)）\s]+$'), '')}';
      }
      if (person.isNotEmpty) {
        label = '$label · $person';
      }
      final String weekSrc = text.contains('(') ? after : text;
      return RoomBooking(
        label: label,
        person: person,
        borrowed: true,
        spec: WeekSpecParser.first(weekSrc) ?? WeekSpec(<List<int>>[], 0, ''),
      );
    }

    // ---- 课程形态 ----
    // `课程名 教师\n(3-18周)\n班级`
    final int parenAt = text.indexOf('(');
    final String head = parenAt > 0 ? text.substring(0, parenAt) : text;
    final String tail = parenAt > 0 ? text.substring(parenAt) : '';

    final List<String> tokens = head.replaceAll('\n', ' ').split(RegExp(r'\s+'));
    String person = '';
    if (tokens.length >= 2) {
      final String last = tokens.last;
      if (RegExp(r'^[\u4e00-\u9fa5·]{2,6}$').hasMatch(last)) {
        person = last;
      }
    }
    final String label =
        person.isNotEmpty ? head.replaceFirst(RegExp('$person\$'), '').trim() : head.trim();

    String className = '';
    final int closeParen = tail.indexOf(')');
    if (closeParen >= 0 && closeParen + 1 < tail.length) {
      className = tail.substring(closeParen + 1).trim();
    }

    return RoomBooking(
      label: label.isEmpty ? head.trim() : label,
      person: person,
      className: className,
      spec: WeekSpecParser.first(text) ?? WeekSpec(<List<int>>[], 0, ''),
    );
  }
}
