/// 课程编辑弹窗（本地增删改）
///
/// 从鸿蒙版 `components/CourseEditor.ets` 移植。
///
/// 交互要点：用一个「课程 chip 行」管理一格里的多门课 ——
/// 点 chip 切换当前编辑的课，`+` 追加，`×` 删除。
/// 这样「一格多课」不需要额外页面就能编辑完。
library;

import 'package:flutter/material.dart';

import '../common/constants.dart';
import '../model/models.dart';
import '../theme/glass_kit.dart';
import 'glass_picker.dart';
import '../theme/theme.dart';

class CourseEditorDialog extends StatefulWidget {
  const CourseEditorDialog({
    required this.row,
    required this.col,
    required this.initial,
    super.key,
  });

  final int row;
  final int col;
  final List<CourseEntry> initial;

  @override
  State<CourseEditorDialog> createState() => _CourseEditorDialogState();
}

class _CourseEditorDialogState extends State<CourseEditorDialog> {
  late List<CourseEntry> _entries;
  int _index = 0;

  /// 校验提示（如「请输入课程名」）。空串表示无提示。
  ///
  /// 用页面内提示而不是 SnackBar：本应用的壳是 `GlassScaffold`
  /// （内部 `CupertinoPageScaffold`），树里**没有 Material 的 Scaffold**，
  /// 而 `ScaffoldMessenger.showSnackBar` 要求有一个已注册的 Scaffold ——
  /// 否则 debug 下抛断言、release 下用户什么也看不到。
  String _hint = '';

  late final TextEditingController _name;
  late final TextEditingController _teacher;
  late final TextEditingController _room;
  late final TextEditingController _campus;

  @override
  void initState() {
    super.initState();
    _entries = widget.initial.isEmpty
        ? <CourseEntry>[_blank()]
        : widget.initial.map((CourseEntry e) => e.clone()).toList();
    _name = TextEditingController(text: _entries[0].courseName);
    _teacher = TextEditingController(text: _entries[0].teacher);
    _room = TextEditingController(text: _entries[0].room);
    _campus = TextEditingController(text: _entries[0].campus);
  }

  @override
  void dispose() {
    _name.dispose();
    _teacher.dispose();
    _room.dispose();
    _campus.dispose();
    super.dispose();
  }

  CourseEntry _blank() => CourseEntry(
    id: 'local-${DateTime.now().microsecondsSinceEpoch}-${DateTime.now().hashCode}',
    courseName: '',
    startWeek: 1,
    endWeek: 18,
    local: true,
  );

  /// 把输入框内容写回当前条目。
  ///
  /// **只在内容真的变了**才打上 `local` 标记并递增 `rev`。
  ///
  /// 为什么必须比较：本方法在「切换 chip / 新增 / 保存」前都会被调用，
  /// 若无条件置 `local = true`，那么「打开编辑弹窗后直接点保存」也会把一门
  /// 服务器课程标成「已修改」—— 界面于是出现一个用户并未做过的改动，
  /// 还多出一个「恢复」入口。这个假阳性会让「已修改」这个提示失去可信度。
  void _flush() {
    final CourseEntry e = _entries[_index];
    final String name = _name.text.trim();
    final String teacher = _teacher.text.trim();
    final String room = _room.text.trim();
    final String campus = _campus.text.trim();
    final bool changed = e.courseName != name ||
        e.teacher != teacher ||
        e.room != room ||
        e.campus != campus;
    if (!changed) {
      return;
    }
    e.courseName = name;
    e.teacher = teacher;
    e.room = room;
    e.campus = campus;
    e.local = true;
    e.rev = e.rev + 1;
  }

  void _switchTo(int i) {
    _flush();
    setState(() {
      _index = i;
      _fillFormFrom(i);
    });
  }

  void _add() {
    _flush();
    setState(() {
      _entries.add(_blank());
      _index = _entries.length - 1;
      // 新条目是空白的，_fillFormFrom 会把四个输入框一并清空
      _fillFormFrom(_index);
    });
  }

  /// 删掉第 [i] 门课。
  ///
  /// 每个 chip 上的 × 各自对应一门课（见 _entryChip），因此这里收 index ——
  /// 早先版本删的是「当前选中」那一门，与用户点的那个 × 未必是同一门。
  void _deleteAt(int i) {
    if (i < 0 || i >= _entries.length) {
      return;
    }
    // 先把表单内容写回**将要被删的那一项之前**的状态：
    // 若正在编辑的就是被删的这项，它的输入内容没有意义；
    // 若是别的项，则要保证它的编辑不丢（_switchTo 之后会重新灌入）。
    if (i != _index) {
      _flush();
    }

    if (_entries.length <= 1) {
      // 删到最后一门时留一条空草稿，保证表单仍可用
      setState(() {
        _entries = <CourseEntry>[_blank()];
        _index = 0;
        _fillFormFrom(0);
      });
      return;
    }

    setState(() {
      _entries.removeAt(i);
      // 删的是当前项或更靠前的项时，选中项要跟着前移，否则会指到别的课上
      if (_index >= i && _index > 0) {
        _index = _index - 1;
      }
      if (_index >= _entries.length) {
        _index = _entries.length - 1;
      }
      _fillFormFrom(_index);
    });
  }

  /// 把第 [i] 项的字段灌进输入框
  void _fillFormFrom(int i) {
    final CourseEntry e = _entries[i];
    _name.text = e.courseName;
    _teacher.text = e.teacher;
    _room.text = e.room;
    _campus.text = e.campus;
  }

  /// 保存前的校验：把「填了东西但没填课名」挡下来。
  ///
  /// 返回出错提示（null 表示可以保存）。
  ///
  /// ===== 为什么不能按「课名为空就当作删除」处理 =====
  /// 早先的逻辑是「名字为空 = 这门课不要了」，于是清空课名再保存会**静默**
  /// 删掉这门课 —— 用户以为只是改了点别的，结果整门课消失了（真机反馈）。
  /// 现在删除有明确的入口（每个 chip 内右缘的 ×），所以：
  ///   - 课名为空、但教师/教室/校区有内容 → 提示补课名，**阻止保存**
  ///     （说明用户是在填这门课，只是漏了最重要的那栏）；
  ///   - **四个字段全空** → 视为「没填的草稿」，保存时丢弃，不打扰用户。
  ///     这是唯一仍会被静默丢弃的情形，且此时用户确实把内容清光了；
  ///     若只是想删掉这门课，用 chip 上的 × 语义更明确。
  String? _validate() {
    for (int i = 0; i < _entries.length; i++) {
      final CourseEntry e = _entries[i];
      final bool hasOther = e.teacher.isNotEmpty ||
          e.room.isNotEmpty ||
          e.campus.isNotEmpty;
      if (e.courseName.isEmpty && hasOther) {
        return _entries.length > 1 ? '请输入课程名（第 ${i + 1} 门）' : '请输入课程名';
      }
    }
    return null;
  }

  void _save() {
    // 先把当前表单写回条目，校验才看得到用户在输入框里的最新内容
    _flush();
    final String? problem = _validate();
    if (problem != null) {
      setState(() => _hint = problem);
      return;
    }
    // 完全空白的条目直接丢弃（用户开了草稿又没用它）。
    // 注意这里**不再**把「有名字的」之外的都当删除 —— 删除走 × 按钮。
    final List<CourseEntry> kept = _entries
        .where((CourseEntry e) => e.courseName.isNotEmpty)
        .toList();
    if (kept.isEmpty && widget.initial.isEmpty) {
      // 新增场景下一个字都没填：视同取消，不产生任何改动
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, kept);
  }

  @override
  Widget build(BuildContext context) {
    final String weekday = kWeekdayLabels[widget.col];
    final String section = kSections[widget.row].label;
    // 弹窗是**真正浮在内容之上**的面板：玻璃在这里才有东西可折射
    // （顶栏/底栏那种「占位式」布局背后没有内容，玻璃会显得很平）。
    //
    // 用 Dialog + 玻璃面板，而**不是**「AlertDialog 外面套玻璃」：
    // AlertDialog 自身铺满整个路由区域（靠 insetPadding 居中面板），
    // 套在外面会让玻璃盖住整屏而不是只包住面板。
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: GlassKit.surface(
          context,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 内容可滚动：小屏 + 键盘弹出时表单会放不下
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.initial.isEmpty ? '添加课程' : '编辑课程',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '$weekday · $section',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textTertiary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          // 课程 chip 行（常显，便于看出这一格有几门课）。
                          // 用自绘药丸玻璃而不是 InputChip：Material 的 chip
                          // 自带灰色填充，浮在玻璃弹窗上像贴纸。
                          //
                          // ===== 删除入口（交互改过两次，这里记下结论）=====
                          // 最初是「长按 chip 删除」—— 没有任何视觉提示，
                          // 用户根本不知道能删（真机反馈「无法删除已有课程」）。
                          // 之后试过「行尾一个 ×」，但那样得先点中 chip 再点 ×，
                          // 多一步，也容易删错。
                          //
                          // 现在：**每个 chip 内部右缘各有一个 ×**（见 _entryChip），
                          // 点哪个 × 就删哪门课，不必先选中；× 常态显示、不随选中态变化。
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: <Widget>[
                              for (int i = 0; i < _entries.length; i++)
                                _entryChip(i),
                              _addChip(),
                            ],
                          ),
                          const SizedBox(height: 14),
                          // 课名一改就把提示撤掉，避免它挂在那里显得没反应
                          _field(_name, '课程名称', '如 数据结构',
                              onChanged: (_) {
                            if (_hint.isNotEmpty) {
                              setState(() => _hint = '');
                            }
                          }),
                          const SizedBox(height: 10),
                          _field(_teacher, '教师', '如 张老师'),
                          const SizedBox(height: 10),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: _field(_room, '教室', '如 9-316'),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _field(_campus, '校区', '章丘'),
                              ),
                            ],
                          ),
                          if (_hint.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: context.dangerColor
                                    .withValues(alpha: 0.12),
                                borderRadius:
                                    BorderRadius.circular(Gaps.radiusSm),
                              ),
                              child: Text(_hint,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: context.dangerColor)),
                            ),
                          ],
                          const SizedBox(height: 14),
                          _weekRow(),
                          const SizedBox(height: 10),
                          _parityRow(),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // 操作行固定在底部（不随内容滚动），保证「保存」始终可见
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    // 药丸玻璃按钮：与表单里的输入框、分段控件同一套语言。
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: GlassKit.fieldBackdrop(
                        context,
                        child: Container(
                          height: 42,
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          alignment: Alignment.center,
                          child: Text('取消',
                              style: TextStyle(
                                  fontSize: 14, color: context.textPrimary)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: _save,
                      child: Container(
                        height: 42,
                        padding: const EdgeInsets.symmetric(horizontal: 26),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('保存',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onPrimary,
                            )),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 起止周：两个玻璃滚轮选择器（与其他下拉统一）。
  ///
  /// 自动纠正仍然保留：起始周不能大于结束周，反之亦然 ——
  /// 这是数据约束，不该交给用户自己保证。
  Widget _weekRow() {
    final CourseEntry e = _entries[_index];
    return Row(
      children: <Widget>[
        Expanded(
          child: _pickerField(
            label: '起始周',
            value: '第 ${e.startWeek} 周',
            onTap: () async {
              final int? v = await showGlassPicker<int>(
                context,
                title: '选择起始周',
                current: e.startWeek,
                options: _weekOptions(),
              );
              if (v == null || !mounted) {
                return;
              }
              setState(() {
                e.startWeek = v;
                if (e.endWeek < e.startWeek) {
                  e.endWeek = e.startWeek;
                }
              });
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _pickerField(
            label: '结束周',
            value: '第 ${e.endWeek} 周',
            onTap: () async {
              final int? v = await showGlassPicker<int>(
                context,
                title: '选择结束周',
                current: e.endWeek,
                options: _weekOptions(),
              );
              if (v == null || !mounted) {
                return;
              }
              setState(() {
                e.endWeek = v;
                if (e.endWeek < e.startWeek) {
                  e.startWeek = e.endWeek;
                }
              });
            },
          ),
        ),
      ],
    );
  }

  /// 一个输入框：标签 + 玻璃底衬 + 高对比输入区。
  ///
  /// 为什么要专门包一层：
  ///   1. **与玻璃背板协调**：裸 TextField 的纯灰底浮在玻璃弹窗上很突兀，
  ///      换成 [GlassKit.fieldBackdrop]（带模糊的浅色玻璃）后层次才连得上；
  ///   2. **可读性**：原来用 `floatingLabelBehavior: never`，
  ///      标签根本不显示、只剩 placeholder；而且文字压在花哨的玻璃上偏灰。
  ///      这里把标签做成**常显的小标题**，输入文字用主色（高对比），
  ///      placeholder 才用弱色。
  Widget _field(
    TextEditingController c,
    String label,
    String hint, {
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label(label),
        const SizedBox(height: 4),
        GlassKit.fieldBackdrop(
          context,
          child: TextField(
            controller: c,
            style: TextStyle(
              fontSize: 15,
              // 输入内容是主体信息，用主色保证在玻璃上依然清晰
              color: context.textPrimary,
            ),
            cursorColor: context.brandColor,
            decoration: InputDecoration(
              isDense: true,
              // ===== 必须显式关掉填充（否则药丸被方角盖住）=====
              // 全局主题设了 `filled: true`，而这里把 border 置成 none ——
              // `InputBorder.none` 会让填充画成**方角矩形**，
              // 正好盖在外层 GlassKit.fieldBackdrop 的药丸上，
              // 于是用户看到的是方形输入框（真机截图确认）。
              // 外层已经有药丸底衬，这里不该再画一层。
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              hintText: hint,
              // placeholder 用 textSecondary 而不是 textTertiary：
              // 后者在浅色玻璃上对比度太低（用户反馈「课程名称/教师这些
              // 提示文字看不清」）。placeholder 是**引导输入**的信息，
              // 属于要读的内容，不该按「最弱的灰」处理。
              hintStyle: TextStyle(
                fontSize: 14,
                color: context.textSecondary.withValues(alpha: 0.75),
              ),
            ),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  /// 表单里统一的小标题。
  ///
  /// 用 textPrimary 而不是 Secondary：它是字段的**名字**，
  /// 与框内的提示文字属于同一层次的可读信息；
  /// 压在花哨玻璃上时，Secondary 的灰会糊进背景里。
  Widget _label(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.textPrimary,
        ),
      );

  List<GlassOption<int>> _weekOptions() => <GlassOption<int>>[
        for (int w = 1; w <= kMaxWeeks; w++) GlassOption<int>(w, '第 $w 周'),
      ];

  /// 统一的「点开滚轮」字段外观：与输入框同款（玻璃底衬 + 药丸圆角），
  /// 这样同一张表单里输入框与选择器看起来是一套东西。
  Widget _pickerField({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label,
              style: TextStyle(fontSize: 11, color: context.textSecondary)),
          const SizedBox(height: 4),
          GlassKit.fieldBackdrop(
            context,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.centerLeft,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14, color: context.textPrimary)),
                  ),
                  Icon(Icons.unfold_more,
                      size: 16, color: context.textSecondary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _parityRow() {
    final CourseEntry e = _entries[_index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _label('单双周'),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            for (int v = 0; v < 3; v++) ...<Widget>[
              if (v > 0) const SizedBox(width: 6),
              Expanded(child: _parityChip(_parityNames[v], v, e)),
            ],
          ],
        ),
      ],
    );
  }

  static const List<String> _parityNames = <String>['每周', '单周', '双周'];

  /// 一个药丸玻璃分段按钮。
  ///
  /// 选中态用实心品牌色（见 GlassKit.pill 的说明）：既要一眼看出选中，
  /// 也避免「玻璃套玻璃」——玻璃弹窗里再叠折射玻璃会产生双重折射。
  Widget _parityChip(String label, int value, CourseEntry e) {
    final bool on = e.parity == value;
    return GestureDetector(
      onTap: () => setState(() => e.parity = value),
      child: GlassKit.pill(
        context,
        selected: on,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              // 选中是实心品牌底 → 用 onPrimary 保证对比；
              // 未选中是浅玻璃 → 用主文字色
              color: on
                  ? Theme.of(context).colorScheme.onPrimary
                  : context.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  /// 课程条目 chip（药丸玻璃）：选中态实心，未选中玻璃。
  Widget _entryChip(int i) {
    final bool on = i == _index;
    final String text = _entries[i].courseName.isEmpty
        ? '课程${i + 1}'
        : _entries[i].courseName;
    final Color fg =
        on ? Theme.of(context).colorScheme.onPrimary : context.textPrimary;
    // × 的颜色：淡灰，且**在两种底色上都要读得出**。
    //   选中（蓝底）→ 白 + 透明即淡灰，压在蓝上层次正好；
    //   未选中（浅底）→ 用次级文字色。
    // 不用更浅的 tertiary：那个在浅底上几乎看不见，
    // 而它是常态控件，必须一眼看得到。
    final Color closeFg = on
        ? Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.72)
        : context.textSecondary;

    return GestureDetector(
      onTap: () => _switchTo(i),
      child: GlassKit.pill(
        context,
        selected: on,
        child: Container(
          height: 36,
          // 左内边距 14 保证名字不贴边；右侧只留 8 + 图标自身宽度，
          // 让 × 贴近框内右缘（用户要求）。
          padding: const EdgeInsets.only(left: 14, right: 8),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  color: fg,
                ),
              ),
              const SizedBox(width: 6),
              // ===== ×：**每个 chip 都有、常态显示、不受选中影响** =====
              //
              // 它是「删掉这一门」的入口，挂在各自 chip 的右缘 ——
              // 点哪个 × 就删哪门课，不需要先选中再删。
              // 只给选中项画的话，用户得先猜「怎么删另一门」；
              // 常态显示才是可发现、可预期的做法。
              GestureDetector(
                // 必须吃掉这次点击：它嵌在外层 GestureDetector 里，
                // 不拦的话会冒泡成「切换到这门课」，× 等于白点。
                onTap: () => _deleteAt(i),
                behavior: HitTestBehavior.opaque,
                child: Icon(Icons.close, size: 14, color: closeFg),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「+」新增课程：玻璃药丸（不选中，因此始终是玻璃）
  Widget _addChip() {
    return GestureDetector(
      onTap: _add,
      child: GlassKit.fieldBackdrop(
        context,
        child: Container(
          height: 36,
          width: 52,
          alignment: Alignment.center,
          child: Icon(Icons.add, size: 18, color: context.brandColor),
        ),
      ),
    );
  }
}
