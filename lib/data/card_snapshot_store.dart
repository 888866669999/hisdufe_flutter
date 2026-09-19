/// 桌面卡片数据快照
///
/// 从鸿蒙版 `data/CardSnapshotStore.ets` 移植。
///
/// ===== 为什么用「快照」而不是让卡片自己算 =====
/// Android App Widget 的渲染由系统进程触发，不能联网、也不适合跑长逻辑。
/// 因此主应用把「今天的课」算好、存成键值对，卡片只做渲染。
/// 这样卡片不会因为教务系统慢而白屏。
///
/// ===== 数据存到哪里（这里踩过一个坑）=====
/// 卡片侧（Kotlin）读的是 `home_widget` 插件的私有 preferences
/// （`HomeWidgetPreferences`），**不是** Flutter `shared_preferences` 的
/// `FlutterSharedPreferences`。
/// 最初我把快照写进 `shared_preferences`、卡片却去读插件的 preferences，
/// 结果卡片永远空白 —— 两边都不报错，只是读不到彼此的数据。
/// 因此卡片数据必须走 `HomeWidget.saveWidgetData`。
///
/// ===== 鸿蒙版「加了课卡片不变」的根修，在这里同样适用 =====
/// 只写数据、不通知卡片重绘，卡片仍显示旧内容。
/// 所以 [refresh] 里「写数据」与「通知」是成对的，不要拆开。
library;

import 'dart:convert';

import 'package:home_widget/home_widget.dart';

import '../common/constants.dart';
import '../common/week_calc.dart';
import 'pref_store.dart';
import 'section_time_store.dart';

class CardCourse {
  CardCourse({
    required this.time,
    required this.name,
    this.room = '',
    this.teacher = '',
    this.done = false,
  });

  final String time;
  final String name;
  final String room;
  final String teacher;

  /// 是否**已上完**（按这节课的**下课时刻**判断，不是上课时刻）。
  ///
  /// 语义要精确：正在上的课不算「已上完」—— 卡片据此给它画删除线并置灰，
  /// 若把进行中的课也算进去，用户会以为这节课已经结束了。
  final bool done;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'time': time,
        'name': name,
        'room': room,
        'teacher': teacher,
        'done': done,
      };
}

class CardSnapshot {
  CardSnapshot({
    this.at = 0,
    this.weekday = '',
    this.date = '',
    this.week = 0,
    this.hasCourse = false,
    List<CardCourse>? courses,
    this.nextText = '',
  }) : courses = courses ?? <CardCourse>[];

  final int at;
  final String weekday;
  final String date;
  final int week;
  final bool hasCourse;
  final List<CardCourse> courses;
  final String nextText;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'at': at,
        'weekday': weekday,
        'date': date,
        'week': week,
        'hasCourse': hasCourse,
        'courses': courses.map((CardCourse c) => c.toJson()).toList(),
        'nextText': nextText,
      };

  String encode() => jsonEncode(toJson());
}

class CardSnapshotStore {
  static const String _weekdayCn = '一二三四五六日';

  /// 卡片侧读取的键名（与 Kotlin 的 `widget_prefs.getString` 保持一致）
  static const String _widgetKey = 'card_snapshot';

  /// 周级快照的键名。Kotlin 侧优先读它、自己算「今天」。
  ///
  /// ===== 为什么还要一份「周级」数据（这是卡片不及时的根因）=====
  /// 早先只存 `card_snapshot`：那是**在写入那一刻**算好的「今天」列表。
  /// 卡片每次 onUpdate 只是把这份 JSON 重画一遍，于是：
  ///   - `done`（已上完）与「下一节」永远停在写入时的时刻，一整天不再变；
  ///   - 平台的 `updatePeriodMillis`（30 分钟）定时刷新形同虚设 ——
  ///     它只是重画旧数据，等于在做无用功；
  ///   - **跨天后仍显示昨天的课**，必须打开一次应用才会纠正。
  ///
  /// 因此改存整周课表（含每门课的周次区间与单双周），让卡片自己按
  /// 当前日期/时间算出今天该显示什么。这样平台每次定时回调、
  /// 以及任何一次 updateWidget 都能得到**当下正确**的内容，
  /// 跨天也能自愈 —— 全程不需要应用在后台运行。
  static const String _weekKey = 'week_snapshot';

  // ==================== 取值助手（一律空安全）====================
  //
  // 快照的数据源是**可能损坏的本地缓存**（用户清理过数据、跨版本升级、
  // 磁盘写入中断都可能留下不完整的字段）。早先这里写的是
  // `e.room as String` 这种硬转换：一旦某个字段是 null 就直接抛
  // TypeError —— 而调用方 `_load` 会把任何异常当成「会话失效」去触发
  // 重新登录（见 re_auth_service.handlePageError），
  // 表现为「课表打开失败还让我重新登录」，极难定位。
  // 所以这里一律容错：取不到就用空值，绝不抛。

  static String _str(Object? v) => v is String ? v : '';

  static int _int(Object? v, int def) {
    if (v is int) {
      return v;
    }
    if (v is num) {
      return v.toInt();
    }
    return def;
  }

  /// 该课表里**是否有任何课程**（用于「不拿空表覆盖已有数据」的判断）
  static bool hasCourses(dynamic tt) {
    if (tt == null) {
      return false;
    }
    try {
      final Object? cells = tt.cells;
      if (cells is! List || cells.isEmpty) {
        return false;
      }
      for (final Object? c in cells) {
        final Object? es = (c as dynamic).entries;
        if (es is List && es.isNotEmpty) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// 生成某一天的课程快照（纯计算，便于单测）。
  ///
  /// [tt] 声明为 dynamic 以避免与 AppState 形成循环依赖；期望传入 `Timetable?`。
  static CardSnapshot build(dynamic tt, String startMonday, DateTime now) {
    final int dow = now.weekday - 1; // 0=Mon
    final String weekday = _weekdayCn[dow];
    final String date = WeekCalc.formatMd(now);
    final int week = startMonday.isEmpty
        ? 0
        : WeekCalc.weekNumber(startMonday, now, kMaxWeeks);

    final int nowMin = now.hour * 60 + now.minute;
    final List<CardCourse> list = <CardCourse>[];
    if (tt != null) {
      for (int r = 0; r < kSectionRows; r++) {
        final Object? cell = tt.findCell(r, dow);
        if (cell == null) {
          continue;
        }
        final SectionTime? st = SectionTimeStore.at(r);
        if (st == null) {
          continue;
        }
        // 判「上完没有」用**下课时刻**，不是上课时刻：
        // 按开始时刻算会把正在上的课标成已上完（14:23 时 14:00 那节仍在进行中），
        // 卡片上就会给它画删除线。Kotlin 侧与鸿蒙端都是按结束时刻算的。
        final int endMin = st.endMinutes();
        final Object? entries = (cell as dynamic).entries;
        if (entries is! List) {
          continue;
        }
        for (final Object? e in entries) {
          // week=0（未设置开学日期）时不过滤，宁可多显示也不漏
          if (week > 0 && !(e as dynamic).isActiveInWeek(week)) {
            continue;
          }
          list.add(CardCourse(
            time: st.start,
            name: _str((e as dynamic).courseName),
            room: _roomOf(e),
            teacher: _str((e as dynamic).teacher),
            done: endMin >= 0 && endMin <= nowMin,
          ));
        }
      }
    }
    list.sort((CardCourse a, CardCourse b) => SectionTimeStore.toMinutes(a.time)
        .compareTo(SectionTimeStore.toMinutes(b.time)));
    return CardSnapshot(
      at: now.millisecondsSinceEpoch,
      weekday: weekday,
      date: date,
      week: week,
      hasCourse: list.isNotEmpty,
      courses: list,
      nextText: _nextText(list),
    );
  }

  /// 「教室(校区)」；两者都缺时给空串（不出现空的括号）
  static String _roomOf(Object? e) {
    final String room = _str((e as dynamic).room);
    final String campus = _str((e as dynamic).campus);
    if (room.isNotEmpty && campus.isNotEmpty) {
      return '$room($campus)';
    }
    return room;
  }

  static String _nextText(List<CardCourse> list) {
    for (final CardCourse c in list) {
      if (!c.done) {
        return '${c.time} ${c.name}${c.room.isNotEmpty ? ' @${c.room}' : ''}';
      }
    }
    return '';
  }

  /// 生成**整周**课表载荷，交给卡片自己算「今天」。
  ///
  /// 结构（键名与 Kotlin 侧逐字对应，改名要两边一起改）：
  /// ```json
  /// {
  ///   "at": 1690000000000,          // 写入时刻，仅用于排查
  ///   "semester": "2026-2027-1",    // 学期号，仅用于排查
  ///   "startMonday": "2026-08-24",  // 第 1 周周一；空串=未设置
  ///   "maxWeeks": 30,
  ///   "sections":    ["08:30",...], // 每行的**上课**时刻
  ///   "sectionEnds": ["10:00",...], // 每行的**下课**时刻
  ///   "total": 12,                  // 课程总数，仅用于排查
  ///   "days": [                     // 7 个元素，索引 0=周一
  ///     [ {"name","room","teacher","row","startWeek","endWeek","parity"} ],
  ///     ...
  ///   ]
  /// }
  /// ```
  ///
  /// 只放卡片渲染必需的字段：卡片是系统进程里的轻量视图，载荷越小越稳。
  ///
  /// `sectionEnds` 是后加的：卡片要标「已上完」，光有开始时刻只能按
  /// 「开始时间过了就算上完」来猜 —— 于是**正在上的那节课也会被标成已上完**。
  /// 有下课时刻才能准确判断。
  static Map<String, dynamic> buildWeek(
    dynamic tt,
    String startMonday, {
    int maxWeeks = kMaxWeeks,
  }) {
    final List<String> sections = <String>[];
    final List<String> sectionEnds = <String>[];
    for (int r = 0; r < kSectionRows; r++) {
      final SectionTime? st = SectionTimeStore.at(r);
      sections.add(st?.start ?? '');
      sectionEnds.add(st?.end ?? '');
    }

    final List<List<Map<String, dynamic>>> days =
        List<List<Map<String, dynamic>>>.generate(7, (_) => <Map<String, dynamic>>[]);

    if (tt != null) {
      for (int dow = 0; dow < 7; dow++) {
        for (int r = 0; r < kSectionRows; r++) {
          final Object? cell = tt.findCell(r, dow);
          if (cell == null) {
            continue;
          }
          final Object? entries = (cell as dynamic).entries;
          if (entries is! List) {
            continue;
          }
          for (final Object? e in entries) {
            days[dow].add(<String, dynamic>{
              'name': _str((e as dynamic).courseName),
              'room': _roomOf(e),
              'teacher': _str((e as dynamic).teacher),
              'row': r,
              'startWeek': _int((e as dynamic).startWeek, 1),
              'endWeek': _int((e as dynamic).endWeek, 18),
              'parity': _int((e as dynamic).parity, 0),
            });
          }
        }
      }
    }

    return <String, dynamic>{
      'at': DateTime.now().millisecondsSinceEpoch,
      'semester': tt == null ? '' : _str((tt as dynamic).semester),
      'startMonday': startMonday,
      'maxWeeks': maxWeeks,
      'sections': sections,
      'sectionEnds': sectionEnds,
      'total': days.fold<int>(0, (int a, List<Map<String, dynamic>> d) => a + d.length),
      'days': days,
    };
  }

  /// 写快照并**通知卡片刷新**。
  ///
  /// 两件事必须成对：只写不通知 = 界面不变；只通知不写 = 显示旧数据。
  ///
  /// ===== 这个方法**绝不抛异常** =====
  /// 它在 `schedule_page._load` → `_apply` 的链路上被 await。
  /// 那条链路虽然会 catch 异常交给 `ReAuthService.handlePageError`，
  /// 但那个入口**只对「会话过期」的异常做续期**，其它异常一律按
  /// 「页面加载失败」显示在界面上 —— 于是「快照里某个字段是 null」
  /// 这种小事会变成课表顶部一条莫名其妙的错误提示，很难定位。
  /// 所以整个方法体包在 try 里，失败就返回 null。
  static Future<CardSnapshot?> refresh(dynamic tt, String startMonday) async {
    try {
      if (tt == null) {
        return null;
      }
      await SectionTimeStore.load();
      final CardSnapshot snap = build(tt, startMonday, DateTime.now());
      final String todayEncoded = snap.encode();
      final String weekEncoded = jsonEncode(buildWeek(tt, startMonday));

      // ===== 空表不覆盖好数据（「卡片课程消失」的根因）=====
      // 课表在「缓存为空 / 换到还没排课的学期 / 抓取只回了一半」时可能是
      // 一张**没有任何课程**的表。若照样写下去，桌面卡片会从「满屏课程」
      // 变成「今天没有课」，而且**在下一次成功刷新之前一直那样** ——
      // 用户看到的就是「课从卡片里消失了」。
      //
      // 因此：新表里一门课都没有、而上次写下的表里有课时，判定这次是
      // 「没拿到数据」而不是「用户真的没课」，**跳过写入**（保留旧数据）。
      // 代价：万一用户真的把课全删了，卡片会多显示一会儿旧课；下一次
      // 有课的刷新或用户点卡片进应用时会纠正。两害相权，宁可留旧数据。
      if (!hasCourses(tt) && _storedWeekHadCourses()) {
        return snap;
      }

      // 1) 今日快照：卡片侧的兜底数据源，同时也是设置页要显示的状态
      await _saveToWidget(_widgetKey, todayEncoded);
      await PrefStore.putText(kKeyCardSnapshot, todayEncoded);
      // 2) 周级快照：卡片优先用它自己算「今天」，跨天/时间段都能自愈
      await _saveToWidget(_weekKey, weekEncoded);
      // 应用侧留一份，用于「上一次的数据里有没有课」这个判断
      await PrefStore.putText(kKeyCardWeek, weekEncoded);
      // 3) 通知系统重绘
      await push();
      return snap;
    } catch (_) {
      // 卡片是附属功能，任何失败都不该影响课表本身
      return null;
    }
  }

  /// 上一次写下的周级载荷里是否含课程（用于「空表不覆盖」判断）
  static bool _storedWeekHadCourses() {
    final String raw = PrefStore.getText(kKeyCardWeek);
    if (raw.isEmpty) {
      return false;
    }
    try {
      final Object? j = jsonDecode(raw);
      if (j is! Map) {
        return false;
      }
      final Object? total = j['total'];
      if (total is int) {
        return total > 0;
      }
      // 兼容没有 total 的旧载荷：逐天看有没有课程
      final Object? days = j['days'];
      if (days is List) {
        for (final Object? d in days) {
          if (d is List && d.isNotEmpty) {
            return true;
          }
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 写一份数据给卡片插件（Kotlin 侧实际读的是它自己的 preferences）
  static Future<void> _saveToWidget(String key, String encoded) async {
    try {
      await HomeWidget.saveWidgetData<String>(key, encoded);
    } catch (_) {
      // 桌面没有卡片时可能失败，不影响主流程
    }
  }

  static Future<void> push() async {
    try {
      await HomeWidget.updateWidget(
        androidName: 'TodayCourseWidgetProvider',
        qualifiedAndroidName: 'com.sdufe.hisdufe_jw.TodayCourseWidgetProvider',
      );
    } catch (_) {
      // 桌面没有卡片时不报错
    }
  }

  /// 读应用侧留存的快照（供设置页显示状态）
  static CardSnapshot? load() {
    final String raw = PrefStore.getText(kKeyCardSnapshot);
    if (raw.isEmpty) {
      return null;
    }
    try {
      final Object? j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) {
        return null;
      }
      final List<CardCourse> courses = <CardCourse>[];
      final Object? cs = j['courses'];
      if (cs is List) {
        for (final Object? c in cs) {
          if (c is Map) {
            courses.add(CardCourse(
              time: _str(c['time']),
              name: _str(c['name']),
              room: _str(c['room']),
              teacher: _str(c['teacher']),
              done: c['done'] == true,
            ));
          }
        }
      }
      return CardSnapshot(
        at: _int(j['at'], 0),
        weekday: _str(j['weekday']),
        date: _str(j['date']),
        week: _int(j['week'], 0),
        hasCourse: j['hasCourse'] == true,
        courses: courses,
        nextText: _str(j['nextText']),
      );
    } catch (_) {
      return null;
    }
  }

  /// 清空快照（退出登录时用，避免 B 看到 A 的今日课程）
  static Future<void> clear() async {
    // 三份都要清：只要留下周级数据，卡片仍能自己算出「今天有课」，
    // 于是换了账号还显示上一个人的课表。应用侧的副本也要清，
    // 否则「上一次有没有课」的判断会把下一个账号的第一张空表挡住。
    await _saveToWidget(_widgetKey, '');
    await _saveToWidget(_weekKey, '');
    await PrefStore.putText(kKeyCardSnapshot, '');
    await PrefStore.putText(kKeyCardWeek, '');
    await push();
  }
}
