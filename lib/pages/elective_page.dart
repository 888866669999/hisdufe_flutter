/// 通选课修读情况页
///
/// 从鸿蒙版 `pages/ElectivePage.ets` 移植。
///
/// 一个必须保留的判断：学校**留空了「要求学分」**（实测页面如此）。
/// 此时不能显示「未达标」（会让人以为要补修），而要如实说
/// 「学校未设置要求」，并且**不画进度条**（没有分母，画出来的长度没有意义）。
///
/// 展示方式：学校原页面是「类别汇总表」+「课程明细表」两张独立表格，
/// 学生要自己在两张表之间对类别名。这里改为 **大类 → 具体课程** 的分组列表：
/// 大类行带修读要求与达标状态，点开才列出该大类下的课程（默认全部收起），
/// 这样一屏能先看清「哪些大类还差学分」，再按需展开明细。
library;

import 'package:flutter/material.dart';

import '../common/constants.dart';
import '../data/app_state.dart';
import '../data/elective_requirement_store.dart';
import '../data/page_cache.dart';
import '../data/re_auth_service.dart';
import '../model/models.dart';
import '../parser/elective_parser.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import '../widgets/app_refresh.dart';
import '../widgets/requirement_editor_dialog.dart';
import '../widgets/state_views.dart';
import '../widgets/top_fade_blur.dart';

class ElectivePage extends StatefulWidget {
  const ElectivePage({super.key});

  @override
  State<ElectivePage> createState() => _ElectivePageState();
}

/// 通选课页：大类 → 具体课程。
///
/// 归并逻辑放在 `ElectiveReport.grouped()`（可单测），这里只负责渲染。
class _ElectivePageState extends State<ElectivePage> {
  bool _loading = true;
  String _error = '';
  /// 操作类提示（保存要求学分的结果）。与 _error（加载失败）分开：
  /// 前者是「页面上已有内容，只是刚做的操作没成功」，不该整屏换成错误页。
  String _error2 = '';
  ElectiveReport? _report;

  /// 展开的大类名。默认空 ⇒ 全部收起。
  final Set<String> _expanded = <String>{};

  /// 归并后的大类。
  ///
  /// 存下来而不是每次 build 现算（`r.grouped()`）：用户改过要求学分后要能
  /// **就地更新**这一项并立刻反映到界面，不必为了一个数字再请求一次服务器。
  List<ElectiveGroup> _groups = <ElectiveGroup>[];

  @override
  void initState() {
    super.initState();
    // 先用内存缓存填首帧（归并 + 叠加自录要求一并做完），
    // 再决定要不要联网 —— 切页回来不会闪加载态。
    final ElectiveReport? cached = _loader().peek();
    if (cached != null) {
      _applyCached(cached);
    }
    _load();
  }

  PageDataLoader<ElectiveReport> _loader() => PageDataLoader<ElectiveReport>(
        key: PageCache.keyOf(AppState.instance.account, kCacheElective),
        fetch: AppState.instance.api.getElectiveHtml,
        parse: ElectiveParser.parse,
        ttl: kTtlElective,
      );

  /// 归并 + 叠加用户自录要求，写进页面状态。
  ///
  /// 两件事分开做：`grouped()` 是纯计算（可单测），读本地配置是 IO ——
  /// 混在一起那个纯函数就不纯了。
  void _applyCached(ElectiveReport r) {
    final List<ElectiveGroup> groups = r.grouped();
    _applyCustomRequirements(groups);
    _report = r;
    _groups = groups;
  }

  Future<void> _load({bool interactive = false, bool force = false}) async {
    // 用户点导航进来的首次加载同样算「主动操作」：
    // 否则会话失效时只会给一句内联提示，逼迫用户再点一次「重试」。
    // 标记是一次性的（取走即清零），冷启动不受影响。
    interactive = interactive || ReAuthService.consumeUserIntent();
    setState(() {
      _error = '';
      if (_report == null) {
        _loading = true;
      }
    });
    try {
      final PageLoadResult<ElectiveReport> res = await _loader().load(force: force);
      if (!mounted) {
        return;
      }
      setState(() {
        _applyCached(res.data);
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

  /// 把用户自录的要求学分叠加到分组上。
  ///
  /// 必须在 `grouped()` 之后单独做一步（见 _load 的说明）。
  void _applyCustomRequirements(List<ElectiveGroup> groups) {
    final String account = AppState.instance.account;
    final Map<String, double> saved =
        ElectiveRequirementStore.load(account);
    if (saved.isEmpty) {
      return;
    }
    for (final ElectiveGroup g in groups) {
      final double? v = saved[g.name];
      if (v != null) {
        g.customRequired = v;
      }
    }
  }

  /// 打开「要求学分」编辑弹窗，保存后**就地更新**（不重新联网）。
  Future<void> _editRequirement(ElectiveGroup g) async {
    final RequirementEditResult? r = await showRequirementEditor(
      context,
      category: g.name,
      current: g.requiredNumber,
      hasCustom: g.hasCustomRequired,
    );
    if (r == null || !mounted) {
      return; // 用户取消
    }
    final String account = AppState.instance.account;
    if (account.isEmpty) {
      setState(() => _error2 = '未获取到账号，无法保存');
      return;
    }
    final bool ok = await ElectiveRequirementStore.save(
      account,
      g.name,
      r.isClear ? -1 : r.value,
    );
    if (!mounted) {
      return;
    }
    if (!ok) {
      setState(() => _error2 = '保存失败，请重试');
      return;
    }
    // 就地更新内存里的值，避免为了一个数字再请求一次服务器。
    //
    // 两件事都要做，缺一不可：
    //   1. 改**这个对象**的字段 —— 界面读的是它；
    //   2. 换一个**新列表** —— 只改字段不换列表时，Flutter 侧的可变字段
    //      改动虽然能被 setState 带出去，但保持「结构变化就换新容器」这个
    //      习惯更稳（与课程编辑、课表编辑的持久化路径一致）。
    g.customRequired = r.isClear ? -1 : r.value;
    setState(() {
      _groups = List<ElectiveGroup>.of(_groups);
      _error2 = '';
    });
  }

  /// 去掉无意义的小数尾巴：12.0 显示成 12
  static String _trimNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  /// 大类状态文案。
  ///
  /// **只看 `requiredNumber`**（它已经把「用户自录 > 服务器」的优先级算在内），
  /// 不要再单独判断 `info.hasRequirement` —— 用户自录了要求、而学校那一列是空时，
  /// 那个判断仍会成立，于是状态显示「请设置学分要求」、副标题却已经写着
  /// 「要求 ≥ X」，自相矛盾（实测踩到过）。
  ({String text, Color color}) _status(ElectiveGroup g) {
    // 没有要求时给一句行动指引。
    // 学校那一列实测是空的，「没有要求」是常态而非异常 ——
    // 与其陈述「学校未设置」这个事实，不如告诉用户下一步能做什么。
    final double req = g.requiredNumber;
    if (req < 0) {
      return (text: '请设置学分要求', color: context.brandColor);
    }
    if (g.earnedNumber + g.ongoingNumber >= req) {
      return (text: '已达标', color: context.successColor);
    }
    return (
      text: '还差 ${(req - g.earnedNumber - g.ongoingNumber).toStringAsFixed(1)}',
      color: context.warningColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ElectiveReport? r = _report;
    // 有缓存内容就直接渲染，刷新失败只在列表顶部提示 ——
    // 用户已经看到的数据不该因为一次刷新失败就消失。
    if (r != null && !(r.categories.isEmpty && r.courses.isEmpty)) {
      // 用 _load 里算好的那份（用户改过要求后要能就地更新，见 _editRequirement）
      final List<ElectiveGroup> groups = _groups;
      // 顶部渐变模糊：与培养方案页同一处理（详见 TopFadeBlur 的说明）
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: AppRefresh(
              onRefresh: () => _load(force: true),
              child: _buildList(r, groups),
            ),
          ),
          const TopFadeBlur(),
        ],
      );
    }
    if (_loading) {
      return const RefreshableFill(child: LoadingView(message: '正在获取通选课修读情况…'));
    }
    if (r == null) {
      return AppRefresh(
        onRefresh: () => _load(force: true),
        child: RefreshableFill(
          child: ErrorView(
              message: _error.isEmpty ? '暂无通选课数据' : _error,
              onRetry: () => _load(interactive: true, force: true)),
        ),
      );
    }
    return AppRefresh(
      onRefresh: () => _load(force: true),
      child: const RefreshableFill(child: EmptyView(title: '暂无通选课数据')),
    );
  }

  Widget _buildList(ElectiveReport r, List<ElectiveGroup> groups) {
    return ListView(
      // 内容不满一屏也要能下拉刷新
      physics: const AlwaysScrollableScrollPhysics(),
      // 底部额外留出玻璃导航栏的高度：extendBody 后内容会滚到 dock 下面，
      // 不留这段空白最后一项会被玻璃压住
      // 顶部让位放在**滚动内容**里（不是视口上），因此首项仍从顶栏下
      // 开始，而滚动时内容会经过顶栏区域、被顶部渐变模糊糊掉。
      // 外壳已对这两页跳过它自己的让位，见 shell.dart 的 pageHandlesTopInset。
      padding: EdgeInsets.fromLTRB(Gaps.page, appBarInset(context) + Gaps.page,
          Gaps.page, Gaps.page + Gaps.scrollTail),
      children: <Widget>[
        // 保存结果提示（成功/失败都走这里；可点掉）。
        // 不用 SnackBar：本应用的壳是 GlassScaffold（内部 CupertinoPageScaffold），
        // 树里没有 Material 的 Scaffold，ScaffoldMessenger 无处挂载 ——
        // debug 下抛断言、release 下用户什么也看不到。
        if (_error2.isNotEmpty) ...<Widget>[
          GestureDetector(
            onTap: () => setState(() => _error2 = ''),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: context.brandColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_error2,
                  style: TextStyle(fontSize: 12, color: context.brandColor)),
            ),
          ),
          const SizedBox(height: Gaps.m),
        ],
        // 有缓存内容但这次刷新失败：提示一下，但**不**清掉内容
        if (_error.isNotEmpty) ...<Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: context.warningColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(_error,
                style: TextStyle(fontSize: 12, color: context.textSecondary)),
          ),
          const SizedBox(height: Gaps.m),
        ],
        _summary(r, groups.length),
        const SizedBox(height: Gaps.m),
        for (final ElectiveGroup g in groups) ...<Widget>[
          _groupCard(g),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: Gaps.s),
        Text('点大类标题可展开该大类下的具体课程',
            style: TextStyle(fontSize: 11, color: context.textTertiary)),
      ],
    );
  }

  Widget _summary(ElectiveReport r, int groupCount) {
    Widget cell(String v, String label) => Expanded(
          child: Column(
            children: <Widget>[
              Text(v,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  )),
              Text(label,
                  style: TextStyle(fontSize: 11, color: context.textTertiary)),
            ],
          ),
        );
    return SectionCard(
      child: Row(
        children: <Widget>[
          cell(r.totalEarned.isEmpty ? '—' : r.totalEarned, '已修学分'),
          cell(r.totalOngoing.isEmpty ? '—' : r.totalOngoing, '正在修读'),
          cell('${r.courses.length}', '门课程'),
          cell('$groupCount', '个类别'),
        ],
      ),
    );
  }

  Widget _groupCard(ElectiveGroup g) {
    final ElectiveCategory? c = g.info;
    final ({String text, Color color}) st = _status(g);
    final bool expandable = g.hasCourses;
    final bool open = expandable && _expanded.contains(g.name);

    // 已修/在修/要求 一行。要求学分的来源要标出来：
    // 用户自录的显示为「要求 ≥ X」，学校给了值的显示为「学校要求 ≥ X」，
    // 都没有则只陈述已修/在修（「去设置」的指引交给上方状态位与左侧按钮）。
    final String earned = (c?.earned.isNotEmpty ?? false) ? c!.earned : '0';
    final String ongoing = (c?.ongoing.isNotEmpty ?? false) ? c!.ongoing : '0';
    String sub = '已修 $earned · 在修 $ongoing';
    if (g.hasCustomRequired) {
      sub += ' · 要求 ≥ ${_trimNum(g.requiredNumber)}';
    } else if (g.requiredNumber >= 0) {
      sub += ' · 学校要求 ≥ ${_trimNum(g.requiredNumber)}';
    }

    return SectionCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 标题行整体可点：点击展开/收起具体课程
          InkWell(
            onTap: expandable
                ? () => setState(() {
                      if (open) {
                        _expanded.remove(g.name);
                      } else {
                        _expanded.add(g.name);
                      }
                    })
                : null,
            borderRadius: BorderRadius.circular(Gaps.radius),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gaps.m, Gaps.m, 8, Gaps.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(g.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary,
                            )),
                      ),
                      Text(st.text,
                          style: TextStyle(fontSize: 12, color: st.color)),
                      if (expandable) ...<Widget>[
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: open ? 0.5 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(Icons.keyboard_arrow_down,
                              size: 20, color: context.textTertiary),
                        ),
                      ] else
                        const SizedBox(width: 24),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 这一行刻意分成**两个互不嵌套的可点区域之外**的独立行：
                  // 上面那块负责展开/收起，这里放「设置/修改要求」按钮 + 学分统计。
                  // 按钮在**左**、统计在右：按钮是行动入口，放左侧更容易被扫到，
                  // 也让各卡片的按钮纵向对齐（想改哪个大类时不用横向找）；
                  // 统计是结果，退到右边。
                  Row(
                    children: <Widget>[
                      // 药丸玻璃按钮，与弹窗里的次级按钮同一套语言
                      GlassKit.fieldBackdrop(
                        context,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => _editRequirement(g),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(Icons.edit_outlined,
                                    size: 13, color: context.brandColor),
                                const SizedBox(width: 3),
                                Text(
                                  g.hasCustomRequired ? '修改要求' : '设置要求学分',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: context.brandColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11, color: context.textTertiary)),
                      ),
                    ],
                  ),
                  // 只有有分母时才画进度条（学校会留空要求学分）
                  if (g.canShowProgress) ...<Widget>[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: ((g.earnedNumber + g.ongoingNumber) /
                                g.requiredNumber)
                            .clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: context.surfaceVariant,
                        color: (g.earnedNumber + g.ongoingNumber) >=
                                g.requiredNumber
                            ? context.successColor
                            : context.brandColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (open) ...<Widget>[
            Divider(height: 1, color: context.dividerColor),
            for (int i = 0; i < g.courses.length; i++) ...<Widget>[
              if (i > 0) Divider(height: 1, color: context.dividerColor),
              _courseRow(g.courses[i]),
            ],
          ],
        ],
      ),
    );
  }

  Widget _courseRow(ElectiveCourse c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(c.courseName,
                    style:
                        TextStyle(fontSize: 14, color: context.textPrimary)),
                if (c.courseCode.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(c.courseCode,
                      style:
                          TextStyle(fontSize: 11, color: context.textTertiary)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (c.credit.isNotEmpty)
                Text('${c.credit} 学分',
                    style: TextStyle(
                        fontSize: 12, color: context.textSecondary)),
              Text(
                c.isOngoing ? '在修' : c.score,
                style: TextStyle(
                  fontSize: c.isOngoing ? 12 : 15,
                  fontWeight: c.isOngoing ? FontWeight.w400 : FontWeight.w600,
                  color: c.isOngoing ? context.brandColor : context.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
