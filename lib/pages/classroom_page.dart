/// 空教室查询页
///
/// 从鸿蒙版 `pages/ClassroomPage.ets` 移植。
///
/// 交互：**全部自动查询，没有「查询」按钮** —— 改任一条件就立刻重新请求。
/// 理由：教室占用是实时变化的（借用记录随时被编辑，实测几分钟内结果就不同），
/// 所以「重新请求」本身就是刷新数据的一部分，不该要求用户再点一次。
///
/// 周次过滤在客户端做（原因见 `model/classroom_models.dart` 顶部说明）。
///
/// ===== 缓存与「点了就重新请求」并不矛盾 =====
/// 这里有三类触发，之前都会被当成「必须联网」：
///   1. 改学期/校区/教学楼/节次 —— 改的是**查询条件**，key 变了就是换数据，
///      联网合理（而且切回上一个条件时能命中缓存）；
///   2. 点星期几 —— **查询条件没变**。服务端返回的本来就是全周占用，
///      换一天只是换客户端读哪一列。之前却重发了一次请求，拿回一模一样的
///      文本再解析一遍；
///   3. 切 dock 进来 —— 见文件顶部的说明。
/// 第 2 类现在直接命中缓存（TTL 见 [kTtlClassroomUsage]），
/// 数据的实时性由 TTL 保证：超过 2 分钟再点任何条件都会真的联网。
library;

import 'package:flutter/material.dart';
// ScrollCacheExtent 只从 rendering 导出（material 不再转出它）
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../common/constants.dart';
import '../data/app_state.dart';
import '../data/page_cache.dart';
import '../data/re_auth_service.dart';
import '../model/classroom_models.dart';
import '../model/models.dart';
import '../network/qz_api.dart';
import '../parser/classroom_parser.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import '../widgets/app_refresh.dart';
import '../widgets/glass_picker.dart';
import '../widgets/glass_picker_field.dart';
import '../widgets/state_views.dart';

class ClassroomPage extends StatefulWidget {
  const ClassroomPage({super.key});

  @override
  State<ClassroomPage> createState() => _ClassroomPageState();
}

class _ClassroomPageState extends State<ClassroomPage> {
  final AppState _app = AppState.instance;

  bool _loading = true;
  bool _busy = false;
  String _error = '';

  List<String> _campuses = <String>[];
  List<String> _semesters = <String>[];
  List<ChoiceItem> _buildings = <ChoiceItem>[];

  String _semester = '';
  String _campus = '';
  String _building = '';
  int _sectionRow = 0;
  int _week = 1;
  int _day = 0;

  ClassroomResult? _result;

  /// 请求序号：只接受最新一次请求的结果，丢弃过期响应。
  ///
  /// 快速连点星期时会有多个请求在飞，若不加这个判断，
  /// 先发后到的旧结果会覆盖新结果（界面看起来「点了没反应」）。
  int _seq = 0;

  // 记忆化：输入不变就不重算
  List<FreeRoom>? _memoFree;
  int _memoFreeKey = -1;
  List<DayFreeStat>? _memoStats;
  int _memoStatsKey = -1;

  @override
  void initState() {
    super.initState();
    _day = DateTime.now().weekday - 1;
    _week = _app.currentWeek > 0 ? _app.currentWeek : 1;
    _bootstrap();
  }

  Future<void> _bootstrap({bool interactive = false}) async {
    // 用户点导航进来的首次加载同样算「主动操作」（同其它页面，见
    // ReAuthService.noteUserIntent）：会话失效时直接续期，
    // 而不是只给一句提示、逼用户再点一次。
    interactive = interactive || ReAuthService.consumeUserIntent();
    setState(() {
      _error = '';
      if (_campuses.isEmpty) {
        _loading = true;
      }
    });
    try {
      // 校区与学期列表（几乎不变的元数据，缓存 6 小时）
      final ClassroomOptions opts =
          (await _optionsLoader().load()).data;
      if (!mounted) {
        return;
      }
      String campus = opts.campuses.isNotEmpty ? opts.campuses.first : '';
      // 优先选章丘校区
      for (final String c in opts.campuses) {
        if (c.contains('章丘')) {
          campus = c;
          break;
        }
      }
      String semester = '';
      final String ttSemester = _app.timetable?.semester ?? '';
      if (ttSemester.isNotEmpty && opts.semesters.contains(ttSemester)) {
        semester = ttSemester;
      } else if (opts.semesters.isNotEmpty) {
        semester = opts.semesters.first;
      }
      setState(() {
        _campuses = opts.campuses;
        _semesters = opts.semesters;
        // 已经在页面上选过条件的（比如切页返回），保留用户的选择，
        // 不要被「默认选章丘」覆盖掉
        if (_campus.isEmpty || !opts.campuses.contains(_campus)) {
          _campus = campus;
        }
        if (_semester.isEmpty || !opts.semesters.contains(_semester)) {
          _semester = semester;
        }
      });
      await _loadBuildings();
      await _search(interactive: interactive);
    } catch (e) {
      if (!mounted) {
        return;
      }
      // 会话失效：先静默续期，成功则重跑初始化。
      // interactive 决定失败时是否弹重新验证：首次自动进入本页只给内联提示。
      final bool renewed = await ReAuthService.handlePageError(e, (String msg) {
        setState(() {
          _loading = false;
          _error = msg;
        });
      }, interactive: interactive);
      if (renewed && mounted) {
        await _bootstrap(interactive: interactive);
      }
    }
  }

  /// 校区/学期列表的加载器（与查询条件无关，全账号一份）
  PageDataLoader<ClassroomOptions> _optionsLoader() =>
      PageDataLoader<ClassroomOptions>(
        key: PageCache.keyOf(AppState.instance.account, kCacheClassroomOptions),
        fetch: _app.api.getClassroomOptionsHtml,
        parse: QzApi.parseClassroomOptions,
        ttl: kTtlClassroomOptions,
      );

  /// 某校区教学楼列表的加载器（key 带校区作变体）
  PageDataLoader<List<ChoiceItem>> _buildingsLoader(String campusId) =>
      PageDataLoader<List<ChoiceItem>>(
        key: PageCache.keyOf(
            AppState.instance.account, kCacheClassroomBuildings, <String>[campusId]),
        fetch: () => _app.api.getBuildingsHtml(campusId),
        parse: QzApi.parseBuildings,
        ttl: kTtlClassroomBuildings,
      );

  /// 占用情况的加载器。
  ///
  /// key 带**全部查询条件**作变体（含节次）：不同条件返回的是不同表格，
  /// 混用会让用户看到别的条件的教室。星期与周次**不进 key** ——
  /// 服务端返回的本来就是整个学期的全周占用，那两项只是客户端读哪一列的选择。
  PageDataLoader<ClassroomResult> _usageLoader() => PageDataLoader<ClassroomResult>(
        key: PageCache.keyOf(AppState.instance.account, kCacheClassroomUsage, <String>[
          _semester,
          _campus.split('|').first,
          _building,
          '$_sectionRow',
        ]),
        fetch: () => _app.api.getClassroomUsageHtml(
            _semester, _campus.split('|').first, _building, _sectionRow),
        parse: (String html) => ClassroomParser.parseResult(html, _sectionRow),
        ttl: kTtlClassroomUsage,
      );

  Future<void> _loadBuildings() async {
    if (_campus.isEmpty) {
      return;
    }
    final String campusId = _campus.split('|').first;
    try {
      final List<ChoiceItem> list = (await _buildingsLoader(campusId).load()).data;
      if (!mounted) {
        return;
      }
      setState(() {
        _buildings = list;
        // 换校区后原教学楼可能不存在，回到「全部」
        final bool stillValid =
            list.any((ChoiceItem b) => b.value == _building);
        if (!stillValid) {
          _building = '';
        }
      });
    } catch (_) {
      // 教学楼列表取不到不阻塞主流程
    }
  }

  Future<void> _search({bool interactive = false, bool force = false}) async {
    if (_semester.isEmpty || _campus.isEmpty) {
      setState(() {
        _loading = false;
        _error = _semesters.isEmpty ? '请先选择学期' : '';
      });
      return;
    }
    final int mySeq = ++_seq;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final ClassroomResult r = (await _usageLoader().load(force: force)).data;
      if (!mounted || mySeq != _seq) {
        // 过期响应：丢弃
        return;
      }
      setState(() {
        _result = r;
        _busy = false;
        _loading = false;
        _memoFree = null;
        _memoStats = null;
      });
    } catch (e) {
      if (!mounted || mySeq != _seq) {
        return;
      }
      // 会话失效：先静默续期，成功则重发这一次查询。
      // 查询通常由用户点「查询」或切校区触发，因此这里多半是主动路径。
      final bool renewed = await ReAuthService.handlePageError(e, (String msg) {
        setState(() {
          _busy = false;
          _loading = false;
          _error = msg;
        });
      }, interactive: interactive);
      if (renewed && mounted) {
        await _search(interactive: interactive, force: force);
      }
    }
  }

  List<FreeRoom> _freeRooms() {
    final ClassroomResult? r = _result;
    if (r == null) {
      return <FreeRoom>[];
    }
    final int key = _day * 1000 + _week;
    if (_memoFreeKey == key && _memoFree != null) {
      return _memoFree!;
    }
    final List<FreeRoom> list = ClassroomFinder.freeRooms(r, _day, _week);
    _memoFree = list;
    _memoFreeKey = key;
    return list;
  }

  List<DayFreeStat> _weekStats() {
    final ClassroomResult? r = _result;
    if (r == null) {
      return <DayFreeStat>[];
    }
    if (_memoStatsKey == _week && _memoStats != null) {
      return _memoStats!;
    }
    final List<DayFreeStat> list = ClassroomFinder.weekStats(r, _week);
    _memoStats = list;
    _memoStatsKey = _week;
    return list;
  }

  @override
  Widget build(BuildContext context) {
    // **筛选控件始终先显示、再谈加载**。
    //
    // 早先是「没加载完就连控件都不画」（`if (_loading) return LoadingView`），
    // 用户进页面先看到一整屏的加载提示、等数据回来控件才冒出来 ——
    // 顺序反了。现在控件是常驻的骨架，加载状态只填在控件下方：
    // 即使数据还没到，用户也能先看到有哪些条件可选。
    return Column(
      children: <Widget>[
        _filters(),
        if (_busy || _loading)
          const LinearProgressIndicator(minHeight: 2)
        else
          const SizedBox(height: 2),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _filters() {
    // 药丸玻璃筛选栏：与页面里的卡片同一档玻璃（listCard），
    // 而不是 toolbar —— 后者是通栏样式，与「一张张卡片」的列表不同级，
    // 也是用户反馈「药丸框颜色与背景不统一」的来源。
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gaps.page, 8, Gaps.page, 6),
      child: GlassKit.listCard(
        context,
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: _dropdown('学期', _semester, _semesters, (String v) async {
                setState(() => _semester = v);
                await _search(interactive: true);
              })),
              const SizedBox(width: 8),
              Expanded(
                child: _dropdown(
                  '校区',
                  _campus,
                  _campuses,
                  (String v) async {
                    setState(() => _campus = v);
                    await _loadBuildings();
                    await _search(interactive: true);
                  },
                  labels: <String, String>{
                    for (final String c in _campuses)
                      c: c.contains('|') ? c.split('|').last : c,
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: _dropdown(
                  '教学楼',
                  _building,
                  _buildings.map((ChoiceItem b) => b.value).toList(),
                  (String v) async {
                    setState(() => _building = v);
                    await _search(interactive: true);
                  },
                  labels: <String, String>{
                    for (final ChoiceItem b in _buildings) b.value: b.label,
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _dropdown(
                  '节次',
                  '$_sectionRow',
                  List<String>.generate(5, (int i) => '$i'),
                  (String v) async {
                    setState(() => _sectionRow = int.tryParse(v) ?? 0);
                    await _search(interactive: true);
                  },
                  labels: <String, String>{
                    for (int i = 0; i < 5; i++) '$i': '第${i + 1}节次',
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: _dropdown(
                  '周次',
                  '$_week',
                  List<String>.generate(30, (int i) => '${i + 1}'),
                  (String v) async {
                    setState(() {
                      _week = int.tryParse(v) ?? 1;
                      _memoFree = null;
                      _memoStats = null;
                    });
                    await _search(interactive: true);
                  },
                  labels: <String, String>{
                    for (int i = 1; i <= 30; i++)
                      '$i': '第 $i 周${i == _app.currentWeek ? '（本周）' : ''}',
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 星期行：既是选择器，也是「本周空闲速览」
          Row(
            children: <Widget>[
              for (int d = 0; d < 7; d++) Expanded(child: _dayCell(d)),
            ],
          ),
        ],
        ),
      ),
    );
  }

  Widget _dropdown(
    String label,
    String value,
    List<String> values,
    ValueChanged<String> onChanged, {
    Map<String, String>? labels,
  }) {
    if (values.isEmpty) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        child: Text('暂无',
            style: TextStyle(fontSize: 13, color: context.textTertiary)),
      );
    }
    final String safe = values.contains(value) ? value : values.first;
    String show(String v) => labels != null ? (labels[v] ?? v) : v;
    // 全部下拉统一走居中玻璃滚轮（学期 / 校区 / 教学楼 / 节次…）
    return GlassPickerField(
      label: label,
      compact: true,
      dense: true,
      value: show(safe),
      onTap: () async {
        final String? v = await showGlassPicker<String>(
          context,
          title: label.isEmpty ? '请选择' : '选择$label',
          current: safe,
          options: <GlassOption<String>>[
            for (final String x in values) GlassOption<String>(x, show(x)),
          ],
        );
        if (v != null && v != value) {
          onChanged(v);
        }
      },
    );
  }

  Widget _dayCell(int day) {
    final List<DayFreeStat> stats = _weekStats();
    final bool selected = day == _day;
    final bool isToday = day == DateTime.now().weekday - 1;
    int? free;
    for (final DayFreeStat s in stats) {
      if (s.day == day) {
        free = s.free;
      }
    }
    return GestureDetector(
      onTap: () {
        // 换一天**不需要联网**：服务端返回的是全周占用，换天只是换读哪一列。
        // 之前这里会重发一次请求、拿回一模一样的文本再解析一遍
        // （数据实时性由 TTL 保证，见文件头）。
        setState(() => _day = day);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: selected ? context.brandColor : context.surfaceVariant,
          borderRadius: BorderRadius.circular(Gaps.radiusSm),
          border: (!selected && isToday)
              ? Border.all(color: context.brandColor, width: 1)
              : null,
        ),
        child: Column(
          children: <Widget>[
            Text(
              ClassroomFinder.dayLabel(day).replaceFirst('周', '周'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? context.brandColor == context.brandColor
                    ? Theme.of(context).colorScheme.onPrimary
                    : context.textPrimary
                    : context.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              free == null ? (isToday ? '今天' : '—') : '$free',
              style: TextStyle(
                fontSize: 10,
                color: selected
                    ? Theme.of(context).colorScheme.onPrimary
                    : context.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    // 本页由外壳补的顶部让位（不在 shell.dart 的 pageHandlesTopInset 名单里），
    // 而且筛选卡片就在本组件上方 —— 指示器落在本区域顶部即可，不能再用
    // 默认的 appBarInset（那会把它推到筛选卡片中间）。
    const double rest = Gaps.m;
    if (_error.isNotEmpty) {
      return AppRefresh(
        onRefresh: () => _search(force: true),
        topInset: rest,
        child: RefreshableFill(
          child: ErrorView(message: _error, onRetry: () => _search(interactive: true, force: true)),
        ),
      );
    }
    final ClassroomResult? r = _result;
    // 数据还没回来：这里只占位，控件已经在上面正常显示了
    if (r == null) {
      return const RefreshableFill(child: LoadingView(message: '正在查询空闲教室…'));
    }
    if (r.rooms.isEmpty) {
      return AppRefresh(
        onRefresh: () => _search(force: true),
        topInset: rest,
        child: const RefreshableFill(
          child: EmptyView(
            title: '没有查到教室',
            hint: '该条件下没有教室数据，可换教学楼或节次再试',
          ),
        ),
      );
    }
    final List<FreeRoom> free = _freeRooms();
    final List<FreeRoom> busy = ClassroomFinder.busyRooms(r, _day, _week);
    final SectionDef section = kSections[_sectionRow];

    // 按教学楼分组
    final Map<String, List<FreeRoom>> grouped = <String, List<FreeRoom>>{};
    for (final FreeRoom f in free) {
      grouped.putIfAbsent(f.building, () => <FreeRoom>[]).add(f);
    }
    final List<String> buildings = grouped.keys.toList()
      ..sort((String a, String b) =>
          ClassroomFinder.compareRoom(a, b));

    // ===== 卡顿的根因与修法 =====
    // 早先是「一个 `ListView(children:)` + **每个教室一个小玻璃块**」。
    // 两个问题叠加：
    //   1. `ListView(children:)` **不是懒的** —— 它一次性构建全部子节点。
    //      本机实测某天有 159 间空闲教室，就一次性建 159 个块；
    //   2. 每个块都是一个 `AdaptiveGlass`（跑一遍玻璃着色器）。
    //      159 个着色器实例同时合成 = 明显掉帧。
    //
    // 现在两项一起改：
    //   - 用 `ListView.builder` 按「组」懒构建，视口外不建；
    //   - 玻璃下沉到**组**这一层（每个教学楼一张卡片，通常 5–8 张），
    //     教室只是卡片里的文字。玻璃数量从 159 降到个位数。
    // 副作用是观感更好：一堆教室聚成一张卡片，比 159 个孤立药丸更像列表。
    //
    // 顺带去掉 `List<Widget>` 的中间层：`itemBuilder` 按 index 取组，
    // 不再先构造整棵子树。
    final int headCount = 2; // 概要行 + 标题行
    final bool hasEmpty = free.isEmpty;
    final int total = headCount + (hasEmpty ? 1 : buildings.length) + 1;

    return AppRefresh(
      onRefresh: () => _search(force: true),
      topInset: rest,
      child: ListView.builder(
        // 内容不满一屏也要能下拉刷新
        physics: const AlwaysScrollableScrollPhysics(),
        // 底部额外留出玻璃导航栏的高度：extendBody 后内容会滚到 dock 下面，
        // 不留这段空白最后一项会被玻璃压住
        padding: const EdgeInsets.fromLTRB(
            Gaps.page, Gaps.page, Gaps.page, Gaps.page + Gaps.scrollTail),
        // 多留一屏缓存：滚动时下一组已就绪，不会滑到一半才出现
        scrollCacheExtent: const ScrollCacheExtent.viewport(1.0),
        itemCount: total,
        itemBuilder: (BuildContext ctx, int i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '共 ${r.rooms.length} 间教室，${section.label}，第 $_week 周',
                style: TextStyle(fontSize: 12, color: context.textTertiary),
              ),
            );
          }
          if (i == 1) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: <Widget>[
                  Text('${ClassroomFinder.dayLabel(_day)} 空闲教室',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      )),
                  const Spacer(),
                  Text('${free.length} 间',
                      style: TextStyle(fontSize: 13, color: context.brandColor)),
                ],
              ),
            );
          }
          if (hasEmpty) {
            if (i == 2) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: EmptyView(title: '该时段没有空闲教室'),
              );
            }
            return _busyFooter(busy);
          }
          final int gi = i - headCount;
          if (gi < buildings.length) {
            return _buildingCard(buildings[gi], grouped[buildings[gi]]!);
          }
          return _busyFooter(busy);
        },
      ),
    );
  }

  /// 一个教学楼一张玻璃卡片，教室在卡片内以药丸文字排布。
  Widget _buildingCard(String building, List<FreeRoom> rooms) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SectionCard(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('$building（${rooms.length}）',
                style: TextStyle(
                    fontSize: 12, color: context.textSecondary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final FreeRoom f in rooms)
                  // 教室本身不再各自一层玻璃（那样又回到 159 个着色器），
                  // 只用极淡的底色块区分边界 —— 材质由外层卡片提供。
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: context.surfaceVariant.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      f.room.contains('(') ? f.room.split('(').first : f.room,
                      style: TextStyle(
                          fontSize: 12, color: context.textPrimary),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _busyFooter(List<FreeRoom> busy) {
    if (busy.isEmpty) {
      return const SizedBox(height: 8);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '该时段有 ${busy.length} 间教室在上课或已被借用',
        style: TextStyle(fontSize: 11, color: context.textTertiary),
      ),
    );
  }
}
