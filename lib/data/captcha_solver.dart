/// 验证码取图 + OCR 自动识别
///
/// ===== 这个类解决什么 =====
/// 「登录时自动填验证码」在三个场景都要用：
///   1. 首次登录（LoginPage）
///   2. 会话失效后的重新验证（ReAuthDialog）
///   3. 静默续期（ReAuthService）
/// 三处的共同动作都是「取一张验证码 → 识别 → 填回输入框」，
/// 因此抽成一个共享步骤，避免三份实现各自演化出不一致的行为。
///
/// ===== 与 ReAuthService 的分工 =====
/// 本类**只负责识别并返回文本**，不提交登录。
/// 这样 UI 可以把识别结果**填进输入框让用户看到并纠正**，
/// 而不是直接替用户提交 —— 识别率约九成，剩下一成必须留给人来改。
/// 真正的登录提交由调用方决定（LoginPage / ReAuthDialog / ReAuthService）。
library;

import 'dart:typed_data';

import 'captcha_model.dart';

/// 一次「取图 + 识别」的结果
class CaptchaSolve {
  CaptchaSolve({
    required this.bytes,
    this.text = '',
    this.ocrOk = false,
    this.reason = '',
  });

  /// 验证码原图（**必须与 text 是同一张图**）
  ///
  /// 这个约束是硬性的：早先鸿蒙版出现过「预填的是识别结果、显示的却是
  /// 另取的一张新图」，用户直接提交必然失败，还会被误认为识别功能坏了。
  final Uint8List bytes;

  /// 识别出的验证码；失败时为空串
  final String text;

  /// 识别是否成功
  final bool ocrOk;

  /// 失败原因（仅用于提示，不阻塞手动输入）
  final String reason;

  bool get hasImage => bytes.isNotEmpty;
}

class CaptchaSolver {
  /// 取一张验证码并尝试识别。
  ///
  /// [fetch] 由调用方注入，避免本类直接依赖 AppState（那会形成循环依赖）。
  static Future<CaptchaSolve?> solve(
    Future<Uint8List> Function() fetch,
  ) async {
    Uint8List bytes;
    try {
      bytes = await fetch();
    } catch (e) {
      return null;
    }
    if (bytes.isEmpty) {
      return null;
    }

    // 模型未就绪（首次调用会解压 asset）时先加载；失败也不影响手动输入
    final OcrOutcome ocr = await CaptchaModel.recognize(bytes);
    if (!ocr.ok) {
      return CaptchaSolve(
        bytes: bytes,
        ocrOk: false,
        reason: ocr.reason,
      );
    }
    return CaptchaSolve(bytes: bytes, text: ocr.text, ocrOk: true);
  }
}
