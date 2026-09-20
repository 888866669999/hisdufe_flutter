/// 全局会话与应用状态
///
/// 从鸿蒙版 `data/AppState.ets` 移植。用单例 + ChangeNotifier，
/// 界面通过 `ListenableBuilder` 订阅，替代鸿蒙版的 AppStorage。
///
/// ===== 两条不可动摇的产品行为 =====
/// 1. **只看课表永远不打扰**：课表来自本地缓存，不需要联网。
///    因此「会话失效」绝不能导致退出登录或弹窗 —— 启动时只做一次后台探测，
///    发现了也仅仅记录，把后果推迟到「真正需要联网的那一刻」。
/// 2. **换账号必须清干净**：内存缓存、卡片快照、上次学期、
///    应用内提醒定时器都要清，否则 B 会看到 A 的数据、收到 A 的提醒。
library;

import 'package:flutter/foundation.dart';

import '../model/models.dart';
import '../network/cookie_jar.dart';
import '../network/qz_api.dart';
import 'credential_store.dart';
import 'elective_requirement_store.dart';
import 'page_cache.dart';
import 'reminder_service.dart';
import 'card_snapshot_store.dart';
import 'pref_store.dart';
import 'timetable_store.dart';

/// 会话探测结果：把「网络失败」与「会话失效」分开。
///
/// 两者都拿不到正常页面，但含义相反：会话失效意味着需要重新验证；
/// 网络失败只说明此刻判断不了，**必须保持登录态不动**，
/// 否则一出校园网就会被误踢回登录页。
class SessionProbe {
  SessionProbe(this.alive, this.networkError);

  final bool alive;
  final bool networkError;
}

/// 账号作用域清理钩子。
///
/// ===== 已经没人用了（保留着是为了说明来龙去脉）=====
/// 这套钩子表当初是为「会话保活」服务的：那个模块反向依赖 AppState，
/// 直接 import 会形成循环依赖，于是改用注册钩子。
/// 保活功能后来整块移除，最后一个钩子也随之消失 ——
/// 现在 `runAll()` 遍历的是一张**空表**，等于什么也不做。
///
/// 之所以还没删掉它：登出流程仍在调 `runAll()`（见 clearAccountScopedState），
/// 而那一步本该承担「停掉跟账号绑定的后台行为」。真正需要在那里做的是
/// **取消已排定的上课提醒**（否则 A 登出后提醒仍会响），
/// 而 ReminderService 并不依赖 AppState，可以直接调 ——
/// 见 clearAccountScopedState 里的实现。
class AccountScopeHooks {
  static final List<VoidCallback> _hooks = <VoidCallback>[];

  static void register(VoidCallback hook) {
    if (!_hooks.contains(hook)) {
      _hooks.add(hook);
    }
  }

  static void runAll() {
    for (final VoidCallback h in List<VoidCallback>.from(_hooks)) {
      try {
        h();
      } catch (_) {
        // 单个钩子失败不应影响登出流程
      }
    }
  }

  static int get size => _hooks.length;
}

class AppState extends ChangeNotifier {
  AppState._();

  static final AppState instance = AppState._();

  final CookieJar jar = CookieJar();
  QzApi? _api;
  QzApi get api => _api ??= QzApi(jar);

  bool _loggedIn = false;
  bool get loggedIn => _loggedIn;

  String account = '';
  String studentName = '';
  String studentId = '';

  /// 会话失效、等待用户重新验证
  bool reauthPending = false;

  /// 是否已保存账号密码
  bool hasCredential = false;

  /// 当前周（0 表示未知）
  int currentWeek = 0;

  /// 开学日期（第 1 周周一，YYYY-MM-DD）
  String semesterStart = '';

  /// 已加载的课表。**只缓存课表**，其余一律实时取。
  Timetable? timetable;

  Future<void> init() async {
    await PrefStore.init();
    semesterStart = PrefStore.loadSemesterStart();
    account = PrefStore.loadAccount();
    currentWeek = PrefStore.loadWeekAlignValue();
    jar.deserialize(PrefStore.loadCookie());
    notifyListeners();
  }

  /// 从持久化恢复会话。
  ///
  /// 只要有已保存的 cookie 就**乐观进入主界面**，不阻塞等待服务器校验；
  /// 校验放到后台，且只有服务器明确要求重新登录才算失效。
  Future<bool> restoreSession() async {
    final String saved = PrefStore.loadCookie();
    if (saved.isEmpty) {
      // 没有本地会话。**刻意不在这里判定「未登录」**：
      // 密钥库里可能还有账号密码，壳层会据此自动重新登录
      // （见 AppShell._restore）—— 这才是「用户无需感知」。
      // 这里只如实报告「没有可恢复的会话」。
      return false;
    }
    jar.deserialize(saved);
    _loggedIn = true;
    notifyListeners();
    // fire-and-forget：失败也不影响已进入的界面
    verifySessionInBackground().catchError((Object _) {});
    return true;
  }

  /// 后台校验会话。
  ///
  /// **无论结果如何都不退出登录、不弹窗**：用户可能只是想看课表，
  /// 而课表是本地缓存。会话失效的后果推迟到真正需要联网时。
  Future<void> verifySessionInBackground() async {
    final SessionProbe probe = await probeSession();
    if (probe.networkError) {
      return;
    }
    if (probe.alive) {
      return;
    }
    hasCredential = await _credentialExists();
    notifyListeners();
  }

  /// 探测一次会话是否有效；有效时回写服务器轮换过的 cookie。
  Future<SessionProbe> probeSession() async {
    try {
      final bool alive = await api.isSessionAlive();
      if (alive) {
        await PrefStore.saveCookie(jar.serialize());
        return SessionProbe(true, false);
      }
      return SessionProbe(false, false);
    } catch (_) {
      return SessionProbe(false, true);
    }
  }

  Future<bool> _credentialExists() => CredentialStore.exists();

  /// 登录成功后
  Future<void> onLoggedIn(String acct) async {
    if (account.isNotEmpty && account != acct) {
      // 换账号：清掉上一个账号的内存缓存，避免串号。
      // 同一账号重新登录（会话续期）则保留，省去白取一遍。
      timetable = null;
    }
    account = acct;
    await PrefStore.saveCookie(jar.serialize());
    _loggedIn = true;
    if (acct.isNotEmpty) {
      await PrefStore.saveAccount(acct);
      studentId = acct;
    }
    reauthPending = false;
    notifyListeners();
  }

  Future<void> persistSession() async {
    if (!jar.isEmpty) {
      await PrefStore.saveCookie(jar.serialize());
    }
  }

  /// 当前账号（用于课表缓存分片）
  Future<String> resolveAccount() async {
    if (account.isNotEmpty) {
      return account;
    }
    final String saved = PrefStore.loadAccount();
    if (saved.isNotEmpty) {
      account = saved;
      return saved;
    }
    return '';
  }

  /// 退出登录：清内存缓存 + 取消提醒 + 清持久化键。
  ///
  /// 刻意**不删**课表文件：它按「账号+学期」分文件保存，
  /// 换回原账号时要能读回本地修改（见 PrefStore.clearAccountScoped 说明）。
  Future<void> logout() async {
    jar.clear();
    await PrefStore.clearCookie();
    await clearAccountScopedState();
    account = '';
    studentName = '';
    studentId = '';
    _loggedIn = false;
    notifyListeners();
  }

  Future<void> clearAccountScopedState() async {
    // 1) 停掉跟账号绑定的后台行为：**取消已排定的上课提醒**。
    //
    // 这一步曾经是空的：原先靠 AccountScopeHooks 让各模块自己注册清理动作，
    // 而唯一注册过它的「会话保活」已被移除，于是登出后 A 的课程提醒
    // 仍留在系统里继续响 —— 换 B 登录后甚至会按 A 的课表提醒他。
    // ReminderService 不依赖 AppState，可以直接调用（原先那句
    // 「直接引用会形成循环依赖」是给保活模块写的，ReminderService 不适用）。
    try {
      await ReminderService.cancelAll();
    } catch (_) {
      // 取消失败不应阻塞登出
    }
    AccountScopeHooks.runAll();
    // 2) 内存缓存
    timetable = null;
    // 2b) 页面缓存（成绩/培养方案/通选/个人信息/空教室原文）。
    //     **必须清**：缓存内容是上一个账号的数据。磁盘层按账号前缀分文件，
    //     不清就长期留在设备上；内存层更直接 —— 同一次进程内换个账号登录，
    //     新的 key 碰不到旧条目，但旧数据仍在内存里（且如果账号串恰好相同，
    //     还会被直接命中）。必须在下面 clearAccountScoped 清掉账号之前调用。
    await PageCache.clearAccount(account);
    // 3) 通选课要求学分是按**专业**录的，同机换账号（不同专业）要求不同，
    //    留着会让 B 以 A 的要求判断达标。
    //    必须在 clearAccount() 之前取账号 —— 它下面就会被清掉。
    await ElectiveRequirementStore.clearAccount(account);
    // 4) 持久化里跟账号绑定的键
    await PrefStore.clearAccountScoped();
    // 5) 等待重新验证标记
    reauthPending = false;
  }

  void markReauthPending() {
    if (!reauthPending) {
      reauthPending = true;
      notifyListeners();
    }
  }

  void clearReauthPending() {
    if (reauthPending) {
      reauthPending = false;
      notifyListeners();
    }
  }

  void setSemesterStart(String date) {
    semesterStart = date;
    PrefStore.saveSemesterStart(date);
    notifyListeners();
  }

  void setCurrentWeek(int week) {
    if (currentWeek != week) {
      currentWeek = week;
      PrefStore.saveWeekAlignValue(week);
      notifyListeners();
    }
  }

  /// 保存课表并写缓存
  Future<bool> saveTimetable(Timetable tt) async {
    timetable = tt;
    final String acct = await resolveAccount();
    final bool ok = await TimetableStore.save(acct, tt.semester, tt);
    notifyListeners();
    return ok;
  }

  /// 把所有「会影响桌面卡片」的东西重新推给卡片。
  ///
  /// 为什么要有这个统一入口：卡片显示的内容由三样东西共同决定 ——
  /// 课表、开学日期、节次作息。任何一样变了都得推一次，否则卡片就停在
  /// 旧数据上。这些改动散落在课表页、设置页、生命周期回调等多处，
  /// 靠「每个调用点自己记得调一次」必然会漏（实测就漏了「改作息」那条）。
  /// 因此收口到这里：谁改了这三者之一，调一次它就够了。
  ///
  /// 内部已保证不抛异常（见 [CardSnapshotStore.refresh]），
  /// 因此调用方不必再包 try —— 这一点很重要：它常被 await 在
  /// 「加载课表」的链路上，那里任何异常都会被误判成会话失效。
  Future<void> pushCardSnapshot() async {
    await CardSnapshotStore.refresh(timetable, semesterStart);
  }
}
