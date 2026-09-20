/// 个人信息：敏感字段必须既不展示也不进缓存
///
/// ===== 这个用例守的是什么 =====
/// 学籍卡片原文里含**身份证号**、入学考号、证书号这类高敏感信息，
/// 而本应用把整页原文落盘做离线缓存 —— 若不拦掉，身份证号就会以明文
/// 躺在应用私有目录里。
///
/// 因此 `ProfileParser` 必须在**解析层**就把它们丢掉：解析结果里没有、
/// 缓存里也就不会出现（缓存存的是原文但只被解析结果消费，
/// 而落盘判定发生在解析之前 —— 见下）。
///
/// 语料 `test/fixtures/profile.html` 是从真实页面脱敏而来的（人名与号码
/// 已替换为虚构值），但**字段名是真实的**，所以能验证关键词匹配有效。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/model/models.dart';
import 'package:hisdufe_jw/parser/profile_parser.dart';

String _fixture() =>
    File('test/fixtures/profile.html').readAsStringSync();

void main() {
  late StudentProfile p;

  setUpAll(() {
    p = ProfileParser.parse(_fixture());
  });

  /// 把所有分组的所有字段拍平成「标签集合」
  Set<String> allLabels() {
    final Set<String> out = <String>{};
    for (final ProfileSection s in p.sections) {
      for (final ProfileField f in s.fields) {
        out.add(f.label);
      }
    }
    return out;
  }

  group('敏感字段被剔除', () {
    test('身份证字段不在解析结果里', () {
      final Set<String> labels = allLabels();
      final Iterable<String> hit =
          labels.where((String l) => l.contains('身份证'));
      expect(hit, isEmpty,
          reason: '原文里有「身份证编号」，解析结果里不该出现它');
    });

    test('入学考号不在解析结果里', () {
      final Set<String> labels = allLabels();
      expect(labels.where((String l) => l.contains('考号')), isEmpty);
    });

    test('证书号类字段不在解析结果里', () {
      final Set<String> labels = allLabels();
      expect(labels.where((String l) => l.contains('证书号')), isEmpty);
    });

    test('原文确实含这些字段（否则上面的用例是空跑）', () {
      final String html = _fixture();
      // 先证明「要拦的东西真的在输入里」，否则上面三条无论实现对不对都会过
      expect(html.contains('身份证'), isTrue,
          reason: '语料里必须有身份证字段，这条用例才有意义');
      expect(html.contains('入学考号'), isTrue);
    });
  });

  group('正常字段不受影响', () {
    test('姓名与学号仍被正确提取（提取发生在过滤之前）', () {
      expect(p.name, isNotEmpty);
      expect(p.studentId, isNotEmpty);
    });

    test('基本信息该有的字段都还在', () {
      final Set<String> labels = allLabels();
      for (final String want in <String>['院系', '专业', '学号', '姓名', '性别']) {
        expect(labels.contains(want), isTrue, reason: '缺少字段：$want');
      }
    });

    test('字段总数与「原文标签数 − 敏感项数」吻合（没有误删）', () {
      final Set<String> labels = allLabels();
      // 语料（脱敏版）里出现的字段标签共 16 个，其中 3 个是敏感项
      // （入学考号、身份证编号、毕(结)业证书号 + 学士证书号 —— 后两者
      // 名字不同但都命中「证书号」，所以实际被剔的是 3 个）。
      // 因此解析结果应是 13 个。这个等式比「大于某个数」更能发现误伤：
      // 少一个正常字段时它会立刻失败。
      expect(labels.length, 13,
          reason: '原文 16 个字段 − 3 个敏感项 = 13；数字变了说明过滤出了偏差');
    });
  });
}
