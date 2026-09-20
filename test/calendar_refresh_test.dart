/// 校历刷新与缓存的语义测试
///
/// 守三条用户明确要求的行为：
///   1. 点「刷新」必须**完整重取**（周历 + 学期列表；作息表与校历图在
///      campus_calendar_test 里覆盖）；
///   2. 刷新失败**不能**把已缓存的周历弄丢；
///   3. 系统时间超出周历范围时自动试拉一次，且**每天限一次**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/common/constants.dart';
import 'package:hisdufe_jw/data/page_cache.dart';
import 'package:hisdufe_jw/data/pref_store.dart';
import 'package:hisdufe_jw/model/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hisdufe_jw/data/semester_calendar_service.dart';

String read(String name) => File('test/fixtures/$name').readAsStringSync();

/// 构造一份「比真实周历早结束」的周历，用来模拟「系统时间已超出范围」。
///
/// 真实夹具是 2026-08-24 起 21 周（到 2027-01-17），今天（2026-09）仍在范围内，
/// 所以必须自己造一份过去的。
SemesterInfo pastSemester() => SemesterInfo(
      code: '2026-2027-1',
      weeks: <WeekDate>[
        WeekDate(1, '2026-01-05'),
        WeekDate(2, '2026-01-12'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 必须先丢掉缓存的实例：`PrefStore.init` 是 `??=` 语义，
    // 不清就会出现「上一个用例写的数据泄漏到下一个用例」——
    // 实测踩到：自动拉取的记账日期从上一个用例漏进了「学期为空」那个用例。
    PrefStore.resetCacheForTest();
    await PrefStore.init();
    PageCache.clearMemoryForTest();
    SemesterCalendarService.clearMemoryForTest();
    tmp = await Directory.systemTemp.createTemp('hisdufe_semcal');
    PageCache.debugSetDirForTest(tmp);
  });

  tearDown(() async {
    PageCache.debugSetDirForTest(null);
    PageCache.clearMemoryForTest();
    SemesterCalendarService.clearMemoryForTest();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  group('刷新失败不能丢掉已有缓存（回归）', () {
    test('load(force) 在缓存存在时会重新联网，但仍能拿到数据', () async {
      // 先放一条**已过期**的缓存（过期的最需要保护：它可能是唯一的离线副本）
      await PageCache.writeForTest(
        PageCache.keyOf('', kCacheSemesterCalendar, <String>['2026-2027-1']),
        read('weekcal.html'),
        DateTime.now().subtract(const Duration(days: 30)),
      );

      // 不联网（api 未初始化 → 请求必失败），走的是「联网抛异常」这条路径。
      // 断言重点：**有缓存时不会返回 null**，即旧数据被保住了。
      final SemesterInfo? got =
          await SemesterCalendarService.load('2026-2027-1', force: true);
      expect(got, isNotNull, reason: '刷新失败时必须回退到缓存，而不是返回空');
      expect(got!.isValid, isTrue);
      expect(got.firstMonday, '2026-08-24', reason: '回退拿到的就是缓存里的那份');
    });

    test('回退时 lastError 说明「显示的是上次数据」，与「完全没有」区分开', () async {
      await PageCache.writeForTest(
        PageCache.keyOf('', kCacheSemesterCalendar, <String>['2026-2027-1']),
        read('weekcal.html'),
        DateTime.now().subtract(const Duration(days: 30)),
      );
      await SemesterCalendarService.load('2026-2027-1', force: true);
      expect(SemesterCalendarService.lastError, contains('已显示上次的数据'));
    });

    test('完全没有缓存时返回 null（界面据此显示空态而不是假数据）', () async {
      final SemesterInfo? got =
          await SemesterCalendarService.load('2026-2027-1', force: true);
      expect(got, isNull);
      expect(SemesterCalendarService.lastError, isNotEmpty);
    });

    test('学期为空时直接返回 null，不发请求也不报错', () async {
      expect(await SemesterCalendarService.load(''), isNull);
      expect(SemesterCalendarService.lastError, isEmpty);
    });
  });

  group('loadCached：只读缓存、绝不联网', () {
    test('有缓存直接给出，不触发任何请求', () async {
      await PageCache.write(
        PageCache.keyOf('', kCacheSemesterCalendar, <String>['2026-2027-1']),
        read('weekcal.html'),
      );
      // api 未初始化，任何真实请求都会失败/抛异常；
      // 这里能拿到数据即证明没走网络
      final SemesterInfo? got = await SemesterCalendarService.loadCachedForTest(
          '2026-2027-1');
      expect(got, isNotNull);
      expect(got!.totalWeeks, 21);
    });

    test('没有缓存返回 null', () async {
      expect(await SemesterCalendarService.loadCachedForTest('2026-2027-1'),
          isNull);
    });
  });

  group('系统时间超出周历范围 → 每天最多自动拉一次', () {
    test('仍在学期内：不触发自动拉取', () async {
      // 真实学期 2026-08-24 ~ 2027-01-17，今天在其中
      await PageCache.write(
        PageCache.keyOf('', kCacheSemesterCalendar, <String>['2026-2027-1']),
        read('weekcal.html'),
      );
      final SemesterInfo? got =
          await SemesterCalendarService.autoFetchIfOutdated('2026-2027-1');
      expect(got, isNull, reason: '还没到假期，不该联网');
      // 不该写「今天试过」的标记，否则假期里第一次就会被跳过
      expect(PrefStore.loadSemesterAutoFetchDay(), isEmpty);
    });

    test('已超出范围：会尝试一次，并记下「今天试过」', () async {
      // 造一份早已结束的周历
      await PageCache.write(
        PageCache.keyOf('', kCacheSemesterCalendar, <String>['2026-2027-1']),
        _htmlForPastSemester(),
      );
      final SemesterInfo? got =
          await SemesterCalendarService.autoFetchIfOutdated('2026-2027-1');
      // 测试环境没有会话，联网必然失败；此时服务层会回退到缓存，
      // 但**不能**把「又拿回同一份旧数据」当成功上报 ——
      // 否则界面会弹「已获取到新学期的教学周历」，而实际什么都没变。
      expect(got, isNull, reason: '拿回的仍是旧数据时不该报成功');
      expect(PrefStore.loadSemesterAutoFetchDay(), isNotEmpty,
          reason: '试过就要记账，否则每次启动都会重试');
    });

    test('同一天内第二次调用：**完全不碰网络**（这就是「每天限一次」）', () async {
      await PageCache.write(
        PageCache.keyOf('', kCacheSemesterCalendar, <String>['2026-2027-1']),
        _htmlForPastSemester(),
      );
      await SemesterCalendarService.autoFetchIfOutdated('2026-2027-1');
      final String day = PrefStore.loadSemesterAutoFetchDay();
      expect(day, isNotEmpty);

      // 把缓存删掉并清掉上次的错误信息：若第二次调用真的「跳过」，
      // 它就不会去 load()，因而不会因缓存缺失而联网、也不会写 lastError。
      // 这一条比「返回 null」强 —— 后者在「跳过」和「试了但失败」时都成立。
      await PageCache.remove(
          PageCache.keyOf('', kCacheSemesterCalendar, <String>['2026-2027-1']));
      SemesterCalendarService.clearMemoryForTest();

      final SemesterInfo? second =
          await SemesterCalendarService.autoFetchIfOutdated('2026-2027-1');
      expect(second, isNull);
      expect(SemesterCalendarService.lastError, isEmpty,
          reason: '跳过时不该有任何联网痕迹（lastError 为空即证明没走请求）');
      expect(PrefStore.loadSemesterAutoFetchDay(), day, reason: '记账日期不变');
    });

    test('学期为空：不做事、不记账', () async {
      expect(await SemesterCalendarService.autoFetchIfOutdated(''), isNull);
      expect(PrefStore.loadSemesterAutoFetchDay(), isEmpty);
    });

    test('记账是「上次试过的日期」，不是布尔值（这样跨天会自动恢复）', () async {
      await PrefStore.saveSemesterAutoFetchDay('2025-01-01');
      // 昨天的记录不该拦住今天（内部按 == 今天比较）
      await PageCache.write(
        PageCache.keyOf('', kCacheSemesterCalendar, <String>['2026-2027-1']),
        _htmlForPastSemester(),
      );
      await SemesterCalendarService.autoFetchIfOutdated('2026-2027-1');
      expect(PrefStore.loadSemesterAutoFetchDay(), isNot('2025-01-01'),
          reason: '跨天之后应当重新有机会尝试');
    });
  });

  group('weekIndexByDay 与月历渲染共用同一份数据', () {
    test('超出范围的周历：weekOf 返回 0（界面显示今天不在学期内）', () {
      final SemesterInfo past = pastSemester();
      expect(past.weekOf(DateTime.now()), 0);
      // 最后一周周日之后一天
      expect(past.weekOf(DateTime(2026, 1, 19)), 0);
      expect(past.weekOf(DateTime(2026, 1, 12)), 2);
    });
  });
}

/// 造一份「已经结束」的周历页面：两行，日期都在过去
String _htmlForPastSemester() => '''
<table>
<tr><td>周次</td><td>星期一</td></tr>
<tr><td>1</td><td title='2026年01月05'>05</td></tr>
<tr><td>2</td><td title='2026年01月12'>12</td></tr>
</table>
''';
