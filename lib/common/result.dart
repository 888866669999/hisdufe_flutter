/// 统一错误类型与用户可见文案
///
/// 从鸿蒙版 `common/Result.ets` 移植。
///
/// 设计要点（沿用了鸿蒙版的教训）：**任何抛出物都要能变成一句给用户看的话**。
/// 鸿蒙版吃过「在 catch 里再抛一次」的亏 —— 当时用 `e as AppError` 做断言，
/// 一旦抛出的是原生错误，`toUserText` 就是 undefined，调用它会二次抛出，
/// 变成未处理异常甚至白屏。Dart 这边同样不能假设 `e is AppError`，
/// 因此统一走 [describe]。
library;

/// 错误分类。调用方按分类决定行为（例如只在验证码类失败上重试）。
enum ErrKind {
  none,
  network,

  /// 会话失效，需要重新验证
  authExpired,
  captcha,
  badCredentials,
  parse,
  server,
  unknown,
}

/// 应用统一异常
class AppError implements Exception {
  AppError(this.kind, this.message, [this.detail = '']);

  final ErrKind kind;
  final String message;
  final String detail;

  /// 给用户看的文案。业务文案优先，其次分类兜底，最后通用兜底。
  String toUserText() {
    if (message.isNotEmpty) {
      return message;
    }
    switch (kind) {
      case ErrKind.network:
        return '网络连接失败，请检查网络后重试';
      case ErrKind.authExpired:
        return '登录状态已失效，请重新登录';
      case ErrKind.captcha:
        return '验证码错误，请重新输入';
      case ErrKind.badCredentials:
        return '账号或密码错误';
      case ErrKind.parse:
        return '数据解析失败，教务系统可能已改版';
      case ErrKind.server:
        return '教务系统响应异常，请稍后重试';
      case ErrKind.none:
      case ErrKind.unknown:
        return '发生未知错误';
    }
  }

  bool get isAuthExpiredError => kind == ErrKind.authExpired;

  @override
  String toString() => 'AppError($kind, $message, $detail)';

  /// 把**任意**抛出物转成可显示的字符串。
  ///
  /// 这是本文件存在的核心理由：不要在任何 catch 块里假定错误类型。
  static String describe(Object? e) {
    if (e == null) {
      return '发生未知错误';
    }
    if (e is AppError) {
      return e.toUserText();
    }
    if (e is FormatException) {
      return '数据解析失败，教务系统可能已改版';
    }
    if (e is String) {
      return e;
    }
    // 其余按普通异常处理；message 可能为空，此时退到通用文案
    final String s = e.toString().replaceFirst('Exception: ', '');
    return s.isNotEmpty ? s : '发生未知错误';
  }

  /// 判断是否为「会话失效」类错误（页面据此抑制重复报错）
  static bool isAuthExpired(Object? e) {
    if (e is AppError) {
      return e.kind == ErrKind.authExpired;
    }
    return false;
  }
}
