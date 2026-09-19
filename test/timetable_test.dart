import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/parser/timetable_parser.dart';

void main() {
  test('课表解析（真实页面）', () {
    final html = File('test/fixtures/timetable.html').readAsStringSync();
    final r = TimetableParser.parse(html, '2026-2027-1', '');
    final tt = r.timetable;

    // 统计
    int courses = 0;
    for (final c in tt.cells) {
      courses += c.entries.length;
    }
    print('rows(section) with data: ${tt.cells.length}');
    print('total course entries: $courses');
    print('remark: "${tt.remark}"');
    print('semesters: ${r.semesters}');
    print('weeks(count): ${r.weeks.length}');

    // 逐格打印，便于肉眼核对
    for (final c in tt.cells) {
      for (final e in c.entries) {
        print('  [row=${c.row} col=${c.col}] "${e.courseName}" '
            'teacher="${e.teacher}" room="${e.room}" campus="${e.campus}" '
            'week=${e.startWeek}-${e.endWeek} parity=${e.parity}');
      }
    }

    expect(courses, greaterThan(0), reason: '应解析出课程');
    for (final c in tt.cells) {
      expect(c.row, inInclusiveRange(0, 4));
      expect(c.col, inInclusiveRange(0, 6));
      for (final e in c.entries) {
        expect(e.courseName.isNotEmpty, isTrue, reason: '课程名不应为空');
      }
    }
  });

  group('学期自动回填（回归）', () {
    // 首次启动时本地没有任何学期记录，请求会传 semester=''。
    // 服务端返回它认为的当前学期（<option ... selected="selected">）。
    // 若解析器不回填这个值，tt.semester 就是空串，而 TimetableStore.save
    // 对空学期直接返回 false —— 表现为「每次启动都要联网，且断网/会话失效时
    // 明明取到过课表却没有任何缓存」，是个静默的功能性缺陷。
    test('请求未指定学期时，取服务端 selected 的学期', () {
      final String html = File('test/fixtures/timetable.html').readAsStringSync();
      final TimetableParseResult r = TimetableParser.parse(html, '', '');
      expect(r.timetable.semester, '2026-2027-1',
          reason: '必须回填服务端选中的学期，否则缓存无法落盘');
    });

    test('请求显式指定学期时，以请求值为准（不信任服务端 selected）', () {
      final String html = File('test/fixtures/timetable.html').readAsStringSync();
      final TimetableParseResult r =
          TimetableParser.parse(html, '2025-2026-2', '');
      expect(r.timetable.semester, '2025-2026-2',
          reason: '用户主动切学期时，请求的学期才是权威');
    });

    test('没有任何 option 时返回空串而不是抛异常', () {
      final TimetableParseResult r =
          TimetableParser.parse('<html><body>无课表</body></html>', '', '');
      expect(r.timetable.semester, '');
      expect(r.timetable.week, '');
    });
  });
}
