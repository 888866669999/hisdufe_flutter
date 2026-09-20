/// 个人信息解析（`#xjkpTable` 学籍卡片）
///
/// 从鸿蒙版 `parser/ProfileParser.ets` 移植。
///
/// ===== 页面形态很乱，这是移植时最容易出错的一处 =====
/// 同一个表里混了三种行：
///   1. 单元格内含 `标签：值`（一个单元格可能塞多组）；
///   2. 相邻单元格成对（左标签、右值）；
///   3. **子表的节标题行**（如「学习简历」）—— 它下面那一行是子表的列名，
///      如果不跳过，就会产出 `起止年月=学校或工作单位` 这种**假字段**。
///
/// 因此 [_isSectionTitleRow] 的判据要精确：单个非空单元格、
/// 3–16 个字、不含数字与冒号。早期判据过宽，把真实字段也一并丢掉了
/// （字段数从 24 掉到 15，肉眼很难发现）。
library;

import '../model/models.dart';
import 'html_lite.dart';

class ProfileParser {
  /// 基本信息字段（按此决定展示顺序；未列出的归入「其他信息」）
  static const List<String> _basicKeys = <String>[
    '院系',
    '专业',
    '学制',
    '班级',
    '学号',
    '姓名',
    '性别',
    '姓名拼音',
    '出生日期',
    '民族',
    '政治面貌',
    '学习层次',
    '学习形式',
    '外语种类',
    '籍贯',
    '婚否',
  ];

  /// **不展示、也不缓存**的字段。
  ///
  /// ===== 为什么要有这个名单 =====
  /// 学籍卡片原文里含**身份证号**、入学考号、证书号这类高敏感信息，
  /// 而本应用把「整页原文」落盘做离线缓存 —— 若不拦掉，
  /// 身份证号就会以明文躺在应用私有目录里（虽然沙箱隔离，但没有必要承担
  /// 这个风险：这些字段与本应用的任何功能都无关）。
  ///
  /// 拦在**解析层**而不是界面层，是为了让缓存也拿不到它们：
  /// 缓存存的是原文、展示的是解析结果，只有在这里丢掉才两边都干净。
  ///
  /// 用关键词匹配而不是精确标签名：服务端这类字段的措辞不统一
  /// （实测见过「身份证编号」，别处可能叫「身份证号」「证件号码」）。
  static const List<String> _sensitiveKeywords = <String>[
    '身份证',
    '证件号',
    '入学考号',
    '证书号',
    '考生号',
    '银行卡',
  ];

  /// 该字段是否属于敏感信息（命中任一关键词）
  static bool _isSensitive(String label) {
    for (final String k in _sensitiveKeywords) {
      if (label.contains(k)) {
        return true;
      }
    }
    return false;
  }

  static StudentProfile parse(String html) {
    final StudentProfile p = StudentProfile();
    final HtmlTable? table = HtmlLite.findTableById(html, 'xjkpTable');
    if (table == null) {
      return p;
    }

    final List<ProfileField> raw = <ProfileField>[];
    bool afterSectionTitle = false;

    for (final HtmlRow row in table.rows) {
      final List<HtmlCell> cells = row.cells;

      if (_isSectionTitleRow(cells)) {
        afterSectionTitle = true;
        continue;
      }
      // 节标题后的那一行：只有**确实是子表列名**时才跳过。
      //
      // 这里必须再加一层判断，否则会误伤真实数据行 ——
      // 实测「学籍卡片」标题（写成 `学 籍 卡 片`）后面紧跟的就是
      // 院系/专业/学制/班级/学号 那一行，早期实现把它当列名整行丢掉，
      // 结果学号、姓名拼音等字段全部消失，而界面上看不出任何异常。
      //
      // 区分依据：列名行不含冒号（`起止年月 / 学 校 或 工 作 单 位 / 职务`），
      // 真实数据行含冒号（`院系：示例学院`）。
      if (afterSectionTitle) {
        afterSectionTitle = false;
        if (!_hasColonCell(cells)) {
          continue;
        }
      }

      // 形态一：`标签：值`（一个单元格可能多组）
      for (final HtmlCell c in cells) {
        final String text = c.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isEmpty || !text.contains('：')) {
          continue;
        }
        _pullColonPairs(text, raw);
      }

      // 形态二：相邻成对
      _pullAdjacentPairs(cells, raw);
    }

    // 去重（保序）
    final List<ProfileField> dedup = <ProfileField>[];
    for (final ProfileField f in raw) {
      if (f.label.isEmpty || f.value.isEmpty) {
        continue;
      }
      if (dedup.any((ProfileField x) => x.label == f.label)) {
        continue;
      }
      dedup.add(f);
    }

    // 抽姓名/学号
    for (final ProfileField f in dedup) {
      if (f.label == '姓名' && p.name.isEmpty) {
        p.name = f.value;
      }
      if (f.label == '学号' && p.studentId.isEmpty) {
        p.studentId = f.value;
      }
    }

    // 分组：基本信息 + 其他信息。
    // 敏感字段在这里被丢弃（见 _sensitiveKeywords 的说明）——
    // 位置刻意放在「提取姓名/学号之后、分组之前」：
    // 万一将来把类别名加进黑名单，也不会影响姓名学号的提取。
    final List<ProfileField> basic = <ProfileField>[];
    final List<ProfileField> others = <ProfileField>[];
    for (final ProfileField f in dedup) {
      if (_isSensitive(f.label)) {
        continue;
      }
      if (_basicKeys.contains(f.label)) {
        basic.add(f);
      } else {
        others.add(f);
      }
    }
    basic.sort((ProfileField a, ProfileField b) =>
        _basicKeys.indexOf(a.label).compareTo(_basicKeys.indexOf(b.label)));

    if (basic.isNotEmpty) {
      p.sections.add(ProfileSection('基本信息', basic));
    }
    if (others.isNotEmpty) {
      p.sections.add(ProfileSection('其他信息', others));
    }
    return p;
  }

  /// 该行是否含「标签：值」形态的单元格
  static bool _hasColonCell(List<HtmlCell> cells) {
    for (final HtmlCell c in cells) {
      if (c.text.contains('：')) {
        return true;
      }
    }
    return false;
  }

  /// 是否是「子表节标题」行。
  ///
  /// 判据：单个非空单元格、3–16 字（**忽略字间空格**）、不含数字与冒号。
  /// 真实页面把标题写成 `学 籍 卡 片`（字间带空格），因此必须先去掉空白再判长度，
  /// 否则长度会虚高。
  static bool _isSectionTitleRow(List<HtmlCell> cells) {
    final List<String> nonEmpty = cells
        .map((HtmlCell c) => c.text.trim())
        .where((String t) => t.isNotEmpty)
        .toList();
    if (nonEmpty.length != 1) {
      return false;
    }
    final String t = nonEmpty.first.replaceAll(RegExp(r'\s+'), '');
    if (t.length < 3 || t.length > 16) {
      return false;
    }
    if (RegExp(r'\d').hasMatch(t) || t.contains('：')) {
      return false;
    }
    return true;
  }

  /// 单元格内 `标签：值 标签：值`
  static void _pullColonPairs(String text, List<ProfileField> out) {
    // 先按冒号切出「值」，再判断值里是否混入了下一个标签
    final List<String> segs = text.split('：');
    for (int i = 0; i < segs.length - 1; i++) {
      final String label = _lastLabel(segs[i]);
      String value = segs[i + 1];
      if (i + 1 < segs.length - 1) {
        // 值的尾部可能粘着下一个标签（如 `A 专业`）
        final RegExpMatch? m =
            RegExp(r'^(.+?)\s+([\u4e00-\u9fa5A-Za-z]{2,10})$').firstMatch(value);
        if (m != null) {
          value = m.group(1)!;
        }
      }
      final String v = value.trim();
      if (label.isNotEmpty && v.isNotEmpty) {
        out.add(ProfileField(label, v));
      }
    }
  }

  /// 取 `A：` 里的 A：按空白切分取最后一段，并限制长度
  static String _lastLabel(String seg) {
    final String t = seg.trim();
    if (t.isEmpty) {
      return '';
    }
    // 不能按冒号再切（调用方已切过），按空白取最后一段
    final List<String> parts = t.split(RegExp(r'\s+'));
    String last = parts.last.trim();
    if (last.length > 12) {
      return '';
    }
    // 含括号的标签要保留（如「毕(结)业证书号」），因此只做长度与空白校验
    if (last.isEmpty) {
      return '';
    }
    return last;
  }

  /// 相邻单元格成对
  static void _pullAdjacentPairs(List<HtmlCell> cells, List<ProfileField> out) {
    for (int i = 0; i + 1 < cells.length; i += 2) {
      final String label = cells[i].text.trim();
      final String value = cells[i + 1].text.trim();
      if (label.isEmpty || value.isEmpty) {
        continue;
      }
      if (label.length > 12 || label.contains('：')) {
        continue;
      }
      if (RegExp(r'^\d+$').hasMatch(label)) {
        continue;
      }
      out.add(ProfileField(label, value));
    }
  }
}
