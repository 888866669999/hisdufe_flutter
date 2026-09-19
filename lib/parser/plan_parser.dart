/// 培养方案解析（含 PDF 附件路径）
///
/// 从鸿蒙版 `parser/PlanParser.ets` 移植。
///
/// ===== PDF 路径是动态提取的（不要写死）=====
/// 附件地址形如 `<iframe src="/ewebeditor/uploadfile/2025033110250359448.pdf">`，
/// 不同专业、不同年份的名字都不同，页数也不同。
/// 因此这里只从页面里**正则提取路径**，不做任何文件名或页数的假设。
///
/// ===== 页面结构 =====
///   - `#dataList`：引言表。其中「三、课程设置总表」是分隔标题，
///     其后的行才是课程数据（还有一层嵌套子表，需要识别并跳过）。
///   - `#mxh`：真正的课程表，**嵌套在 `#dataList` 内部**，
///     而且用单引号写 id（`<TABLE id='mxh'>`）。
///     这两点都踩过坑：早期的按 id 查找只扫最外层表，导致整张培养方案空白。
///
/// 课程行数据**从右往左读**：因为左侧的「选课组/课号」列数不固定，
/// 从右边数位置才是稳定的。
library;

import '../model/models.dart';
import 'html_lite.dart';

class PlanParser {
  /// 只有带这些前缀的才算正文小标题
  static const List<String> _sectionPrefixes = <String>['一、', '二、', '三、', '四、', '五、'];

  static PlanDetail parse(String html) {
    final PlanDetail detail = PlanDetail();

    final HtmlTable? dataList = HtmlLite.findTableById(html, 'dataList');
    if (dataList != null) {
      _readIntro(dataList, detail);
    }

    final HtmlTable? mxh = HtmlLite.findTableById(html, 'mxh');
    if (mxh != null) {
      _readCourses(mxh, detail);
    }

    detail.pdfPath = _parsePdfPath(html);
    detail.buildGroups();
    return detail;
  }

  /// 提取 PDF 附件相对地址。
  ///
  /// 直接匹配「路径本身」而不是 iframe 标签，这样不依赖引号风格与属性顺序
  /// （真实页面里出现过单引号、双引号混用）。
  static String _parsePdfPath(String html) {
    final RegExpMatch? m = RegExp(
      r'/[A-Za-z0-9_/.-]*uploadfile/[A-Za-z0-9_.%-]+\.pdf',
      caseSensitive: false,
    ).firstMatch(html);
    if (m != null && m.group(0)!.isNotEmpty) {
      return m.group(0)!;
    }
    // 兜底：任意位置的 .pdf 路径
    final RegExpMatch? m2 = RegExp(
      r'[A-Za-z0-9_/.-]+\.pdf',
      caseSensitive: false,
    ).firstMatch(html);
    return m2?.group(0) ?? '';
  }

  /// 读引言段落
  static void _readIntro(HtmlTable table, PlanDetail detail) {
    for (final HtmlRow row in table.rows) {
      // 课程表的行（含这些表头）不是引言
      final String joined = row.text;
      if (joined.contains('学时分类') && joined.contains('开设学期')) {
        continue;
      }
      for (final HtmlCell cell in row.cells) {
        final String raw = cell.text.trim();
        if (raw.isEmpty) {
          continue;
        }
        for (final String line in raw.split('\n')) {
          final String t = line.trim();
          if (t.isEmpty) {
            continue;
          }
          if (!_sectionPrefixes.any((String p) => t.startsWith(p))) {
            continue;
          }
          // 「课程设置总表」是分隔标题，不是正文
          if (t.contains('课程设置总表')) {
            continue;
          }
          final String body = _stripHeading(t);
          if (body.isEmpty) {
            continue;
          }
          if (t.contains('培养目标')) {
            detail.introParagraphs.add(body);
          } else {
            detail.detailParagraphs.add(body);
          }
        }
      }
    }
  }

  /// 去掉 `一、` 之类前缀与内嵌的「培养目标/详细说明」
  static String _stripHeading(String line) {
    String s = line;
    for (final String p in _sectionPrefixes) {
      if (s.startsWith(p)) {
        s = s.substring(p.length);
        break;
      }
    }
    s = s.replaceFirst(RegExp(r'^\s*培养目标'), '');
    s = s.replaceFirst(RegExp(r'^\s*详细说明'), '');
    return s.trim();
  }

  /// 读课程表：数据行 + 合计/小计
  ///
  /// **合计不读「合计行」，而是把课程行自己加起来。**
  /// 原因（实测，别再改回去）：合计/小计行的列数与课程行**不一样** ——
  /// 课程行 12–13 列，小计行只有 9 列（丢掉体系/选课组/课号/课程名称/类别
  /// 这些文字列，只留学分与 6 个学时分类再跟一个空列）。
  /// 早期用「从右数第 6 格 = 学分、第 3 格 = 总学时」这类固定偏移去读，
  /// 结果在两个不同列数的行上悄悄读错列：页面上显示成
  /// 「425 学分 / 136 学时」（实际取到的是讲课学时与实验学时），
  /// 既不是 425 也不是 136 该在的位置，而且**不报任何错**。
  /// 另外这个页面的合计行本身是坏的（服务端填的是 `-->`）。
  ///
  /// 求和法还有个附带好处：它天然与「课程设置总表」逐门课对得上，
  /// 用户能自己核对，不必相信一个来源不明的总数。
  static void _readCourses(HtmlTable table, PlanDetail detail) {
    String currentSystem = '';

    for (final HtmlRow row in table.rows) {
      final List<HtmlCell> cells = row.cells;
      if (cells.isEmpty) {
        continue;
      }
      final String first = cells[0].text.trim();

      // 合计 / 小计行：列布局与课程行不同，跳过（总数由课程行求和得出）
      if (first.startsWith('合计') || first.startsWith('小计')) {
        continue;
      }
      // 表头行（第一格是「体系」，或含「讲课学时」）
      if (first == '体系' || row.text.contains('讲课学时')) {
        continue;
      }
      // 数据行最少 12 列（右侧 10 项 + 选课组 + 体系）
      if (cells.length < 12) {
        continue;
      }

      final PlanCourse c = _readCourseFromRight(cells, currentSystem);
      if (c.courseName.isEmpty) {
        continue;
      }
      if (c.system.isNotEmpty) {
        currentSystem = c.system;
      }
      detail.courses.add(c);
    }

    // 学分与总学时：由课程行累加（见上方说明）
    double credit = 0;
    double hours = 0;
    for (final PlanCourse c in detail.courses) {
      credit += double.tryParse(c.credit) ?? 0;
      hours += double.tryParse(c.totalHours) ?? 0;
    }
    detail.totalCredit = credit;
    detail.totalHours = hours;
  }

  /// 从右往左读一行的课程数据。
  ///
  /// 真实表头（8 列）：`体系 | 选课组 | 课号 | 课程名称 | 类别 | 学分 | 学时分类 | 开设学期`
  /// 数据行的学时被展平成 6 列（讲课/实践/讲座/实验/上机/总学时），
  /// 因此数据行是 12–13 列。
  ///
  /// 关键点：**「体系」只在每个分组的首行出现**，后续行第 0 格是空的
  /// （靠 rowspan 视觉合并）。所以要向下继承，否则整表会归成一组 ——
  /// 实测这样就只剩 1 个分组，而正确结果是 6 个。
  ///
  /// 从右侧数的位置是稳定的（左侧列数因选课组是否为空而变化）：
  ///   开设学期、总学时、上机、实验、讲座、实践、讲课、学分、类别、课程名称、
  ///   课号、选课组（可选）
  static PlanCourse _readCourseFromRight(
    List<HtmlCell> cells,
    String inheritSystem,
  ) {
    String at(int fromEnd) {
      final int i = cells.length - 1 - fromEnd;
      if (i < 0 || i >= cells.length) {
        return '';
      }
      return cells[i].text.trim();
    }

    // 第 0 格是「体系」（仅分组首行有值）
    final String system = cells.isNotEmpty ? cells[0].text.trim() : '';
    // 第 1 格是「选课组」（可选，可能不存在）
    final String group = cells.length > 1 ? cells[1].text.trim() : '';

    return PlanCourse(
      semester: at(0),
      totalHours: at(1),
      computerHours: at(2),
      labHours: at(3),
      seminarHours: at(4),
      practiceHours: at(5),
      lectureHours: at(6),
      credit: at(7),
      category: at(8),
      courseName: at(9),
      courseCode: at(10),
      group: group,
      system: system.isNotEmpty ? system : inheritSystem,
    );
  }
}
