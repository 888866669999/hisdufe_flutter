/// 凭据存储（系统密钥库）
///
/// 从鸿蒙版 `data/CredentialStore.ets` 移植。鸿蒙侧用 `@kit.AssetStoreKit`，
/// Android 侧用 `flutter_secure_storage`（底层 Android Keystore 加密）。
///
/// 注意**不要**再写「底层是 EncryptedSharedPreferences」：该库从 10.0 起
/// 已不再使用它，改为自研方案（Keystore 持有密钥 + AES-GCM 加密后存储）。
/// 本文件下面那句「11.x 不再接受 encryptedSharedPreferences 参数」也是同一件事。
///
/// ===== 安全边界 =====
/// - 「记住账号密码」**默认是勾选状态**，因此正常登录就会写入密钥库；
///   用户主动取消勾选、或退出登录时立即清除（这一点是设计选择：
///   默认记住能免去每次输验证码前的账号密码输入，而凭据存在系统密钥库里）；
/// - 密钥库里的值不落日志、不进错误上报。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Credential {
  Credential(this.account, this.password);

  final String account;
  final String password;
}

class CredentialStore {
  static const String _keyAccount = 'sdufe_jw_account';
  static const String _keyPassword = 'sdufe_jw_password';

  // flutter_secure_storage 11.x 默认就走 Android Keystore 加密，
  // 不再需要（也不接受）encryptedSharedPreferences 参数。
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// 内存缓存 + 单一 in-flight，避免启动时并发读取。
  ///
  /// 鸿蒙版曾因两处并发查密钥库导致主线程阻塞（appfreeze THREAD_BLOCK_6S），
  /// 这里从一开始就串行化。
  static Credential? _cache;
  static bool _loaded = false;
  static Future<Credential?>? _inFlight;

  /// 世代号：异步读期间若用户点了「清除」，回调不应把旧值写回缓存。
  static int _generation = 0;

  static Future<Credential?> load() async {
    if (_loaded) {
      return _cache;
    }
    if (_inFlight != null) {
      return _inFlight;
    }
    _inFlight = _doLoad();
    try {
      return await _inFlight;
    } finally {
      _inFlight = null;
    }
  }

  static Future<Credential?> _doLoad() async {
    final int gen = _generation;
    try {
      final String? account = await _storage.read(key: _keyAccount);
      final String? password = await _storage.read(key: _keyPassword);
      if (gen != _generation) {
        // 期间被清除过，不要写回缓存
        return null;
      }
      if (account == null || account.isEmpty || password == null || password.isEmpty) {
        _cache = null;
      } else {
        _cache = Credential(account, password);
      }
      _loaded = true;
      return _cache;
    } catch (_) {
      // 读取失败（例如密钥库被重置）时视为无凭据，而不是抛给界面
      _cache = null;
      _loaded = true;
      return null;
    }
  }

  static Future<bool> exists() async => (await load()) != null;

  static Future<void> save(String account, String password) async {
    _generation++;
    await _storage.write(key: _keyAccount, value: account);
    await _storage.write(key: _keyPassword, value: password);
    _cache = Credential(account, password);
    _loaded = true;
  }

  static Future<void> clear() async {
    _generation++;
    _cache = null;
    _loaded = true;
    try {
      await _storage.delete(key: _keyAccount);
      await _storage.delete(key: _keyPassword);
    } catch (_) {
      // 清除失败不应阻塞登出流程
    }
  }
}
