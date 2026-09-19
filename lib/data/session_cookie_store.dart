/// 会话 cookie 的加密存储（系统密钥库）
///
/// 从鸿蒙版 `data/SessionCookieStore.ets` 移植：鸿蒙侧用 `@kit.AssetStoreKit`，
/// 这里用 `flutter_secure_storage`（底层 Android Keystore 加密）。
///
/// 注：该库 10.0 起已不用 EncryptedSharedPreferences，改为 Keystore + AES-GCM，
/// 因此不要再按旧资料描述它的实现。
///
/// ===== 为什么必须加密（而不是放在 shared_preferences）=====
/// `JSESSIONID` 是**持有即可用**的凭据：拿到它就等于拿到该学生的完整登录态，
/// 不需要账号密码、也不受验证码保护。
///
/// 而 `shared_preferences` 是**明文 XML**。实测确认过：
/// 在可调试构建上 `adb shell run-as <包名> cat shared_prefs/FlutterSharedPreferences.xml`
/// 能直接打印出 `session_cookie` 的原文。
/// （`allowBackup="false"` 已挡住云备份这条路径，但明文本身仍是可被读取的。）
///
/// 因此会话 cookie 改存系统密钥库，与账号密码（[CredentialStore]）同一套机制。
///
/// ===== 为什么需要内存缓存（重要）=====
/// 密钥库**只有异步接口**，而调用方是同步的：
/// `AppState.init()` / `restoreSession()` 里都是
/// `jar.deserialize(PrefStore.loadCookie())` —— 它们发生在构建首帧之前，
/// 改成 async 会把异步性扩散到整个启动链路。
///
/// 折中做法：[prime] 在 `PrefStore.init()` 里被 await 一次，
/// 把 cookie 读进内存；之后 [cached] 同步返回。
/// 代价是启动时多一次密钥库读取（几毫秒），换掉整条链路的异步改造。
///
/// ===== 兼容旧版本（平滑迁移）=====
/// 升级前 `shared_preferences` 里已经有明文 cookie。直接不读它会导致
/// **所有老用户被登出一次**，这不能接受。因此 [prime] 的顺序是：
///   1. 先读密钥库；
///   2. 密钥库里没有，再读一次旧明文；
///   3. 若旧明文存在 → 写入密钥库并**抹掉明文**，然后返回。
/// 这样迁移对用户完全无感，且明文只多存在最后一次。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../common/constants.dart';
import 'pref_store.dart';

class SessionCookieStore {
  /// 密钥库别名。与凭据（sdufe_jw_account/password）分开，便于独立清除。
  static const String _key = 'sdufe_jw_session';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// 内存里的会话（同步读取的唯一来源）
  static String _cached = '';
  static bool _primed = false;

  /// 启动时预热一次（由 `PrefStore.init()` await）。
  ///
  /// 幂等：重复调用只生效一次。
  static Future<void> prime() async {
    if (_primed) {
      return;
    }
    _primed = true;
    try {
      final String? fromKeystore = await _storage.read(key: _key);
      if (fromKeystore != null && fromKeystore.isNotEmpty) {
        _cached = fromKeystore;
        return;
      }
    } catch (_) {
      // 密钥库不可用：继续走下面的旧明文兜底，至少不把用户登出
    }
    // 密钥库没有 → 可能是升级前留下的明文。读到就顺手迁移。
    final String legacy = PrefStore.getText(kKeySessionCookie);
    if (legacy.isNotEmpty) {
      _cached = legacy;
      await save(legacy);
    }
  }

  /// 同步读取（调用方在首帧之前用它恢复会话）
  static String cached() => _cached;

  /// 写入密钥库，并**无论成败都抹掉明文**。
  static Future<void> save(String cookie) async {
    _cached = cookie;
    bool ok = true;
    try {
      if (cookie.isEmpty) {
        await _storage.delete(key: _key);
      } else {
        await _storage.write(key: _key, value: cookie);
      }
    } catch (_) {
      ok = false;
    }
    // 明文一定要清掉，否则升级后旧值会一直留着，等于没加固
    await PrefStore.putText(kKeySessionCookie, '');
    if (!ok) {
      // 降级：密钥库故障时宁可先保证「能登录」。
      // 登录不了比明文存储更糟，而且这条路径只在密钥库异常时才会走到。
      await PrefStore.putText(kKeySessionCookie, cookie);
    }
  }

  static Future<void> clear() async {
    _cached = '';
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // 不存在或失败都忽略
    }
    // 兼容降级路径写下的明文，一并清掉
    await PrefStore.putText(kKeySessionCookie, '');
  }
}
