import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/parser/score_parser.dart';
import 'package:hisdufe_jw/parser/profile_parser.dart';
import 'package:hisdufe_jw/parser/week_calendar_parser.dart';
import 'package:hisdufe_jw/parser/plan_parser.dart';
import 'package:hisdufe_jw/parser/elective_parser.dart';
import 'package:hisdufe_jw/parser/classroom_parser.dart';
import 'package:hisdufe_jw/model/classroom_models.dart';

String read(String n) => File('test/fixtures/$n').readAsStringSync();

void main() {
  test('成绩：解析记录并汇总', () {
    final rs = ScoreParser.parse(read('score.html'));
    final s = ScoreParser.summarize(rs);
    // ignore: avoid_print
    print('scores=${rs.length} credit=${s.totalCredit} gpa=${s.weightedGpa}');
    expect(rs, isNotEmpty);
    for (final r in rs) {
      expect(r.courseName.isNotEmpty, isTrue);
    }
    // 加权绩点应在合理区间
    expect(s.weightedGpa, inInclusiveRange(0, 5));
  });

  test('个人信息：不产生子表列名假字段', () {
    final p = ProfileParser.parse(read('profile.html'));
    final labels = <String>[];
    for (final sec in p.sections) {
      for (final f in sec.fields) {
        labels.add(f.label);
      }
    }
    // ignore: avoid_print
    print('fields=${labels.length} name=${p.name} id=${p.studentId}');
    expect(labels, isNotEmpty);
    expect(labels.contains('学号'), isTrue);
    expect(labels.contains('姓名'), isTrue);
    // 子表列名不应成为字段
    expect(labels.any((l) => l.contains('起止年月')), isFalse);
    expect(labels.any((l) => l.contains('工作单位')), isFalse);
  });

  test('周历：21 周且周一递增 7 天', () {
    final wd = WeekCalendarParser.parseWeekDates(read('weekcal.html'));
    // ignore: avoid_print
    print('weeks=${wd.length} first=${wd.isNotEmpty ? wd.first.monday : ""}');
    expect(wd.length, greaterThan(10));
    expect(wd.first.week, 1);
    for (final w in wd) {
      expect(w.monday, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    }
    // 相邻周相差 7 天
    for (int i = 1; i < wd.length; i++) {
      expect(wd[i].week, wd[i - 1].week + 1);
      final a = DateTime.parse(wd[i - 1].monday);
      final b = DateTime.parse(wd[i].monday);
      expect(b.difference(a).inDays, 7);
    }
  });

  test('培养方案：课程表 + 分组（无 PDF）', () {
    final d = PlanParser.parse(read('plan.html'));
    // ignore: avoid_print
    print('courses=${d.courses.length} groups=${d.groups.length} '
        'credit=${d.totalCredit} hours=${d.totalHours}');
    expect(d.courses, isNotEmpty);
    expect(d.groups, isNotEmpty);
    for (final c in d.courses) {
      expect(c.courseName.isNotEmpty, isTrue);
    }
  });

  test('通选课：类别与课程', () {
    final r = ElectiveParser.parse(read('elective.html'));
    // ignore: avoid_print
    print('cats=${r.categories.length} courses=${r.courses.length} '
        'earned=${r.totalEarned} ongoing=${r.totalOngoing}');
    expect(r.categories, isNotEmpty);
    expect(r.courses, isNotEmpty);
    // 学校留空「要求学分」时不能判为达标
    for (final c in r.categories) {
      if (!c.hasRequirement) {
        expect(c.satisfied(), isFalse, reason: '未设置要求时不应判为已达标');
      }
    }
  });

  test('教室：解析占用并做周次过滤', () {
    final html = read('classroom.html');
    final options = ClassroomParser.parseCampuses(html);
    final res = ClassroomParser.parseResult(html, 0);
    // ignore: avoid_print
    print('rooms=${res.rooms.length} campuses=${options.length}');
    expect(res.rooms, isNotEmpty);

    // 取一周做统计，结果应与房间数一致（空闲 + 占用 = 总数）
    final stats = ClassroomFinder.weekStats(res, 4);
    expect(stats.length, 7);
    for (final st in stats) {
      expect(st.total, res.rooms.length);
      expect(st.free, inInclusiveRange(0, st.total));
    }
  });

  test('教室：楼号匹配必须严格（1 不能匹配 11-101）', () {
    expect(ClassroomFinder.belongsTo('11-101', '1'), isFalse);
    expect(ClassroomFinder.belongsTo('1-101', '1'), isTrue);
    expect(ClassroomFinder.belongsTo('9-316', '9'), isTrue);
  });

  test('教室：节次代码第 5 行是 09/11', () {
    expect(ClassroomFinder.sectionCodes(4), <String>['09', '11']);
    expect(ClassroomFinder.sectionCodes(0), <String>['01', '02']);
  });

  test('周次说明解析：区间 / 单双周 / 多段', () {
    final s1 = WeekSpecParser.first('(3-18周)');
    expect(s1, isNotNull);
    expect(s1!.isActive(3), isTrue);
    expect(s1.isActive(19), isFalse);

    // 真实写法是 (1-18双周) / (4单周)，不是嵌套括号
    final s2 = WeekSpecParser.first('(1-18双周)');
    expect(s2!.parity, 2);
    expect(s2.isActive(6), isTrue);
    expect(s2.isActive(7), isFalse);

    // (4单周) 是真实页面存在的**矛盾写法**：第 4 周是偶数却标「单周」。
    // 若无条件按奇偶过滤，这门课永远不会显示（静默丢课）。
    // 因此以显式周次为准，忽略不自洽的奇偶标记。
    final s2b = WeekSpecParser.first('(4单周)');
    expect(s2b!.parity, 1);
    expect(s2b.isActive(4), isTrue, reason: '显式周次应优先于不自洽的单双周标记');
    expect(s2b.isActive(5), isFalse);

    // 而自洽的写法仍要按单双周过滤（真实页面写作 1-18双周）
    final s2c = WeekSpecParser.first('(1-18双周)');
    expect(s2c, isNotNull);
    expect(s2c!.isActive(6), isTrue);
    expect(s2c.isActive(7), isFalse, reason: '区间内存在偶数周，双周标记有效');

    final s3 = WeekSpecParser.first('(1-2,4-5,7-8,10-11,13,15-18周)');
    expect(s3!.isActive(3), isFalse);
    expect(s3.isActive(4), isTrue);
    expect(s3.isActive(13), isTrue);
    expect(s3.isActive(14), isFalse);
    expect(s3.isActive(18), isTrue);
  });
}
