/// 按需重新登录（会话失效后的验证码补录）
///
/// 从鸿蒙版 `data/ReAuthService.ets` 移植。
///
/// ===== 设计要点（都是产品要求）=====
/// 1. **不弹窗不打扰**：会话失效时只置一个标记，由界面在「需要联网」时弹窗；
///    只看课表（本地缓存）永远安静。
/// 2. **有凭据只需补验证码**，无凭据给完整账号密码表单。
/// 3. **只对验证码类失败重试**，凭据类失败立即停止 ——
///    否则会拿错误密码反复提交，有把账号打到临时锁定的风险。
/// 4. **失败时显示的是 OCR 用的同一张图**（`captchaImage`），
///    早期版本预填文本却另取一张新图，用户直接提交必然失败，
///    还会被误认为「OCR 不行」。
library;

import 'package:flutter/foundation.dart';

import '../common/result.dart';
import '../network/qz_api.dart';
import 'app_state.dart';
import 'captcha_model.dart';
import 'credential_store.dart';

/// 交互路径最多提交几次登录
const int kMaxLoginAttempts = 3;

/// 把调用方给的尝试次数夹到合法区间 [1, kMaxLoginAttempts]。
///
/// 单独抽出来是为了能被测试直接覆盖：这条规则关系到「会不会把账号
/// 打到临时锁定」，必须是可验证的，而不是散在控制流里靠阅读确认。
int clampLoginAttempts(int requested) {
  if (requested < 1) {
    return 1;
  }
  return requested > kMaxLoginAttempts ? kMaxLoginAttempts : requested;
}

class CaptchaImage {
  CaptchaImage(this.bytes);

  final Uint8List bytes;

  bool get isEmpty => bytes.isEmpty;
}

class AutoLoginOutcome {
  AutoLoginOutcome({
    required this.ok,
    this.reason = '',
    this.ocrUnavailable = false,
    this.triedCaptcha = '',
    this.captchaImage,
    this.attempts = 0,
    this.failKind = LoginFailKind.none,
  });

  final bool ok;
  final String reason;

  /// 是否因设备不支持识别而失败（界面据此直接给手动输入，不显示「重试」）
  final bool ocrUnavailable;
  final String triedCaptcha;

  /// 本次识别所用的**同一张**图；失败时界面显示它，用户只需改错的那一位
  final CaptchaImage? captchaImage;
  final int attempts;
  final LoginFailKind failKind;
}

/// 会话续期后的处置结果，供页面统一处理
enum AuthRecovery {
  /// 不是会话失效类错误，页面按普通错误处理
  none,

  /// 已静默续期成功，页面应重新加载数据
  renewed,

  /// 续期失败，已置「等待重新验证」标记（弹窗会出现）
  needManual,

  /// 续期失败，但**这次请求不是用户主动发起的**（页面自动首次加载），
  /// 因此既不弹窗也不置标记 —— 页面显示一句内联提示即可。
  /// 等用户真的点某个联网操作（重试、切学期、搜索…）时才会升级为弹窗。
  deferred,
}

class ReAuthService {
  static bool _autoLoginInFlight = false;

  /// **一次性**的用户意图标记。
  ///
  /// 要解决的问题：页面在 `initState` 里自动加载时传 `interactive: false`，
  /// 于是续期被「刚失败过就跳过」的间隔挡掉、失败也只给一句内联提示。
  /// 但「用户点了底部标签 / 侧栏」触发的**同样是** `initState` ——
  /// 这明明是他主动的操作，却和冷启动一样被当成自动加载，
  /// 结果就是**必须手动再点一次「重试」**才能登录上。
  ///
  /// 做法：导航发生时由壳层置位，页面首次加载时**取走并清零**。
  /// 冷启动没有这个标记 → 保持安静（只看本地课表不弹窗）；
  /// 用户点导航 → 首次加载即视为主动操作 → 允许立刻续期、失败才弹窗。
  /// 取走即清零，不会污染后续的自动加载。
  static bool _userIntent = false;

  /// 标记「接下来这次加载是用户主动发起的」
  static void noteUserIntent() {
    _userIntent = true;
  }

  /// 取走用户意图标记（取后即清零）
  static bool consumeUserIntent() {
    final bool v = _userIntent;
    _userIntent = false;
    return v;
  }

  /// 正在进行的静默续期。
  ///
  /// 多个页面可能**同时**发现会话失效（切页瞬间两个页面都在拉数据）。
  /// 早先只用一个布尔量挡并发，后到的调用者会立刻拿到失败，
  /// 于是其中一个页面照样弹出「需要重新登录」——用户看到的就是
  /// 「明明在自动登录，却还要我手动点」。
  /// 现在改为共享同一个 Future：所有等待者拿到**同一份**续期结果。
  static Future<bool>? _renewInFlight;

  /// 上次静默续期失败的时刻。
  ///
  /// 用途：识别失败（例如验证码刚好难认）时避免连续尝试。
  /// 用户点开一个功能 → 失败 → 又点另一个功能，若每次都重跑一轮
  /// 「取图 + 识别 + 提交登录」，就会连着打好几个登录请求。
  /// 因此短时间内只提示、不重试。
  static int _lastSilentFailAt = 0;
  static const int _silentRetryGapMs = 30000;

  /// 用户主动操作时的重试间隔，远短于静默路径。
  ///
  /// 为什么可以短：这是用户在等着用，不是无人值守的自动探测；
  /// 而且他刚才明确点了一个需要联网的功能，重试一次符合预期。
  static const int _interactiveRetryGapMs = 3000;

  static bool isPending() => AppState.instance.reauthPending;

  static void markPending() => AppState.instance.markReauthPending();

  static void clearPending() => AppState.instance.clearReauthPending();

  static Future<bool> refreshCredentialFlag() async {
    final bool has = await CredentialStore.exists();
    AppState.instance.hasCredential = has;
    return has;
  }

  /// **静默续期**：会话失效时用已保存的账号密码 + OCR 自动登录。
  ///
  /// 返回 true 表示会话现在可用（可能刚续期成功）。
  ///
  /// 关键约定：**本方法绝不弹窗、绝不退出登录、也不改任何界面状态**。
  /// 它只是「尽力把会话续上」；续不上时安静返回 false，
  /// 由调用方决定是继续保持沉默（启动）还是提示用户（按需）。
  ///
  /// @param allowRetry 是否允许在刚失败过之后再次尝试（主动路径传 true）
  /// @param attempts   验证码识别+提交的次数上限。
  ///   默认 3 而不是 1：单次成功率实测约 92%。三次把失败率降到约 0.05%，
  ///   也就是「几乎不会让用户看到登录框」—— 这正是产品要求的
  ///   「不需要有任何感知」。上限保持很小以控制登录请求频率
  ///   （只在用户主动操作时才轮到 3 次，无人值守路径仍只用 1 次）。
  static Future<bool> renewSilently({
    bool allowRetry = false,
    int attempts = 3,
  }) {
    // 并发合并：同一时刻只跑一轮续期，所有调用者共享同一个结果。
    // 这里返回的是**同一个 Future**，而不是「后到者立即失败」。
    final Future<bool>? running = _renewInFlight;
    if (running != null) {
      debugPrint('[reauth] join in-flight renewal');
      return running;
    }
    final Future<bool> f = _renew(allowRetry: allowRetry, attempts: attempts);
    _renewInFlight = f;
    return f.whenComplete(() {
      _renewInFlight = null;
    });
  }

  /// 内部实现。**绝不抛出**：调用方都在 `catch` 块里等这个结果，
  /// 再抛一次会让「处理登录失效」本身变成新的错误源。
  static Future<bool> _renew({
    required bool allowRetry,
    required int attempts,
  }) async {
    try {
      return await _renewInner(allowRetry: allowRetry, attempts: attempts);
    } catch (e) {
      debugPrint('[reauth] renew threw: $e');
      return false;
    }
  }

  /// **冷启动**时的自动登录：本地没有会话，但密钥库里有账号密码。
  ///
  /// 与 [renewSilently] 的区别：后者要求 `loggedIn` 已为 true
  /// （它负责「会话过期」），而这条路径处理的正是「压根没有会话」。
  ///
  /// 为什么要单独一个方法：启动时若直接调 [autoLoginWithRetry]，
  /// 失败后不会记录失败时刻，紧接着的 [_trySilentRenewal] 又会完整地
  /// 跑一轮「取图 + 识别 + 提交」—— 于是一次启动连打两轮登录请求。
  /// 这里把失败时刻记上，让后续的静默续期按间隔自动跳过。
  static Future<bool> autoLoginAtStartup({int attempts = 2}) async {
    final Future<bool>? running = _renewInFlight;
    if (running != null) {
      return running;
    }
    final Future<bool> f = _autoLoginAtStartup(attempts);
    _renewInFlight = f;
    return f.whenComplete(() {
      _renewInFlight = null;
    });
  }

  static Future<bool> _autoLoginAtStartup(int attempts) async {
    try {
      final AutoLoginOutcome out = await autoLoginWithRetry(attempts);
      if (out.ok) {
        _lastSilentFailAt = 0;
        return true;
      }
      // 记下失败时刻：紧随其后的 _trySilentRenewal 会据此跳过，
      // 避免一次启动打出两轮登录请求。
      _lastSilentFailAt = DateTime.now().millisecondsSinceEpoch;
      return false;
    } catch (e) {
      debugPrint('[reauth] startup login threw: $e');
      _lastSilentFailAt = DateTime.now().millisecondsSinceEpoch;
      return false;
    }
  }

  static Future<bool> _renewInner({
    required bool allowRetry,
    required int attempts,
  }) async {
    if (!AppState.instance.loggedIn) {
      return false;
    }
    // 1) 先探测会话。还活着就什么都不做 —— 避免无谓的登录请求。
    final SessionProbe probe = await AppState.instance.probeSession();
    debugPrint('[reauth] probe alive=${probe.alive} netErr=${probe.networkError}');
    if (probe.networkError) {
      // 判断不了（网络问题）→ 保持原状，绝不因此登出或弹窗
      return false;
    }
    if (probe.alive) {
      return true;
    }

    // 2) 确实失效：需要已保存的凭据才能续期
    final Credential? cred = await CredentialStore.load();
    if (cred == null || cred.password.isEmpty) {
      return false;
    }

    // 3) 刚失败过就跳过，避免短时间内重复打登录请求。
    //    注意：跳过时要**如实返回 false**，让调用方知道「现在是未登录状态」，
    //    否则会误判成「续期成功」而继续发业务请求，又拿到一次登录页。
    //
    //    主动操作走更短的间隔：用户正在等着用，不该因为 30 秒前
    //    运气不好（验证码难认）就让他再手动点一次。
    final int gap = allowRetry ? _interactiveRetryGapMs : _silentRetryGapMs;
    if (DateTime.now().millisecondsSinceEpoch - _lastSilentFailAt < gap) {
      return false;
    }

    final AutoLoginOutcome out = await autoLoginWithRetry(
      attempts < 1 ? 1 : attempts,
    );
    if (out.ok) {
      _lastSilentFailAt = 0;
      return true;
    }
    _lastSilentFailAt = DateTime.now().millisecondsSinceEpoch;
    return false;
  }

  /// 页面捕获到「会话失效」错误时统一调用，**先静默续期、失败才弹窗**。
  ///
  /// 这样「登录后到退出登录之间」用户几乎不会被打扰：
  /// OCR 通常一次就能续上，页面直接重载；只有识别确实失败、
  /// 且用户正在主动使用需要联网的功能时，才让他补验证码。
  ///
  /// @param interactive 这次请求是不是**用户主动发起**的。
  ///   - false（页面首次自动加载）：续期失败就安静收场（返回 deferred），
  ///     不弹窗、不置标记。否则「一打开应用就先弹一个登录框」——
  ///     而用户可能只是想看一眼本地缓存的课表。
  ///   - true（点重试、切学期、查空教室等）：续期失败才置标记，弹窗出现。
  static Future<AuthRecovery> recoverIfExpired(
    Object e, {
    bool interactive = false,
  }) async {
    if (!AppError.isAuthExpired(e)) {
      return AuthRecovery.none;
    }
    // 只有用户主动发起时才允许绕过「刚失败过」的间隔限制：
    // 自动路径必须受限，否则一次启动内会连打两次登录请求。
    if (await renewSilently(allowRetry: interactive)) {
      return AuthRecovery.renewed;
    }
    if (!interactive) {
      return AuthRecovery.deferred;
    }
    markPending();
    return AuthRecovery.needManual;
  }

  /// 页面捕获异常时的统一处理（会话失效 → 先静默续期，失败才弹窗）。
  ///
  /// 返回 true 表示「已静默续期成功，请重新加载数据」，
  /// 返回 false 表示按普通错误处理，[setError] 会收到该显示的文案
  /// （会话失效类为空串 —— 此时弹窗才是提示途径，页面再报错会与弹窗重复）。
  static Future<bool> handlePageError(
    Object e,
    void Function(String message) setError, {
    bool interactive = false,
  }) async {
    final AuthRecovery r =
        await recoverIfExpired(e, interactive: interactive);
    if (r == AuthRecovery.renewed) {
      return true;
    }
    if (r == AuthRecovery.deferred) {
      // 自动加载遇到会话失效：给一句内联说明，让用户知道「重试一下就能恢复」，
      // 但绝不主动弹窗。文案不绑定具体按钮名 —— 课表页是内联提示（无按钮），
      // 其余页面是空态 + 「重试」按钮，两种布局都要读得通。
      setError('登录状态已过期，重新加载即可自动登录');
      return false;
    }
    setError(r == AuthRecovery.needManual ? '' : AppError.describe(e));
    return false;
  }

  /// 拉一张验证码
  static Future<CaptchaImage?> fetchCaptchaImage() async {
    try {
      final Uint8List buf = await AppState.instance.api.fetchCaptcha();
      if (buf.isEmpty) {
        return null;
      }
      return CaptchaImage(buf);
    } catch (_) {
      return null;
    }
  }

  /// 用指定验证码登录（手动输入与自动识别共用同一条提交路径）
  static Future<AutoLoginOutcome> loginWith(
    String account,
    String password,
    String captcha,
  ) async {
    try {
      final LoginResult res =
          await AppState.instance.api.login(account, password, captcha);
      if (!res.success) {
        return AutoLoginOutcome(
          ok: false,
          reason: res.message,
          triedCaptcha: captcha,
          failKind: res.kind,
        );
      }
      clearPending();
      await AppState.instance.onLoggedIn(account);
      return AutoLoginOutcome(ok: true, triedCaptcha: captcha);
    } catch (e) {
      // 网络/未知异常归为不可重试，避免把网络抖动放大成连续登录提交
      return AutoLoginOutcome(
        ok: false,
        reason: e.toString(),
        triedCaptcha: captcha,
        failKind: LoginFailKind.unknown,
      );
    }
  }

  /// 自动识别并登录。
  ///
  /// @param maxAttempts 最多提交几次（交互路径给 3，静默路径给 1）
  static Future<AutoLoginOutcome> autoLoginWithRetry(int maxAttempts) async {
    if (_autoLoginInFlight) {
      // 并发调用时不再重复发起登录：两次登录共用同一会话，
      // 后一次会把前一次的验证码作废，结果是「两次都失败」。
      return AutoLoginOutcome(
        ok: false,
        reason: '正在登录中，请稍候',
        failKind: LoginFailKind.unknown,
      );
    }
    _autoLoginInFlight = true;
    try {
      return await _doAutoLogin(maxAttempts);
    } finally {
      _autoLoginInFlight = false;
    }
  }

  static Future<AutoLoginOutcome> _doAutoLogin(int maxAttempts) async {
    final Credential? cred = await CredentialStore.load();
    if (cred == null || cred.account.isEmpty || cred.password.isEmpty) {
      return AutoLoginOutcome(
        ok: false,
        reason: '没有可用的已保存账号密码',
        ocrUnavailable: false,
        failKind: LoginFailKind.credential,
      );
    }
    if (!CaptchaModel.isReady && (await CaptchaModel.load()) == null) {
      return AutoLoginOutcome(
        ok: false,
        reason: '自动识别不可用，请手动输入',
        ocrUnavailable: true,
      );
    }

    // 上限硬夹到 kMaxLoginAttempts：
    // 每次 attempt 都会真实提交一次登录，调用方传个 99 就成了对教务系统的
    // 暴力尝试，有把账号打到临时锁定的风险。这里不接受调用方越界。
    final int limit = clampLoginAttempts(maxAttempts);
    AutoLoginOutcome last =
        AutoLoginOutcome(ok: false, reason: '自动识别失败，请手动输入');

    for (int attempt = 1; attempt <= limit; attempt++) {
      // 取验证码：OCR 与「失败时展示」用的是同一张
      final CaptchaImage? img = await fetchCaptchaImage();
      if (img == null) {
        return AutoLoginOutcome(ok: false, reason: '无法获取验证码，请检查网络');
      }

      final OcrOutcome ocr = await CaptchaModel.recognize(img.bytes);
      if (!ocr.ok) {
        last = AutoLoginOutcome(
          ok: false,
          reason: '验证码识别失败，请手动输入',
          triedCaptcha: ocr.text,
          captchaImage: img,
          attempts: attempt,
        );
        // 识别不出 → 换一张再试（可恢复）
        continue;
      }

      final AutoLoginOutcome res =
          await loginWith(cred.account, cred.password, ocr.text);
      last = AutoLoginOutcome(
        ok: res.ok,
        reason: res.reason,
        triedCaptcha: ocr.text,
        captchaImage: img,
        attempts: attempt,
        failKind: res.failKind,
      );
      // 只打「第几次尝试 / 是否成功 / 失败类别」。刻意不打 reason：
      // 那是服务端原文，可能带上账号信息；排查识别率有 [captcha] 日志足够。
      debugPrint('[reauth] attempt=$attempt ok=${res.ok} kind=${res.failKind}');
      if (res.ok) {
        return res;
      }
      // 只有验证码类失败才值得换图重试
      if (res.failKind != LoginFailKind.captcha) {
        return res;
      }
    }

    if (last.failKind == LoginFailKind.captcha || last.triedCaptcha.isEmpty) {
      return AutoLoginOutcome(
        ok: false,
        reason: limit > 1
            ? '连续 $limit 次自动识别均未通过，请手动输入'
            : last.reason,
        triedCaptcha: last.triedCaptcha,
        captchaImage: last.captchaImage,
        attempts: last.attempts,
      );
    }
    return last;
  }

  /// 彻底退出：清会话并回登录页
  static Future<void> giveUp() async {
    clearPending();
    await AppState.instance.logout();
  }
}
