/// 上课提醒服务（本地通知）
///
/// 鸿蒙版有「系统代理提醒 + 应用内定时器」双通道，因为鸿蒙对第三方应用
/// 管控了代理提醒配额。**Android 不需要这么绕**：
/// `flutter_local_notifications` 的 `zonedSchedule` 由系统 AlarmManager
/// 托管，应用退出后照样触发，因此这里只保留一条通道，实现更简单也更可靠。
///
/// 这样做还有一个好处：不再需要「应用保活」来维持提醒，
/// 也就不必为了提醒而长期占用后台资源。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../common/constants.dart';
import '../model/models.dart';
import '../model/reminder_plan.dart';
import 'pref_store.dart';
import 'section_time_store.dart';

class ReminderService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _inited = false;

  /// 通知 id 计数器。
  ///
  /// 必须保证唯一：重复 id 会让新通知**覆盖**旧通知，
  /// 表现为「明明排了 5 条却只收到 1 条」。
  static int _nextId = 0;

  /// 提醒 id 的起始值。
  ///
  /// 划分一段固定区间是为了能**识别**「哪些待发通知是自己排的」——
  /// 读回真实条数时（见 [pendingCount]）不该把别的通知算进来。
  static const int _idBase = 20000;

  /// id 区间长度。一学期最多几十条，留足余量即可。
  static const int _idSpan = 10000;

  /// 已排定通知的 id（用于取消）
  static final List<int> _scheduled = <int>[];

  static const String _channelId = 'class_reminder';
  static const String _channelName = '上课提醒';
  static const String _channelDesc = '按课表在课前提醒';

  static Future<void> init() async {
    if (_inited) {
      return;
    }
    tzdata.initializeTimeZones();
    // 用设备本地时区，避免跨时区时提醒时间漂移
    tz.setLocalLocation(tz.getLocation(DateTime.now().timeZoneName.isNotEmpty
        ? 'Asia/Shanghai'
        : 'Asia/Shanghai'));

    const AndroidInitializationSettings android =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings settings =
        InitializationSettings(android: android);
    await _plugin.initialize(settings);
    _inited = true;
  }

  /// 请求通知权限（Android 13+ 需要）
  static Future<bool> ensurePermission() async {
    await init();
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) {
      return false;
    }
    final bool? granted = await android.requestNotificationsPermission();
    return granted ?? false;
  }

  static Future<bool> notificationEnabled() async {
    await init();
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) {
      return false;
    }
    final bool? enabled = await android.areNotificationsEnabled();
    return enabled ?? false;
  }

  /// 按当前课表重排全部提醒。
  ///
  /// 每次调用都先清空再重建，因此课表改动后不会残留旧提醒。
  static Future<int> reschedule(Timetable? tt, String startMonday) async {
    await init();
    await cancelAll();
    // 计数器归零：id 要落在 [_idBase, _idBase + _idSpan) 内（见下面的分配），
    // 不归零的话反复重排会让它一路涨到区间之外，
    // 那些通知就再也认不出来（表现为设置页读回 0 条）。
    // 此刻旧提醒已被 cancelAll 清光，从头分配不会撞号。
    _nextId = 0;
    if (tt == null || startMonday.isEmpty) {
      return 0;
    }
    await SectionTimeStore.load();
    final List<SectionStart> sections = SectionTimeStore.all()
        .map((SectionTime s) =>
            SectionStart(s.label, s.start, ReminderPlan.toMinutes(s.start)))
        .toList();
    final int advance = PrefStore.loadReminderAdvance();
    final List<PendingNotice> list = ReminderPlan.buildUpcoming(
      tt,
      startMonday,
      advance,
      kMaxWeeks,
      sections,
      DateTime.now(),
    );

    const AndroidNotificationDetails android = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
    );
    const NotificationDetails details = NotificationDetails(android: android);

    int count = 0;
    for (final PendingNotice p in list) {
      // id 一律落在 [_idBase, _idBase + _idSpan) 内，见 [_allocId]
      final int id = _allocId();
      try {
        await _plugin.zonedSchedule(
          id,
          '即将上课：${p.title}',
          p.content,
          tz.TZDateTime.fromMillisecondsSinceEpoch(tz.local, p.at),
          details,
          // 两个 required 参数都不能省：缺 uiLocalNotificationDateInterpretation
          // 会在 18.x 上直接编译不过。
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          // 显式给 payload，否则部分 ROM 会丢弃排定项
          payload: p.key,
        );
        _scheduled.add(id);
        count++;
      } catch (e) {
        debugPrint('[reminder] schedule failed: $e');
      }
    }
    await PrefStore.saveReminderOn(true);
    return count;
  }

  /// 取消所有已排提醒
  static Future<void> cancelAll() async {
    await init();
    for (final int id in _scheduled) {
      try {
        await _plugin.cancel(id);
      } catch (_) {
        // 单个取消失败不应影响其余
      }
    }
    _scheduled.clear();
    try {
      await _plugin.cancelAll();
    } catch (_) {
      // 忽略
    }
  }

  /// 系统里当前**真正**还挂着的提醒条数。
  ///
  /// ===== 为什么必须问系统，而不是用内存里的 `_scheduled.length` =====
  /// `_scheduled` 只在本进程排过提醒时才有值。用户退出设置页（甚至重启应用）
  /// 再进来时它是空的 —— 于是设置页显示「已排定 0 条」，
  /// 而实际上系统里还挂着十几条提醒。用户会以为提醒没生效，
  /// 反复开关「上课提醒」去重排（这反而让问题更明显）。
  ///
  /// 界面要反映的是**真实状态**，因此这里直接向插件查询待发通知，
  /// 并与我们的 id 区间取交集 —— 只统计自己排的那些
  /// （测试通知、以及其它功能排的通知不该计进来）。
  static Future<int> pendingCount() async {
    await init();
    try {
      final List<PendingNotificationRequest> all =
          await _plugin.pendingNotificationRequests();
      return all.where((PendingNotificationRequest r) => _isOurs(r.id)).length;
    } catch (_) {
      // 查询失败时退回内存计数：至少比「永远 0」准确
      return _scheduled.length;
    }
  }

  /// 该通知 id 是否属于本服务排定的提醒。
  ///
  /// id 的分配规则见 [nextIdForTest]：从 [_idBase] 起连续递增。
  /// 测试通知也走同一区间（它同样是一次「上课提醒」），因此一并计入。
  static bool _isOurs(int id) => id >= _idBase && id < _idBase + _idSpan;

  /// 分配下一个通知 id，并把计数器推进一位。
  ///
  /// 抽成这个形状是为了**可测**：id 与「能否被识别为自己排的通知」
  /// 之间的契约（见 [pendingCount]）曾经被破坏过 —— 早先的回绕用的是
  /// `% 1000000`，算出的 id 远超区间上界，于是读回条数时全部落选，
  /// 设置页永远显示「已排定 0 条」。
  static int _allocId() => _idBase + (_nextId++ % _idSpan);

  /// 仅测试用：暴露 id 分配与识别，用于锁住上面那条契约
  @visibleForTesting
  static int nextIdForTest() => _allocId();

  /// 仅测试用：重置计数器与待排列表
  @visibleForTesting
  static void resetForTest() {
    _nextId = 0;
    _scheduled.clear();
  }

  /// 仅测试用：判断某个 id 是否算「本服务排的」
  @visibleForTesting
  static bool isOursForTest(int id) => _isOurs(id);

  /// 发一条测试通知（30 秒后），用于端到端确认提醒链路可用。
  static Future<void> scheduleTest() async {
    await init();
    const AndroidNotificationDetails android = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
    );
    const NotificationDetails details = NotificationDetails(android: android);
    final int id = _idBase + 999999;
    await _plugin.zonedSchedule(
      id,
      '测试课程',
      '这是一条测试提醒，看到即表示上课提醒可用',
      tz.TZDateTime.now(tz.local).add(const Duration(seconds: 30)),
      details,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'test',
    );
  }
}
