/// 节次作息存储的契约测试
///
/// 这里锁住的是两个**已在真机上暴露过**的缺陷，都属于「界面看着正常、
/// 数据却是错的」那类，靠肉眼回归极难发现：
///
///   1. **保存不生效**：弹窗里改了时刻，点保存后存储没变。根因是保存时
///      写的是「打开弹窗时的旧 draft」而不是「校验通过的输入框新值」。
///      这个 bug 在 store 层看不出来（`saveAll` 本身没问题），
///      因此在设置页那一层补一个端到端的断言 —— 见
///      `test/section_time_save_test.dart` 的 widget 测试。
///   2. **官网改动只同步一次**：判据曾是「存储值 == 包内常量」，
///      一旦同步过就不再相等，于是被判成「用户自定义」而永久停止同步。
///      这里锁住新的来源标记语义。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/common/constants.dart';
import 'package:hisdufe_jw/data/pref_store.dart';
import 'package:hisdufe_jw/data/section_time_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 造一个与官方值不同的作息（每段整体后移 5 分钟）
List<SectionTime> _shifted() => kSections
    .map((SectionDef s) => SectionTime(s.index, s.label, s.start, s.end))
    .toList()
    .asMap()
    .entries
    .map((MapEntry<int, SectionTime> e) => SectionTime(
          e.value.index,
          e.value.label,
          '08:35',
          e.value.end,
        ))
    .toList();

void main() {
  setUp(() async {
    // 每个用例都从「干净的存储」开始。两步都要做：
    //   1. 换掉底层 mock store；
    //   2. 清掉 PrefStore 与 SectionTimeStore 的进程内静态缓存 ——
    //      `init()` 是幂等的（`??=`），不清缓存的话第 1 步对已缓存的
    //      实例无效，用例会看到上一个用例写的数据（实测踩过）。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PrefStore.resetCacheForTest();
    await PrefStore.init();
    await SectionTimeStore.resetCacheForTest();
  });

  group('来源标记：区分「官网同步」与「用户手改」', () {
    test('全新安装时是官方值', () {
      expect(SectionTimeStore.isDefault(), isTrue);
      expect(SectionTimeStore.all().first.start, kSections.first.start);
    });

    test('用户保存后判为自定义', () async {
      await SectionTimeStore.saveAll(_shifted());
      expect(SectionTimeStore.isDefault(), isFalse);
    });

    test('官网同步后**仍然**是官方值（这是关键的一条）', () async {
      // 模拟官网把第一节改成 08:35
      await SectionTimeStore.saveOfficial(_shifted());

      // 值确实变了
      expect(SectionTimeStore.all().first.start, '08:35');
      // 但「来源」仍是官方 —— 于是下一次官网再改，还能同步进来。
      // 旧实现会在这一步失败：它会拿 08:35 与包内常量 08:30 比，判成自定义。
      expect(SectionTimeStore.isDefault(), isTrue);
    });

    test('同步多次不会累积成「自定义」', () async {
      for (int i = 0; i < 3; i++) {
        await SectionTimeStore.saveOfficial(_shifted());
      }
      expect(SectionTimeStore.isDefault(), isTrue);
    });

    test('用户改过之后，官网同步值不再被写入', () async {
      await SectionTimeStore.saveAll(_shifted());
      expect(SectionTimeStore.isDefault(), isFalse);

      // 再走一次同步路径（真实调用方会先查 isDefault，这里直接调
      // saveOfficial 也应当只写值、不改来源 —— 标记由调用方把关）
      await SectionTimeStore.saveOfficial(_shifted());
      expect(SectionTimeStore.isDefault(), isFalse);
    });

    test('恢复官方会清掉自定义标记，重新可被同步', () async {
      await SectionTimeStore.saveAll(_shifted());
      expect(SectionTimeStore.isDefault(), isFalse);

      await SectionTimeStore.resetToDefault();

      expect(SectionTimeStore.isDefault(), isTrue);
      expect(SectionTimeStore.all().first.start, kSections.first.start);
    });
  });

  group('持久化', () {
    test('保存的值能跨「重启」读回来', () async {
      await SectionTimeStore.saveAll(_shifted());

      // 模拟重启：清掉内存缓存，从存储重新加载
      await SectionTimeStore.resetCacheForTest();
      await SectionTimeStore.load();

      expect(SectionTimeStore.all().first.start, '08:35');
      expect(SectionTimeStore.isDefault(), isFalse);
    });

    test('官网同步的值也能跨重启读回，且来源仍是官方', () async {
      await SectionTimeStore.saveOfficial(_shifted());

      await SectionTimeStore.resetCacheForTest();
      await SectionTimeStore.load();

      expect(SectionTimeStore.all().first.start, '08:35');
      expect(SectionTimeStore.isDefault(), isTrue);
    });

    test('存储损坏（段数与课表不符）时回退到官方值，不崩', () async {
      await PrefStore.saveSectionTimes('08:00-09:00;10:00-11:00');

      await SectionTimeStore.resetCacheForTest();
      await SectionTimeStore.load();

      expect(SectionTimeStore.all().length, kSections.length);
      expect(SectionTimeStore.all().first.start, kSections.first.start);
    });

    test('存储里出现非数字内容时回退到官方值，不崩', () async {
      await PrefStore.saveSectionTimes('abc;def;ghi;jkl;mno');

      await SectionTimeStore.resetCacheForTest();
      await SectionTimeStore.load();

      // 脏值**整份**回退到官方值：解析层不接受任何非法时刻
      // （否则脏值会流到提醒计算里，表现为「某节课提醒时间莫名其妙」）。
      // 断言用 510（= 08:30）而不是 -1：-1 是 toMinutes 的「非法」约定，
      // 出现在这里反而说明脏值被存下来了。
      final String start = SectionTimeStore.all().first.start;
      expect(SectionTimeStore.toMinutes(start), 510, reason: '实际读到: $start');
      expect(SectionTimeStore.isDefault(), isTrue);
    });
  });

  group('validateAndBuild：把输入框内容变成可保存的作息', () {
    /// 五个合法输入，用于做「只改一处」的对照
    List<String> okStarts() => <String>['08:30', '10:20', '14:00', '15:50', '18:40'];
    List<String> okEnds() => <String>['10:00', '11:50', '15:30', '17:20', '21:05'];
    List<String> labels() =>
        <String>['第一、二节', '第三、四节', '第五、六节', '第七、八节', '第九~十一节'];

    test('返回值取自**输入**，而不是任何旧的草稿', () {
      // 这就是「保存不生效」的核心契约：改了第一节的起始时间，
      // 返回值里必须带上新值。旧实现保存的是打开弹窗时的 draft，
      // 于是校验看了一眼新值、存下去的还是旧值。
      final List<String> s = okStarts();
      s[0] = '09:15';

      String? err;
      final List<SectionTime>? out = SectionTimeStore.validateAndBuild(
        starts: s,
        ends: okEnds(),
        labels: labels(),
        error: (String m) => err = m,
      );

      expect(err, isNull);
      expect(out, isNotNull);
      expect(out!.first.start, '09:15');
      // 其余保持原样
      expect(out[1].start, '10:20');
      expect(out.length, kSections.length);
    });

    test('自动补零成 HH:mm', () {
      final List<String> s = okStarts();
      s[0] = '8:5';
      final List<String> e = okEnds();
      e[0] = '9:7';

      final List<SectionTime>? out = SectionTimeStore.validateAndBuild(
        starts: s,
        ends: e,
        labels: labels(),
        error: (_) {},
      );

      expect(out!.first.start, '08:05');
      expect(out.first.end, '09:07');
    });

    test('两端空白被忽略', () {
      final List<String> s = okStarts();
      s[0] = '  08:30  ';
      final List<SectionTime>? out = SectionTimeStore.validateAndBuild(
        starts: s,
        ends: okEnds(),
        labels: labels(),
        error: (_) {},
      );
      expect(out!.first.start, '08:30');
    });

    test('格式非法时返回 null 并给出带节次名的说明', () {
      final List<String> s = okStarts();
      s[2] = '25:00'; // 小时越界

      String? err;
      final List<SectionTime>? out = SectionTimeStore.validateAndBuild(
        starts: s,
        ends: okEnds(),
        labels: labels(),
        error: (String m) => err = m,
      );

      expect(out, isNull);
      expect(err, contains('第五、六节'));
      expect(err, contains('HH:mm'));
    });

    test('结束早于开始时报错（并指出是哪一节）', () {
      final List<String> e = okEnds();
      e[3] = '08:00'; // 早于同节的 15:50

      String? err;
      final List<SectionTime>? out = SectionTimeStore.validateAndBuild(
        starts: okStarts(),
        ends: e,
        labels: labels(),
        error: (String m) => err = m,
      );

      expect(out, isNull);
      expect(err, contains('第七、八节'));
      expect(err, contains('晚于'));
    });

    test('开始与结束相同也算错（零长度的一节课没有意义）', () {
      final List<String> e = okEnds();
      e[0] = okStarts()[0];

      final List<SectionTime>? out = SectionTimeStore.validateAndBuild(
        starts: okStarts(),
        ends: e,
        labels: labels(),
        error: (_) {},
      );
      expect(out, isNull);
    });

    test('三个列表长度不一致时拒绝，不静默截断', () {
      final List<SectionTime>? out = SectionTimeStore.validateAndBuild(
        starts: <String>['08:30'],
        ends: <String>['10:00'],
        labels: <String>['第一、二节', '第三、四节'],
        error: (_) {},
      );
      expect(out, isNull);
    });

    test('返回值可直接交给 saveAll 并落盘', () async {
      final List<String> s = okStarts();
      s[4] = '19:00';
      final List<SectionTime>? out = SectionTimeStore.validateAndBuild(
        starts: s,
        ends: okEnds(),
        labels: labels(),
        error: (_) {},
      );
      await SectionTimeStore.saveAll(out!);

      await SectionTimeStore.resetCacheForTest();
      await SectionTimeStore.load();

      expect(SectionTimeStore.all().last.start, '19:00');
      expect(SectionTimeStore.isDefault(), isFalse);
    });
  });

  group('toMinutes 边界', () {
    test('合法时刻', () {
      expect(SectionTimeStore.toMinutes('00:00'), 0);
      expect(SectionTimeStore.toMinutes('08:30'), 510);
      expect(SectionTimeStore.toMinutes('23:59'), 1439);
    });

    test('非法输入一律 -1（不是 0，也不是抛异常）', () {
      for (final String bad in <String>[
        '',
        '8',
        '08',
        '08:',
        ':30',
        '24:00',
        '23:60',
        '-1:00',
        'aa:bb',
        '08:30:00',
      ]) {
        expect(SectionTimeStore.toMinutes(bad), -1, reason: '输入: "$bad"');
      }
    });
  });
}
