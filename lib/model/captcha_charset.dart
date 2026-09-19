/// ddddocr 模型的字符表（仅保留字母与数字）
///
/// ===== 这张表必须与所用模型严格配套（踩过一次，很隐蔽）=====
/// ddddocr 有两套字符表和两个模型，**索引→字符的映射完全不同**：
///
///   模型                   字符表          本仓库是否使用
///   common_old.onnx        CHARSET_OLD     ✅ 用的这个（13MB 量化版，实测 92%）
///   common.onnx            CHARSET_BETA    （浮点版 53MB）
///
/// 两者都是 8210 类，输出形状也一样，**所以拿错表不会报任何错** ——
/// 模型照常推理、照常返回索引，只是查表后变成一堆牛头不对马嘴的字符。
/// 本仓库就经历过：用了 BETA 的表配 OLD 的模型，12 张语料识别率 0%，
/// 而日志里 indices/steps/classes 全部正常，看不出任何异常。
///
/// 症状是「识别率 0%，但模型明明跑起来了」时，**第一件事就是核对这张表**。
/// 判断方法：把设备上打出的 indices 拿到两套表里各查一次，
/// 哪套能解出字母数字就是对的（见 test/charset_test.dart 的锁定用例）。
///
/// ===== 为什么只保留 62 项 =====
/// 完整表含两万多个汉字，而验证码只会出现字母与数字，全量内置纯属浪费。
/// 但**索引不能压缩**：它是模型输出的绝对值，模型给出 5806 就必须查 5806。
/// 因此保留原索引做稀疏映射。
library;

class CaptchaCharset {
  /// 模型输出类别总数（用于校验）
  static const int classCount = 8210;

  /// [索引, 字符码] 稀疏表，取自 ddddocr `CHARSET_OLD`
  static const List<List<int>> _pairs = <List<int>>[
    <int>[78, 50], <int>[357, 70], <int>[409, 55], <int>[687, 68],
    <int>[747, 77], <int>[761, 67],
    <int>[806, 114], <int>[821, 89], <int>[1066, 98], <int>[1107, 99],
    <int>[1583, 74], <int>[1614, 73],
    <int>[1638, 102], <int>[1769, 118], <int>[2041, 105], <int>[2089, 108],
    <int>[2203, 66], <int>[2525, 69],
    <int>[2663, 117], <int>[2879, 57], <int>[3072, 107], <int>[3466, 115],
    <int>[3930, 80], <int>[3963, 90],
    <int>[4050, 110], <int>[4410, 49], <int>[4488, 71], <int>[4617, 109],
    <int>[4666, 75], <int>[4730, 122],
    <int>[4771, 65], <int>[4810, 87], <int>[5027, 112], <int>[5046, 84],
    <int>[5225, 88], <int>[5418, 79],
    <int>[5554, 72], <int>[5726, 100], <int>[5734, 86], <int>[5806, 52],
    <int>[5961, 54], <int>[6185, 106],
    <int>[6216, 78], <int>[6257, 101], <int>[6386, 83], <int>[6601, 81],
    <int>[6612, 121], <int>[6672, 76],
    <int>[6736, 120], <int>[6749, 48], <int>[6939, 111], <int>[6977, 53],
    <int>[6979, 56], <int>[7136, 119],
    <int>[7198, 97], <int>[7262, 82], <int>[7284, 85], <int>[7405, 113],
    <int>[7721, 51], <int>[7723, 116],
    <int>[8119, 103], <int>[8196, 104],
  ];

  static final Map<int, String> _map = <int, String>{
    for (final List<int> p in _pairs) p[0]: String.fromCharCode(p[1]),
  };

  /// 索引 → 字符；命中不到返回空串（含 CTC 的 blank=0）
  static String charOf(int index) {
    if (index <= 0) {
      return '';
    }
    return _map[index] ?? '';
  }

  /// CTC 贪心解码。
  ///
  /// 规则（与 ddddocr 的 `_ctc_decode_indices` 一致）：
  ///   1. 合并连续重复索引（CTC 经典折叠）；
  ///   2. 丢弃 blank（索引 0）。
  ///
  /// **不做易混字符纠正**（1↔l、0↔O）：模型自己的判断比后处理替换更可信，
  /// 擅自替换只会在原本正确时引入错误。
  static String decode(List<int> indices) {
    final StringBuffer out = StringBuffer();
    int prev = -1;
    for (final int idx in indices) {
      if (idx != prev && idx != 0) {
        out.write(charOf(idx));
      }
      prev = idx;
    }
    return out.toString();
  }
}
