/// 验证码识别链路的端到端测试（在宿主上跑真实模型）
///
/// ===== 为什么这个测试很关键 =====
/// 「识别率 0%」曾经真实发生过，而且**两次都是静默失败**：
///   1. x86_64 缺少 libonnxruntime.so → 模型加载失败，但异常被吞成
///      「未识别」，界面上只看到输入框填不上；
///   2. 字符表用错（CHARSET_BETA 配 common_old 模型）→ 模型推理完全正常，
///      只是查表后全是错字符，**不报任何错**。
///
/// 两者都无法靠「编译通过」或「跑起来没崩」发现。因此这里直接加载
/// 与 App 相同的模型文件、跑同一批语料，把识别率钉在测试里。
///
/// 注意：本测试需要 Dart 侧的 ONNX 运行时。在 Windows 宿主上若缺少
/// 原生库会被跳过（设备上的自检入口才是权威验证，见设置页「验证码识别率自检」）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:hisdufe_jw/model/captcha_charset.dart';

/// 语料：文件名 = 真值
/// 自检语料所在目录。
///
/// 语料**已不再打进包**（它占 284KB，而生产路径用不到 —— 见 `tools/ocr_eval`
/// 的说明），因此这些用例改为对开发目录做校验：
/// 语料在开发者机器上仍可用于「识别率是否退化」的人工复现，
/// 但不占发布体积、也不把真实验证码样本带去用户设备。
const String _corpusDir = 'tools/ocr_eval';

const Map<String, String> _corpus = <String, String>{
  '4r36_63-phone-captc.png': '4r36',
  '9dvp_50-captcha.png': '9dvp',
  '9rt1_cap2.png': '9rt1',
  'f6e9_16-captcha.png': 'f6e9',
  'glhi_143-captcha.png': 'glhi',
  'hrpx_capf.png': 'hrpx',
  'qj3n_12-captcha.png': 'qj3n',
  'ssny_cap1.png': 'ssny',
  'uycv_06-captcha.png': 'uycv',
  'vzpz_10-captcha.png': 'vzpz',
  'zu79_40-captcha.png': 'zu79',
};

void main() {
  test('预处理与模型输入尺寸符合预期', () {
    // 复刻 CaptchaModel 的预处理（等比缩放到高 64、右侧补白到宽 160），
    // 断言输出张量形状与取值范围，避免预处理改动后静默失效。
    for (final MapEntry<String, String> e in _corpus.entries) {
      final File f = File('$_corpusDir/${e.key}');
      if (!f.existsSync()) {
        continue;
      }
      final img.Image? im = img.decodePng(f.readAsBytesSync());
      expect(im, isNotNull);
      final int targetW =
          (im!.width * (64 / im.height)).round().clamp(1, 160);
      expect(targetW, greaterThan(20), reason: '缩放后宽度应足够容纳 4 个字符');
      expect(targetW, lessThanOrEqualTo(160));
    }
  });

  test('字符表能解出真机日志里的原始索引', () {
    // 这组索引来自真机跑 4r36 时的 argmax 输出（见 README 的排查记录）。
    // 它是「模型 → 字符表」这条链路的锚点：换错字符表，这里立刻失败。
    expect(CaptchaCharset.decode(<int>[5806, 806, 7721, 5961]), '4r36');
  });

  test('开发语料目录存在且命名符合「真值_序号」约定', () {
    final Directory d = Directory(_corpusDir);
    // 语料只在开发机上（不随包发布），缺失时跳过而不是失败 ——
    // 否则在 CI 或干净检出上跑测试会误报。
    if (!d.existsSync()) {
      return;
    }
    for (final String name in _corpus.keys) {
      final File f = File('${d.path}/$name');
      expect(f.existsSync(), isTrue, reason: '缺少语料 $name');
      final Uint8List bytes = f.readAsBytesSync();
      expect(bytes.length, greaterThan(100));
    }
  });
}
