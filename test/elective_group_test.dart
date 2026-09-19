/// 通选课「大类 → 具体课程」归并与解析测试
///
/// 语料是真实抓取的页面（`test/fixtures/elective.html`）。
///
/// 覆盖的是这次改版最容易被改错的三件事：
///   1. 归并后**不能漏掉任何课程**，也不能多出空组；
///   2. 「大类没有课」与「课程没有大类」两个方向的错配都要兜住；
///   3. 学校留空「要求学分」时**不能画进度条**，也不能判成未达标。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/model/models.dart';
import 'package:hisdufe_jw/parser/elective_parser.dart';

String _html() => File('test/fixtures/elective.html').readAsStringSync();

void main() {
  group('解析真实页面', () {
    test('类别汇总与课程明细都能解析出来', () {
      final ElectiveReport r = ElectiveParser.parse(_html());
      expect(r.categories.length, greaterThan(5));
      expect(r.courses.length, greaterThan(5));
      // 总学分行不能被当成一个类别
      expect(r.categories.map((ElectiveCategory c) => c.name),
          isNot(contains('总学分')));
      expect(r.totalEarned, '8');
      expect(r.totalOngoing, '4');
    });
  });

  group('大类归并', () {
    test('汇总表里的大类全部保留，课程挂到对应大类下', () {
      final ElectiveReport r = ElectiveParser.parse(_html());
      final List<ElectiveGroup> g = r.grouped();

      // 每个汇总类别都在（即使本学期没有课）
      for (final ElectiveCategory c in r.categories) {
        expect(g.map((ElectiveGroup x) => x.name), contains(c.name),
            reason: '${c.name} 是有修读要求的大类，不能被隐藏');
      }

      // 每门课程都恰好落在自己的大类下
      for (final ElectiveCourse c in r.courses) {
        final String key = c.category.isEmpty ? '未标注类别' : c.category;
        final ElectiveGroup? group =
            g.where((ElectiveGroup x) => x.name == key).firstOrNull;
        expect(group, isNotNull, reason: '${c.courseName} 的类别 $key 应有对应分组');
        expect(group!.courses.contains(c), isTrue);
      }

      // 不丢课：分组内课程总数 == 原课程数
      final int total =
          g.fold<int>(0, (int s, ElectiveGroup x) => s + x.courses.length);
      expect(total, r.courses.length);
    });

    test('课程明细里出现、汇总表没有的大类会被追加（课程不能凭空消失）', () {
      final ElectiveReport r = ElectiveReport(
        categories: <ElectiveCategory>[
          ElectiveCategory(name: '人文艺术类', required: '4', earned: '4'),
        ],
        courses: <ElectiveCourse>[
          ElectiveCourse(
              courseName: '旅游文化学', category: '人文艺术类', credit: '2'),
          ElectiveCourse(
              courseName: '某新增课程', category: '新增大类', credit: '2'),
        ],
      );
      final List<ElectiveGroup> g = r.grouped();
      expect(g.length, 2);
      expect(g[1].name, '新增大类');
      expect(g[1].info, isNull);
      expect(g[1].courses.length, 1);
    });

    test('课程类别为空时归入「未标注类别」，不会丢掉', () {
      final ElectiveReport r = ElectiveReport(
        courses: <ElectiveCourse>[
          ElectiveCourse(courseName: '无类别课程', category: ''),
        ],
      );
      final List<ElectiveGroup> g = r.grouped();
      expect(g.length, 1);
      expect(g.first.name, '未标注类别');
      expect(g.first.courses.length, 1);
    });

    test('汇总表重名时只建一组，不重复', () {
      final ElectiveReport r = ElectiveReport(
        categories: <ElectiveCategory>[
          ElectiveCategory(name: '体育保健类', required: '', earned: '1'),
          ElectiveCategory(name: '体育保健类', required: '', earned: '1'),
        ],
      );
      expect(r.grouped().length, 1);
    });

    test('空报表不产生任何分组', () {
      expect(ElectiveReport().grouped(), isEmpty);
    });
  });

  group('进度条与达标判定', () {
    test('学校留空要求学分时：不画进度条，也不算未达标', () {
      final ElectiveReport r = ElectiveParser.parse(_html());
      // 真实页面里要求学分全为空
      for (final ElectiveGroup g in r.grouped()) {
        if (g.info != null && g.info!.required.isEmpty) {
          expect(g.canShowProgress, isFalse,
              reason: '${g.name} 没有分母，画进度条长度没有意义');
        }
      }
    });

    test('有要求学分且能解析成数字才画进度条', () {
      final ElectiveGroup ok = ElectiveGroup('人文艺术类')
        ..info = ElectiveCategory(name: '人文艺术类', required: '4', earned: '4');
      expect(ok.canShowProgress, isTrue);
      expect(ok.requiredNumber, 4);
      expect(ok.earnedNumber, 4);

      final ElectiveGroup blank = ElectiveGroup('财经特色类')
        ..info = ElectiveCategory(name: '财经特色类', required: '');
      expect(blank.canShowProgress, isFalse);

      final ElectiveGroup zero = ElectiveGroup('零要求')
        ..info = ElectiveCategory(name: '零要求', required: '0');
      expect(zero.canShowProgress, isFalse, reason: '分母为 0 会算出 NaN/Inf');

      final ElectiveGroup noInfo = ElectiveGroup('没有汇总信息');
      expect(noInfo.canShowProgress, isFalse);
    });
  });
}
