/// 轻量 HTML 解析（无 DOM 依赖）
///
/// 从鸿蒙版 `parser/HtmlLite.ets` 移植。
///
/// ===== 为什么不用现成的 HTML 解析库 =====
/// 教务系统返回的是**服务端渲染的表格页面**，结构规整但有几处怪癖
/// （单引号属性、嵌套 table、`<br>` 分隔的多条记录）。第三方解析器当然能用，
/// 但这里需要「按表头文本定位列」「按 `title` 属性取值」这类语义操作，
/// 用正则+扫描反而更直白，也更容易写出针对真实页面的回归测试。
///
/// 保留的关键实现细节：
///   - [HtmlCell.openTag]：周历的日期**只存在于 `title` 属性里**，
///     单元格文本只有 `24`，因此必须能读到开标签属性。
///   - [HtmlLite.scanCells]：单次从左到右扫描，**不能**用
///     「findAll 后按 indexOf 排序」——当两行内容相同时，
///     indexOf 会返回同一位置导致顺序错乱（成绩页 序号=2/学分=2 就是这种情况）。
library;

/// 单元格
class HtmlCell {
  String tag = '';
  String id = '';
  String cls = '';
  int colspan = 1;
  int rowspan = 1;

  /// 开标签原文（含属性），用于读取 `title` 等属性
  String openTag = '';
  String inner = '';
  String text = '';

  /// 读属性值，兼容单/双引号与无引号
  String attr(String name) => HtmlLite.attr(openTag, name);
}

class HtmlRow {
  HtmlRow(this.cells);

  final List<HtmlCell> cells;

  String get text => cells.map((HtmlCell c) => c.text).join(' ').trim();
}

class HtmlTable {
  HtmlTable(this.rows);

  final List<HtmlRow> rows;

  String get text => rows.map((HtmlRow r) => r.text).join('\n');
}

/// 下拉选项
class HtmlOption {
  HtmlOption(this.value, this.label, this.selected);

  final String value;
  final String label;
  final bool selected;
}

class HtmlLite {
  /// 自闭合标签集合
  static const Set<String> _voidTags = <String>{
    'br',
    'img',
    'input',
    'hr',
    'meta',
    'link',
    'base',
    'col',
    'source',
    'area',
  };

  /// 实体解码
  static String decode(String s) {
    if (!s.contains('&')) {
      return s;
    }
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&');
  }

  /// 读标签属性。
  ///
  /// 支持 `name="v"`、`name='v'`、`name=v`。属性名要求前面是空白或标签名，
  /// 避免 `data-id` 被 `id` 命中。
  ///
  /// 正则按属性名缓存：本方法是热路径（每个单元格读 4 个属性，
  /// 培养方案页 918 格 → 3672 次调用），而 `RegExp(...)` 每次构造都要重新编译。
  /// 调用方用到的属性名只有固定的几个（id/class/colspan/rowspan/title），
  /// 缓存命中率接近 100%。用 Map 而不是给每个属性写常量，
  /// 是为了不把这里变成「加个属性就得改两处」的地方。
  static final Map<String, RegExp> _attrRes = <String, RegExp>{};

  static String attr(String tagHtml, String name) {
    if (tagHtml.isEmpty || name.isEmpty) {
      return '';
    }
    RegExp? re = _attrRes[name];
    if (re == null) {
      re = RegExp(
        '(?:^|[\\s"\'])${RegExp.escape(name)}\\s*=\\s*'
        '(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
        caseSensitive: false,
      );
      _attrRes[name] = re;
    }
    final RegExpMatch? m = re.firstMatch(tagHtml);
    if (m == null) {
      return '';
    }
    return m.group(1) ?? m.group(2) ?? m.group(3) ?? '';
  }

  /// ===== 预编译的正则（性能）=====
  ///
  /// 为什么必须提升为静态常量：`toText` 是**每个单元格调一次**的热函数
  /// （培养方案页 918 个单元格），而 Dart 每次 `RegExp(...)` 构造都要重新编译
  /// 正则 —— 内联写在函数体里就是 5 × 918 = 4590 次编译。
  /// 实测把培养方案解析从 26ms 压到 8ms 量级。
  static final RegExp _reComment = RegExp(r'<!--[\s\S]*?-->');
  static final RegExp _reBr = RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false);
  static final RegExp _reBlockClose = RegExp(
    r'</\s*(?:div|p|tr|td|th|li|table|h[1-6]|section)\s*>',
    caseSensitive: false,
  );
  static final RegExp _reAnyTag = RegExp(r'<[^>]*>');
  static final RegExp _reSpaces = RegExp(r'[ \t\u00A0]+');

  /// 把一段 HTML 片段转成纯文本。
  ///
  /// `<br>` 与块级标签闭合都转成换行，便于「一格多行」的语义还原。
  static String toText(String? frag) {
    if (frag == null || frag.isEmpty) {
      return '';
    }
    String s = frag;

    // 去注释（避免注释里的标签干扰）
    s = s.replaceAll(_reComment, '');

    // <br> 系列 → 换行
    s = s.replaceAll(_reBr, '\n');
    // 块级闭合 → 换行
    s = s.replaceAll(_reBlockClose, '\n');
    // 其余标签丢掉
    s = s.replaceAll(_reAnyTag, '');
    s = decode(s);

    final List<String> lines = s
        .split('\n')
        .map((String l) => l.replaceAll(_reSpaces, ' ').trim())
        .where((String l) => l.isNotEmpty)
        .toList();
    return lines.join('\n');
  }

  /// 标签开标签的结束位置（`>` 的下标）
  static int _endOfTag(String html, int start) {
    final int gt = html.indexOf('>', start);
    return gt < 0 ? html.length : gt;
  }

  /// 深度配平地取出某个标签的内容（能处理嵌套同类标签，如嵌套 table）
  ///
  /// [lower] 允许调用方传入已备好的小写副本：本方法内部的 indexOf 需要
  /// 大小写无关，而 `html.toLowerCase()` 是**全量复制**。像
  /// `_findAllRaw(tableHtml, 'tr')` 这样逐个子标签调用时，若每次都自己复制，
  /// 成本就变成「标签数 × 文档长度」—— 实测培养方案页 82 行 × 68KB 要 57ms，
  /// 而这份副本对整个循环来说是同一份，完全没必要重复。
  static String? _extractBalanced(
    String html,
    int tagStart,
    String tagName, {
    String? lower,
  }) {
    final int openEnd = _endOfTag(html, tagStart);
    final String lowerHtml = lower ?? html.toLowerCase();
    final String openToken = '<$tagName';
    final String closeToken = '</$tagName';
    int depth = 0;
    int i = tagStart;
    while (i < html.length) {
      final int nextOpen = lowerHtml.indexOf(openToken, i);
      final int nextClose = lowerHtml.indexOf(closeToken, i);
      if (nextClose < 0) {
        return null;
      }
      if (nextOpen >= 0 && nextOpen < nextClose) {
        // 确认是标签名边界（避免 <table 命中 <tableX）
        final int after = nextOpen + openToken.length;
        final bool boundary = after >= lowerHtml.length ||
            _isNameBoundary(lowerHtml.codeUnitAt(after));
        if (boundary) {
          depth++;
          i = _endOfTag(html, nextOpen) + 1;
          continue;
        }
        i = nextOpen + openToken.length;
        continue;
      }
      depth--;
      if (depth <= 0) {
        return html.substring(openEnd + 1, nextClose);
      }
      i = nextClose + closeToken.length;
    }
    return null;
  }

  static bool _isNameBoundary(int c) {
    // 允许的标签名后续字符之外即为边界
    return !((c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x2D);
  }

  /// 找出所有顶层 `tag` 元素的外层原文
  static List<String> _findAllRaw(String html, String tag) {
    final List<String> out = <String>[];
    final String lower = html.toLowerCase();
    final String openToken = '<$tag';
    int i = 0;
    while (i < html.length) {
      final int at = lower.indexOf(openToken, i);
      if (at < 0) {
        break;
      }
      final int after = at + openToken.length;
      if (after < lower.length && !_isNameBoundary(lower.codeUnitAt(after))) {
        i = after;
        continue;
      }
      if (_voidTags.contains(tag)) {
        final int gt = _endOfTag(html, at);
        out.add(html.substring(at, gt + 1));
        i = gt + 1;
        continue;
      }
      // 把已备好的 lower 传进去：本方法已被调用 N 次（每个 tr 一次），
      // 每次内部再 toLowerCase 一遍全量文本会变成 N×文档长度的复制
      final String? inner = _extractBalanced(html, at, tag, lower: lower);
      if (inner == null) {
        i = after;
        continue;
      }
      final int closeAt = lower.indexOf('</$tag', at);
      final int end = closeAt < 0
          ? html.length
          : _endOfTag(html, closeAt) + 1;
      out.add(html.substring(at, end));
      i = end;
    }
    return out;
  }

  /// 按文档顺序扫描一行内的 td/th。
  ///
  /// 单次从左到右扫描，保证严格顺序（见文件头说明）。
  static List<HtmlCell> scanCells(String rowHtml) {
    final List<HtmlCell> cells = <HtmlCell>[];
    final String lower = rowHtml.toLowerCase();
    final List<int> starts = <int>[];
    int i = 0;
    while (i < rowHtml.length) {
      final int td = lower.indexOf('<td', i);
      final int th = lower.indexOf('<th', i);
      int at = -1;
      if (td >= 0 && th >= 0) {
        at = td < th ? td : th;
      } else if (td >= 0) {
        at = td;
      } else if (th >= 0) {
        at = th;
      }
      if (at < 0) {
        break;
      }
      final int after = at + 3;
      if (after < lower.length && !_isNameBoundary(lower.codeUnitAt(after))) {
        i = after;
        continue;
      }
      starts.add(at);
      i = after;
    }

    for (int k = 0; k < starts.length; k++) {
      final int at = starts[k];
      final int gt = _endOfTag(rowHtml, at);
      final String openTag = gt >= 0 ? rowHtml.substring(at, gt + 1) : rowHtml;
      final HtmlCell cell = HtmlCell();
      cell.openTag = openTag;
      cell.tag = _tagNameAt(rowHtml, at);
      cell.id = attr(openTag, 'id');
      cell.cls = attr(openTag, 'class');
      cell.colspan = int.tryParse(attr(openTag, 'colspan')) ?? 1;
      cell.rowspan = int.tryParse(attr(openTag, 'rowspan')) ?? 1;
      if (cell.colspan < 1) {
        cell.colspan = 1;
      }
      if (cell.rowspan < 1) {
        cell.rowspan = 1;
      }
      // 内容范围：到下一个单元格开始（或本行结束）
      final int nextAt = (k + 1 < starts.length) ? starts[k + 1] : rowHtml.length;
      final int closeIdx = lower.lastIndexOf('</', nextAt);
      final int contentEnd = closeIdx > gt ? closeIdx : nextAt;
      cell.inner = rowHtml.substring(gt + 1, contentEnd);
      cell.text = toText(cell.inner);
      cells.add(cell);
    }
    return cells;
  }

  static String _tagNameAt(String html, int at) {
    int i = at + 1;
    final StringBuffer sb = StringBuffer();
    while (i < html.length) {
      final int c = html.codeUnitAt(i);
      if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) {
        sb.writeCharCode(c);
        i++;
      } else {
        break;
      }
    }
    return sb.toString().toLowerCase();
  }

  /// 解析一张表
  static HtmlTable parseTable(String tableHtml) {
    final List<HtmlRow> rows = <HtmlRow>[];
    for (final String trRaw in _findAllRaw(tableHtml, 'tr')) {
      final List<HtmlCell> cells = scanCells(trRaw);
      if (cells.isNotEmpty) {
        rows.add(HtmlRow(cells));
      }
    }
    return HtmlTable(rows);
  }

  /// 页面上所有表（不含嵌套表内部的重复计数：嵌套表也会各算一张，
  /// 因此调用方通常配合「表头文本」来挑表）
  static List<HtmlTable> parseTables(String html) {
    final List<HtmlTable> out = <HtmlTable>[];
    for (final String raw in _findAllRaw(html, 'table')) {
      out.add(parseTable(raw));
    }
    return out;
  }

  /// 按 id 找表（兼容单引号写法，如 `<TABLE id='mxh'>`）。
  ///
  /// 必须能穿透**嵌套**：培养方案页的课程表 `#mxh` 是嵌在 `#dataList` 内部的，
  /// 而 [_findAllRaw] 只会返回最外层表（内层已被外层吞掉）。
  /// 早期版本因此找不到 `#mxh`，培养方案页会显示成「暂无数据」。
  static HtmlTable? findTableById(String html, String id) {
    // 先按 id 直接定位开标签，再配平取出该表 —— 不受嵌套层级影响。
    final RegExp re = RegExp(
      '<table[^>]*\\sid\\s*=\\s*(?:"$id"|\'$id\'|$id)[^>]*>',
      caseSensitive: false,
    );
    final RegExpMatch? m = re.firstMatch(html);
    if (m == null) {
      return null;
    }
    final int at = m.start;
    final String? inner = _extractBalanced(html, at, 'table');
    if (inner == null) {
      return null;
    }
    // 用「开标签 + 内容」重建，保证属性仍可读
    final int gt = _endOfTag(html, at);
    final String openTag = html.substring(at, gt + 1);
    return parseTable('$openTag$inner</table>');
  }

  /// 按表头关键字找表（在前 3 行里搜），同样会搜到嵌套表
  static HtmlTable? findTableByHeader(String html, String keyword) {
    for (final String raw in _findAllRawDeep(html, 'table')) {
      final HtmlTable t = parseTable(raw);
      final int limit = t.rows.length < 3 ? t.rows.length : 3;
      for (int r = 0; r < limit; r++) {
        if (t.rows[r].text.contains(keyword)) {
          return t;
        }
      }
    }
    return null;
  }

  /// 找出**所有层级**的表（含嵌套），外层在前。
  ///
  /// 单独实现而不是递归 [_findAllRaw]：这里只是把每个 `<table` 开标签
  /// 都当作一个起点各配平一次，实现简单且不会漏掉内层表。
  static List<String> _findAllRawDeep(String html, String tag) {
    final List<String> out = <String>[];
    final String lower = html.toLowerCase();
    final String openToken = '<$tag';
    int i = 0;
    while (i < html.length) {
      final int at = lower.indexOf(openToken, i);
      if (at < 0) {
        break;
      }
      final int after = at + openToken.length;
      if (after < lower.length && !_isNameBoundary(lower.codeUnitAt(after))) {
        i = after;
        continue;
      }
      // 同上：这个循环会对每个 <table> 起点各配平一次，共享同一份 lower
      final String? inner = _extractBalanced(html, at, tag, lower: lower);
      if (inner == null) {
        i = after;
        continue;
      }
      final int gt = _endOfTag(html, at);
      final String openTag = html.substring(at, gt + 1);
      out.add('$openTag$inner</$tag>');
      // 继续往后扫，这样内层表也会各自成为一项
      i = gt + 1;
    }
    return out;
  }

  /// 读下拉选项
  static List<HtmlOption> findSelect(String html, String name) {
    final RegExp re = RegExp(
      '<select[^>]*name\\s*=\\s*(?:"$name"|\'$name\'|$name)[^>]*>([\\s\\S]*?)</select>',
      caseSensitive: false,
    );
    final RegExpMatch? m = re.firstMatch(html);
    if (m == null) {
      return <HtmlOption>[];
    }
    final String body = m.group(1) ?? '';
    final List<HtmlOption> out = <HtmlOption>[];
    for (final RegExpMatch om
        in RegExp(r'<option([^>]*)>([\s\S]*?)</option>', caseSensitive: false)
            .allMatches(body)) {
      final String attrs = om.group(1) ?? '';
      final String label = toText(om.group(2) ?? '');
      final String value = attr('<x $attrs>', 'value');
      final bool selected = attrs.toLowerCase().contains('selected');
      out.add(HtmlOption(value, label, selected));
    }
    return out;
  }

  /// 读隐藏 input 的值
  static String findInputValue(String html, String name) {
    final RegExp re = RegExp(
      '<input[^>]*name\\s*=\\s*(?:"$name"|\'$name\'|$name)[^>]*>',
      caseSensitive: false,
    );
    final RegExpMatch? m = re.firstMatch(html);
    if (m == null) {
      return '';
    }
    return attr(m.group(0) ?? '', 'value');
  }

  /// 是否是登录页。
  ///
  /// 判据必须同时满足「有密码框」和「有验证码/encoded 相关字段」，
  /// 否则会把 `xsMain.jsp` 自带的 `loginForm1` 误判成登录页。
  static bool isLoginPage(String html) {
    if (!RegExp(r'type\s*=\s*["\u0027]password["\u0027]', caseSensitive: false)
        .hasMatch(html)) {
      return false;
    }
    if (html.contains('RANDOMCODE') || html.contains('SafeCodeImg')) {
      return true;
    }
    if (html.contains('name="encoded"') ||
        html.contains("name='encoded'") ||
        html.contains('id="encoded"') ||
        html.contains("id='encoded'")) {
      return true;
    }
    return false;
  }
}
