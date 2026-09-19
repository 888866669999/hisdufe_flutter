/// 课表页
///
/// 从鸿蒙版 `pages/SchedulePage.ets` 移植。
///
/// ===== 加载策略（关键，别改）=====
/// 课表**优先读本地缓存**，网络只是兜底：
///   1. 用「当前账号 + 上次学期」找缓存；
///   2. 账号未知时，若缓存里只有一个账号就用它（多账号时不猜）；
///   3. 学期未知时用缓存里的第一个学期；
///   4. 都没有才请求网络。
/// 这样即使用户离线、或会话已失效，也一定能看到课表 ——
/// 这也是「只看课表不打扰」的前提。
///
/// ===== 本地编辑 ====
/// 用户可点任意格子增删改课程（一格多课时用 chip 切换，每个 chip
/// 右侧的 × 直接删掉那一门）。改动立即落盘（按账号 + 学期分片），
/// 同时刷新桌面卡片快照、并重排上课提醒。
///
/// ===== 怎么判断「课表被改过」=====
/// 走 `Timetable.hasLocalEdits()`：既看条目的 `local` 标记（新增/修改），
/// 也对比 `serverIds` 基线（删除）。只看 `local` 是不够的 ——
/// 删除会把标记连同条目一起去掉，于是删完反倒显示「未修改」，
/// 用户既看不到「已修改」入口、也没法恢复。
library;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../common/constants.dart';
import '../common/week_calc.dart';
import '../data/app_state.dart';
import '../data/re_auth_service.dart';
import '../data/card_snapshot_store.dart';
import '../data/pref_store.dart';
import '../data/reminder_service.dart';
import '../data/section_time_store.dart';
import '../data/timetable_store.dart';
import '../data/week_service.dart';
import '../model/card_layout.dart';
import '../model/models.dart';
import '../parser/timetable_parser.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import 'top_bar_slot.dart';
import '../widgets/calendar_sheet.dart';
import '../widgets/glass_picker.dart';
import '../widgets/glass_picker_field.dart';
import '../widgets/course_editor.dart';
import '../widgets/state_views.dart';

class SchedulePage extends StatefulWidget {
  const SchedulePage({this.onOpenClassroom, super.key});

  /// 打开空教室查询页。由外壳传入（页面自己不知道导航结构）。
  ///
  /// 入口放在顶栏右上角（原设置按钮的位置）：看课表时最常接着要问的就是
  /// 「这节哪儿有空教室」，放在同一行最省一次跳转。
  final VoidCallback? onOpenClassroom;

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  final AppState _app = AppState.instance;

  bool _loading = true;
  String _error = '';
  String _week = '';
  Timetable? _tt;
  /// 课表是否来自本地缓存。
  ///
  /// **仅用于日志与内部判断，不显示给用户** —— 数据来源是内部策略，
  /// 写进界面属于实现细节泄漏（见 _footer 的说明）。
  // ignore: unused_field
  bool _fromCache = false;

  /// 表头固定高度。
  ///
  /// 为什么不参与「5 行等分」：表头内容（星期 + 日期）高度是已知常量，
  /// 固定它能让下面 5 行的等分计算有确定的分母。否则表头也跟着缩放，
  /// 行高会随字体度量漂移，一屏是否装得下就变得不可预测。
  static const double _kHeaderH = 44;

  /// 今天那一列的深色药丸底色。取近黑而非纯黑：
  /// 纯黑在浅色渐变上过于突兀。
  static const Color _kTodayPill = Color(0xFF33353A);

  @override
  void initState() {
    super.initState();
    // 默认**自动跟随本周**：只有用户显式选过周次/全部时才用保存值。
    // 早先直接沿用上次选择，导致「一直停在几周前看的那一周」。
    _week = PrefStore.loadLastWeek();
    if (_week.isEmpty) {
      _week = kWeekAuto;
    }
    _load();
  }

  @override
  void dispose() {
    // 离开课表页时要摘掉顶栏控件，否则顶栏还挂着「周次/学期/校历」，
    // 点进去却发现点在别的页面上。
    TopBarSlot.clear();
    super.dispose();
  }

  Future<void> _load({bool interactive = false}) async {
    // 用户点导航进来的首次加载同样算「主动操作」：
    // 否则会话失效时只会给一句内联提示，逼迫用户再点一次「重试」。
    // 标记是一次性的（取走即清零），冷启动不受影响。
    interactive = interactive || ReAuthService.consumeUserIntent();
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await SectionTimeStore.load();
      final String account = await _app.resolveAccount();

      // 1) 先按「账号 + 学期」找缓存
      String semester = _tt?.semester ?? PrefStore.loadLastSemester();
      if (account.isNotEmpty && semester.isNotEmpty) {
        final Timetable? cached = await TimetableStore.load(account, semester);
        if (cached != null) {
          await _apply(cached, true);
          return;
        }
      }

      // 2) 账号未知：缓存里只有一个账号时用它
      if (account.isEmpty && semester.isNotEmpty) {
        final String found = await TimetableStore.findAccountForSemester(semester);
        if (found.isNotEmpty) {
          final Timetable? cached = await TimetableStore.load(found, semester);
          if (cached != null) {
            await _apply(cached, true);
            return;
          }
        }
      }

      // 3) 学期未知：用缓存里的第一个
      if (account.isNotEmpty && semester.isEmpty) {
        final List<String> sems = await TimetableStore.cachedSemesters();
        if (sems.isNotEmpty) {
          final Timetable? cached = await TimetableStore.load(account, sems.first);
          if (cached != null) {
            await _apply(cached, true);
            return;
          }
        }
      }

      // 4) 兜底：请求网络
      await _fetchFromNetwork(semester);
    } catch (e) {
      if (!mounted) {
        return;
      }
      // 会话失效：先静默续期，成功就重跑一次，用户看不到任何提示。
      // interactive 决定续期失败时的表现：首次自动加载只给内联提示（不弹窗），
      // 用户主动刷新/切学期才允许弹重新验证。
      final bool renewed = await ReAuthService.handlePageError(e, (String msg) {
        setState(() {
          _loading = false;
          _error = msg;
        });
      }, interactive: interactive);
      if (renewed && mounted) {
        await _load();
      }
    }
  }

  Future<void> _fetchFromNetwork(String semester) async {
    final TimetableParseResult res =
        await _app.api.getTimetable(semester, '');
    final Timetable tt = res.timetable;
    if (_app.currentWeek > 0 && tt.week.isEmpty) {
      tt.week = _app.currentWeek.toString();
    }
    await _apply(tt, false);
    // 网络取回后落盘，下次即可离线看
    final String acct = await _app.resolveAccount();
    if (tt.semester.isNotEmpty && acct.isNotEmpty) {
      await TimetableStore.save(acct, tt.semester, tt);
    }
  }

  Future<void> _apply(Timetable tt, bool fromCache) async {
    // 新鲜拉取的课表要记下「服务器给了哪些课」作为基线，用于检测删除。
    //
    // 只在**非缓存**路径记：缓存里存的可能是用户改过的版本，
    // 拿它当基线等于把之前的改动当成「服务器原本就长这样」，
    // 删除就检测不出来了（见 Timetable.serverIds 的说明）。
    if (!fromCache) {
      tt.captureServerBaseline();
    }
    _app.timetable = tt;
    if (tt.semester.isNotEmpty) {
      await PrefStore.saveLastSemester(tt.semester);
    }
    // 顺便刷新桌面卡片（桌面卡片读的是快照）
    await CardSnapshotStore.refresh(tt, _app.semesterStart);
    if (!mounted) {
      return;
    }
    setState(() {
      _tt = tt;
      _fromCache = fromCache;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    final Timetable? tt = _tt;
    if (tt == null) {
      return;
    }
    tt.pruneEmptyCells();
    tt.edited = tt.hasLocalEdits();
    final String account = await _app.resolveAccount();
    final bool ok = await TimetableStore.save(account, tt.semester, tt);
    if (!mounted) {
      return;
    }
    // 保存失败时走页面内的 _error 提示位，**不用 SnackBar**：
    // 本应用的壳是 GlassScaffold（内部 CupertinoPageScaffold），
    // 树里没有 Material 的 Scaffold，而 ScaffoldMessenger.showSnackBar
    // 断言 `_scaffolds.isNotEmpty` —— debug 下直接抛断言，release 下
    // 用户什么也看不到（这个坑在 PDF 下载那里踩过）。
    if (!ok) {
      setState(() => _error = '本地保存失败，修改可能在重启后丢失');
    }
    setState(() {});
    // 课表变了：卡片快照与上课提醒都要跟着更新
    await CardSnapshotStore.refresh(tt, _app.semesterStart);
    if (PrefStore.loadReminderOn()) {
      await ReminderService.reschedule(tt, _app.semesterStart);
    }
  }

  Future<void> _openEditor(int row, int col) async {
    final Timetable? tt = _tt;
    if (tt == null) {
      return;
    }
    final CellData? cell = tt.findCell(row, col);
    final List<CourseEntry> initial = cell == null
        ? <CourseEntry>[]
        : cell.entries.map((CourseEntry e) => e.clone()).toList();
    final List<CourseEntry>? result = await showDialog<List<CourseEntry>>(
      context: context,
      builder: (BuildContext ctx) => CourseEditorDialog(
        row: row,
        col: col,
        initial: initial,
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    final CellData target = tt.ensureCell(row, col);
    target.entries = result;
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const LoadingView(message: '正在获取课表…');
    }
    if (_tt == null) {
      return ErrorView(
          message: _error.isEmpty ? '暂无课表数据' : _error,
          onRetry: () => _load(interactive: true));
    }
    // 把「周次 / 学期 / 校历」提交到顶栏，与标题和设置按钮同一行。
    //
    // 为什么搬上去：这三个控件原先自成一行压在课表上方，把纵向空间吃掉，
    // 底部备注被挤到只剩两行。移到顶栏后整行高度还给课表与备注。
    // 提交必须在帧后（见 TopBarSlot 的说明），因此这里只发起，
    // 不在 build 期间改任何状态。
    TopBarSlot.submit(_topBarControls());

    // 不再需要外层 LayoutBuilder：网格自己会按可用区域均分（见 _grid）。
    return Column(
      children: <Widget>[
        if (_error.isNotEmpty)
          // 课表有本地缓存，所以这里不遮挡内容：只在上方给一条可点的提示。
          // 点它 = 用户主动发起重试，此时才允许弹重新验证。
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: Gaps.page, vertical: 2),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(_error,
                      style: TextStyle(
                          fontSize: 12, color: context.dangerColor)),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _load(interactive: true),
                  child: Text('重新加载',
                      style: TextStyle(
                          fontSize: 12, color: context.brandColor)),
                ),
              ],
            ),
          ),
        Expanded(child: _grid()),
        // 备注等底部内容整体上移，避开浮层 dock —— 否则被玻璃压住
        // （真机上「备注」正文就被 dock 遮掉了）。
        // 见 shell.dart 里 extendBody 的说明：内容会滚到 dock 下面。
        Padding(
          padding: const EdgeInsets.only(bottom: Gaps.scrollTail),
          child: _footer(),
        ),
      ],
    );
  }

  /// 学期代码的顶栏缩写：`2026-2027-1` → `26-27-1`。
  ///
  /// 只在顶栏用；完整的学期串在滚轮弹窗与设置页里照常显示。
  /// 前缀两位年份已足够区分（同一时间只会看相邻几个学期）。
  String _shortSemester(String code) {
    final List<String> parts = code.split('-');
    if (parts.length != 3) {
      return code;
    }
    String y(String s) => s.length >= 2 ? s.substring(s.length - 2) : s;
    return '${y(parts[0])}-${y(parts[1])}-${parts[2]}';
  }

  /// 顶栏里的「周次 / 学期 / 校历 / 空教室」。
  ///
  /// ===== 删掉「课表」二字之后为什么还要重新布局 =====
  /// 标题原先占着这一行最左边，控件只能吃剩下的宽度。标题删掉后这一整行
  /// 都归控件所有，于是有两个新问题要处理：
  ///
  ///   1. **大屏上会被拉得过宽**。`Expanded` 会吃掉全部剩余宽度，在平板上
  ///      （内容区上限 980）两个选择器各能到 400 逻辑像素 —— 一个写着
  ///      「第 4 周」的药丸有半个屏幕宽，看着不像控件，像输入框。
  ///      所以整行套一层 `ConstrainedBox` 限宽并居中：手机上它本来就填满，
  ///      宽度限制不生效；平板上则收成一排紧凑的控件浮在中间。
  ///   2. 视觉重心。标题在时这一行是「左标题 + 右控件」；没了标题，
  ///      若仍左对齐，右边会空出一大片，反而不平衡。居中后是一排完整的
  ///      工具行，看起来更有意为之。
  ///
  /// 与页内版本的区别：
  ///   - 不再自带页面内边距与底色（顶栏自己有玻璃底）；
  ///   - 高度收紧到 32（见 GlassKit.topBarControlH），四个控件像素级对齐；
  ///   - 学期用与其它选择器**同一套药丸玻璃**外观（见 GlassPickerField）。
  Widget _topBarControls() {
    final Timetable tt = _tt!;
    // 两个选择器等宽（flex 3:3）。
    //
    // 用 Expanded 而不是 Flexible：早先控件吃不到剩余宽度，只能按固有宽度
    // 靠右挤着排，周次与学期被压成「26-…」这种截断。
    //
    // 为什么是等宽：周次最长是「第 30 周」（4 字 + 空格 ≈ 45px），
    // 学期缩写是「26-27-1」（7 字符 ≈ 50px），两者体量本就相近；
    // 等宽能让中间那条缝保持在正中，看着最稳。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 3,
              // 周次不再用下拉框，改为屏幕中央的液态玻璃滚轮弹窗
              // （31 个周次在下拉列表里翻起来很累；滚轮更贴合「选一个周」）。
              child: _weekField(),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              // 学期选择：同样改为居中玻璃滚轮（与周次一致）。
              // 顶栏空间有限，这里显示缩写「26-27-1」；完整学期
              // （2026-2027-1）在点开的滚轮里能看到。
              //
              // centered: true —— 旁边的周次框是「值+箭头」整体居中的，
              // 学期框不居中的话文字贴左、右侧空一块，两个并排明显不齐。
              child: GlassPickerField(
                label: '',
                compact: true,
                dense: true,
                centered: true,
                value:
                    tt.semester.isEmpty ? '学期' : _shortSemester(tt.semester),
                onTap: _pickSemester,
              ),
            ),
            const SizedBox(width: 8),
            // 校历入口：官方校历图 + 官方作息时刻表。
            // 看课表时最常需要翻的就是它，因此与筛选条件并排。
            _calendarButton(tt.semester),
            // 空教室快捷入口：看课表时最常接着要问的就是「哪儿有空教室」。
            // 放在最右（原设置按钮的位置），与校历按钮同高同形。
            if (widget.onOpenClassroom != null) ...<Widget>[
              const SizedBox(width: 8),
              _classroomButton(),
            ],
            // 「已修改」不再占用顶栏：它是个低频的「恢复」入口，却有整整一个
            // 药丸控件的体量，把周次/学期的宽度挤掉一截。现在挪到下方备注
            // 标签的右侧，做成与「备注」二字同高的小按钮（见 _editedChip）。
          ],
        ),
      ),
    );
  }

  /// 空教室快捷入口。
  ///
  /// **形状与校历按钮完全一致**：同样用 `GlassButton.custom` + 同样的
  /// `LiquidRoundedRectangle(borderRadius: 20)` + 同样的高度。
  /// 早先用 GestureDetector + fieldBackdrop（药丸圆角 999），在
  /// 「宽 36 / 高 32」这种近方形比例下会被收敛成一个**圆**，
  /// 与旁边圆角矩形的校历按钮并排时明显不是一套控件。
  ///
  /// 只放图标不放文字：顶栏横向空间要留给周次与学期，
  /// Tooltip 保证语义不丢（读屏也能读到）。
  Widget _classroomButton() {
    return Tooltip(
      message: '空教室查询',
      child: GlassButton.custom(
        onTap: () => widget.onOpenClassroom?.call(),
        shape: const LiquidRoundedRectangle(borderRadius: 20),
        // 自管图层：它是独立元素，不在任何玻璃容器内部
        useOwnLayer: true,
        width: 46,
        height: GlassKit.topBarControlH,
        child: Icon(Icons.meeting_room_outlined,
            size: 17, color: context.brandColor),
      ),
    );
  }

  /// 校历入口按钮：液态玻璃效果。
  ///
  /// 这里能用玻璃按钮的原因：它是**独立浮在页面上**的元素，
  /// 不在任何玻璃容器内部。库作者明确禁止「玻璃套玻璃」
  /// （交互玻璃自带折射面，嵌套会产生双重折射、裁掉弹性动画，
  /// 并浪费 GPU 填充率），所以弹窗内部的按钮保持普通样式。
  // ==================== 周次解析（三态语义，务必区分）====================
  //
  // `_week` 有三种取值，用途不同，**不能混用同一个解析**：
  //   - `kWeekAuto`：自动跟随本周 → 过滤用「当前周」，日期也用当前周
  //   - `''`      ：全部周次     → 过滤**不设条件**（0），日期仍用当前周
  //   - `'3'`     ：指定第 3 周  → 过滤与日期都用 3
  //
  // 早先把「全部」也解析成当前周（`int.tryParse('') ?? currentWeek`），
  // 于是选了「全部」其实只显示当前周 —— 选项与行为不符，属于静默错误。

  /// 过滤用周次：**0 表示不按周次过滤**（即「全部」）
  int _filterWeek() {
    if (_week == kWeekAuto || _week.isEmpty) {
      // 「自动」按当前周过滤；「全部」返回 0（不过滤）
      return _week == kWeekAuto ? _app.currentWeek : 0;
    }
    return int.tryParse(_week) ?? 0;
  }

  /// 日期显示用周次：始终是一个真实周次（「全部」时用当前周）
  int _displayWeek() {
    if (_week == kWeekAuto || _week.isEmpty) {
      return _app.currentWeek;
    }
    return int.tryParse(_week) ?? _app.currentWeek;
  }

  /// 打开学期滚轮
  Future<void> _pickSemester() async {
    final Timetable tt = _tt!;
    final String? v = await showGlassPicker<String>(
      context,
      title: '选择学期',
      current: tt.semester,
      options: <GlassOption<String>>[
        for (final String x in tt.semesters) GlassOption<String>(x, x),
      ],
    );
    if (v == null || v == tt.semester || !mounted) {
      return;
    }
    setState(() {
      _tt = Timetable(semester: v);
      _loading = true;
    });
    // 切学期是用户主动操作
    await _load(interactive: true);
  }

  /// 周次选择入口：点开居中玻璃弹窗。
  ///
  /// 显示当前周次；为空（未选/「全部」）时显示「全部」。
  Widget _weekField() {
    final bool auto = _week == kWeekAuto;
    final int w = auto ? _app.currentWeek : (int.tryParse(_week) ?? 0);
    // 只显示「第 N 周」。三种状态（跟随本周 / 全部 / 指定周）收敛成同一个
    // 短语面：跟随本周与指定周都显示周号，选「全部」时才显示「全部」。
    //
    // 刻意不再显示「本周」小标记：跟随本周时周号本身就是当前周
    // （如「第 4 周」），再挂一个「本周」既重复又占宽 ——
    // 用户要的是「直接看到第几周」。
    final String label = w > 0 ? '第 $w 周' : '全部';
    return GestureDetector(
      onTap: _pickWeek,
      // 药丸玻璃：与学期选择器、顶栏右侧的设置按钮同一套外观与尺寸
      child: GlassKit.fieldBackdrop(
        context,
        child: Container(
          height: GlassKit.topBarControlH,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 不再放星期图标：顶栏要给「第几周」本身留空间，
              // 且图标与右侧设置按钮的齿轮在视觉上互相干扰
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: GlassKit.topBarControlFs,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.unfold_more,
                  size: GlassKit.topBarControlFs + 2, color: context.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开周次选择器，选中后保存并刷新。
  ///
  /// 用通用玻璃滚轮（`glass_picker`）而不是专用实现 ——
  /// 全应用的下拉都收敛到同一个组件，样式与交互必然一致，
  /// 也不会出现「改了一个忘了另一个」。
  Future<void> _pickWeek() async {
    final int cw = _app.currentWeek;
    final String? picked = await showGlassPicker<String>(
      context,
      title: '选择周次',
      current: _week,
      options: <GlassOption<String>>[
        GlassOption<String>(kWeekAuto, '跟随本周'),
        const GlassOption<String>('', '全部'),
        for (int w = 1; w <= kMaxWeeks; w++)
          GlassOption<String>('$w', '第 $w 周'),
      ],
      // 「本周」标记：让用户一眼看到现在处在哪一周
      markLabel: (String v) => v == '$cw' ? '本周' : '',
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _week = picked);
    PrefStore.saveLastWeek(picked);
  }

  Widget _calendarButton(String semester) {
    return Tooltip(
      message: '校历与作息表',
      child: GlassButton.custom(
        // 注意：GlassButton 用 onTap，与 ElevatedButton 的 onPressed 相反
        // （而 GlassIconButton 反倒是 onPressed，两者容易记反）。
        onTap: () =>
            showAcademicCalendarSheet(context, semesterCode: semester),
        shape: const LiquidRoundedRectangle(borderRadius: 20),
        // 自管图层：它在筛选栏里是独立元素，不是玻璃容器的子节点
        useOwnLayer: true,
        // 与周次/学期选择器同高同宽档位：顶栏四个控件必须像素级对齐
        width: 72,
        height: GlassKit.topBarControlH,
        // 必须用 `.custom` + child：`GlassButton` 的 `label` 只是
        // **无障碍语义标签**（给读屏用的），它不会画出文字 ——
        // 只传 icon/label 时按钮上只有图标（实测踩到过）。
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.calendar_month_outlined, size: 15),
            const SizedBox(width: 5),
            Text('校历',
                style: TextStyle(fontSize: 13, color: context.textPrimary)),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReset() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('恢复为服务器数据'),
        content: const Text(
            '将清除本学期的所有本地修改（新增、编辑、删除），并从教务系统重新获取课表。是否继续？'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: context.dangerColor),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    final Timetable? tt = _tt;
    if (tt == null) {
      return;
    }
    final String account = await _app.resolveAccount();
    await TimetableStore.remove(account, tt.semester);
    setState(() => _loading = true);
    // 用户主动点了「恢复为服务器数据」
    await _load(interactive: true);
  }

  /// 课表网格：**整周固定一屏**（7 天 × 5 节同时可见，无横纵滚动）。
  ///
  /// ===== 版式参照成熟课表 App（用户指定的视觉基准）=====
  ///   1. 极浅冷色**渐变底**代替白底 + 网格线：彩色课程卡直接浮在渐变上，
  ///      不需要分隔线与单元格描边；空白区域保持干净（仍可点击新增课程）。
  ///   2. **实心彩卡 + 白字**（见 `CoursePalette`），按颜色记课。
  ///   3. 表头**星期 + 日期**两行，今天用深色药丸反白标出。
  ///   4. 左侧节次列：节次名 + 起止时刻，弱色小字 —— 它是「尺子」，
  ///      不该与课程卡抢注意力。
  ///
  /// ===== 两条必须遵守的约束（别改回去）=====
  ///   1. **行高不能再由课程内容决定**。早先用 `IntrinsicHeight` 让行随课程
  ///      撑高 —— 一屏装不下 5 行，必然纵向滚动。现在每行等分剩余高度。
  ///   2. **内容必须能收缩**。格子变小后文字若还按固有高度排就会溢出，
  ///      所以所有文本都走 `maxLines + ellipsis`，卡内再套 `ClipRect` 兜底。
  Widget _grid() {
    final Timetable tt = _tt!;
    // 过滤与日期分开解析（见上面两个 helper 的说明）
    final int week = _filterWeek();
    final int dispWeek = _displayWeek();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 节次列宽：要容纳「一、二」加上两行时刻
        final double labelW = (c.maxWidth * 0.105).clamp(38.0, 60.0);
        // 列宽 = 可用宽度减去节次列后 7 等分 —— 确定值，7 列恰好铺满
        final double colW = (c.maxWidth - labelW) / kWeekdayCols;
        // 教室/教师是否显示。
        //
        // 早先门槛设在 68dp，结果 54.6dp 列宽的手机上**永远不显示教室** ——
        // 而教室恰恰是课表里最常被查的信息。参照实现在约 47dp 的卡片里
        // 照样显示（只是换行），因此把门槛降到「能容下两三个字符」即可，
        // 窄的时候靠换行与省略，而不是直接不显示。
        final bool roomy = colW >= 42;
        // 字号随格子缩放，避免窄格子把字挤成竖排
        final double nameFs = (colW * 0.17).clamp(9.0, 11.5);
        final double metaFs = (colW * 0.135).clamp(7.5, 9.5);
        // 行高是确定值：5 行等分「表头之外的可用高度」。
        // **卡内显示几行不再在这里估算** —— 估算必然低估（漏算内边距、
        // 行距、单双周那行），矮屏上会直接溢出。改为在 _cell 里用真实
        // 文本度量逐级降级，见 model/card_layout.dart。
        final double rowH =
            ((c.maxHeight - _kHeaderH) / kSectionRows).clamp(20.0, 420.0);

        return Container(
          // 整页统一底色（与筛选栏、底部栏同色号）——
          // 之前表格用渐变、栏用白色，三种底色并存显得不统一。
          color: context.schedBgColor,
          child: Column(
            children: <Widget>[
              // 表头高度固定（内容只有星期与日期，是已知量），不参与均分
              SizedBox(
                height: _kHeaderH,
                child: Row(
                  children: <Widget>[
                    SizedBox(width: labelW, child: _monthCell(dispWeek)),
                    for (int d = 0; d < kWeekdayCols; d++)
                      SizedBox(
                        width: colW,
                        child: _weekdayHeader(d, dispWeek, compact: !roomy),
                      ),
                  ],
                ),
              ),
              // 5 行等分剩余高度 → 整周恰好铺满可用区域
              Expanded(
                child: Column(
                  children: <Widget>[
                    for (int r = 0; r < kSectionRows; r++)
                      Expanded(
                        child: _sectionRow(
                          r,
                          labelW,
                          colW,
                          week,
                          roomy: roomy,
                          nameFs: nameFs,
                          metaFs: metaFs,
                          rowH: rowH,
                        ),
                      ),
                  ],
                ),
              ),
              if (tt.remark.isNotEmpty)
                _remarkBox(tt.remark)
              // 没有备注正文但有改动时，仍要给出「已修改」入口
              // （见 _editedOnlyStrip 的说明）
              else if (tt.edited)
                _editedOnlyStrip(),
            ],
          ),
        );
      },
    );
  }

  /// 备注：说明性文字，不是课表本身的一部分，所以放在网格**下方**；
  /// 用半透明底让它与渐变背景区分开，又不至于像一块白色补丁。
  Widget _remarkBox(String remark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: 6),
      // 备注与表格同底色，仅靠一条分隔线与留白区分 —— 不再引入第三种底色
      color: context.schedBgColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _remarkLabelRow(),
          const SizedBox(height: 2),
          // 完整展示，不截断：备注里是「哪些课没排进课表」这类必须看全的
          // 信息，截成两行加省略号等于没写。顶栏搬走筛选控件后，
          // 纵向空间已经够它自然撑开。
          Text(remark,
              style: TextStyle(fontSize: 10, color: context.textSecondary)),
        ],
      ),
    );
  }

  /// 备注标签行：「备注」+（改过课表时）右侧的「已修改」小按钮。
  ///
  /// ===== 「已修改」为什么放在这里 =====
  /// 它原本是顶栏里一个和「周次/学期」同高的药丸控件。但它是个**低频的
  /// 恢复入口**（只在手动改过课表后才出现），却要占掉顶栏一行里最紧俏的
  /// 一段宽度，把两个每天都要用的选择器挤窄。
  ///
  /// 挪到备注标签右侧后：
  ///   - 体量降到与「备注」二字同高，不再是个「控件」，而是一句附注；
  ///   - 位置语义也对：这行字说的正是「课表被改动过」这类说明，
  ///     与备注是同一个层级的信息。
  Widget _remarkLabelRow() {
    return Row(
      children: <Widget>[
        Text('备注',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: context.warningColor,
            )),
        if (_tt?.edited ?? false) ...<Widget>[
          const SizedBox(width: 8),
          _editedChip(),
        ],
      ],
    );
  }

  /// 「已修改」小按钮。
  ///
  /// 刻意不用玻璃：这个尺寸（约 40×15）下折射与高光根本看不出来，
  /// 却要为它多开一个图层；一层淡琥珀色底足以表达「这是个可点的标签」，
  /// 也正好与「备注」的警示色同族。
  Widget _editedChip() {
    return GestureDetector(
      onTap: _confirmReset,
      // 命中区域比视觉稍大一点，手指才好点中
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: context.warningColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text('已修改',
            style: TextStyle(
              // 与「备注」同字号：这一行里两者是同一层级的附注
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: context.warningColor,
            )),
      ),
    );
  }

  /// 没有备注正文、但课表被改过时的窄条：只放那枚「已修改」小按钮。
  ///
  /// 为什么需要它：不是每份课表都有备注行（`#bz_td` 可能不存在）。
  /// 若把小按钮**只**挂在备注标签旁边，那些没有备注的课表就再也找不到
  /// 恢复入口了 —— 而这恰恰是用户改坏课表后最需要的地方。
  ///
  /// 这里**只**放按钮、不放「备注」二字：没有备注正文却顶着一个
  /// 「备注」标签，会让人以为下面缺了一段内容。
  Widget _editedOnlyStrip() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: 6),
      color: context.schedBgColor,
      child: Align(alignment: Alignment.centerLeft, child: _editedChip()),
    );
  }

  /// 表头最左侧的月份格。
  ///
  /// 只在**能算出日期**时显示月份：周次未配置时算不出月份，
  /// 显示一个「月」字反而让人以为有数据。
  Widget _monthCell(int week) {
    final String label = week > 0 ? WeekService.monthLabel(week, 0) : '';
    if (label.isEmpty) {
      return const SizedBox.shrink();
    }
    return Center(
      child: Text(label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.textSecondary,
          )),
    );
  }

  Widget _weekdayHeader(int day, int week, {required bool compact}) {
    final String date = week > 0 ? WeekService.dayLabel(week, day) : '';
    final bool isToday = week > 0 &&
        WeekCalc.isTodayInWeek(_app.semesterStart, week, DateTime.now()) &&
        DateTime.now().weekday - 1 == day;
    final String wd = kWeekdayLabels[day].replaceFirst('星期', '');
    // 日期数字：`MM/DD` 取后一段；取不到就只显示星期
    final String dayNum = date.contains('/') ? date.split('/').last : '';

    // 今天：深色药丸反白，一眼定位「现在在哪一列」
    if (isToday && dayNum.isNotEmpty) {
      return Center(
        child: Container(
          padding:
              EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: 3),
          decoration: BoxDecoration(
            color: _kTodayPill,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(wd,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  )),
              Text(dayNum,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  )),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(wd,
              maxLines: 1,
              style: TextStyle(
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w500,
                color: context.textSecondary,
              )),
          if (dayNum.isNotEmpty)
            Text(dayNum,
                maxLines: 1,
                style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    color: context.textTertiary)),
        ],
      ),
    );
  }

  /// 左侧节次标签：节次名 + 起止时刻。
  ///
  /// ===== 为什么也要逐级降级 =====
  /// 这一列在矮屏（横屏）上会被压到 20dp 出头，而「节次名 + 开始 + 结束」
  /// 三行小字加起来约 36dp —— 直接堆上去必然溢出（画面上是黄黑警告条）。
  /// 因此和课程卡用同一套思路：**先量真实高度，再按优先级丢弃**。
  /// 丢弃顺序：结束时刻 → 开始时刻 → 节次名收成一行。
  ///
  /// 为什么保留节次名到最后：它是这一行的**身份**（第几大节）；
  /// 时刻是辅助信息，用户最常看的是「这节课在第几节」。
  Widget _timeLabel(SectionTime? st, {required bool roomy, required double availH}) {
    if (st == null) {
      return const SizedBox.shrink();
    }
    final String name = st.label.replaceAll('第', '').replaceAll('节', '');
    final double nameFs = roomy ? 11 : 10;
    const double timeFs = 9;
    final double lineName = nameFs * 1.2;
    const double lineTime = timeFs * 1.25;
    const double gap = 1;

    // 预算按「内容高度」算：扣掉上下 padding
    final double budget = (availH - 4).clamp(0.0, 9999.0);

    bool fits(int nameLines, bool showStart, bool showEnd) {
      double h = nameLines * lineName;
      if (showStart) {
        h += gap + lineTime;
      }
      if (showEnd) {
        h += lineTime;
      }
      return h <= budget;
    }

    // 逐级降级：先丢结束、再丢开始、最后把节次名收成一行
    int nameLines = 2;
    if (!fits(nameLines, true, true)) {
      if (fits(nameLines, true, false)) {
        // 只显示开始时刻
        return _labelColumn(name, nameFs, nameLines, st.start, '', timeFs);
      }
      if (fits(nameLines, false, false)) {
        return _labelColumn(name, nameFs, nameLines, '', '', timeFs);
      }
      nameLines = 1;
      if (fits(nameLines, true, false)) {
        return _labelColumn(name, nameFs, nameLines, st.start, '', timeFs);
      }
      return _labelColumn(name, nameFs, 1, '', '', timeFs);
    }
    return _labelColumn(name, nameFs, 2, st.start, st.end, timeFs);
  }

  Widget _labelColumn(
    String name,
    double nameFs,
    int nameLines,
    String start,
    String end,
    double timeFs,
  ) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(
          name,
          textAlign: TextAlign.center,
          maxLines: nameLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: nameFs,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: context.textSecondary,
          ),
        ),
        if (start.isNotEmpty) ...<Widget>[
          const SizedBox(height: 1),
          Text(start,
              maxLines: 1,
              style: TextStyle(fontSize: timeFs, color: context.textTertiary)),
        ],
        if (end.isNotEmpty)
          Text(end,
              maxLines: 1,
              style: TextStyle(fontSize: timeFs, color: context.textTertiary)),
      ],
    );
  }

  /// 一个节次行。高度由父级 `Expanded` 均分给定，**不随内容变化**。
  Widget _sectionRow(
    int row,
    double labelW,
    double colW,
    int week, {
    required bool roomy,
    required double nameFs,
    required double metaFs,
    required double rowH,
  }) {
    final Timetable tt = _tt!;
    final SectionTime? st = SectionTimeStore.at(row);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: labelW,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
            child: _timeLabel(st, roomy: roomy, availH: rowH),
          ),
        ),
        for (int d = 0; d < kWeekdayCols; d++)
          SizedBox(
            width: colW,
            child: _cell(
              tt,
              row,
              d,
              week,
              roomy: roomy,
              nameFs: nameFs,
              metaFs: metaFs,
              rowH: rowH,
              colW: colW,
            ),
          ),
      ],
    );
  }

  Widget _cell(
    Timetable tt,
    int row,
    int day,
    int week, {
    required bool roomy,
    required double nameFs,
    required double metaFs,
    required double rowH,
    required double colW,
  }) {
    final CellData? cell = tt.findCell(row, day);
    final List<CourseEntry> active = cell == null
        ? <CourseEntry>[]
        : cell.entries.where((CourseEntry e) => e.isActiveInWeek(week)).toList();

    // 这一格分给每门课的高度：行高减去上下 padding 与卡片间距后按门数均分。
    // 同格有两门课（单周 + 双周）时各得一半 —— 这是必须支持的常见情形。
    const double cellPad = 1.5;
    final double innerH = (rowH - cellPad * 2).clamp(0.0, 9999.0);
    final double perCourse = active.isEmpty
        ? innerH
        : ((innerH - 2.0 * (active.length - 1)) / active.length)
            .clamp(0.0, 9999.0);
    // 卡片内容可用宽度：列宽减去左右 padding(5*2) 与 margin
    final double innerW = (colW - 10 - cellPad * 2).clamp(0.0, 9999.0);

    return GestureDetector(
      onTap: () => _openEditor(row, day),
      // 关键：必须有 `behavior: opaque`。
      // `GestureDetector` 默认是 `deferToChild`，而空白格的子节点是
      // `SizedBox.expand()`（无内容、无背景）—— 它不参与命中测试，
      // 于是整格对点击「透明」，tap 直接穿透过去，编辑框永远打不开。
      // 空白格不画边框也不填色（参照成熟课表 App 的干净底），
      // 但**依然可点**：点空白格即可新增课程。
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(cellPad),
        child: active.isEmpty
            ? const SizedBox.expand()
            // 多门课（单周课 + 双周课）同格时必须都看到，用 Expanded 均分格高
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final CourseEntry e in active)
                    Expanded(
                      child: _courseCard(
                        e,
                        nameFs: nameFs,
                        metaFs: metaFs,
                        availH: perCourse,
                        innerW: innerW,
                        showMeta: roomy,
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  /// 课程卡：**实心彩底 + 白字**（参照版式）。
  ///
  /// 内容是**可收缩**的 —— 全部走 `maxLines + ellipsis`，外面再套 `ClipRect`：
  /// 格子再小也只是少显示，不会溢出（溢出条会破坏「固定一屏」的前提），
  /// 更不会撑破行高。
  ///
  /// 单双周徽标贴在**卡片底部**（参照版式的位置）：它是对整门课的限定，
  Widget _courseCard(
    CourseEntry e, {
    required double nameFs,
    required double metaFs,
    required double availH,
    required double innerW,
    required bool showMeta,
  }) {
    final List<Color> colors = CoursePalette.of(e.courseName);
    final Color fill = colors[0];
    final Color fg = colors[1];
    final String place = e.campus.isEmpty
        ? e.room
        : (e.room.isEmpty ? '' : '${e.room}(${e.campus})');
    final String parity = e.parityText();

    // 用**真实文本度量**决定显示几行，而不是估算 —— 估算必然低估，
    // 矮屏（横屏）上会撑破格子并报 overflow。见 model/card_layout.dart。
    final CardPlan plan = planCard(
      availH: availH,
      innerW: innerW,
      nameText: e.courseName,
      metaText: showMeta ? place : '',
      hasParity: parity.isNotEmpty,
      nameFs: nameFs,
      metaFs: metaFs,
      maxNameLines: 6,
      // 传入真实文字缩放：无障碍大字号下同一段文字占更多行，
      // 按 1.0 度量会低估，进而撑破格子。
      textScaler: MediaQuery.textScalerOf(context),
    );

    // 注意：这里**不能**用 `Spacer`。
    // Spacer 是 Expanded，需要**有界的**父高度；而下面兜底用的 OverflowBox
    // 会放开高度约束 → Spacer 吃掉无限空间，把文字挤出裁剪区，
    // 表现为「有单双周徽标的卡片整张空白」。改用 spaceBetween：
    // 在有界高度里效果与 Spacer 相同（首行贴顶、徽标贴底），且不依赖 flex。
    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(
          e.courseName,
          maxLines: plan.nameLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: nameFs,
            height: 1.15,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
        if (plan.metaLines > 0 && place.isNotEmpty) ...<Widget>[
          const SizedBox(height: 1),
          // 允许折行：参照实现在窄卡片里把「@7-120(章丘)」折成两行，
          // 直接省略会让「@7-120」看起来就是完整教室。
          Text(
            '@$place',
            maxLines: plan.metaLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: metaFs,
              height: 1.15,
              fontWeight: FontWeight.w500,
              color: fg.withValues(alpha: 0.92),
            ),
          ),
        ],
        // 单双周推到底部（参照版式位置）：它是对整门课的限定，
        // 用 Spacer 推到最下，免得与「课名→教室」的阅读顺序打架。
        if (plan.showParity) ...<Widget>[
          Text(
            parity,
            maxLines: 1,
            style: TextStyle(
              fontSize: metaFs,
              height: 1.15,
              fontWeight: FontWeight.w600,
              color: fg.withValues(alpha: 0.95),
            ),
          ),
        ],
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        // 本地手改的课加一圈描边，与服务器数据区分。
        // 描边用白色半透明 —— 在实心彩底上才看得出来。
        border: e.local
            ? Border.all(
                color: Colors.white.withValues(alpha: 0.85), width: 1.2)
            : null,
      ),
      // 兜底：`planCard` 的度量基于「标准字体缩放」，而用户可能开了
      // 无障碍大字号 —— 此时真实排版会比度量结果高。用 OverflowBox 放开
      // 高度约束再配 ClipRect 裁剪，**最坏也只是少显示一行**，
      // 而不是画面上出现黄黑 overflow 警告条（那会破坏「固定一屏」的观感）。
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          maxHeight: double.infinity,
          minHeight: 0,
          child: body,
        ),
      ),
    );
  }

  /// 底部提示条。
  ///
  /// **只在一件事真的需要用户处理时才出现**：没设开学日期 → 无法定位当前周。
  /// 其余情况整条不渲染。
  ///
  /// 去掉了原先常驻的两句：「当前第 N 周」与「点击课程可编辑」——
  /// 前者在周次选择器上已经能看到，后者是操作提示而非状态；
  /// 常驻显示只是平白占掉一行高度、天天看同一句话。
  Widget _footer() {
    if (_displayWeek() > 0) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      // 与表格同色号（整页统一底色）
      color: context.schedBgColor,
      padding: const EdgeInsets.symmetric(horizontal: Gaps.page, vertical: 8),
      child: Text(
        '未设置开学日期，无法自动定位当前周',
        style: TextStyle(fontSize: 11, color: context.textTertiary),
      ),
    );
  }
}
