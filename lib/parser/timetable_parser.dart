/// 课表解析（`#kbtable`）
///
/// 从鸿蒙版 `parser/TimetableParser.ets` 移植。
///
/// ===== 页面结构（已对着真实页面核实）=====
/// `#kbtable` 共 7 个有效行：
///   - 第 0 行：星期表头 `星期一…星期日`；
///   - 第 1..5 行：五个节次（第一、二节 … 第九~十一节）；
///   - 最后一行 `#bz_td`（colspan=7）：备注，形如
///     「教学安排中未排课表课程：A , B」。
/// 列 0 是节次名，列 1..7 对应周一到周日。
///
/// 每个格子内部有两层同内容的 div：`kbcontent1`（简略）与 `kbcontent`（含教师）。
/// **只解析其中一层**，否则同一门课会被加两遍。
///
/// 一门课的文本形态（多门课之间用 `----------------------` 分隔）：
///   课程名 [教师] 1-18(周) 或 (双周) 或 (单周)，后跟 7-120(章丘)
/// 页面在 `<font title="老师">` 这类属性里给了语义标签，优先按属性取值，
/// 取不到再用正则兜底（不同学期页面写法略有差异）。
library;

import '../common/constants.dart';
import '../model/models.dart';
import 'html_lite.dart';

class TimetableParseResult {
  TimetableParseResult(this.timetable, this.semesters, this.weeks);

  final Timetable timetable;
  final List<String> semesters;
  final List<String> weeks;
}

class TimetableParser {
  /// 一格多课的分隔符：6 个及以上连续短横
  static final RegExp _multiSep = RegExp(r'-{6,}');

  static TimetableParseResult parse(String html, String semester, String week) {
    // 请求时可能**没有指定学期**（首次启动、本地还没记录过），
    // 此时服务端返回的是「它认为的当前学期」，并以 selected 标出。
    // 必须把这个值回填到 tt.semester，否则：
    //   - 课表拿不到学期名 → TimetableStore.save 因 semester 为空直接失败
    //     → 首次启动永远存不下缓存，每次启动都要联网；
    //   - 会话一旦失效，明明取到过课表却没有任何缓存可看。
    // 因此「请求值优先，请求为空时取服务端选中项」。
    final List<HtmlOption> semOpts = HtmlLite.findSelect(html, 'xnxq01id');
    final List<HtmlOption> weekOpts = HtmlLite.findSelect(html, 'zc');
    final String sem =
        semester.isNotEmpty ? semester : _selectedValue(semOpts);
    final String wk = week.isNotEmpty ? week : _selectedValue(weekOpts);

    final Timetable tt = Timetable()
      ..semester = sem
      ..week = wk;

    final HtmlTable? table = HtmlLite.findTableById(html, 'kbtable');
    if (table == null) {
      return TimetableParseResult(tt, _values(semOpts), _values(weekOpts));
    }

    int sectionRow = 0;
    for (final HtmlRow row in table.rows) {
      if (_isRemarkRow(row)) {
        tt.remark = _remarkText(row);
        continue;
      }
      // 头部行（含星期表头）跳过
      if (_isHeaderRow(row)) {
        continue;
      }
      // 数据行：列 0 是节次名，列 1..7 是周一到周日
      if (sectionRow >= kSectionRows) {
        continue;
      }
      for (int c = 1; c < row.cells.length && c <= kWeekdayCols; c++) {
        final HtmlCell cell = row.cells[c];
        final List<CourseEntry> entries =
            _parseCell(cell, sectionRow, c - 1);
        if (entries.isEmpty) {
          continue;
        }
        final CellData cd = tt.ensureCell(sectionRow, c - 1);
        cd.entries.addAll(entries);
      }
      sectionRow++;
    }

    tt.semesters = _values(semOpts);
    tt.weeks = _values(weekOpts);
    return TimetableParseResult(tt, tt.semesters, tt.weeks);
  }

  /// 取下拉框里被服务端标记为 selected 的值；没有就退回第一项。
  ///
  /// 退回第一项是有意的：教务系统的学期下拉一般按「最新在前」排序，
  /// 且实测服务端总会给当前学期打上 selected。若某次没打标记，
  /// 用第一项比用空串好 —— 空串会让缓存写入整体失效（见 parse 的说明）。
  static String _selectedValue(List<HtmlOption> opts) {
    for (final HtmlOption o in opts) {
      if (o.selected && o.value.isNotEmpty) {
        return o.value;
      }
    }
    for (final HtmlOption o in opts) {
      if (o.value.isNotEmpty) {
        return o.value;
      }
    }
    return '';
  }

  static List<String> _values(List<HtmlOption> opts) => opts
      .map((HtmlOption o) => o.value)
      .where((String v) => v.isNotEmpty)
      .toList();

  /// 是否是备注行：单格且 colspan 很大，或单元格 id 是 bz_td，
  /// 或首格文本含「备注」
  static bool _isRemarkRow(HtmlRow row) {
    if (row.cells.length == 1) {
      final HtmlCell c = row.cells.first;
      if (c.colspan >= 5 || c.id == 'bz_td') {
        return true;
      }
    }
    if (row.cells.length == 2) {
      final String first = row.cells[0].text;
      if (first.contains('备注') || row.cells[1].id == 'bz_td') {
        return true;
      }
    }
    return false;
  }

  static String _remarkText(HtmlRow row) {
    for (final HtmlCell c in row.cells) {
      if (c.id == 'bz_td' && c.text.isNotEmpty) {
        return c.text;
      }
    }
    for (final HtmlCell c in row.cells) {
      if (c.colspan >= 5 && c.text.isNotEmpty) {
        return c.text;
      }
    }
    return '';
  }

  /// 是否是表头行（含星期表头，或整行都没有课程内容）
  static bool _isHeaderRow(HtmlRow row) {
    final String joined = row.text;
    if (joined.contains('星期一') && joined.contains('星期日')) {
      return true;
    }
    // 有些页面第一行是「节次 / 星期一 …」在同一行
    if (joined.contains('星期一') && row.cells.length >= 6) {
      return true;
    }
    return false;
  }

  /// 只取一层内容（优先含教师的详细层）
  static String _pickBlock(String inner) {
    final RegExp detailed = RegExp(
      r'<div[^>]*class\s*=\s*["\u0027][^"\u0027]*\bkbcontent\b[^"\u0027]*["\u0027][^>]*>([\s\S]*?)</div>',
      caseSensitive: false,
    );
    final RegExpMatch? dm = detailed.firstMatch(inner);
    if (dm != null && (dm.group(1) ?? '').trim().isNotEmpty) {
      return dm.group(1)!;
    }
    final RegExp simple = RegExp(
      r'<div[^>]*class\s*=\s*["\u0027][^"\u0027]*kbcontent1[^"\u0027]*["\u0027][^>]*>([\s\S]*?)</div>',
      caseSensitive: false,
    );
    final RegExpMatch? sm = simple.firstMatch(inner);
    if (sm != null && (sm.group(1) ?? '').trim().isNotEmpty) {
      return sm.group(1)!;
    }
    return inner;
  }

  static List<CourseEntry> _parseCell(HtmlCell cell, int row, int col) {
    final String block = _pickBlock(cell.inner);
    if (HtmlLite.toText(block).trim().isEmpty) {
      return <CourseEntry>[];
    }
    final List<CourseEntry> out = <CourseEntry>[];

    // 一格多课：按长破折号切开，各自独立解析
    final List<String> chunks = _multiSep.hasMatch(block)
        ? block.split(_multiSep)
        : <String>[block];

    for (final String chunk in chunks) {
      final CourseEntry? e = _parseOne(chunk, row, col);
      if (e != null && e.courseName.isNotEmpty) {
        out.add(e);
      }
    }
    return out;
  }

  static CourseEntry? _parseOne(String chunk, int row, int col) {
    if (chunk.trim().isEmpty) {
      return null;
    }
    final CourseEntry e = CourseEntry(id: '', courseName: '');

    // 1) 优先用 <font title="…"> 的语义标签
    bool hasSemantic = false;
    final RegExp fontRe = RegExp(
      r'<font[^>]*title\s*=\s*["\u0027]([^"\u0027]*)["\u0027][^>]*>([\s\S]*?)</font>',
      caseSensitive: false,
    );
    for (final RegExpMatch m in fontRe.allMatches(chunk)) {
      final String title = HtmlLite.decode(m.group(1) ?? '');
      final String value = HtmlLite.toText(m.group(2) ?? '').trim();
      if (value.isEmpty) {
        continue;
      }
      if (title.contains('老师') || title.contains('教师')) {
        e.teacher = value;
        hasSemantic = true;
      } else if (title.contains('周次') || title.contains('节次')) {
        e.weekText = value;
        hasSemantic = true;
      } else if (title.contains('教室') || title.contains('地点')) {
        _applyRoom(e, value);
        hasSemantic = true;
      }
    }
    if (hasSemantic) {
      _applyWeek(e, e.weekText);
    }

    // 2) 课程名 = 去掉所有 <font> 后的第一行
    String withoutFont = chunk.replaceAll(fontRe, ' ');
    final String nameText = HtmlLite.toText(withoutFont).trim();
    e.courseName = nameText.split('\n').first.trim();

    // 3) 语义标签不足时，用正则从原文兜底
    if (e.weekText.isEmpty) {
      final String all = HtmlLite.toText(chunk);
      _fillFromText(e, all);
    }
    if (e.room.isEmpty || e.campus.isEmpty) {
      final String all = HtmlLite.toText(chunk);
      _fillRoomFromText(e, all);
    }

    // 4) 稳定的 id：同一门课每次解析都能得到同一个 id
    e.id = 'srv-$row-$col-${e.courseName}-${e.startWeek}-${e.endWeek}-${e.parity}';
    return e;
  }

  /// 教室文本形如 `9-316(章丘)` 或 `7-120(章丘)`
  static void _applyRoom(CourseEntry e, String value) {
    final RegExp re = RegExp(r'^(.+?)\s*[（(]\s*([^)）]+)\s*[)）]\s*$');
    final RegExpMatch? m = re.firstMatch(value.trim());
    if (m != null) {
      e.room = m.group(1)!.trim();
      e.campus = m.group(2)!.trim();
    } else {
      e.room = value.trim();
    }
  }

  /// 从整段文本兜底提取周次/教室/教师
  static void _fillFromText(CourseEntry e, String text) {
    final RegExp weekRe = RegExp(
      r'\d+\s*[-—~]+\s*\d+\s*\(\s*(单|双)?周\s*\)|\(\s*(单|双)?周\s*\)',
    );
    final RegExpMatch? wm = weekRe.firstMatch(text);
    if (wm != null) {
      e.weekText = wm.group(0)!;
      _applyWeek(e, e.weekText);
    }

    for (final String line in text.split('\n')) {
      final String t = line.trim();
      if (t.isEmpty || t == e.courseName) {
        continue;
      }
      // 教师启发式：职称，或 2–6 个汉字/间隔号
      if (e.teacher.isEmpty &&
          (RegExp(r'讲师|副教授|教授|助教|工程师|研究员').hasMatch(t) ||
              RegExp(r'^[\u4e00-\u9fa5·]{2,6}$').hasMatch(t))) {
        e.teacher = t;
      }
    }
  }

  /// 教室兜底：`数字开头的房间号(校区)`
  static void _fillRoomFromText(CourseEntry e, String text) {
    final RegExp re = RegExp(
      r'([0-9A-Za-z\-]+)\s*[（(]\s*([\u4e00-\u9fa5]{2,6})\s*[)）]',
    );
    for (final RegExpMatch m in re.allMatches(text)) {
      final String room = m.group(1) ?? '';
      if (room.isNotEmpty && RegExp(r'^\d').hasMatch(room)) {
        e.room = room;
        e.campus = m.group(2) ?? '';
        return;
      }
    }
  }

  /// 从周次文本解析起始/结束周与单双周
  static void _applyWeek(CourseEntry e, [String? text]) {
    final String t = (text == null || text.isEmpty) ? e.weekText : text;
    if (t.contains('双周')) {
      e.parity = 2;
    } else if (t.contains('单周')) {
      e.parity = 1;
    } else {
      e.parity = 0;
    }
    final RegExpMatch? r = RegExp(r'(\d+)\s*[-—~]+\s*(\d+)').firstMatch(t);
    if (r != null) {
      e.startWeek = int.tryParse(r.group(1)!) ?? 1;
      e.endWeek = int.tryParse(r.group(2)!) ?? 18;
    } else {
      final RegExpMatch? single = RegExp(r'(\d+)').firstMatch(t);
      if (single != null) {
        final int v = int.tryParse(single.group(1)!) ?? 1;
        e.startWeek = v;
        e.endWeek = v;
      }
    }
    if (e.endWeek < e.startWeek) {
      final int tmp = e.startWeek;
      e.startWeek = e.endWeek;
      e.endWeek = tmp;
    }
  }
}
