/// 校历（学期教学周历）的数据层测试
///
/// 守的是这次改动的核心承诺：**校历不再依赖随包图片，也不再有任何
/// 硬编码日期** —— 全部由教务系统的「教学周历」实时推导，
/// 因此换学年后自动跟上，不需要改代码。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/data/semester_calendar_service.dart';
import 'package:hisdufe_jw/model/models.dart';
import 'package:hisdufe_jw/parser/week_calendar_parser.dart';

String read(String name) =>
    File('test/fixtures/$name').readAsStringSync();

/// 用真实页面造一个 SemesterInfo（不碰网络）
SemesterInfo infoFromFixture() {
  final String html = read('weekcal.html');
  return SemesterInfo(
    code: WeekCalendarParser.parseSemester(html),
    weeks: WeekCalendarParser.parseWeekDates(html),
  );
}

void main() {
  group('可选学期列表（服务端为准，不自己推算年份）', () {
    test('从真实页面解析出全部学期，且按服务端顺序（新的在前）', () {
      final List<ChoiceItem> opts =
          WeekCalendarParser.parseSemesterOptions(read('weekcal.html'));
      expect(opts, isNotEmpty);
      expect(opts.first.value, '2026-2027-1', reason: '服务端把最新的放在最前');
      // 真实页面里 12 个学期
      expect(opts.length, 12);
      // 每个都必须是合法学期代码
      for (final ChoiceItem o in opts) {
        expect(o.value, matches(RegExp(r'^\d{4}-\d{4}-[123]$')));
      }
    });

    test('学期标签是可读文案，不是裸代码', () {
      final List<ChoiceItem> opts =
          WeekCalendarParser.parseSemesterOptions(read('weekcal.html'));
      final ChoiceItem first = opts.first;
      expect(first.label, '2026-2027 学年第一学期');
      expect(first.value, '2026-2027-1',
          reason: 'value 才是提交给服务端的键，不能被改写成文案');
    });

    test('没有 select 时返回空列表而不是抛异常', () {
      expect(WeekCalendarParser.parseSemesterOptions('<html></html>'), isEmpty);
    });

    test('选项里混入非学期代码（如「全部」）时被过滤掉', () {
      const String html = '<select name="xnxq01id">'
          '<option value="">全部</option>'
          '<option value="2026-2027-1">2026-2027-1</option>'
          '</select>';
      final List<ChoiceItem> opts =
          WeekCalendarParser.parseSemesterOptions(html);
      expect(opts.length, 1);
      expect(opts.first.value, '2026-2027-1');
    });

    test('重复出现的学期只保留一个', () {
      const String html = '<select name="xnxq01id">'
          '<option value="2026-2027-1">a</option>'
          '<option value="2026-2027-1">b</option>'
          '</select>';
      expect(WeekCalendarParser.parseSemesterOptions(html).length, 1);
    });
  });

  group('「当前显示的学期」必须取 selected 的那一项', () {
    test('真实页面：selected 就是当前学期', () {
      expect(WeekCalendarParser.parseSelectedSemester(read('weekcal.html')),
          '2026-2027-1');
    });

    test('请求旧学期时不会被页面里最新的学期代码带偏（回归）', () {
      // 回归背景：下拉列表永远「最新的在前」，所以请求 2025-2026-2 时，
      // 页面里**第一个出现**的学期代码仍是 2026-2027-1。
      // 早先取的是「第一个出现的代码」，于是标题写着第一学期、
      // 下面画的却是第二学期的日历 —— 界面看着正常，信息是错的。
      const String html = '<select name="xnxq01id">'
          '<option value="2026-2027-1">2026-2027-1</option>'
          '<option value="2025-2026-2" selected="selected">2025-2026-2</option>'
          '<option value="2025-2026-1">2025-2026-1</option>'
          '</select>';
      expect(WeekCalendarParser.parseSemester(html), '2026-2027-1',
          reason: '旧行为：第一个出现的代码');
      expect(WeekCalendarParser.parseSelectedSemester(html), '2025-2026-2',
          reason: '新行为：真正显示的那个');
    });

    test('selected 用单引号、或只有裸 selected 属性都能认', () {
      const String a = '<select name="xnxq01id">'
          "<option value='2025-2026-2' selected>2025-2026-2</option>"
          '</select>';
      expect(WeekCalendarParser.parseSelectedSemester(a), '2025-2026-2');

      const String b = '<select name="xnxq01id">'
          '<option value=2025-2026-2 selected>2025-2026-2</option>'
          '</select>';
      expect(WeekCalendarParser.parseSelectedSemester(b), '2025-2026-2');
    });

    test('选项里混进「全部」时不会把它当学期代码', () {
      const String html = '<select name="xnxq01id">'
          '<option value="" selected>全部</option>'
          '<option value="2026-2027-1">2026-2027-1</option>'
          '</select>';
      // 空值不是合法学期代码 → 退化为第一个合法选项，而不是返回空串
      expect(WeekCalendarParser.parseSelectedSemester(html), '2026-2027-1');
    });

    test('没有 select 时返回空串（服务端改版时不猜）', () {
      expect(WeekCalendarParser.parseSelectedSemester('<html></html>'), '');
    });
  });

  group('学期信息：全部由周历推导，无硬编码', () {
    test('开学日 = 第 1 周周一；总周数 = 最大周次', () {
      final SemesterInfo info = infoFromFixture();
      expect(info.isValid, isTrue);
      expect(info.firstMonday, '2026-08-24');
      expect(info.totalWeeks, 21);
      expect(info.lastDay, '2027-01-17', reason: '第 21 周周日');
    });

    test('某个学期的日期换了，推导结果跟着换（证明没有硬编码）', () {
      // 造一个「下学年」的周历：把第一学期整体往后推一年
      final SemesterInfo next = SemesterInfo(
        code: '2027-2028-1',
        weeks: <WeekDate>[
          WeekDate(1, '2027-08-23'),
          WeekDate(2, '2027-08-30'),
          WeekDate(3, '2027-09-06'),
        ],
      );
      expect(next.firstMonday, '2027-08-23');
      expect(next.totalWeeks, 3);
      expect(next.lastDay, '2027-09-12');
      // 同一份代码，两个学期的结果完全不同 —— 说明数据来自输入，
      // 而不是任何写死的常量
      expect(next.firstMonday, isNot(infoFromFixture().firstMonday));
    });

    test('currentWeek：今天是第几周', () {
      final SemesterInfo info = infoFromFixture();
      expect(info.weekOf(DateTime(2026, 8, 24)), 1, reason: '开学当天是第 1 周');
      expect(info.weekOf(DateTime(2026, 8, 30)), 1, reason: '第 1 周周日仍算第 1 周');
      expect(info.weekOf(DateTime(2026, 8, 31)), 2, reason: '第 2 周周一');
      expect(info.weekOf(DateTime(2026, 9, 20)), 4);
      // 学期开始前、结束后都是 0（不是负数、不是 1）
      expect(info.weekOf(DateTime(2026, 8, 23)), 0);
      expect(info.weekOf(DateTime(2027, 3, 1)), 0);
    });

    test('weekIndexByDay：一周里的每一天都能查到周次', () {
      final SemesterInfo info = infoFromFixture();
      final Map<String, int> byDay = info.weekIndexByDay();
      for (int i = 0; i < 7; i++) {
        final DateTime d = DateTime(2026, 8, 24).add(Duration(days: i));
        String two(int n) => n < 10 ? '0$n' : '$n';
        final String key = '${d.year}-${two(d.month)}-${two(d.day)}';
        expect(byDay[key], 1, reason: '$key 属于第 1 周');
      }
      // 学期外不出现
      expect(byDay['2026-08-23'], isNull);
      expect(byDay['2030-01-01'], isNull);
    });

    test('mondayOf：取不到时返回 null 而不是抛异常', () {
      final SemesterInfo info = infoFromFixture();
      expect(info.mondayOf(1)!.year, 2026);
      expect(info.mondayOf(999), isNull);
      expect(info.mondayOf(0), isNull);
    });

    test('空周历不算有效（界面据此不显示空月历）', () {
      final SemesterInfo empty = SemesterInfo(code: '2026-2027-1', weeks: <WeekDate>[]);
      expect(empty.isValid, isFalse);
      expect(empty.firstMonday, '');
      expect(empty.totalWeeks, 0);
      expect(empty.lastDay, '');
      expect(empty.weekOf(DateTime(2026, 9, 20)), 0);
    });

    test('日期字段损坏时跳过那一周，不影响其余周', () {
      final SemesterInfo info = SemesterInfo(
        code: 'x',
        weeks: <WeekDate>[
          WeekDate(1, '2026-08-24'),
          WeekDate(2, 'not-a-date'),
          WeekDate(3, '2026-09-07'),
        ],
      );
      expect(info.mondayOf(1), isNotNull);
      expect(info.mondayOf(2), isNull);
      expect(info.mondayOf(3), isNotNull);
      expect(info.weekOf(DateTime(2026, 9, 7)), 3);
    });
  });

  group('跨年：第 1 学期必然跨年', () {
    test('12 月与次年 1 月都能正确算周次', () {
      final SemesterInfo info = infoFromFixture();
      // 第 21 周是 2027-01-11 ~ 2027-01-17，已经跨到次年
      expect(info.weekOf(DateTime(2027, 1, 11)), 21);
      expect(info.weekOf(DateTime(2027, 1, 17)), 21);
      expect(info.weekOf(DateTime(2027, 1, 18)), 0, reason: '学期已结束');
      // 这一条如果按 MM-dd 字符串比较就必然算错（"01-11" < "12-01"）
      expect(info.weekOf(DateTime(2026, 12, 28)), 19);
    });
  });
}
