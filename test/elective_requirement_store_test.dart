/// 通选课要求学分：存储与解析
///
/// 这些用例锁住的是几条容易改坏的行为：
///   - 按账号隔离（同机换账号不能串用）；
///   - 清除语义（value < 0 删掉该条，而不是写一个 -1 进去）；
///   - 输入解析的严格性（"12abc" 不能被当成 12 —— 那会让用户以为存了 12）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/common/constants.dart';
import 'package:hisdufe_jw/data/elective_requirement_store.dart';
import 'package:hisdufe_jw/data/pref_store.dart';
import 'package:hisdufe_jw/model/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PrefStore.resetCacheForTest();
    await PrefStore.init();
  });

  group('保存与读取', () {
    test('保存后能读回同一个值', () async {
      await ElectiveRequirementStore.save('u1', '安全教育类', 12);
      final Map<String, double> m = ElectiveRequirementStore.load('u1');
      expect(m['安全教育类'], 12);
    });

    test('小数被保留（培养方案里确实有 8.5 这种）', () async {
      await ElectiveRequirementStore.save('u1', '人文艺术类', 8.5);
      expect(ElectiveRequirementStore.load('u1')['人文艺术类'], 8.5);
    });

    test('同账号多个大类互不干扰', () async {
      await ElectiveRequirementStore.save('u1', 'A类', 4);
      await ElectiveRequirementStore.save('u1', 'B类', 6);
      final Map<String, double> m = ElectiveRequirementStore.load('u1');
      expect(m.length, 2);
      expect(m['A类'], 4);
      expect(m['B类'], 6);
    });

    test('重复保存同一个大类是覆盖，不是追加', () async {
      await ElectiveRequirementStore.save('u1', 'A类', 4);
      await ElectiveRequirementStore.save('u1', 'A类', 9);
      final Map<String, double> m = ElectiveRequirementStore.load('u1');
      expect(m.length, 1);
      expect(m['A类'], 9);
    });

    test('不同账号互相看不到（要求挂在专业上）', () async {
      await ElectiveRequirementStore.save('u1', 'A类', 4);
      expect(ElectiveRequirementStore.load('u2'), isEmpty);
      await ElectiveRequirementStore.save('u2', 'A类', 7);
      expect(ElectiveRequirementStore.load('u1')['A类'], 4);
      expect(ElectiveRequirementStore.load('u2')['A类'], 7);
    });

    test('空账号不读不写（避免把记录写到空键上）', () async {
      expect(await ElectiveRequirementStore.save('', 'A类', 4), isFalse);
      expect(ElectiveRequirementStore.load(''), isEmpty);
    });
  });

  group('清除语义', () {
    test('传 -1 是删除该条，而不是存一个 -1 进去', () async {
      await ElectiveRequirementStore.save('u1', 'A类', 4);
      await ElectiveRequirementStore.save('u1', 'A类', -1);
      expect(ElectiveRequirementStore.load('u1').containsKey('A类'), isFalse);

      // 底层也不该留下 -1（否则以后有别的读取路径会把它当成一个值）
      final String raw = PrefStore.getText(kKeyElectiveRequired);
      expect(raw.contains('-1'), isFalse);
    });

    test('清除一个不影响另一个', () async {
      await ElectiveRequirementStore.save('u1', 'A类', 4);
      await ElectiveRequirementStore.save('u1', 'B类', 6);
      await ElectiveRequirementStore.save('u1', 'A类', -1);
      final Map<String, double> m = ElectiveRequirementStore.load('u1');
      expect(m.containsKey('A类'), isFalse);
      expect(m['B类'], 6);
    });

    test('clearAccount 只删该账号的记录', () async {
      await ElectiveRequirementStore.save('u1', 'A类', 4);
      await ElectiveRequirementStore.save('u2', 'A类', 7);
      await ElectiveRequirementStore.clearAccount('u1');
      expect(ElectiveRequirementStore.load('u1'), isEmpty);
      expect(ElectiveRequirementStore.load('u2')['A类'], 7);
    });
  });

  group('输入解析', () {
    test('接受整数与一位小数', () {
      expect(ElectiveRequirementStore.parseInput('12'), 12);
      expect(ElectiveRequirementStore.parseInput('8.5'), 8.5);
      expect(ElectiveRequirementStore.parseInput(' 6 '), 6);
      // 0 也是合法的（「这一大类不用修」）
      expect(ElectiveRequirementStore.parseInput('0'), 0);
    });

    test('拒绝夹杂非数字的串（不能被读成 12）', () {
      expect(ElectiveRequirementStore.parseInput('12abc'), -1);
      expect(ElectiveRequirementStore.parseInput('abc'), -1);
      expect(ElectiveRequirementStore.parseInput('1.2.3'), -1);
      expect(ElectiveRequirementStore.parseInput(''), -1);
    });

    test('拒绝超出合理范围的值', () {
      expect(ElectiveRequirementStore.parseInput('201'), -1);
      expect(ElectiveRequirementStore.parseInput('-5'), -1);
      expect(ElectiveRequirementStore.parseInput('200'), 200);
    });
  });

  group('容错', () {
    test('存储内容损坏时当作空表，不抛异常', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kKeyElectiveRequired: 'not json at all',
      });
      PrefStore.resetCacheForTest();
      await PrefStore.init();
      expect(ElectiveRequirementStore.load('u1'), isEmpty);
      // 损坏之后仍能正常写入（会自动覆盖掉坏内容）
      expect(await ElectiveRequirementStore.save('u1', 'A类', 4), isTrue);
      expect(ElectiveRequirementStore.load('u1')['A类'], 4);
    });

    test('数组里混入非法项时跳过它们，保留合法项', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kKeyElectiveRequired: jsonEncode(<Object>[
          <String, Object>{'a': 'u1', 'c': 'A类', 'v': 4},
          <String, Object>{'a': 'u1', 'c': '', 'v': 5}, // 空大类名
          <String, Object>{'a': 'u1', 'v': 6}, // 缺大类名
          'a bare string', // 根本不是对象
          <String, Object>{'a': 'u1', 'c': 'B类', 'v': 999}, // 超上限
          <String, Object>{'a': 'u1', 'c': 'C类', 'v': 7},
        ]),
      });
      PrefStore.resetCacheForTest();
      await PrefStore.init();
      final Map<String, double> m = ElectiveRequirementStore.load('u1');
      expect(m.length, 2);
      expect(m['A类'], 4);
      expect(m['C类'], 7);
    });
  });

  group('与模型协作（防止「保存了但界面没变」）', () {
    test('叠加后 requiredNumber 用自录值，且标出来源', () {
      final ElectiveCategory info = ElectiveCategory(
        name: '安全教育类',
        required: '', // 学校留空 —— 真实页面就是这样
        earned: '1',
        ongoing: '0',
      );
      final ElectiveGroup g = ElectiveGroup('安全教育类')..info = info;

      // 没有自录值时：没有要求
      expect(g.requiredNumber, -1);
      expect(g.hasCustomRequired, isFalse);
      expect(g.canShowProgress, isFalse);

      // 自录 12 后立刻生效（这一步曾经漏掉，导致「保存了但界面没变」）
      g.customRequired = 12;
      expect(g.requiredNumber, 12);
      expect(g.hasCustomRequired, isTrue);
      expect(g.canShowProgress, isTrue);

      // 清除后回落到服务器的空值
      g.customRequired = -1;
      expect(g.requiredNumber, -1);
      expect(g.hasCustomRequired, isFalse);
    });

    test('用户自录优先于服务器给的值', () {
      final ElectiveGroup g = ElectiveGroup('某类')
        ..info = ElectiveCategory(
          name: '某类',
          required: '4', // 学校给了个值
          earned: '0',
          ongoing: '0',
        );
      expect(g.requiredNumber, 4);

      g.customRequired = 9;
      expect(g.requiredNumber, 9, reason: '用户按自己专业填的更准，应以它为准');
    });

    test('存档读回后能正确叠加到分组上', () async {
      await ElectiveRequirementStore.save('u1', '安全教育类', 12);
      final Map<String, double> saved =
          ElectiveRequirementStore.load('u1');

      final ElectiveGroup g = ElectiveGroup('安全教育类')
        ..info = ElectiveCategory(
          name: '安全教育类',
          required: '',
          earned: '1',
          ongoing: '3',
        );
      final double? v = saved[g.name];
      if (v != null) {
        g.customRequired = v;
      }

      expect(g.requiredNumber, 12);
      // 已修 1 + 在修 3 = 4 < 12 ⇒ 还差 8
      expect(g.earnedNumber + g.ongoingNumber, 4);
      expect(g.hasCustomRequired, isTrue);
    });
  });
}
