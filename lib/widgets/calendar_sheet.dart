/// 校历弹窗：自绘月历（周次）× 官方作息表
///
/// ===== 数据来源与「随年份更新」怎么保证 =====
/// 主数据是教务系统的「教学周历」（`/jsxsd/jxzl/jxzl_query`）：
/// 一张「第 N 周 ←→ 周一日期」的对照表，学校每学期排课时录入，
/// **换学年后取到的是新数据**，不需要改代码、不需要随包图片。
/// 见 [SemesterCalendarService]。
///
/// 界面由两部分组成：
///   1. **自绘月历**（[SemesterMonthGrid]）：每个教学日标出教学周次，
///      非教学日留白。它承载的是「日期 + 周次 + 学期边界」，
///      与官方校历图给的信息一致，但可随年份更新、可参与计算；
///   2. **官方作息表**：节次起止时刻（决定上课提醒），
///      仍从学校官网抓、失败退内置（那部分是数字表格，不是图片，能直接解析）。
///
/// ===== 为什么删掉了内置的校历图片 =====
/// 早先随包内置了 2026 学年的两张校历图（约 740KB）作为兜底。
/// 它的**失效方式很危险**：换学年后内置图就是去年的，而界面上完全看不出，
/// 用户会照着过期日期安排行程。相比之下「取不到就不显示」是安全的降级 ——
/// 所以这里只在**联网拿到**官方图时才展示它（那次一定是当期版本），
/// 拿不到就只显示自绘月历。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/academic_calendar.dart';
import '../data/app_state.dart';
import '../data/campus_calendar_service.dart';
import '../data/card_snapshot_store.dart';
import '../data/reminder_service.dart';
import '../data/semester_calendar_service.dart';
import '../data/week_service.dart';
import '../model/models.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import '../widgets/glass_picker.dart';
import '../widgets/semester_month_grid.dart';

/// 打开校历弹窗。
///
/// [semesterCode] 是当前学期代码（如 2026-2027-1），用来决定先显示哪一学期。
Future<void> showAcademicCalendarSheet(
  BuildContext context, {
  String semesterCode = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => _CalendarSheet(initialSemester: semesterCode),
  );
}

class _CalendarSheet extends StatefulWidget {
  const _CalendarSheet({required this.initialSemester});

  final String initialSemester;

  @override
  State<_CalendarSheet> createState() => _CalendarSheetState();
}

class _CalendarSheetState extends State<_CalendarSheet> {
  /// 当前查看的学期代码
  late String _semester = widget.initialSemester;

  /// 服务端给的「有周历的学期」列表；为空时只显示当前学期
  List<ChoiceItem> _semesters = <ChoiceItem>[];

  SemesterInfo? _info;
  bool _loading = true;
  bool _refreshing = false;
  String _error = '';

  /// 校正开学日期后的结果提示
  String _fixHint = '';

  /// 官方作息（含官网原图，若有）
  CampusCalendar? _campus;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 作息表先出（本地缓存/内置，不等网络）
    final CampusCalendar local = await CampusCalendarService.load();
    if (!mounted) {
      return;
    }
    setState(() => _campus = local);

    // 学期列表与周历并行取：列表决定下拉里有哪些选项，
    // 周历决定画什么内容，两者互不依赖
    final List<ChoiceItem> sems = await SemesterCalendarService.semesters();
    if (!mounted) {
      return;
    }
    // 学期列表拿到后，如果当前学期为空（比如冷启动没进过课表），
    // 用列表里最新的那个
    final String pick = _semester.isNotEmpty
        ? _semester
        : (sems.isNotEmpty ? sems.first.value : '');
    setState(() {
      _semesters = sems;
      _semester = pick;
    });

    await _loadSemester(pick);
    if (!mounted) {
      return;
    }
    setState(() => _loading = false);
    // 打开时**不再**无条件重抓作息表与校历图：
    // 那两张原始图实测 2.74MB，学校一学期才换一次，每开一次弹窗就重下
    // 纯属浪费。7 天为周期交给 isStale 判断（与启动时那条一致）。
    if (CampusCalendarService.isStale()) {
      _refreshCampus(silent: true);
    }
    // 系统时间已超出周历范围（放假了）→ 每天最多自动拉一次新学期周历
    unawaited(_autoFetchIfOutdated(pick));
  }

  Future<void> _autoFetchIfOutdated(String code) async {
    final SemesterInfo? got = await SemesterCalendarService.autoFetchIfOutdated(code);
    if (got == null || !mounted) {
      return;
    }
    // 真拉到了新周历：换成它并提示一次（这种事一个假期只发生一两次）
    setState(() {
      _info = got;
      _semester = got.code;
      _fixHint = '已获取到新学期的教学周历（${got.code}）';
    });
  }

  Future<void> _loadSemester(String code, {bool force = false}) async {
    if (code.isEmpty) {
      setState(() {
        _info = null;
        _error = '';
      });
      return;
    }
    setState(() => _error = '');
    final SemesterInfo? got =
        await SemesterCalendarService.load(code, force: force);
    if (!mounted) {
      return;
    }
    setState(() {
      // **只在真的没有数据时才清空 _info**。
      // 早先无条件写成 got（刷新失败时 got 为 null），于是点刷新遇到断网，
      // 界面会把已经显示着的校历整个擦掉 —— 用户手里唯一的离线副本就这么没了，
      // 而那次刷新失败本不该有任何破坏性。
      // 服务层的 _fallbackFromCache 会优先返回旧缓存，这里再兜一层。
      if (got != null) {
        _info = got;
      }
      _error = got == null
          ? (SemesterCalendarService.lastError.isEmpty
              ? '该学期暂无教学周历'
              : SemesterCalendarService.lastError)
          : '';
    });
  }

  Future<void> _refreshCampus({bool silent = false}) async {
    if (_refreshing) {
      return;
    }
    setState(() => _refreshing = true);
    final CampusCalendar? got = await CampusCalendarService.refresh();
    if (!mounted) {
      return;
    }
    setState(() {
      _refreshing = false;
      if (got != null) {
        _campus = got;
      } else if (!silent) {
        // 只有用户**主动**点刷新时才提示失败
        _error = CampusCalendarService.lastError.isEmpty
            ? '未能获取最新作息表'
            : '未能获取最新作息表：${CampusCalendarService.lastError}';
      }
    });
  }

  /// 用户点了刷新：**完整重取一遍**，一个都不省。
  ///
  /// 三样东西各自独立，缺任何一样都会让人以为「刷新了但没变」：
  ///   1. 教学周历 —— 强制联网（`force: true` 绕过 TTL 与内存缓存）；
  ///   2. 作息时刻表 —— `refresh()` 本身就是无条件抓取；
  ///   3. 校历原图 —— 同上，且这次会真的走网络（不因 URL 相同而跳过？
  ///      **仍然跳过**：URL 相同意味着学校没换图，本地文件即最新，
  ///      此时重下 2.74MB 只是白费流量；URL 变了必然重下）。
  ///
  /// 学期列表也一起重取：它决定下拉里有哪些学期，学校新开学时全靠它。
  Future<void> _refreshAll() async {
    // 先重取学期列表（可能新增了学期），失败保留旧的
    final List<ChoiceItem> sems = await SemesterCalendarService.semesters(force: true);
    if (!mounted) {
      return;
    }
    if (sems.isNotEmpty) {
      setState(() => _semesters = sems);
    }
    await _loadSemester(_semester, force: true);
    await _refreshCampus();
  }

  /// 选学期。
  ///
  /// 用全应用统一的**玻璃滚轮**（[showGlassPicker]），而不是自己拼一个列表：
  ///   1. 学期有十几个（实测服务端返回 12 个），自己拼的列表在手机上会**溢出**
  ///      —— 弹窗高度上限是屏幕的 9/16，12 行 × 56dp 远超它，实测报
  ///      「BOTTOM OVERFLOWED BY 255 PIXELS」，而平板上又能放下，
  ///      于是同一个页面在不同设备上时好时坏；
  ///   2. 滚轮固定 3–5 行高，选项再多也不会溢出（它内部就是可滚的）；
  ///   3. 学期/周次的选择在别处也走这个组件，交互与观感一致。
  Future<void> _pickSemester() async {
    if (_semesters.isEmpty) {
      return;
    }
    final String? v = await showGlassPicker<String>(
      context,
      title: '选择学期',
      current: _semester,
      options: <GlassOption<String>>[
        for (final ChoiceItem s in _semesters)
          GlassOption<String>(s.value, s.label),
      ],
    );
    if (v == null || v == _semester || !mounted) {
      return;
    }
    setState(() {
      _semester = v;
      _loading = true;
    });
    await _loadSemester(v);
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  /// 学期要覆盖的月份：从第 1 周周一所在月，到最后一周周日所在月
  List<({int year, int month})> _months(SemesterInfo info) {
    final DateTime? first = info.mondayOf(1);
    final DateTime? last = info.mondayOf(info.totalWeeks);
    if (first == null || last == null) {
      return <({int year, int month})>[];
    }
    final DateTime end = last.add(const Duration(days: 6));
    final List<({int year, int month})> out = <({int year, int month})>[];
    DateTime cur = DateTime(first.year, first.month, 1);
    final DateTime stop = DateTime(end.year, end.month, 1);
    // 上限 14 个月：一个学期最多跨 8 个月左右，14 足够且能防住脏数据
    // （比如服务端某行日期写成了 2099 年，会把这里变成死循环）
    for (int i = 0; i < 14 && !cur.isAfter(stop); i++) {
      out.add((year: cur.year, month: cur.month));
      cur = DateTime(cur.year, cur.month + 1, 1);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;
    final bool wide = size.width >= 720;

    if (_loading && _info == null) {
      return GlassKit.surface(
        context,
        radius: 18,
        child: SizedBox(
          height: size.height * 0.4,
          child: Center(
            child: Text('正在读取校历…',
                style: TextStyle(fontSize: 13, color: context.textTertiary)),
          ),
        ),
      );
    }

    final SemesterInfo? info = _info;
    final List<String> lines =
        _campus?.sections ?? AcademicCalendar.sectionLines();

    return GlassKit.surface(
      context,
      radius: 22,
      child: SizedBox(
        width: size.width,
        height: size.height * 0.88,
        child: Column(
          children: <Widget>[
            _handle(),
            _title(context, info),
            _semesterRow(context),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gaps.l, 0, Gaps.l, Gaps.s),
                child: Text(_error,
                    style: TextStyle(fontSize: 11, color: context.warningColor)),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(Gaps.l, 0, Gaps.l, Gaps.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    ..._startDateNotice(context, info),
                    ..._monthGrids(context, info, wide),
                    const SizedBox(height: Gaps.l),
                    _sectionTable(context, lines),
                    ..._officialImages(context),
                  ],
                ),
              ),
            ),
            _closeBar(context),
          ],
        ),
      ),
    );
  }

  /// 开学日期与校历不一致时，给一条可一键校正的提示。
  ///
  /// 为什么需要：开学日期决定**全应用**的周次（课表标题、上课提醒、
  /// 桌面卡片都按它算）。它是可以手动设的，一旦设错，界面上不会有任何
  /// 报错 —— 只是所有周次集体偏移，而且看起来完全正常。
  /// 校历里的第 1 周周一就是权威答案，所以这里把两者摆在一起，
  /// 让用户一眼看出差在哪、并一键改过来。
  ///
  /// 刻意**不自动覆盖**：手动设置是明确的用户意图（有人会故意把
  /// 补考周算作第 1 周），静默改掉比不改更糟。
  List<Widget> _startDateNotice(BuildContext context, SemesterInfo? info) {
    if (info == null || info.firstMonday.isEmpty) {
      return <Widget>[];
    }
    final String stored = AppState.instance.semesterStart;
    // 没设过就不提示：那种情况启动时已自动填了校历的值
    if (stored.isEmpty || stored == info.firstMonday) {
      return _fixHint.isEmpty ? <Widget>[] : _hintBlock(context);
    }
    return <Widget>[
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: Gaps.l),
        padding: const EdgeInsets.all(Gaps.m),
        decoration: BoxDecoration(
          color: context.warningColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Gaps.radiusSm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('开学日期与校历不一致',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                )),
            const SizedBox(height: 4),
            Text(
              '当前设为 $stored，校历显示第 1 周应为 ${info.firstMonday}。'
              '周次、上课提醒、桌面卡片都按这个日期计算，设错会让它们整体偏移。',
              style: TextStyle(fontSize: 11, color: context.textSecondary),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _applyOfficialStart,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: context.brandColor,
                  borderRadius: BorderRadius.circular(Gaps.radiusSm),
                ),
                child: Text('按校历校正为 ${info.firstMonday}',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.onBrand)),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _hintBlock(BuildContext context) => <Widget>[
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: Gaps.l),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: context.brandSoftColor,
            borderRadius: BorderRadius.circular(Gaps.radiusSm),
          ),
          child: Text(_fixHint,
              style: TextStyle(fontSize: 12, color: context.brandColor)),
        ),
      ];

  /// 把开学日期改成校历的值，并让依赖它的东西重新算一遍。
  ///
  /// 这几步缺一不可（照 settings_page 的同一流程）：
  ///   1. 写入并吸附到周一；2. 重算当前周；3. 重排上课提醒；
  ///   4. 刷新桌面卡片。只改第 1 步的话，周次显示会立刻对，
  ///      但提醒与卡片仍按旧日期排定 —— 属于「改了没生效」。
  Future<void> _applyOfficialStart() async {
    final SemesterInfo? info = _info;
    if (info == null || info.firstMonday.isEmpty) {
      return;
    }
    try {
      await WeekService.setStartMonday(info.firstMonday);
      await WeekService.align(true);
      await ReminderService.reschedule(
          AppState.instance.timetable, AppState.instance.semesterStart);
      await CardSnapshotStore.refresh(
          AppState.instance.timetable, AppState.instance.semesterStart);
      if (!mounted) {
        return;
      }
      setState(() => _fixHint =
          '已按校历把开学日期改为 ${info.firstMonday}，当前第 ${AppState.instance.currentWeek} 周');
    } catch (e) {
      if (mounted) {
        setState(() => _fixHint = '保存失败：$e');
      }
    }
  }

  /// 自绘月历：宽屏两列，窄屏一列
  List<Widget> _monthGrids(
      BuildContext context, SemesterInfo? info, bool wide) {
    if (info == null) {
      return <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 28),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.surfaceVariant,
            borderRadius: BorderRadius.circular(Gaps.radiusSm),
          ),
          child: Text('暂无该学期的教学周历',
              style: TextStyle(fontSize: 13, color: context.textTertiary)),
        ),
      ];
    }
    final List<({int year, int month})> months = _months(info);
    if (months.isEmpty) {
      return <Widget>[];
    }
    if (!wide) {
      return <Widget>[
        for (final ({int year, int month}) m in months)
          Padding(
            padding: const EdgeInsets.only(bottom: Gaps.l),
            child: SemesterMonthGrid(
                year: m.year, month: m.month, info: info),
          ),
      ];
    }
    // 宽屏并排：一次看到更多月份，少滚几屏
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < months.length; i += 2) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: Gaps.l),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: SemesterMonthGrid(
                  year: months[i].year, month: months[i].month, info: info),
            ),
            const SizedBox(width: Gaps.l),
            Expanded(
              child: i + 1 < months.length
                  ? SemesterMonthGrid(
                      year: months[i + 1].year,
                      month: months[i + 1].month,
                      info: info)
                  : const SizedBox(),
            ),
          ],
        ),
      ));
    }
    return rows;
  }

  /// 官网校历原图。**只在联网拿到时显示** ——
  /// 那是当期版本，可以放心当权威参照；拿不到就不显示（原因见文件头）。
  List<Widget> _officialImages(BuildContext context) {
    final List<String> cached = _campus?.images ?? <String>[];
    if (cached.isEmpty) {
      return <Widget>[];
    }
    return <Widget>[
      const SizedBox(height: Gaps.l),
      Text('学校官方校历图',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: context.textPrimary,
          )),
      const SizedBox(height: 4),
      Text(
        '来源：学校官网「校园服务 · 最新校历」，下面月历由教务系统教学周历生成。',
        style: TextStyle(fontSize: 11, color: context.textTertiary),
      ),
      const SizedBox(height: Gaps.s),
      for (final String p in cached)
        Padding(
          padding: const EdgeInsets.only(bottom: Gaps.m),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Gaps.radiusSm),
            child: Image(
              image: FileImage(File(p)) as ImageProvider<Object>,
              fit: BoxFit.contain,
              // 缓存文件坏了就整块不显示，而不是给一个红色报错框 ——
              // 月历已经把信息给全了，图片只是佐证
              errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                  const SizedBox.shrink(),
            ),
          ),
        ),
    ];
  }

  Widget _handle() => Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        decoration: BoxDecoration(
          color: context.dividerColor,
          borderRadius: BorderRadius.circular(2),
        ),
      );

  Widget _title(BuildContext context, SemesterInfo? info) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gaps.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('校历',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                )),
            const SizedBox(height: 2),
            Text(
              info == null
                  ? '教学周历'
                  : '共 ${info.totalWeeks} 周 · 第 1 周 ${info.firstMonday} 起 · '
                      '至 ${info.lastDay}',
              style: TextStyle(fontSize: 11, color: context.textTertiary),
            ),
          ],
        ),
      );

  /// 学期选择行 + 刷新
  Widget _semesterRow(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gaps.l, Gaps.m, Gaps.l, Gaps.m),
        child: Row(
          children: <Widget>[
            Expanded(
              child: GestureDetector(
                onTap: _pickSemester,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: context.surfaceVariant,
                    borderRadius: BorderRadius.circular(Gaps.radiusSm),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _semesterLabel(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13, color: context.textPrimary),
                        ),
                      ),
                      Icon(Icons.expand_more,
                          size: 18, color: context.textTertiary),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: Gaps.s),
            GestureDetector(
              onTap: _refreshing ? null : _refreshAll,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: context.brandSoftColor,
                  borderRadius: BorderRadius.circular(Gaps.radiusSm),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (_refreshing)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: context.brandColor,
                        ),
                      )
                    else
                      Icon(Icons.refresh, size: 15, color: context.brandColor),
                    const SizedBox(width: 4),
                    Text('刷新',
                        style: TextStyle(
                            fontSize: 12, color: context.brandColor)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  String _semesterLabel() {
    if (_semester.isEmpty) {
      return '选择学期';
    }
    for (final ChoiceItem s in _semesters) {
      if (s.value == _semester) {
        return s.label;
      }
    }
    return _semester;
  }

  Widget _sectionTable(BuildContext context, List<String> lines) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gaps.m),
        decoration: BoxDecoration(
          color: context.surfaceVariant,
          borderRadius: BorderRadius.circular(Gaps.radiusSm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('日常教学时刻表',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                )),
            const SizedBox(height: 6),
            for (final String line in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 13,
                    // 课间休息弱化显示：它是说明，不是可上课的节次
                    color: line.contains('课间')
                        ? context.textTertiary
                        : context.textSecondary,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Text('此处为学校官方的作息时刻；「设置 → 节次作息」可本地微调，上课提醒按该值计算。',
                style: TextStyle(fontSize: 11, color: context.textTertiary)),
          ],
        ),
      );

  Widget _closeBar(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gaps.l, Gaps.s, Gaps.l, Gaps.m),
          child: SizedBox(
            width: double.infinity,
            height: 46,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                // 半透明而非实色：玻璃面板上再放实色块会显得突兀
                backgroundColor: context.surfaceColor.withValues(alpha: 0.35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Gaps.radiusSm),
                ),
              ),
              child: Text('关闭',
                  style: TextStyle(
                    fontSize: 15,
                    color: context.textPrimary,
                  )),
            ),
          ),
        ),
      );
}
