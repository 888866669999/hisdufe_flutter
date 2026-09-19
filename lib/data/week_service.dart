/// 教学周服务：开学日期、当前周、与系统时间对齐
///
/// 从鸿蒙版 `data/WeekService.ets` 移植。
///
/// 对齐策略：进入应用或打开课表时，若距上次对齐超过 6 小时才重算。
/// 为什么需要节流：每次重算都要读盘+写盘，而进课表是高频操作；
/// 6 小时内周次不会变（周次以「天」为单位变化），重算纯属浪费。
library;

import '../common/constants.dart';
import '../common/week_calc.dart';
import 'app_state.dart';
import 'pref_store.dart';

class WeekService {
  /// 读取开学日期（已吸附到周一）
  static String start() => AppState.instance.semesterStart;

  static bool isConfigured() => start().isNotEmpty;

  /// 设置开学日期。
  ///
  /// 会吸附到那一周的周一：教务的周次以周一为界，用户随手填个周三
  /// 会让整学期周次偏移。
  static Future<void> setStartMonday(String dateText) async {
    final DateParts? p = WeekCalc.parse(dateText);
    if (p == null) {
      throw const FormatException('invalid date');
    }
    final DateTime mon =
        WeekCalc.mondayOf(DateTime(p.year, p.month, p.day));
    AppState.instance.setSemesterStart(WeekCalc.fromDate(mon));
  }

  /// 与系统时间对齐当前周
  ///
  /// @param force true 时忽略 6 小时节流
  static Future<int> align([bool force = false]) async {
    final String startMonday = start();
    if (startMonday.isEmpty) {
      return 0;
    }
    final int lastAt = PrefStore.loadWeekAlignAt();
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        lastAt > 0 &&
        nowMs - lastAt < kWeekAlignInterval.inMilliseconds) {
      return PrefStore.loadWeekAlignValue();
    }
    final int week = WeekCalc.weekNumber(startMonday, DateTime.now(), kMaxWeeks);
    AppState.instance.setCurrentWeek(week);
    await PrefStore.saveWeekAlignAt(nowMs);
    await PrefStore.saveWeekAlignValue(week);
    return week;
  }

  static int cachedWeek() => PrefStore.loadWeekAlignValue();

  /// `MM/DD`
  static String dayLabel(int week, int offset) {
    final DateTime? d = WeekCalc.dateOfDay(start(), week, offset);
    return d == null ? '' : WeekCalc.formatMd(d);
  }

  /// 形如 `9月`（表头最左侧的月份标记）。
  ///
  /// 与日期一样依赖开学日期：没配置时算不出，返回空串 ——
  /// 界面据此不显示，而不是显示一个空的「月」字。
  static String monthLabel(int week, int offset) {
    final DateTime? d = WeekCalc.dateOfDay(start(), week, offset);
    return d == null ? '' : '${d.month}月';
  }

  /// 今天相对本周周一的天偏移（0=周一）；开学日期无效时返回 -1
  static int configuredWeekday() {
    final DateParts? p = WeekCalc.parse(start());
    if (p == null) {
      return -1;
    }
    return DateTime.now().weekday - 1;
  }

  /// 官方校历建议的开学日期（若与当前不一致，界面提示）
  static String officialStartFor(String semester) => '';
}
