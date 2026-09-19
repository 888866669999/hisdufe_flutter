/// 日期与教学周推算（纯逻辑）
///
/// 从鸿蒙版 `common/WeekCalc.ets` 移植。
///
/// 这里的每一条校验都是踩坑换来的，不要简化：
///   - [WeekCalc.parse] 必须拒绝「格式合法但日历上不存在」的日期
///     （如 2026-02-31）。早期只校验月份范围，导致用户填错日期后
///     周次整体错位，却没有任何报错。
///   - 周次一律以**周一**为一周之始（与教务一致），
///     因此传入的开学日期若不在周一，要先吸附到那一周的周一。
library;

class DateParts {
  const DateParts(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;
}

class WeekCalc {
  static const int _msPerDay = 86400000;

  /// 解析 `YYYY-MM-DD`。
  ///
  /// 返回 null 表示无效。校验包含「日历上真实存在」：
  /// 通过 `DateTime.utc` 往返比对，2026-02-31 这类输入会被拒绝
  /// （Dart 会把 2 月 31 日自动进位到 3 月 3 日，往返后不相等）。
  static DateParts? parse(String text) {
    final String s = text.trim();
    if (s.length < 8 || s.length > 10) {
      return null;
    }
    final List<String> parts = s.split('-');
    if (parts.length != 3) {
      return null;
    }
    final int? y = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    final int? d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) {
      return null;
    }
    if (y < 1970 || y > 2200 || m < 1 || m > 12 || d < 1 || d > 31) {
      return null;
    }
    final DateTime dt = DateTime.utc(y, m, d);
    if (dt.year != y || dt.month != m || dt.day != d) {
      return null; // 日历上不存在，例如 2 月 31 日
    }
    return DateParts(y, m, d);
  }

  /// 格式化为 `YYYY-MM-DD`
  static String format(DateParts p) {
    final String m = p.month < 10 ? '0${p.month}' : '${p.month}';
    final String d = p.day < 10 ? '0${p.day}' : '${p.day}';
    return '${p.year}-$m-$d';
  }

  static String fromDate(DateTime dt) =>
      format(DateParts(dt.year, dt.month, dt.day));

  /// `MM/DD`
  static String formatMd(DateTime dt) {
    final String m = dt.month < 10 ? '0${dt.month}' : '${dt.month}';
    final String d = dt.day < 10 ? '0${dt.day}' : '${dt.day}';
    return '$m/$d';
  }

  /// 把任意日期吸附到它所在那一周的周一
  static DateTime mondayOf(DateTime dt) {
    final DateTime day = DateTime(dt.year, dt.month, dt.day);
    // Dart: weekday 1=Mon .. 7=Sun
    return day.subtract(Duration(days: day.weekday - 1));
  }

  /// 计算 `now` 落在第几教学周。
  ///
  /// 返回 0 表示「不在学期内」（还没开学，或超出最大周数）。
  /// 用真实日期的毫秒差计算，而不是比较 `MM-dd` 字符串 ——
  /// 后者在跨年时必然出错（12 月到 1 月）。
  static int weekNumber(String startMonday, DateTime now, int maxWeeks) {
    final DateParts? p = parse(startMonday);
    if (p == null) {
      return 0;
    }
    final DateTime start = mondayOf(DateTime(p.year, p.month, p.day));
    final DateTime today = DateTime(now.year, now.month, now.day);
    final int diffDays = today.difference(start).inDays;
    if (diffDays < 0) {
      return 0;
    }
    final int week = (diffDays ~/ 7) + 1;
    if (maxWeeks > 0 && week > maxWeeks) {
      return 0;
    }
    return week;
  }

  /// 第 `week` 周的周一
  static String mondayOfWeek(String startMonday, int week) {
    final DateParts? p = parse(startMonday);
    if (p == null) {
      return '';
    }
    final DateTime start = mondayOf(DateTime(p.year, p.month, p.day));
    return fromDate(start.add(Duration(days: (week - 1) * 7)));
  }

  /// 第 `week` 周第 `offset` 天（0=周一）的日期
  static DateTime? dateOfDay(String startMonday, int week, int offset) {
    final DateParts? p = parse(startMonday);
    if (p == null) {
      return null;
    }
    final DateTime start = mondayOf(DateTime(p.year, p.month, p.day));
    return start.add(Duration(days: (week - 1) * 7 + offset));
  }

  /// 今天是否落在第 `week` 周内（含周一..周日）
  static bool isTodayInWeek(String startMonday, int week, DateTime now) {
    final DateTime? monday = dateOfDay(startMonday, week, 0);
    if (monday == null) {
      return false;
    }
    final DateTime today = DateTime(now.year, now.month, now.day);
    final int diff = today.difference(monday).inDays;
    return diff >= 0 && diff < 7;
  }

  /// 两个日期相差的天数（b - a）
  static int daysBetween(String a, String b) {
    final DateParts? pa = parse(a);
    final DateParts? pb = parse(b);
    if (pa == null || pb == null) {
      return 0;
    }
    return DateTime(pb.year, pb.month, pb.day)
        .difference(DateTime(pa.year, pa.month, pa.day))
        .inDays;
  }

  /// 供提醒排期使用：从周一起算的第 n 天 0 点毫秒
  static int dayStartMs(DateTime day) =>
      DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;

  static const int msPerDay = _msPerDay;
}
