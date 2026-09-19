/// 成绩解析
///
/// 从鸿蒙版 `parser/ScoreParser.ets` 移植。
///
/// 列位置**按表头文本定位**而不是写死下标：真实表头是
/// `序号/开课学期/课程编号/课程名称/成绩/学分/绩点/考试性质/课程性质/课程属性/辅修课程`，
/// 但不同学期可能少一两列，写死下标会整行错位。
///
/// 注意 `学分` 与 `平均学分绩点` 这类包含关系：先精确匹配，再退回包含匹配，
/// 否则 `学分` 会命中「平均学分绩点」那一列。
library;

import '../model/models.dart';
import 'html_lite.dart';

class ScoreParser {
  static const List<String> _defaultCols = <String>[
    '序号',
    '开课学期',
    '课程编号',
    '课程名称',
    '成绩',
    '学分',
    '绩点',
    '考试性质',
    '课程性质',
    '课程属性',
    '辅修课程',
  ];

  static List<ScoreRecord> parse(String html) {
    final HtmlTable? table = HtmlLite.findTableByHeader(html, '课程名称') ??
        HtmlLite.findTableById(html, 'dataList');
    if (table == null) {
      return <ScoreRecord>[];
    }

    // 找表头行
    int headerRow = -1;
    final int limit = table.rows.length < 4 ? table.rows.length : 4;
    for (int r = 0; r < limit; r++) {
      if (table.rows[r].text.contains('课程名称')) {
        headerRow = r;
        break;
      }
    }
    if (headerRow < 0) {
      return <ScoreRecord>[];
    }

    final List<HtmlCell> header = table.rows[headerRow].cells;
    final List<String> labels = header.map((HtmlCell c) => c.text.trim()).toList();
    final Map<String, int> cols = <String, int>{};
    for (int i = 0; i < _defaultCols.length; i++) {
      cols[_defaultCols[i]] = _findCol(labels, _defaultCols[i], i);
    }

    final List<ScoreRecord> out = <ScoreRecord>[];
    for (int r = headerRow + 1; r < table.rows.length; r++) {
      final List<HtmlCell> cells = table.rows[r].cells;
      if (cells.length < 5) {
        continue;
      }
      final String joined = table.rows[r].text;
      if (joined.contains('未查询到数据')) {
        continue;
      }
      String at(String key) {
        final int? idx = cols[key];
        if (idx == null || idx < 0 || idx >= cells.length) {
          return '';
        }
        return cells[idx].text.trim();
      }

      final String name = at('课程名称');
      if (name.isEmpty) {
        continue;
      }
      out.add(ScoreRecord(
        index: at('序号'),
        semester: _firstNonEmpty(<String>[at('开课学期'), at('学期')]),
        courseCode: _firstNonEmpty(<String>[at('课程编号'), at('课程代码')]),
        courseName: name,
        score: at('成绩'),
        credit: at('学分'),
        gpa: at('绩点'),
        examType: at('考试性质'),
        courseNature: at('课程性质'),
        courseAttr: at('课程属性'),
        minor: at('辅修课程'),
      ));
    }
    return out;
  }

  /// 先精确匹配，再包含匹配
  static int _findCol(List<String> labels, String want, int fallback) {
    for (int i = 0; i < labels.length; i++) {
      if (labels[i] == want) {
        return i;
      }
    }
    for (int i = 0; i < labels.length; i++) {
      if (labels[i].contains(want)) {
        return i;
      }
    }
    return fallback;
  }

  static String _firstNonEmpty(List<String> xs) {
    for (final String x in xs) {
      if (x.isNotEmpty) {
        return x;
      }
    }
    return '';
  }

  /// 汇总：门数、总学分、加权绩点。
  ///
  /// 加权绩点只统计**有绩点**的课程（`gpaNumber() < 0` 的跳过），
  /// 否则会把「只有及格/不及格」的课程算成 0 绩点，把平均值拉低。
  static ScoreSummary summarize(List<ScoreRecord> records) {
    double creditSum = 0;
    double weighted = 0;
    for (final ScoreRecord r in records) {
      final double c = r.creditNumber();
      final double g = r.gpaNumber();
      if (g >= 0) {
        creditSum += c;
        weighted += g * c;
      }
    }
    final double avg = creditSum <= 0 ? 0 : weighted / creditSum;
    return ScoreSummary(
      records.length,
      (creditSum * 100).round() / 100,
      (avg * 1000).round() / 1000,
    );
  }

  /// 读学期下拉（`kksj`）
  static List<ChoiceItem> readSemesters(String html) {
    return HtmlLite.findSelect(html, 'kksj')
        .where((HtmlOption o) => o.value.isNotEmpty)
        .map((HtmlOption o) => ChoiceItem(
              o.label.isNotEmpty ? o.label : o.value,
              o.value,
            ))
        .toList();
  }
}
