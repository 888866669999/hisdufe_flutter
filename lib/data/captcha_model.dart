/// 验证码识别：用 ddddocr 的训练模型在本机推理
///
/// ===== 为什么要用训练模型，而不是系统 OCR =====
/// 鸿蒙版实测过通用文字识别（Core Vision Kit）：多种预处理组合下
/// 完全正确率只有 **14%–42%**。它按自然场景文字训练，对「4 个扭曲字符」
/// 这种输入几乎不可用。而 ddddocr（MIT 许可）专门在这类验证码上训练过，
/// **同一批语料实测 11/12（92%）**，差距是量级性的。
///
/// ===== Android 比鸿蒙版省事 =====
/// 鸿蒙只有 MindSpore Lite、只吃 `.ms`，因此必须把 ONNX 转换一遍，
/// 而且量化版用到的算子（ConvInteger / DynamicQuantizeLSTM）还不受支持，
/// 只能退用浮点版（54 MB）。
/// Android 直接有 ONNX Runtime，可以**加载 ddddocr 原版量化模型**
/// （13 MB，精度也更高），无需任何转换。
///
/// ===== 隐私：不需要联网 =====
/// 模型随包内置、推理在本机完成；不上传验证码，也不请求第三方服务。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import '../model/captcha_charset.dart';

/// 模型要求的输入尺寸：灰度、高 64、宽 160
const int kModelHeight = 64;
const int kModelWidth = 160;

class OcrOutcome {
  OcrOutcome(this.ok, this.text, [this.reason = '']);

  final bool ok;
  final String text;
  final String reason;
}

class CaptchaModel {
  static OrtSession? _session;
  static bool _loading = false;
  static String _loadError = '';

  static bool get isReady => _session != null;

  static String get loadError => _loadError;

  /// 加载模型（幂等，首次调用时把 asset 释放到文件再加载）。
  ///
  /// ONNX Runtime 需要文件路径，而 Flutter 的 asset 在包里不能直接当文件读，
  /// 因此先复制到应用私有目录。只做一次。
  static Future<OrtSession?> load() async {
    if (_session != null) {
      return _session;
    }
    if (_loading) {
      return null;
    }
    _loading = true;
    try {
      final ByteData data = await rootBundle.load('assets/captcha.onnx');
      final Directory dir = await getApplicationSupportDirectory();
      final File f = File('${dir.path}/captcha.onnx');

      // 关键：必须按 offsetInBytes/lengthInBytes 取**这个 asset 的那一段**。
      //
      // `data.buffer.asUint8List()` 会返回整个底层缓冲区，而 rootBundle 返回的
      // ByteData 常常是某个更大缓冲区的**视图**（offset 非 0）。
      // 直接写整个 buffer 会写出一个长度不对、内容错位的文件，
      // ONNX Runtime 加载它必然失败 —— 表现就是「识别率 0%」：
      // 每次识别都返回「模型未加载」，输入框永远填不上。
      final Uint8List bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

      final bool needWrite =
          !await f.exists() || await f.length() != bytes.length;
      if (needWrite) {
        await f.writeAsBytes(bytes, flush: true);
      }

      OrtEnv.instance.init();
      final OrtSessionOptions opts = OrtSessionOptions()
        ..setIntraOpNumThreads(2);
      _session = OrtSession.fromFile(f, opts);
      _loadError = '';
      return _session;
    } catch (e) {
      _loadError = e.toString();
      debugPrint('[captcha] model load failed: $_loadError');
      return null;
    } finally {
      _loading = false;
    }
  }

  /// 识别一张验证码（JPEG 字节）
  static Future<OcrOutcome> recognize(Uint8List jpeg) async {
    final OrtSession? session = await load();
    if (session == null) {
      return OcrOutcome(false, '', '模型未加载：$_loadError');
    }
    try {
      final img.Image? decoded = img.decodeImage(jpeg);
      if (decoded == null) {
        return OcrOutcome(false, '', '验证码图片解析失败');
      }

      // 1) 等比缩放到高 64（保持宽高比）
      final double scale = kModelHeight / decoded.height;
      int targetW = (decoded.width * scale).round();
      if (targetW < 1) {
        targetW = 1;
      }
      final img.Image resized =
          img.copyResize(decoded, width: targetW, height: kModelHeight,
              interpolation: img.Interpolation.linear);

      // 2) 灰度 + 归一化 + 右侧补白到 160
      //    补白用白色（1.0），与训练时的 padding 一致。
      final Float32List tensor =
          Float32List(kModelHeight * kModelWidth)..fillRange(
              0, kModelHeight * kModelWidth, 1.0);
      for (int y = 0; y < kModelHeight; y++) {
        for (int x = 0; x < kModelWidth && x < targetW; x++) {
          final img.Pixel p = resized.getPixel(x, y);
          // 亮度（与鸿蒙版同样的权重，避免两版结果不一致）
          final num lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          tensor[y * kModelWidth + x] = lum / 255.0;
        }
      }

      // 3) 推理：输入 NCHW 1×1×64×160
      final List<OrtValue> inputs = <OrtValue>[
        OrtValueTensor.createTensorWithDataList(
          tensor,
          <int>[1, 1, kModelHeight, kModelWidth],
        ),
      ];
      final List<OrtValue?>? outputs = await session.runAsync(
        OrtRunOptions(),
        <String, OrtValue>{session.inputNames.first: inputs.first},
      );
      if (outputs == null || outputs.isEmpty) {
        return OcrOutcome(false, '', '模型无输出');
      }

      // 4) 解码：输出形状 [T, 1, C]，逐时间步取 argmax
      final Object? raw = outputs.first?.value;
      if (raw is! List) {
        return OcrOutcome(false, '', '输出形状异常');
      }
      // raw 形如 [[[f,f,...], ...]]（batch 维）
      final List<List<double>> steps = _flatten(raw);
      if (steps.isEmpty) {
        return OcrOutcome(false, '', '输出为空');
      }
      final List<int> indices = <int>[];
      for (final List<double> probs in steps) {
        int best = 0;
        double bestVal = -1;
        for (int c = 0; c < probs.length; c++) {
          if (probs[c] > bestVal) {
            bestVal = probs[c];
            best = c;
          }
        }
        indices.add(best);
      }
      final String text = CaptchaCharset.decode(indices);
      // 诊断：把形状与逐步结果打出来。
      // 识别率异常时，这一行能直接区分「模型没跑起来」「输出结构不对」
      // 与「字符表对不上」这三种完全不同的故障。
      debugPrint('[captcha] img=${decoded.width}x${decoded.height} '
          'resized=${targetW}x$kModelHeight steps=${steps.length} '
          'classes=${steps.first.length} idx=${indices.join(",")} text="$text"');
      if (text.isEmpty) {
        return OcrOutcome(false, '', '未识别出字符');
      }
      return OcrOutcome(true, text);
    } catch (e) {
      debugPrint('[captcha] recognize failed: $e');
      return OcrOutcome(false, '', e.toString());
    }
  }

  /// 把 ONNX 的三维输出摊平成 [时间步][类别]
  static List<List<double>> _flatten(Object raw) {
    final List<List<double>> out = <List<double>>[];
    void walk(Object? node, {required bool isRoot}) {
      if (node is List) {
        // 判断是不是「一维数值数组」
        if (node.isNotEmpty && node.first is num) {
          out.add(node.map((Object? v) => (v as num).toDouble()).toList());
          return;
        }
        for (final Object? c in node) {
          walk(c, isRoot: false);
        }
      }
    }

    walk(raw, isRoot: true);
    return out;
  }

  /// 释放（退出登录等场景可选调用）
  static void release() {
    _session?.release();
    _session = null;
  }
}
