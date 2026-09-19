/// 导航结构的契约测试
///
/// 锁定「空教室只有一个入口」这个决定：底部 dock / 宽屏侧栏都不再列它，
/// 但页面本身仍在（可从课表页顶栏进入），且顶栏标题必须正确。
///
/// 为什么值得写测试：这两件事很容易在后续改动里悄悄退化 ——
/// 有人把空教室加回导航列表（入口又变重复），或忘了给它配标题
/// （顶栏落到「山财教务」这个兜底文案上，看起来像进错了页面）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/pages/shell.dart';

void main() {
  group('底部 dock / 侧栏的导航项', () {
    test('不含空教室（它只保留课表页顶栏一个入口）', () {
      expect(
        kNavItems.any((NavItem n) => n.key == 'classroom'),
        isFalse,
        reason: '空教室不该再出现在 dock/侧栏里，否则入口重复',
      );
    });

    test('包含其余五个主页面', () {
      final List<String> keys =
          kNavItems.map((NavItem n) => n.key).toList();
      expect(keys, <String>['schedule', 'score', 'plan', 'elective', 'profile']);
    });

    test('key 唯一（重复会让选中态错位）', () {
      final Set<String> seen = <String>{};
      for (final NavItem n in kNavItems) {
        expect(seen.add(n.key), isTrue, reason: '重复的 key: ${n.key}');
      }
    });
  });

  group('不在导航项里、但有独立标题的页面', () {
    test('空教室与设置都有标题', () {
      expect(kExtraPageTitles['classroom'], '空教室');
      expect(kExtraPageTitles['settings'], '设置');
    });

    test('这些页面确实不在导航项里（否则标题会重复两处维护）', () {
      for (final String key in kExtraPageTitles.keys) {
        expect(
          kNavItems.any((NavItem n) => n.key == key),
          isFalse,
          reason: '$key 同时出现在两处，标题来源会打架',
        );
      }
    });
  });
}
