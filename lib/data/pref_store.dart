/// 本地偏好存储（shared_preferences 包装）
///
/// 从鸿蒙版 `data/PrefStore.ets` 移植。键名保持一致，便于两版对照排查。
///
/// 明确的边界：**这里不存密码**。密码只在用户主动勾选「记住账号密码」时
/// 进系统密钥库（见 credential_store.dart）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../common/constants.dart';
import 'session_cookie_store.dart';

class PrefStore {
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    // 会话 cookie 存在系统密钥库里，而调用方是**同步**读取的
    // （AppState.init / restoreSession 都在首帧之前同步 deserialize）。
    // 因此在这里预热一次，把 cookie 读进内存，见 SessionCookieStore 的说明。
    await SessionCookieStore.prime();
  }

  /// 丢弃已缓存的实例，让下一次 [init] 重新 `getInstance()`。
  ///
  /// 只给测试用。原因：`init` 是 `??=` 语义（幂等），而测试里
  /// `SharedPreferences.setMockInitialValues(...)` 只替换**底层**存储、
  /// 不会换掉已经缓存的实例 —— 于是「每个用例用一份干净的存储」做不到，
  /// 用例之间会互相看到对方写的数据。清掉缓存后才能真正隔离。
  @visibleForTesting
  static void resetCacheForTest() {
    _prefs = null;
  }

  static SharedPreferences get _p {
    final SharedPreferences? p = _prefs;
    if (p == null) {
      throw StateError('PrefStore 未初始化，请先 await PrefStore.init()');
    }
    return p;
  }

  static String getText(String key, [String def = '']) =>
      _p.getString(key) ?? def;

  static Future<void> putText(String key, String value) => _p.setString(key, value);

  static int getInt(String key, [int def = 0]) => _p.getInt(key) ?? def;

  static Future<void> putInt(String key, int value) => _p.setInt(key, value);

  static bool getBool(String key, [bool def = false]) => _p.getBool(key) ?? def;

  static Future<void> putBool(String key, bool value) => _p.setBool(key, value);

  static Future<void> remove(String key) => _p.remove(key);

  // ---- 会话 cookie（加密存储）----
  //
  // 三个方法对外签名保持不变（loadCookie 仍是同步的），
  // 内部改为走系统密钥库。详见 SessionCookieStore 的类注释：
  // JSESSIONID 是「持有即可用」的凭据，不能明文放在 shared_preferences 里。

  static Future<void> saveCookie(String cookie) =>
      SessionCookieStore.save(cookie);

  /// 同步读取。值由 `init()` 预热到内存（见 SessionCookieStore.prime）。
  static String loadCookie() => SessionCookieStore.cached();

  static Future<void> clearCookie() => SessionCookieStore.clear();

  // ---- 账号 ----

  static Future<void> saveAccount(String account) =>
      putText(kKeyAccount, account);

  static String loadAccount() => getText(kKeyAccount);

  static Future<void> clearAccount() => putText(kKeyAccount, '');

  // ---- 是否记住账号密码 ----
  //
  // 这个开关**决定密码是否写入系统密钥库**（账号无论如何都会记住，
  // 见 login_page：账号总是 saveAccount）。默认开启，登录页的复选框
  // 也是默认勾选态 —— 用户不主动取消就会记住。

  /// 默认 true（与鸿蒙版一致：默认记住账号，方便下次登录）
  static bool loadRemember() => getText(kKeyRemember, '1') != '0';

  static Future<void> saveRemember(bool remember) =>
      putText(kKeyRemember, remember ? '1' : '0');

  // ---- 上次选择 ----

  static String loadLastSemester() => getText(kKeyLastSemester);

  static Future<void> saveLastSemester(String s) =>
      putText(kKeyLastSemester, s);

  static String loadLastWeek() => getText(kKeyLastWeek);

  static Future<void> saveLastWeek(String w) => putText(kKeyLastWeek, w);

  static String loadLastScoreSemester() => getText(kKeyLastScoreSemester);

  static Future<void> saveLastScoreSemester(String s) =>
      putText(kKeyLastScoreSemester, s);

  // ---- 开学日期与周次对齐 ----

  static String loadSemesterStart() => getText(kKeySemesterStart);

  static Future<void> saveSemesterStart(String date) =>
      putText(kKeySemesterStart, date);

  static int loadWeekAlignAt() => getInt(kKeyWeekAlignAt);

  static Future<void> saveWeekAlignAt(int ms) => putInt(kKeyWeekAlignAt, ms);

  static int loadWeekAlignValue() => getInt(kKeyWeekAlignValue);

  static Future<void> saveWeekAlignValue(int week) =>
      putInt(kKeyWeekAlignValue, week);

  // ---- 提醒 ----

  static bool loadReminderOn() => getText(kKeyReminderOn, '0') == '1';

  static Future<void> saveReminderOn(bool on) =>
      putText(kKeyReminderOn, on ? '1' : '0');

  static int loadReminderAdvance() =>
      int.tryParse(getText(kKeyReminderAdvance, '15')) ?? 15;

  static Future<void> saveReminderAdvance(int m) =>
      putText(kKeyReminderAdvance, m.toString());

  // ---- 节次作息 ----

  static String loadSectionTimes() => getText(kKeySectionTimes);

  static Future<void> saveSectionTimes(String v) => putText(kKeySectionTimes, v);

  /// 作息是否被用户手动改过（判据的说明见 [kKeySectionTimesCustom]）
  static bool loadSectionTimesCustom() =>
      getText(kKeySectionTimesCustom, '0') == '1';

  static Future<void> saveSectionTimesCustom(bool v) =>
      putText(kKeySectionTimesCustom, v ? '1' : '0');

  /// 退出登录时清理「跟账号绑定」的键。
  ///
  /// 刻意**不删**课表文件：它按「账号+学期」分文件保存，
  /// 换回原账号时要能读回本地修改。
  static Future<void> clearAccountScoped() async {
    await putText(kKeyCardSnapshot, '');
    await clearAccount();
    await putText(kKeyLastSemester, '');
    await putText(kKeyLastWeek, '');
    await putText(kKeyLastScoreSemester, '');
  }
}
