/// 官网校历抓取解析测试
///
/// 语料是**真实抓取**的官网页面（`test/fixtures/campus_calendar.html`，
/// 2026 年 9 月抓取），不是手写的最小样例 —— 因为这一块的风险恰好是
/// 「学校改版后解析悄悄失效」，用手写样例测不出真实结构里的嵌套与转义。
///
/// 重点覆盖三件事：
///   1. 作息表能解析出正确的 5 个节次 + 3 个课间休息（顺序不能错位）；
///   2. 校历图地址能取出、去重、转成绝对地址（`&amp;` 必须还原成 `&`）；
///   3. 官网作息能正确归并成课表的 5 行（第九、十节 + 第十一节 要合并），
///      且**行数不足时必须拒绝映射**，不能按错位时间算提醒。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/data/campus_calendar_service.dart';

String _fixture() => File('test/fixtures/campus_calendar.html').readAsStringSync();

void main() {
  test('从真实官网页面解析出作息表（含课间休息，顺序正确）', () {
    final List<String> lines = CampusCalendarService.parseSectionLines(_fixture());
    expect(lines, isNotEmpty);

    // 官方的「日常教学时刻表」把节次**逐个**列出，与课表的行划分并不一一对应：
    // 前 4 行各含两节，最后两行分别是「第九、十节」和「第十一节」→ 共 6 行。
    // 这个差异必须承认，不能假设官网就是 5 行（否则会误判解析失败）。
    final List<String> teach =
        lines.where((String l) => !l.contains('课间')).toList();
    expect(teach.length, 6);
    expect(teach[0], '第一、二节  08:30 - 10:00');
    expect(teach[1], '第三、四节  10:20 - 11:50');
    expect(teach[2], '第五、六节  14:00 - 15:30');
    expect(teach[3], '第七、八节  15:50 - 17:20');
    expect(teach[4], '第九、十节  18:40 - 20:10');
    expect(teach[5], '第十一节  20:20 - 21:05');

    // 3 个课间休息
    final List<String> breaks =
        lines.where((String l) => l.contains('课间')).toList();
    expect(breaks.length, 3);
    expect(breaks[0], '课间休息  10:00 - 10:20');
    expect(breaks[1], '课间休息  15:30 - 15:50');
    expect(breaks[2], '课间休息  20:10 - 20:20');
  });

  test('课间休息紧跟在其所属节次之后（不能错位）', () {
    final List<String> lines = CampusCalendarService.parseSectionLines(_fixture());
    int at(String text) => lines.indexWhere((String l) => l.startsWith(text));

    // 第一、二节 → 课间 10:00-10:20 → 第三、四节
    expect(at('第一、二节'), lessThan(at('课间休息  10:00')));
    expect(at('课间休息  10:00'), lessThan(at('第三、四节')));
    // 第五、六节 → 课间 15:30-15:50 → 第七、八节
    expect(at('第五、六节'), lessThan(at('课间休息  15:30')));
    expect(at('课间休息  15:30'), lessThan(at('第七、八节')));
    // 第九、十节 → 课间 20:10-20:20 → 第十一节
    expect(at('第九、十节'), lessThan(at('课间休息  20:10')));
    expect(at('课间休息  20:10'), lessThan(at('第十一节')));
  });

  test('解析校历图：绝对地址、去重、还原 &amp;', () {
    final List<String> urls = CampusCalendarService.parseImageUrls(
        _fixture(), kCalendarPageUrl);
    expect(urls.length, 2, reason: '官网校历图恰好两张（两个学期）');
    for (final String u in urls) {
      expect(u, startsWith('https://www.sdufe.edu.cn/'));
      expect(u, isNot(contains('&amp;')));
      expect(u, contains('.jpg'));
    }
    // 去重：两张图地址必须不同
    expect(urls[0] == urls[1], isFalse);
    // 取的是原图属性（CMS 里拼作 `orisrc`），不是 800px 的展示版 `src`。
    // 注意：所有附属图地址的尾部查询串是相同的，只能整串比较，
    // 用「后缀相同」判断会永远为真、测不出取错属性。
    final String oriUrl = RegExp(r'orisrc="([^"]+)"')
        .allMatches(_fixture())
        .first
        .group(1)!
        .replaceAll('&amp;', '&');
    expect(urls.first, 'https://www.sdufe.edu.cn$oriUrl');
    final String srcUrl = RegExp(r'(?<![a-z])src="(/virtual_attach_file[^"]+)"')
        .allMatches(_fixture())
        .first
        .group(1)!
        .replaceAll('&amp;', '&');
    expect(urls.first, isNot('https://www.sdufe.edu.cn$srcUrl'),
        reason: '取到 src 说明属性名匹配退化成了子串匹配');
  });

  test('官网作息归并成课表 5 行（最后一行合并九~十一节）', () {
    final List<String> lines = CampusCalendarService.parseSectionLines(_fixture());
    final List<List<String>>? rows = CampusCalendarService.mapToGridRows(lines);
    expect(rows, isNotNull);
    expect(rows!.length, 5);
    expect(rows[0], <String>['08:30', '10:00']);
    expect(rows[1], <String>['10:20', '11:50']);
    expect(rows[2], <String>['14:00', '15:30']);
    expect(rows[3], <String>['15:50', '17:20']);
    // 第九、十节(18:40-20:10) + 第十一节(20:20-21:05) 合成 18:40-21:05
    expect(rows[4], <String>['18:40', '21:05']);
  });

  test('官网作息少于 5 行时必须拒绝映射（宁可不用，也不能错位）', () {
    final List<String> tooFew = <String>[
      '第一、二节  08:30 - 10:00',
      '第三、四节  10:20 - 11:50',
      '课间休息  10:00 - 10:20',
    ];
    expect(CampusCalendarService.mapToGridRows(tooFew), isNull);
  });

  test('归并结果与内置官方值一致（内置值确实是官方值）', () {
    final List<String> lines = CampusCalendarService.parseSectionLines(_fixture());
    final List<List<String>> rows = CampusCalendarService.mapToGridRows(lines)!;
    // 与 kOfficialSections 逐行比对：若有一天官网改了时间，这条会失败，
    // 提醒我们需要同步更新内置兜底值与 docs/技术笔记.md。
    const List<List<String>> expected = <List<String>>[
      <String>['08:30', '10:00'],
      <String>['10:20', '11:50'],
      <String>['14:00', '15:30'],
      <String>['15:50', '17:20'],
      <String>['18:40', '21:05'],
    ];
    expect(rows, expected);
  });

  test('解析官网更新时间', () {
    expect(CampusCalendarService.parseUpdated(_fixture()), '2026年7月');
  });

  test('页面改版（无作息表）时返回空而不是抛异常', () {
    expect(CampusCalendarService.parseSectionLines('<html><body>维护中</body></html>'),
        isEmpty);
    expect(
        CampusCalendarService.parseImageUrls(
            '<html><img src="/images/logo.png"></html>', kCalendarPageUrl),
        isEmpty);
    expect(CampusCalendarService.parseUpdated('<html></html>'), '');
  });

  test('时间格式归一化：单位数补零、兼容全角与波浪线', () {
    // 通过 parseSectionLines 间接验证（_normalizeRange 是私有的）
    const String html = '<table><tr><td>节次</td><td>起止时间</td></tr>'
        '<tr><td>第一、二节</td><td>8:30-10:00</td></tr>'
        '<tr><td>第三、四节</td><td>10：20－11：50</td></tr>'
        '<tr><td>第五、六节</td><td>14:00~15:30</td></tr>'
        '<tr><td>第七、八节</td><td>15:50-17:20</td></tr>'
        '<tr><td>第九~十一节</td><td>18:40-21:05</td></tr></table>';
    final List<String> out = CampusCalendarService.parseSectionLines(html);
    expect(out.length, 5);
    expect(out[0], '第一、二节  08:30 - 10:00');
    expect(out[1], '第三、四节  10:20 - 11:50');
    expect(out[2], '第五、六节  14:00 - 15:30');
    expect(out[4], '第九~十一节  18:40 - 21:05');
  });
}
