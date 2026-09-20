/// 成绩页
///
/// 从鸿蒙版 `pages/ScorePage.ets` 移植。
///
/// 一条产品决定：**筛选栏在空数据时也要显示**。
/// 早期版本把筛选栏挂在「有数据」的条件下，导致没有成绩的学期整页空白，
/// 用户以为界面坏了、也没法切回别的学期。
///
/// ===== 两个缓存 key =====
/// 学期下拉（`score_semesters`）与成绩列表（`score_list`）分别缓存，
/// 且成绩列表的 key 带**学期**作为变体：每个学期的成绩互相独立，
/// 切回看过的学期能直接出结果。学期下拉单独缓存是因为它几乎不变
/// （一学期才多一条），没必要每次进页面都拉一遍。
library;

import 'package:flutter/material.dart';

import '../common/constants.dart';
import '../data/app_state.dart';
import '../data/re_auth_service.dart';
import '../data/page_cache.dart';
import '../data/pref_store.dart';
import '../model/models.dart';
import '../parser/score_parser.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import '../widgets/app_refresh.dart';
import '../widgets/glass_picker.dart';
import '../widgets/glass_picker_field.dart';
import '../widgets/state_views.dart';

class ScorePage extends StatefulWidget {
  const ScorePage({super.key});

  @override
  State<ScorePage> createState() => _ScorePageState();
}

class _ScorePageState extends State<ScorePage> {
  final AppState _app = AppState.instance;
  final TextEditingController _search = TextEditingController();

  /// 筛选栏是否收起（随滚动方向切换）
  bool _filterHidden = false;

  /// 筛选栏高度（含内边距）。列表要给浮层让出这段空间。
  static const double _filterHeight = 60;

  /// 上一次滚动位置，用于判断方向
  double _lastOffset = 0;

  final ScrollController _scrollCtrl = ScrollController();

  /// 按滚动方向显示/隐藏筛选栏。
  ///
  /// 判定带一点滞后（阈值 6px）：手指微抖会频繁翻转方向，
  /// 不加阈值时筛选栏会跟着抖，比一直显示更烦人。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) {
      return;
    }
    final double off = _scrollCtrl.offset;
    final double delta = off - _lastOffset;
    if (delta.abs() < 6) {
      return;
    }
    _lastOffset = off;
    // 顶部附近始终显示：刚进页面或回滚到顶时，筛选栏应当在
    final bool shouldHide = delta > 0 && off > 24;
    if (shouldHide != _filterHidden && mounted) {
      setState(() => _filterHidden = shouldHide);
    }
  }

  bool _loading = true;
  String _error = '';
  String _semester = '';
  List<ScoreRecord> _records = <ScoreRecord>[];
  List<ChoiceItem> _semesters = <ChoiceItem>[];

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _semester = PrefStore.loadLastScoreSemester();
    // 先用内存缓存填首帧，再决定要不要联网（避免切页回来闪加载态）
    _records = _listLoader().peek() ?? <ScoreRecord>[];
    _semesters = _semesterLoader().peek() ?? <ChoiceItem>[];
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _search.dispose();
    super.dispose();
  }

  /// 成绩列表的加载器。key 带学期作变体，各学期独立缓存。
  ///
  /// 每次现取（不缓存字段）：账号或学期变了 key 就得变，
  /// 留在字段里会出现「切了学期还在读上一个学期的缓存」这类错位。
  PageDataLoader<List<ScoreRecord>> _listLoader() => PageDataLoader<List<ScoreRecord>>(
        key: PageCache.keyOf(
            AppState.instance.account, kCacheScoreList, <String>[_semester]),
        fetch: () => _app.api.getScoresHtml(_semester),
        parse: ScoreParser.parse,
        ttl: kTtlScoreList,
      );

  /// 学期下拉的加载器（不带学期变体：它本身就是「所有学期」）
  PageDataLoader<List<ChoiceItem>> _semesterLoader() =>
      PageDataLoader<List<ChoiceItem>>(
        key: PageCache.keyOf(AppState.instance.account, kCacheScoreSemesters),
        fetch: _app.api.getScoreSemestersHtml,
        parse: ScoreParser.readSemesters,
        ttl: kTtlScoreSemesters,
      );

  Future<void> _load({bool interactive = false, bool force = false}) async {
    // 用户点导航进来的首次加载同样算「主动操作」：
    // 否则会话失效时只会给一句内联提示，逼迫用户再点一次「重试」。
    // 标记是一次性的（取走即清零），冷启动不受影响。
    interactive = interactive || ReAuthService.consumeUserIntent();
    // 已有内容时不铺整屏加载态：切页回来该立刻看到旧数据，新数据到了再替换
    setState(() {
      _error = '';
      if (_records.isEmpty && _semesters.isEmpty) {
        _loading = true;
      }
    });
    try {
      // 学期下拉失败不致命：成绩列表才是这一页的主体，
      // 拿不到学期列表顶多是筛选器少几个选项、切不了学期。
      List<ChoiceItem> sems;
      try {
        sems = (await _semesterLoader().load(force: force)).data;
      } catch (_) {
        sems = _semesters;
      }
      final List<ScoreRecord> recs =
          (await _listLoader().load(force: force)).data;
      if (!mounted) {
        return;
      }
      setState(() {
        _semesters = sems;
        // 本地已有数据时，网络返回空结果**不覆盖**：
        // 这多半是服务端那次查询异常（而不是「成绩被删了」），
        // 清空会让用户以为数据丢了。
        // 真没有成绩的学期，本来就不会有缓存，走的也是这条 else 之外的分支。
        if (recs.isNotEmpty || _records.isEmpty) {
          _records = recs;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      // 会话失效时**先尝试静默续期**（用已保存的账号密码 + OCR 自动登录），
      // 成功就直接重载，用户完全无感；只有续期也失败才置弹窗标记。
      final bool renewed = await ReAuthService.handlePageError(e, (String msg) {
        setState(() {
          _loading = false;
          _error = msg;
        });
      }, interactive: interactive);
      if (renewed && mounted) {
        await _load(force: force);
      }
    }
  }

  List<ScoreRecord> get _filtered {
    final String q = _search.text.trim().toLowerCase();
    if (q.isEmpty) {
      return _records;
    }
    return _records
        .where((ScoreRecord r) =>
            r.courseName.toLowerCase().contains(q) ||
            r.courseCode.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final ScoreSummary sum = ScoreParser.summarize(_records);
    return Column(
      children: <Widget>[
        _summaryBar(sum),
        // 筛选栏**浮在列表之上**，随滚动方向显示/隐藏：
        // 上滑（看后面的课）收起，下滑（回看）弹出。
        //
        // 用 Stack 而不是 Column：[Column] 里筛选栏占着固定高度，
        // 隐藏时那块空间会空出来（内容跳动）；浮层则是列表从它下面穿过，
        // 收起时列表自然铺满，视觉上连续。
        Expanded(
          child: Stack(
            children: <Widget>[
              // 列表本身**占满整个视口**（不再用 Padding 把视口往下推）。
              //
              // 早先这里包了一层 `Padding(top: _filterHeight)`，那是在给
              // **视口**加内边距 —— 列表被整体下移并裁在 y=60 以下，内容
              // 永远不可能出现在筛选栏底下，于是「透过玻璃看见下方课程」
              // 无从谈起（玻璃再透也没东西可透）。
              //
              // 让位改由列表自己的 `padding.top` 承担（见 _body）：ListView
              // 的内边距随内容滚动，因此首项仍然从栏下开始，而后续课程行
              // 会滚到栏底下、透过玻璃可见。
              //
              // 下拉刷新包在**列表之外、Stack 之内**：筛选栏与统计条不该
              // 跟着被下拉，只有列表内容应该。
              //
              // topInset 取筛选栏高度：本页由外壳补的顶部让位（不在
              // shell.dart 的 pageHandlesTopInset 名单里），指示器落点应当
              // 在筛选栏**下方**，否则会压在筛选栏上。
              AppRefresh(
                onRefresh: () => _load(force: true),
                topInset: _filterHeight + Gaps.s,
                child: _body(),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                left: 0,
                right: 0,
                // 收起时整条移出视口上沿
                top: _filterHidden ? -_filterHeight - 8 : 0,
                child: _filterBar(),
              ),
            ],
          ),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(Gaps.m),
            child: Text(_error,
                style: TextStyle(fontSize: 12, color: context.dangerColor)),
          ),
      ],
    );
  }

  Widget _summaryBar(ScoreSummary sum) {
    Widget cell(String value, String label) => Expanded(
          child: Column(
            children: <Widget>[
              Text(value,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  )),
              Text(label,
                  style: TextStyle(fontSize: 11, color: context.textTertiary)),
            ],
          ),
        );
    return Container(
      // 与页面底色统一（原来是白色，与页背景拼出两种色块）
      color: context.schedBgColor,
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: <Widget>[
          cell('${sum.count}', '门课程'),
          cell(sum.totalCredit.toStringAsFixed(
                  sum.totalCredit == sum.totalCredit.roundToDouble() ? 0 : 1),
              '总学分'),
          cell(sum.weightedGpa.toStringAsFixed(3), '加权绩点'),
        ],
      ),
    );
  }

  /// 学期下拉的显示文案
  String _semesterLabel() {
    if (_semester.isEmpty) {
      return '全部学期';
    }
    for (final ChoiceItem s in _semesters) {
      if (s.value == _semester) {
        return s.label;
      }
    }
    return _semester;
  }

  /// 打开学期滚轮
  Future<void> _pickSemester() async {
    final List<GlassOption<String>> opts = <GlassOption<String>>[
      const GlassOption<String>('', '全部学期'),
      for (final ChoiceItem s in _semesters)
        GlassOption<String>(s.value, s.label),
    ];
    final String? v = await showGlassPicker<String>(
      context,
      title: '选择学期',
      current: _semester,
      options: opts,
    );
    if (v == null || v == _semester || !mounted) {
      return;
    }
    setState(() => _semester = v);
    await PrefStore.saveLastScoreSemester(v);
    // 切学期是用户主动操作：失败时可以直接弹重新验证
    await _load(interactive: true);
  }

  Widget _filterBar() {
    // 与下方课程行**同一等级**的玻璃：都用 listCard（minimal 档）。
    //
    // 早先用 toolbar（整条通栏、圆角不同），视觉上比课程行「高一级」，
    // 显得像个独立栏；改成与课程行同档后，它就是「浮在列表上的第一行」。
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gaps.page, 4, Gaps.page, 6),
      child: SectionCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: <Widget>[
            // 学期只给 2 份宽度、搜索框给 3 份。
            //
            // 反过来（学期 3 / 搜索 2）时，学期那个选择器占了一大截，
            // 而它显示的只是「2026-2027-1」这种定长文本，宽度用不完；
            // 搜索框却是**要输入**的，越宽越好用。真机上后者被压到
            // 只剩几个字的位置，输入体验很差。
            Expanded(
              flex: 2,
              // 学期选择：点开居中玻璃滚轮（与其他页统一）。
              // dense 让它与右侧搜索框严格等高。
              child: GlassPickerField(
                label: '',
                compact: true,
                dense: true,
                // 居中：这个框比右侧搜索框窄（flex 2 vs 3），
                // 靠左会让「全部学期」贴着左边、右侧空一大块
                centered: true,
                value: _semesterLabel(),
                onTap: _pickSemester,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              // 搜索框也做成药丸玻璃，与学期选择器成一套
              child: GlassKit.fieldBackdrop(
                context,
                child: Container(
                  height: GlassKit.topBarControlH,
                  alignment: Alignment.centerLeft,
                  child: TextField(
                    controller: _search,
                    style: TextStyle(
                      fontSize: GlassKit.topBarControlFs,
                      color: context.textPrimary,
                    ),
                    cursorColor: context.brandColor,
                    decoration: InputDecoration(
                      isDense: true,
                      // 同 course_editor 的说明：外层是药丸底衬，
                      // 这里再画一层方角填充会把药丸的形状盖掉。
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      hintText: '搜索课程名/编号',
                      // placeholder 提到 Secondary：压在玻璃上时
                      // Tertiary 的灰几乎看不见
                      hintStyle: TextStyle(
                        fontSize: GlassKit.topBarControlFs,
                        color: context.textSecondary.withValues(alpha: 0.75),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const RefreshableFill(child: LoadingView(message: '正在获取成绩…'));
    }
    if (_records.isEmpty) {
      // 空态也要能下拉刷新：没有成绩时用户最可能想再试一次
      return RefreshableFill(
        child: EmptyView(
          title: _error.isEmpty ? '暂无成绩数据' : _error,
        ),
      );
    }
    final List<ScoreRecord> list = _filtered;
    if (list.isEmpty) {
      return const RefreshableFill(child: EmptyView(title: '没有匹配的课程'));
    }
    return ListView.separated(
      controller: _scrollCtrl,
      // 内容不满一屏也要能下拉刷新（否则成绩少的时候拉不动）
      physics: const AlwaysScrollableScrollPhysics(),
      // 顶部：给浮层筛选栏让出高度（+ 常规页边距），使首项从栏下开始；
      // 这部分内边距**随内容滚动**，所以往下滚时课程行会升到筛选栏底下
      // 并被玻璃透出来 —— 这正是「栏底透明、能看见下方内容」的实现方式。
      //
      // 底部：额外留出玻璃导航栏的高度（extendBody 后内容会滚到 dock
      // 下面，不留这段空白最后一项会被玻璃压住）。
      padding: EdgeInsets.fromLTRB(
          Gaps.page, _filterHeight + Gaps.page, Gaps.page,
          Gaps.page + Gaps.scrollTail),
      itemCount: list.length,
      separatorBuilder: (BuildContext _, int _) => const SizedBox(height: 8),
      itemBuilder: (BuildContext ctx, int i) => _row(list[i]),
    );
  }

  Widget _row(ScoreRecord r) {
    return SectionCard(
      padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(r.courseName,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    )),
                const SizedBox(height: 3),
                Row(
                  children: <Widget>[
                    Text(r.semester,
                        style: TextStyle(
                            fontSize: 11, color: context.textTertiary)),
                    if (r.courseNature.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: context.surfaceVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(r.courseNature,
                            style: TextStyle(
                                fontSize: 10, color: context.textSecondary)),
                      ),
                    ],
                    if (r.credit.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 6),
                      Text('${r.credit} 学分',
                          style: TextStyle(
                              fontSize: 11, color: context.textTertiary)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                r.score,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: r.isFail ? context.dangerColor : context.textPrimary,
                ),
              ),
              if (r.gpa.isNotEmpty)
                Text('${r.gpa} 绩点',
                    style:
                        TextStyle(fontSize: 10, color: context.textTertiary)),
            ],
          ),
        ],
      ),
    );
  }
}
