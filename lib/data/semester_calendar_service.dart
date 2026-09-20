/// 学期信息：从教务系统的「教学周历」构建。
///
/// ===== 为什么不用学校官网的校历图片 =====
/// 官网那张校历是**图片**，而且一年换一张。早先的做法是把 2026 学年的两张图
/// 随包内置（`assets/calendar_2026_{1,2}.jpg`，约 740KB），结果是：
///   - 2027 年之后装到的新版本，内置图就是**过期的**，界面上却看不出来
///     —— 用户会照着去年的日期安排行程；
///   - 图片里的信息（周次、开学日、假期边界）无法参与计算，
///     只能靠人工转录成常量，转录一次就固定了，同样不随年份更新；
///   - 每张 1.4MB，白占安装包体积。
///
/// 教务系统的「教学周历查看」（`/jsxsd/jxzl/jxzl_query`）是同一个信息的
/// **结构化**版本：一张「第 N 周 ←→ 周一日期」的对照表，学校每学期排课时录入。
/// 用它做唯一数据源，就同时解决了上面三个问题 ——
/// 换学年后取到的是新数据，无需改代码、无需换图、也不占包体积。
///
/// ===== 缓存 =====
/// 走通用的 [PageDataLoader]（内存 → 磁盘 → 网络，见 page_cache.dart），
/// 按「学期」分 key：切学期时各自命中各自的缓存，且离线可用。
library;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../common/constants.dart';
import '../model/models.dart';
import '../parser/week_calendar_parser.dart';
import 'app_state.dart';
import 'page_cache.dart';
import 'pref_store.dart';

/// 一个学期的教学安排（全部由校历周次表推导，无硬编码日期）
class SemesterInfo {
  SemesterInfo({
    required this.code,
    required this.weeks,
  });

  /// 学期代码，如 `2026-2027-1`
  final String code;

  /// 「第 N 周 ←→ 周一日期」，按周次升序
  final List<WeekDate> weeks;

  bool get isValid => code.isNotEmpty && weeks.isNotEmpty;

  /// 第 1 周周一（YYYY-MM-DD）—— 全部周次计算的基准
  String get firstMonday => weeks.isEmpty ? '' : weeks.first.monday;

  /// 总教学周数
  int get totalWeeks => weeks.isEmpty ? 0 : weeks.last.week;

  /// 最后一周的周日（YYYY-MM-DD）
  String get lastDay {
    final DateTime? mon = mondayOf(totalWeeks);
    if (mon == null) {
      return '';
    }
    return _fmt(mon.add(const Duration(days: 6)));
  }

  /// 某教学周的周一；该周不在表内或日期非法时返回 null
  DateTime? mondayOf(int week) {
    for (final WeekDate w in weeks) {
      if (w.week == week) {
        return WeekCalendarParser.mondayOf(w.monday);
      }
    }
    return null;
  }

  /// 今天是第几周（不在学期内则 0）
  int weekOf(DateTime today) => WeekCalendarParser.currentWeek(weeks, today);

  /// 每个日期对应的教学周；不在学期内返回 0。
  ///
  /// 用**日期区间**判断，而不是「周一相同」：这样一周里的任意一天都能查到，
  /// 界面画月历时不必对每一天都去找它属于哪一周。
  Map<String, int> weekIndexByDay() {
    final Map<String, int> out = <String, int>{};
    for (final WeekDate w in weeks) {
      final DateTime? mon = mondayOf(w.week);
      if (mon == null) {
        continue;
      }
      for (int i = 0; i < 7; i++) {
        out[_fmt(mon.add(Duration(days: i)))] = w.week;
      }
    }
    return out;
  }

  static String _fmt(DateTime d) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

class SemesterCalendarService {
  /// 当前已知的学期信息（内存）
  static SemesterInfo? _mem;

  /// 上次加载的失败原因（界面用来区分「没数据」与「取不到」）
  static String lastError = '';

  static SemesterInfo? get current => _mem;

  /// 取某学期的教学周历。
  ///
  /// 全程不抛异常：校历取不到只是这一块内容退化为「暂不可用」，
  /// 不该影响课表、成绩等主流程。
  ///
  /// [force] 为 true 时**总是**重新联网（用户点了刷新就该完整拉一遍）。
  /// 但强制刷新失败时**不会**把已缓存的数据丢掉 —— 见下面的回退。
  static Future<SemesterInfo?> load(
    String semester, {
    bool force = false,
  }) async {
    if (semester.isEmpty) {
      lastError = '';
      return null;
    }
    if (_mem != null && _mem!.code == semester && !force) {
      return _mem;
    }
    lastError = '';
    final PageDataLoader<SemesterInfo> loader = _loaderFor(semester);
    try {
      final SemesterInfo info = (await loader.load(force: force)).data;
      if (!info.isValid) {
        lastError = '该学期暂无教学周历';
        // 服务器回了一份合法页面但里面没有周次表（学校还没录入）：
        // 这算「这次没取到」，同样保留旧缓存
        return await _fallbackFromCache(loader, semester);
      }
      _mem = info;
      await _applyToAppState(info);
      return info;
    } catch (e) {
      // 不把异常抛给界面：校历是辅助信息
      lastError = e.toString();
      debugPrint('[calendar] load failed: $e');
      return await _fallbackFromCache(loader, semester);
    }
  }

  /// 刷新失败（或服务端还没录入）时的回退：用缓存里的旧数据继续显示。
  ///
  /// 为什么必须有这一步：曾经点「刷新」时网络不通，界面会**把已经显示着的
  /// 校历整个擦掉**（`_loadSemester` 把 `_info` 置成了 null）——
  /// 用户手里原有的、可能是唯一一份离线可用的校历就这么没了，
  /// 而这次刷新失败本不该有任何破坏性。
  ///
  /// 回退只读缓存、**不再联网**：刚刚那次请求就是失败的，
  /// 再走一遍 `load()` 只会白等一次超时。
  static Future<SemesterInfo?> _fallbackFromCache(
      PageDataLoader<SemesterInfo> loader, String semester) async {
    final SemesterInfo? old = await loader.loadCached();
    if (old == null || !old.isValid) {
      return null;
    }
    _mem = old;
    // 提示与「取到的是旧的」区分开，界面据此显示成警告而不是错误
    lastError = lastError.isEmpty
        ? '未能获取最新教学周历，已显示上次的数据'
        : '$lastError；已显示上次的数据';
    return old;
  }

  /// 构造某学期的加载器（key 带学期作变体；缓存 6 小时）
  static PageDataLoader<SemesterInfo> _loaderFor(String semester) =>
      PageDataLoader<SemesterInfo>(
        key: PageCache.keyOf(AppState.instance.account, kCacheSemesterCalendar,
            <String>[semester]),
        // 服务端拿到指定学期：不传参数只会返回「当前学期」，
        // 而本页允许用户切到别的学期看
        fetch: () => AppState.instance.api.getWeekCalendarHtml(semester),
        parse: (String html) {
          // 代码取「服务端实际显示的那个学期」（selected 选项），而不是
          // 请求时传的值或页面里第一个出现的代码 —— 前者会被服务端忽略，
          // 后者永远是最新的学期。取错会得到「标题与日历不同学期」的错位。
          final String shown = WeekCalendarParser.parseSelectedSemester(html);
          return SemesterInfo(
            code: shown.isEmpty ? semester : shown,
            weeks: WeekCalendarParser.parseWeekDates(html),
          );
        },
        ttl: kTtlSemesterCalendar,
      );

  /// 用户主动刷新：完整重取一次周历。
  ///
  /// 与 [load] 的区别是**语义**而不是实现：`load` 是「进入页面时取到数据」，
  /// 命中缓存即返回；这个方法表达「用户要求最新」，因此总是联网。
  /// 两者共用同一条加载链与同一份缓存，所以刷新成功后，
  /// 页面与后续的 `load` 都会看到新数据。
  static Future<SemesterInfo?> refresh(String semester) =>
      load(semester, force: true);

  /// 系统时间已经超出周历范围时，自动尝试拉取一次新周历；**每天最多一次**。
  ///
  /// 为什么需要：期末之后（寒暑假里）周历自然就「过期」了 ——
  /// 今天是第 0 周，界面上的周次、上课提醒、桌面卡片全都算不出来。
  /// 而新学期的周历此时可能已经录入教务系统，只是本地还存着旧的那份。
  ///
  /// 为什么限每天一次：触发条件（今天晚于最后一周）在整个假期里**持续成立**，
  /// 不限频就会每次启动、每次打开校历都联网 —— 而学校一学期只更新一次，
  /// 那些请求几乎全是白打的。
  ///
  /// 返回新拉到的周历；不满足条件、今天已试过、或拉取失败都返回 null。
  static Future<SemesterInfo?> autoFetchIfOutdated(String semester) async {
    if (semester.isEmpty) {
      return null;
    }
    if (_autoFetchTriedToday()) {
      return null;
    }
    final SemesterInfo? cur = await load(semester);
    if (cur == null || cur.weeks.isEmpty) {
      return null;
    }
    // 「超出范围」= 今天晚于最后一周的周日。仍在学期内就不该自动联网。
    final DateTime? lastMon = cur.mondayOf(cur.totalWeeks);
    if (lastMon == null) {
      return null;
    }
    final DateTime lastSunday = lastMon.add(const Duration(days: 6));
    final DateTime today = DateTime.now();
    final DateTime t = DateTime(today.year, today.month, today.day);
    if (!t.isAfter(lastSunday)) {
      return null;
    }
    // 标记**先写**：一次拉取可能耗时数秒，期间用户切页会再次触发本方法，
    // 不先占位就会并发打出多个请求
    await PrefStore.saveSemesterAutoFetchDay(_todayText(t));
    debugPrint('[calendar] out of range, auto fetching: $semester');

    final SemesterInfo? refreshed = await refresh(semester);
    if (refreshed == null) {
      return null;
    }
    // ===== 必须确认「真的拿到新数据」，而不是又拿回那份旧的 =====
    // refresh() 失败时会**回退到缓存**（保住离线数据，见 _fallbackFromCache），
    // 于是它可能返回一份非空、但与刚读到的完全相同的数据。
    // 若直接把它当成功上报，界面会弹「已获取到新学期的教学周历」——
    // 而实际上什么都没变，属于**报告了不存在的成功**。
    // 判据用「周历内容是否不同」：新学期的第 1 周周一必然不是旧的。
    final bool changed = refreshed.code != cur.code ||
        refreshed.firstMonday != cur.firstMonday ||
        refreshed.totalWeeks != cur.totalWeeks;
    return changed ? refreshed : null;
  }

  /// 今天是否已经自动拉取过（用于把频率限制为每天一次）
  static bool _autoFetchTriedToday() {
    final String day = PrefStore.loadSemesterAutoFetchDay();
    return day.isNotEmpty && day == _todayText(DateTime.now());
  }

  static String _todayText(DateTime d) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// 可选学期列表（服务端为准）。失败返回空列表。
  static Future<List<ChoiceItem>> semesters({bool force = false}) async {
    try {
      final PageDataLoader<List<ChoiceItem>> loader =
          PageDataLoader<List<ChoiceItem>>(
        key: PageCache.keyOf(AppState.instance.account, kCacheSemesterList),
        fetch: AppState.instance.api.getWeekCalendarHtml,
        parse: WeekCalendarParser.parseSemesterOptions,
        ttl: kTtlSemesterList,
      );
      final List<ChoiceItem> got = (await loader.load(force: force)).data;
      if (got.isNotEmpty) {
        return got;
      }
      // 服务端没给列表（页面结构变了）→ 退回上次缓存，
      // 否则学期下拉会变成一个空框
      return await loader.loadCached() ?? got;
    } catch (e) {
      debugPrint('[calendar] semesters failed: $e');
      final List<ChoiceItem>? cached = await _semesterLoaderCached();
      return cached ?? <ChoiceItem>[];
    }
  }

  static Future<List<ChoiceItem>?> _semesterLoaderCached() async {
    final PageDataLoader<List<ChoiceItem>> loader =
        PageDataLoader<List<ChoiceItem>>(
      key: PageCache.keyOf(AppState.instance.account, kCacheSemesterList),
      fetch: AppState.instance.api.getWeekCalendarHtml,
      parse: WeekCalendarParser.parseSemesterOptions,
      ttl: kTtlSemesterList,
    );
    return loader.loadCached();
  }

  /// 把校历里的开学日期**补进**应用状态（仅在用户没设过时）。
  ///
  /// 这条让「开学日期」从「必须手动设置」变成「默认就是对的」：
  /// 周次显示、上课提醒、桌面卡片全都依赖它，而它的权威值本来就在
  /// 教务系统的周历里。用户手动改过的值永不被覆盖 ——
  /// 手动设置是明确意图（比如补考周算作第 1 周），不能被一次联网抹掉。
  static Future<void> _applyToAppState(SemesterInfo info) async {
    if (info.firstMonday.isEmpty) {
      return;
    }
    final AppState app = AppState.instance;
    if (app.semesterStart.isNotEmpty) {
      return;
    }
    app.setSemesterStart(info.firstMonday);
    // 顺手把当前周也算出来：否则要等下一次 WeekService.align 才更新
    app.setCurrentWeek(info.weekOf(DateTime.now()));
  }

  /// 仅供测试：直接读缓存（不联网、不写任何状态）。
  ///
  /// 单独暴露是因为「回退到缓存」这条路径在生产代码里总是紧跟着一次
  /// 失败的联网，测试里无法把它单独隔离出来验证。
  @visibleForTesting
  static Future<SemesterInfo?> loadCachedForTest(String semester) =>
      _loaderFor(semester).loadCached();

  /// 仅供测试：清掉内存态
  static void clearMemoryForTest() {
    _mem = null;
    lastError = '';
  }
}
