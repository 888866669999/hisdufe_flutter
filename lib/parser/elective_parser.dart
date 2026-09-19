/// 通选课修读情况解析
///
/// 从鸿蒙版 `parser/ElectiveParser.ets` 移植。两张表都按表头关键字定位。
///
/// 一个必须保留的产品行为：学校**确实留空了「要求学分」**（实测页面如此）。
/// 因此界面不能判成「未达标」，而要显示「学校未设置要求」。
/// 早期版本把它当成 0，导致每一条都显示「已达标」，属于静默的错误结论。
library;

import '../model/models.dart';
import 'html_lite.dart';

class ElectiveParser {
  static ElectiveReport parse(String html) {
    final ElectiveReport r = ElectiveReport();

    // 类别表：表头含「要求学分」
    final HtmlTable? cat = HtmlLite.findTableByHeader(html, '要求学分');
    if (cat != null) {
      _readCategories(cat, r);
    }

    // 课程表：表头含「通选课类别」
    final HtmlTable? course = HtmlLite.findTableByHeader(html, '通选课类别');
    if (course != null) {
      _readCourses(course, r);
    }
    return r;
  }

  static void _readCategories(HtmlTable table, ElectiveReport r) {
    int headerRow = -1;
    final int limit = table.rows.length < 4 ? table.rows.length : 4;
    for (int i = 0; i < limit; i++) {
      if (table.rows[i].text.contains('要求学分')) {
        headerRow = i;
        break;
      }
    }
    if (headerRow < 0) {
      return;
    }

    for (int i = headerRow + 1; i < table.rows.length; i++) {
      final List<HtmlCell> cells = table.rows[i].cells;
      if (cells.length < 4) {
        continue;
      }
      String at(int n) => n < cells.length ? cells[n].text.trim() : '';
      final String name = at(0);
      if (name.isEmpty) {
        continue;
      }
      if (name.contains('总学分')) {
        r.totalEarned = at(2);
        r.totalOngoing = at(3);
        continue;
      }
      r.categories.add(ElectiveCategory(
        name: name,
        required: at(1),
        earned: at(2),
        ongoing: at(3),
      ));
    }
  }

  static void _readCourses(HtmlTable table, ElectiveReport r) {
    int headerRow = -1;
    final int limit = table.rows.length < 4 ? table.rows.length : 4;
    for (int i = 0; i < limit; i++) {
      if (table.rows[i].text.contains('通选课类别')) {
        headerRow = i;
        break;
      }
    }
    if (headerRow < 0) {
      return;
    }

    for (int i = headerRow + 1; i < table.rows.length; i++) {
      final List<HtmlCell> cells = table.rows[i].cells;
      if (cells.length < 5) {
        continue;
      }
      String at(int n) => n < cells.length ? cells[n].text.trim() : '';
      final String name = at(1);
      if (name.isEmpty || name == '课程名称') {
        continue;
      }
      r.courses.add(ElectiveCourse(
        courseCode: at(0),
        courseName: name,
        credit: at(2),
        score: at(3),
        category: at(4),
      ));
    }
  }
}
