/// 培养方案页
///
/// 三部分：
///   1. 培养目标（文字说明，表格给不出）；
///   2. 课程设置总表（按体系分组）；
///   3. PDF 附件的**下载**入口（若有附件）。
///
/// ===== 为什么不做内嵌预览 =====
/// 早先这一页内嵌了 PDF 预览（pdfrx / PDFium）。那条路在本项目里反复出问题：
///   - 库自身的 `InteractiveViewer` 与外层列表抢竖直拖动，表现为
///     「上下拖不动 PDF，得先左右滑一点」（手势阈值差 18 vs 36，见记忆记录）；
///   - 每次进来都要解析文档、缓存位图（十几页要近百 MB），
///     而这只是培养方案的附件，用户真正要的多半是**拿走文件**而不是在手机上读；
///   - 还要求 PDFium 原生库随包分发（每个 ABI 6–7 MB），
///     构建时一旦拉不到对应架构就会失败。
///
/// 现在只保留下载：点一下交给系统的「另存为」流程（见 [PdfSaver]），
/// 文件落到用户自己选的位置。功能更直接，也去掉了上面全部三类问题。
///
/// 附件路径与文件名完全动态（从页面正则提取），不假设任何固定值。
library;

import 'package:flutter/material.dart';

import '../common/constants.dart';
import '../data/app_state.dart';
import '../data/page_cache.dart';
import '../data/pdf_saver.dart';
import '../data/pdf_store.dart';
import '../data/re_auth_service.dart';
import '../model/models.dart';
import '../parser/plan_parser.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import '../widgets/app_refresh.dart';
import '../widgets/state_views.dart';
import '../widgets/top_fade_blur.dart';

class PlanPage extends StatefulWidget {
  const PlanPage({super.key});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final AppState _app = AppState.instance;

  bool _loading = true;
  String _error = '';
  PlanDetail? _detail;
  /// 已展开的分组（按 `g.system` 记）。
  ///
  /// 存「展开」而不是「收起」：空集即**全部收起**，这正是期望的默认值。
  /// 早先存的是「收起」集合，空集等于全部展开 —— 一份 10 门课的分组
  /// 一进页面就铺满好几屏，用户得先滚很久才看得到下一个分组。
  ///
  /// 这个写法与通选页（elective_page）一致，两页行为统一。
  final Set<String> _expanded = <String>{};

  /// 页面级提示（成功/失败都走这里）。
  ///
  /// 为什么不用 SnackBar：本应用的壳是 `GlassScaffold`（内部
  /// `CupertinoPageScaffold`），树里**没有 Material 的 `Scaffold`**。
  /// `ScaffoldMessenger` 本身存在（`MaterialApp` 会建），但它的
  /// `showSnackBar` 断言「必须有已注册的 Scaffold」—— 缺了就 debug 抛断言、
  /// release 下静默不显示。「点下载没反应」有一半原因就在这里。
  /// 改成页面自己的提示条，与设置页那种「顶部一条横幅」的做法一致。
  String _hint = '';


  @override
  void initState() {
    super.initState();
    // 先用内存缓存填首帧，再决定要不要联网（避免切页回来闪加载态）
    _detail = _loader().peek();
    _load();
  }

  PageDataLoader<PlanDetail> _loader() => PageDataLoader<PlanDetail>(
        key: PageCache.keyOf(AppState.instance.account, kCachePlan),
        fetch: _app.api.getPlanHtml,
        parse: PlanParser.parse,
        ttl: kTtlPlan,
      );

  Future<void> _load({bool interactive = false, bool force = false}) async {
    // 用户点导航进来的首次加载同样算「主动操作」：
    // 否则会话失效时只会给一句内联提示，逼迫用户再点一次「重试」。
    // 标记是一次性的（取走即清零），冷启动不受影响。
    interactive = interactive || ReAuthService.consumeUserIntent();
    // 已有内容时不铺整屏加载态：切页回来该立刻看到旧数据，新数据到了再替换
    setState(() {
      _error = '';
      if (_detail == null) {
        _loading = true;
      }
    });
    try {
      final PageLoadResult<PlanDetail> r = await _loader().load(force: force);
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = r.data;
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

  @override
  Widget build(BuildContext context) {
    final PlanDetail? d = _detail;
    // 有缓存内容就直接渲染，刷新与错误都在列表内部消化 ——
    // 整屏替换会把用户已经在看的内容清掉，而培养方案是**基本不变**的数据，
    // 加载失败把整页变空没有任何道理。
    if (d != null && !(d.courses.isEmpty && d.introParagraphs.isEmpty)) {
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: AppRefresh(onRefresh: () => _load(force: true), child: _buildList(d)),
          ),
          const TopFadeBlur(),
        ],
      );
    }
    if (_loading) {
      return const RefreshableFill(child: LoadingView(message: '正在获取培养方案…'));
    }
    if (d == null) {
      return AppRefresh(
        onRefresh: () => _load(force: true),
        child: RefreshableFill(
          child: ErrorView(
              message: _error.isEmpty ? '暂无培养方案数据' : _error,
              onRetry: () => _load(interactive: true, force: true)),
        ),
      );
    }
    // 取到了数据但内容为空（服务器上确实没有）：下拉仍然重新请求 ——
    // 数据可能是刚发布的，再拉一次总比「拉不动」合理。
    return AppRefresh(
      onRefresh: () => _load(force: true),
      child: const RefreshableFill(child: EmptyView(title: '暂无培养方案数据')),
    );
  }

  /// 页面主体列表（原 build 的内容，抽出以便被 Stack 包裹）
  Widget _buildList(PlanDetail d) {
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
            // 保存 PDF 的结果提示（成功/失败都在这里，见 _hint 的说明）
            if (_hint.isNotEmpty) ...<Widget>[
              _hintBanner(),
              const SizedBox(height: Gaps.m),
            ],
            // 有缓存内容但这次刷新失败：提示一下，但**不**清掉内容
            if (_error.isNotEmpty) ...<Widget>[
              _staleBanner(),
              const SizedBox(height: Gaps.m),
            ],
            if (d.introParagraphs.isNotEmpty || d.detailParagraphs.isNotEmpty)
              _introCard(d),
            const SizedBox(height: Gaps.m),
            _summaryCard(d),
            if (d.pdfPath.isNotEmpty) ...<Widget>[
              const SizedBox(height: Gaps.m),
              _pdfCard(d),
            ],
            const SizedBox(height: Gaps.m),
            Text('课程设置总表',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                )),
            const SizedBox(height: 8),
            for (final PlanGroup g in d.groups) ...<Widget>[
              _groupCard(g),
              const SizedBox(height: 8),
            ],
          ],
        );

  }

  /// 保存结果提示条：可点掉，与设置页的提示条同一形态
  Widget _hintBanner() {
    return GestureDetector(
      onTap: () => setState(() => _hint = ''),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.brandColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _hint,
          style: TextStyle(fontSize: 12, color: context.brandColor),
        ),
      ),
    );
  }

  /// 「刷新失败，以下是缓存内容」提示条
  Widget _staleBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.warningColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _error,
        style: TextStyle(fontSize: 12, color: context.textSecondary),
      ),
    );
  }

  Widget _introCard(PlanDetail d) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('培养目标',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              )),
          const SizedBox(height: 8),
          for (final String p in <String>[...d.introParagraphs, ...d.detailParagraphs])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                p,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: context.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _summaryCard(PlanDetail d) {
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
    String num(double x) =>
        x == x.roundToDouble() ? x.toStringAsFixed(0) : x.toStringAsFixed(1);
    return SectionCard(
      child: Row(
        children: <Widget>[
          cell('${d.courses.length}', '门课程'),
          cell(num(d.totalCredit), '总学分'),
          cell(num(d.totalHours), '总学时'),
        ],
      ),
    );
  }

  /// PDF 附件卡片：只有一行「附件名 + 下载」。
  ///
  /// 不再内嵌预览 —— 原因见文件头「为什么不做内嵌预览」。
  /// 保留卡片形态（而不是做成一个裸按钮）是为了：
  ///   - 与页面其它区块同一套玻璃语言；
  ///   - 明确告诉用户这个附件叫什么，下载前就知道拿到了什么文件。
  Widget _pdfCard(PlanDetail d) {
    // 从附件路径取原文件名（去掉查询串）；取不到就用中性描述
    final String raw = d.pdfPath.split('/').last.split('?').first;
    final String name = (raw.isNotEmpty && raw.toLowerCase().endsWith('.pdf'))
        ? raw
        : '培养方案.pdf';

    return SectionCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          Icon(Icons.picture_as_pdf_outlined,
              size: 20, color: context.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('培养方案 PDF',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    )),
                const SizedBox(height: 2),
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textTertiary,
                    )),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 药丸玻璃按钮，与弹窗里的次级按钮同一套语言
          GlassKit.fieldBackdrop(
            context,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => _downloadPdf(d.pdfPath),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.download_outlined,
                        size: 16, color: context.brandColor),
                    const SizedBox(width: 4),
                    Text('下载',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: context.brandColor,
                        )),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 下载 PDF：交给 [PdfSaver]（Android 走系统的「创建文档」弹窗）。
  ///
  /// ===== 为什么不再用 ScaffoldMessenger 提示（两个 bug 叠在一起）=====
  /// 1. 本应用的壳用的是 `GlassScaffold`，它内部是 `CupertinoPageScaffold`
  ///    —— 树里没有 Material 的 `Scaffold`，`ScaffoldMessenger.showSnackBar`
  ///    所要求的挂载点不存在：用户点「下载」后屏幕上什么也没有，
  ///    看起来就是「按钮无法使用」。
  /// 2. 就算提示能显示，旧实现把文件复制进 `Android/data/<包名>/files/exports`
  ///    —— Android 11 起文件管理器读不到这个目录，用户存了也打不开。
  ///
  /// 现在改成：**结果直接写进页面自己的提示条**（`_hint`，与本页其它反馈
  /// 同一处），保存位置由系统弹窗决定（用户自己选的，一定能找到）。
  Future<void> _downloadPdf(String pdfPath) async {
    if (pdfPath.isEmpty || !mounted) {
      return;
    }
    setState(() => _hint = '正在保存…');
    try {
      final String account = await _app.resolveAccount();
      // 复用 PdfStore 的缓存：下过一次就不会再请求一遍
      final String local = await PdfStore.download(
        AppState.instance.jar,
        account,
        pdfPath,
      );
      // 从附件路径取原文件名（去掉查询串）；取不到就用默认名
      final String raw = pdfPath.split('/').last.split('?').first;
      final String name =
          (raw.isNotEmpty && raw.toLowerCase().endsWith('.pdf'))
              ? raw
              : '培养方案.pdf';
      final PdfSaveOutcome out =
          await PdfSaver.save(localPath: local, fileName: name);
      if (!mounted) {
        return;
      }
      setState(() {
        if (out.ok) {
          _hint = '已保存为 ${out.location}';
        } else if (out.cancelled) {
          // 取消是正常操作，不该报成错误，也不该留一条「正在保存…」
          _hint = '';
        } else {
          _hint = '保存失败：${out.message}';
        }
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _hint = '保存失败：$e');
    }
  }

  Widget _groupCard(PlanGroup g) {
    // 默认收起：只有用户点开过的分组才在 _expanded 里
    final bool open = _expanded.contains(g.system);
    return SectionCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          InkWell(
            onTap: () => setState(() {
              if (open) {
                _expanded.remove(g.system);
              } else {
                _expanded.add(g.system);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: Gaps.m, vertical: 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(g.system,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        )),
                  ),
                  Text(
                    '${g.courses.length} 门 · '
                    '${g.totalCredit == g.totalCredit.roundToDouble() ? g.totalCredit.toStringAsFixed(0) : g.totalCredit.toStringAsFixed(1)} 学分',
                    style:
                        TextStyle(fontSize: 11, color: context.textTertiary),
                  ),
                  Icon(
                    // 收起时朝下（提示「点开」），展开时朝上（提示「收起」）
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: context.textTertiary,
                  ),
                ],
              ),
            ),
          ),
          if (open) ...<Widget>[
            const Divider(height: 1),
            for (final PlanCourse c in g.courses) _courseRow(c),
          ],
        ],
      ),
    );
  }

  Widget _courseRow(PlanCourse c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(c.courseName,
                    style: TextStyle(
                        fontSize: 14, color: context.textPrimary)),
                const SizedBox(height: 3),
                Row(
                  children: <Widget>[
                    if (c.courseCode.isNotEmpty)
                      Text(c.courseCode,
                          style: TextStyle(
                              fontSize: 11, color: context.textTertiary)),
                    if (c.semester.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 8),
                      Text('第${c.semester}学期',
                          style: TextStyle(
                              fontSize: 11, color: context.textTertiary)),
                    ],
                    if (c.category.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: context.surfaceVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(c.category,
                            style: TextStyle(
                                fontSize: 10, color: context.textSecondary)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Text('${c.credit} 学分',
              style: TextStyle(fontSize: 13, color: context.textSecondary)),
        ],
      ),
    );
  }
}
