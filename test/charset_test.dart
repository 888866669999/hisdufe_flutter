import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/model/captcha_charset.dart';

void main() {
  test('字符表与所用模型（common_old / CHARSET_OLD）配套', () {
    // 这组索引是**真机跑模型时打印出来的原始 argmax 结果**
    // （语料 4r36，日志见 docs/技术笔记.md）。用它们做断言，等价于锁住
    // 「模型输出 → 字符」这条链路，而不只是抽查几个数字。
    //
    // 为什么必须这样测：CHARSET_OLD 与 CHARSET_BETA 都是 8210 类、
    // 输出形状一致，**配错表不会报任何错**，只会让识别率变 0。
    // 只有用真实模型输出做断言，才能挡住这种回归。
    final List<int> deviceIndices = <int>[5806, 806, 7721, 5961];
    expect(CaptchaCharset.decode(deviceIndices), '4r36',
        reason: '真机对语料 4r36 的原始索引必须解出 4r36');

    // 逐项核对若干索引（含大小写与数字）
    expect(CaptchaCharset.charOf(5806), '4');
    expect(CaptchaCharset.charOf(806), 'r');
    expect(CaptchaCharset.charOf(7721), '3');
    expect(CaptchaCharset.charOf(5961), '6');
    expect(CaptchaCharset.charOf(4730), 'z');
    expect(CaptchaCharset.charOf(4410), '1');
    expect(CaptchaCharset.charOf(8196), 'h');
    expect(CaptchaCharset.charOf(4771), 'A');
  });

  test('blank(0) 与未知索引返回空', () {
    expect(CaptchaCharset.charOf(0), '');
    expect(CaptchaCharset.charOf(-1), '');
    expect(CaptchaCharset.charOf(999999), '');
  });

  test('CTC 折叠连续重复并丢 blank', () {
    // 5806='4'，5961='6'，0=blank
    // 4 4 4(重复) | blank | 6 6(重复) | 4  =>  "464"
    final indices = <int>[5806, 5806, 5806, 0, 5961, 5961, 5806];
    expect(CaptchaCharset.decode(indices), '464');
  });

  test('不在表内的索引（汉字）被丢弃，不产生噪声字符', () {
    // 4725 在 CHARSET_OLD 里是汉字「艨」，不在 62 项字母数字表内。
    // 必须静默丢弃，而不是塞一个奇怪字符进去打乱验证码长度。
    expect(CaptchaCharset.charOf(4725), '');
    expect(CaptchaCharset.decode(<int>[4725, 5806, 4725]), '4');
  });

  test('同一字符被 blank 隔开时不折叠（CTC 的经典语义）', () {
    // 4 | blank | 4  =>  "44"，而不是 "4"
    expect(CaptchaCharset.decode(<int>[5806, 0, 5806]), '44');
  });

  test('全 blank 解码为空', () {
    expect(CaptchaCharset.decode(<int>[0, 0, 0]), '');
  });

  test('字符表共 62 项（26 大写 + 26 小写 + 10 数字）', () {
    final set = <String>{};
    for (int i = 0; i < CaptchaCharset.classCount; i++) {
      final c = CaptchaCharset.charOf(i);
      if (c.isNotEmpty) set.add(c);
    }
    expect(set.length, 62);
    // 大小写都要有（验证码区分大小写）
    expect(set.contains('A'), isTrue);
    expect(set.contains('a'), isTrue);
  });
}
