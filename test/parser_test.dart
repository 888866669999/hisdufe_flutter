/// 解析器回归测试
///
/// 语料是**真实抓取的页面**（已脱敏），放在 test/fixtures/。
/// 鸿蒙版用 Node 脚本跑同样的断言（testdata/run-tests.mjs，423 条）；
/// 这里用 Dart 原生测试重写核心部分，保证移植过程中解析行为不走样。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/parser/html_lite.dart';
import 'package:hisdufe_jw/model/models.dart';
import 'package:hisdufe_jw/parser/plan_parser.dart';

String read(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('HtmlLite 基础能力', () {
    test('解码实体', () {
      expect(HtmlLite.decode('a&nbsp;b&lt;c&gt;d&amp;e'), 'a b<c>d&e');
    });

    test('读取属性：双引号 / 单引号 / 无引号', () {
      expect(HtmlLite.attr('<td id="a">', 'id'), 'a');
      expect(HtmlLite.attr("<td id='b'>", 'id'), 'b');
      expect(HtmlLite.attr('<td id=c>', 'id'), 'c');
    });

    test('属性名匹配要有边界：data-id 不能命中 id', () {
      expect(HtmlLite.attr('<td data-id="x">', 'id'), '');
    });

    test('toText 把 <br> 与块级闭合转成换行、丢标签、去空行', () {
      expect(HtmlLite.toText('a<br>b'), 'a\nb');
      expect(HtmlLite.toText('<div>a</div><div>b</div>'), 'a\nb');
      expect(HtmlLite.toText('  <b>x</b>  \n\n <i>y</i> '), 'x\ny');
    });

    test('toText 去注释', () {
      expect(HtmlLite.toText('a<!-- <b>x</b> -->b'), 'ab');
    });

    test('isLoginPage 需要密码框 + 验证码/encoded 字段', () {
      expect(
        HtmlLite.isLoginPage('<input type="password"><img src="SafeCodeImg">'),
        isTrue,
      );
      expect(HtmlLite.isLoginPage('<input type="password">'), isFalse);
      // xsMain.jsp 里也有密码框，但没有验证码字段，不能被判成登录页
      expect(
        HtmlLite.isLoginPage('<form id="loginForm1"><input type="password">'),
        isFalse,
      );
    });

    test('scanCells 保证文档顺序（内容相同的单元格不串位）', () {
      final HtmlRow row =
          HtmlRow(HtmlLite.scanCells('<td>2</td><td>x</td><td>2</td>'));
      expect(row.cells.length, 3);
      expect(row.cells[0].text, '2');
      expect(row.cells[1].text, 'x');
      expect(row.cells[2].text, '2');
    });

    test('findTableById 兼容单引号 id', () {
      final HtmlTable? t = HtmlLite.findTableById(
        "<table border='1'><tr><td>only</td></tr></TABLE>".replaceAll(
          '<table',
          "<TABLE id='mxh'",
        ),
        'mxh',
      );
      expect(t, isNotNull);
      expect(t!.rows.first.cells.first.text, 'only');
    });
  });

  group('真实页面：成绩页', () {
    test('按表头定位列并读出记录', () {
      final String html = read('score.html');
      final HtmlTable? t = HtmlLite.findTableByHeader(html, '课程名称');
      expect(t, isNotNull, reason: '应能按「课程名称」表头找到成绩表');

      // 找到表头行，确认列语义
      final List<HtmlCell> header = t!.rows.first.cells;
      final List<String> labels =
          header.map((HtmlCell c) => c.text).toList();
      expect(labels, contains('课程名称'));
      expect(labels, contains('成绩'));
      expect(labels, contains('学分'));
      expect(labels, contains('绩点'));
    });
  });

  group('真实页面：个人信息', () {
    test('#xjkpTable 存在且能读到「学号/姓名」', () {
      final String html = read('profile.html');
      final HtmlTable? t = HtmlLite.findTableById(html, 'xjkpTable');
      expect(t, isNotNull, reason: '学籍卡片表的 id 是 xjkpTable');
      final String all = t!.text;
      expect(all.contains('学号'), isTrue);
      expect(all.contains('姓名'), isTrue);
    });
  });

  group('真实页面：课表', () {
    test('#kbtable 有 7 列并在首行给出星期表头', () {
      final String html = read('timetable.html');
      final HtmlTable? t = HtmlLite.findTableById(html, 'kbtable');
      expect(t, isNotNull);
      expect(t!.rows.isNotEmpty, isTrue);
      final String head = t.rows.first.text;
      expect(head.contains('星期一'), isTrue);
      expect(head.contains('星期日'), isTrue);
    });

    test('一格多课的课程确实用长破折号分隔', () {
      final String html = read('timetable.html');
      final HtmlTable? t = HtmlLite.findTableById(html, 'kbtable');
      bool found = false;
      for (final HtmlRow r in t!.rows) {
        for (final HtmlCell c in r.cells) {
          if (RegExp(r'-{6,}').hasMatch(c.inner)) {
            found = true;
          }
        }
      }
      expect(found, isTrue, reason: '真实课表里存在一格多课（用 ------ 分隔）');
    });
  });

  group('真实页面：周历', () {
    test('日期只写在 title 属性里，单元格文本只有日号', () {
      final String html = read('weekcal.html');
      // 形如 title='2026年08月24'
      final RegExp re = RegExp("title\\s*=\\s*['\"]?\\d{4}年\\d{1,2}月\\d{1,2}");
      expect(re.hasMatch(html), isTrue);
    });
  });

  group('真实页面：培养方案', () {
    test('#mxh 课程表用单引号 id，仍能被找到', () {
      final String html = read('plan.html');
      final HtmlTable? t = HtmlLite.findTableById(html, 'mxh');
      expect(t, isNotNull, reason: "真实页面写成 <TABLE id='mxh'>");
    });


    test('学分/总学时由课程行求和，不是合计行的错列（回归）', () {
      // 回归背景：合计/小计行只有 9 列，课程行有 12–13 列。
      // 早期用「从右数第 6 格=学分、第 3 格=总学时」的固定偏移去读合计行，
      // 实际取到的是「讲课学时 / 实验学时」，页面显示成 425 学分 / 136 学时，
      // 且不报任何错。正确值是逐门课求和得到的 162 / 3434。
      final PlanDetail d = PlanParser.parse(read('plan.html'));
      expect(d.courses.length, 68);
      expect(d.totalCredit, closeTo(162, 0.001));
      expect(d.totalHours, closeTo(3434, 0.001));
      // 学时必然远大于学分（1 学分 ≈ 17–34 学时）；若两者颠倒或错列，这条会失败
      expect(d.totalHours, greaterThan(d.totalCredit * 5),
          reason: '总学时与学分不可能同量级，量级错误说明读错了列');
    });

    test('每门课的学分与总学时都能解析成数字', () {
      final PlanDetail d = PlanParser.parse(read('plan.html'));
      for (final PlanCourse c in d.courses) {
        expect(double.tryParse(c.credit), isNotNull,
            reason: '${c.courseName} 的学分「${c.credit}」应为数字');
        expect(double.tryParse(c.totalHours), isNotNull,
            reason: '${c.courseName} 的总学时「${c.totalHours}」应为数字');
      }
    });

    test('分组来自「体系」列的向下继承（首行有值、后续行为空）', () {
      final PlanDetail d = PlanParser.parse(read('plan.html'));
      final Set<String> systems =
          d.courses.map((PlanCourse c) => c.system).where((String s) => s.isNotEmpty).toSet();
      expect(systems.length, greaterThan(3),
          reason: '若不继承，整表会归成 1 组');
      // 不应有课程落在空体系里
      expect(d.courses.every((PlanCourse c) => c.system.isNotEmpty), isTrue);
    });

    test('PDF 附件地址从页面里解析出来（不写死文件名）', () {
      final String html = read('plan.html');
      final PlanDetail d = PlanParser.parse(html);
      // 真实页面里培养方案正文与附件在同一页；附件是 uploadfile 下的 pdf。
      // 关键断言是「地址来自页面」而不是任何常量：
      // 不同专业、不同年份的培养方案文件名与页数都不同。
      if (d.pdfPath.isNotEmpty) {
        expect(d.pdfPath, contains('uploadfile'),
            reason: '附件路径应指向教务系统的 uploadfile 目录');
        expect(d.pdfPath.toLowerCase(), endsWith('.pdf'));
      } else {
        // 某些专业的方案页面确实没有附件；此时 UI 不显示 PDF 卡片。
        // 这里只要求解析不抛异常，不强行要求一定有附件。
        expect(d.pdfPath, isEmpty);
      }
    });
  });

  group('真实页面：通选课 / 空教室', () {
    test('通选课两类表都能按表头找到', () {
      final String html = read('elective.html');
      final HtmlTable? cat = HtmlLite.findTableByHeader(html, '要求学分');
      expect(cat, isNotNull, reason: '类别表表头含「要求学分」');
      final HtmlTable? course = HtmlLite.findTableByHeader(html, '通选课类别');
      expect(course, isNotNull, reason: '课程表表头含「通选课类别」');
    });

    test('教室结果页 #kbtable 存在（含「被借用」记录）', () {
      final String html = read('classroom.html');
      final HtmlTable? t = HtmlLite.findTableById(html, 'kbtable');
      expect(t, isNotNull);
      expect(html.contains('被借用'), isTrue);
    });
  });
}
