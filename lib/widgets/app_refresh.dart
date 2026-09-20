/// 下拉刷新：按当前材质给两套实现
///
/// ===== 为什么要两套 =====
/// 本应用有两种可选材质（见 theme/material_style.dart），它们的视觉语言完全不同：
///   - **M3**：实心层次色，配 Material 原生的圆形进度圈最自然；
///   - **液态玻璃**：折射、毛玻璃，配 Material 的实心圆点会显得是「贴上去的」。
///
/// 直接都用 RefreshIndicator 也能跑，但那会让玻璃模式下的下拉刷新成为
/// 整套 UI 里唯一不协调的部件 —— 而这是用户每次进页面都会看到的元素。
///
/// ===== 两套实现的公共部分 =====
///   - 都在 [AppRefresh] 里按材质分派，调用方只写一次 `AppRefresh(onRefresh: ...)`；
///   - 指示器的**落点**都对齐 M3（见 [AppRefresh.build] 里的 `rest`），
///     所以切换材质时指示器出现的位置一致，只有观感与动画不同。
///     （触发阈值也照 M3 的量级取，但没有逐像素复刻，见 [_kArmDistance]。）
///
/// ===== 顶栏让位（关键，否则指示器看不见）=====
/// 有些页面（培养方案、通选、我的）自己接管了顶部让位：内容从**屏幕顶部**
/// 开始、滚过顶栏底下，顶栏画在内容之上。这些页面的指示器若不额外下移，
/// 就会正好出现在顶栏底下被遮住 —— 表现为「下拉了但看不到任何反馈」。
/// [AppRefresh.topInset] 负责这件事；其余页面由外壳补让位，
/// 需要显式给一个合适的值（原因见该参数说明）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/glass_kit.dart';
import '../theme/material_style.dart';
import '../theme/theme.dart';

/// 下拉刷新容器：自动按当前材质选择实现。
///
/// 用法与 `RefreshIndicator` 一致，但**必须**给被包裹的可滚动组件加上
/// `physics: const AlwaysScrollableScrollPhysics()`：
/// ```dart
/// AppRefresh(
///   onRefresh: () => _load(force: true),
///   child: ListView(
///     physics: const AlwaysScrollableScrollPhysics(),
///     children: <Widget>[...],
///   ),
/// )
/// ```
/// 原因是内容不足一屏时，默认物理特性会直接拒绝滚动，下拉手势连
/// `OverscrollNotification` 都不会产生（RefreshIndicator 同样收不到通知）——
/// 表现为「数据少的页面下拉没反应，数据多的页面正常」。
/// 这类「只在部分数据下失效」的问题极难排查，所以在这里写死这个前提。
/// 状态视图（空态/错误态）不滚动，用 [RefreshableFill] 包一层即可。
class AppRefresh extends StatelessWidget {
  const AppRefresh({
    required this.onRefresh,
    required this.child,
    this.topInset,
    super.key,
  });

  /// 刷新回调。返回的 Future 完成前，指示器保持可见
  final Future<void> Function() onRefresh;

  /// 被包裹的可滚动内容（ListView / CustomScrollView 这类）
  final Widget child;

  /// 指示器静止时距**本组件顶部**的距离。
  ///
  /// 默认（不传）取 `appBarInset + Gaps.s`，适用于**自己接管了顶部让位**
  /// 的页面（内容从屏幕顶部开始、从顶栏下穿过）：培养方案、通选、我的
  /// （见 shell.dart 的 `pageHandlesTopInset`）。此时不补偿就会被顶栏遮住。
  ///
  /// 其余页面由外壳统一在**视口**上补了顶栏高度，本组件已经位于顶栏之下，
  /// 再用默认值就会把指示器推到页面中间。那些页面要么显式传一个小值，
  /// 要么传自己顶部那块固定栏的高度（如成绩页的筛选栏）。
  final double? topInset;

  @override
  Widget build(BuildContext context) {
    final double rest = topInset ?? (appBarInset(context) + Gaps.s);

    if (SurfaceStyleController.isGlass) {
      return GlassPullToRefresh(restOffset: rest, onRefresh: onRefresh, child: child);
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: context.brandColor,
      backgroundColor: context.surfaceColor,
      displacement: rest,
      child: child,
    );
  }
}

/// 与 Material `RefreshIndicator._kDragSizeFactorLimit` 同值。
///
/// Material 的做法是：指示器距顶 = `displacement * positionFactor`，
/// 而 `positionFactor = 0..1.5`（下拉过程中）或 `1.0`（刷新中）。
/// 也就是说**下拉到阈值时指示器在 1.5 倍落点处，松手后会略微上收**到落点。
/// 玻璃版本复刻这个系数，两种材质的手感才一致；这个数字看着奇怪，
/// 但它是 Material 的既有行为，改掉反而会让切换材质时感觉「跳」。
const double _kDragSizeFactorLimit = 1.5;

/// 触发刷新所需的下拉距离（逻辑像素）。
///
/// Material 用的是视口高度的 25%（`_kDragContainerExtentPercentage`），
/// 在本应用最窄的屏（360×640dp）上约 160。这里取 200 稍重一点：
/// 玻璃指示器同时在做「放大 + 渐显 + 圆弧填充」三个过渡，行程长一些
/// 才看得清，否则刚下拉就已经触发，视觉上像闪了一下。
const double _kArmDistance = 200;

/// 刷新中/落点时的指示器直径
const double _kIndicatorSize = 36;

/// 把**不可滚动**的状态视图（加载中/空态/错误态）撑满视口并可下拉。
///
/// 直接把这些状态视图放进 [AppRefresh] 是没用的：它们不是可滚动组件 →
/// 收不到 `OverscrollNotification` → 下拉毫无反应。于是会出现
/// 「有数据时能下拉刷新，没数据（最需要刷新）时反而拉不动」这种失败模式。
///
/// 用法：`RefreshableFill(child: EmptyView(...))`。它撑满可用高度，
/// 让下拉手势有地方落下，同时让内容仍在垂直方向居中。
class RefreshableFill extends StatelessWidget {
  const RefreshableFill({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints c) => SingleChildScrollView(
        // 内容不满一屏也要能拉
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          // 撑满视口高度，子组件（多为 Center）才能垂直居中。
          // 高度无界时（比如被放进纵向可滚动的父级）退回 0：
          // ConstrainedBox 收到 minHeight: infinity 会直接抛断言，
          // 而这种场景下「不居中」远好过整页崩溃。
          constraints: BoxConstraints(
            minHeight: c.maxHeight.isFinite ? c.maxHeight : 0,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 液态玻璃下拉刷新（自绘）
///
/// ===== 交互与视觉 =====
///   1. 下拉时，一颗玻璃药丸从顶栏下方渐显、逐渐放大；
///   2. 药丸内一段圆弧随下拉进度填充（进度 = 下拉距离 / 触发阈值）；
///   3. 到达阈值时药丸高亮（品牌色描边），表示「松手就刷新」；
///   4. 松手后圆弧转为不定量旋转，直到 [onRefresh] 完成；
///   5. 完成后药丸缩小淡出（内容由各自的滚动物理回弹）。
///
/// ===== 为什么自绘而不是找现成包 =====
/// 这个组件只用到 AnimationController + 自绘圆弧 + 已有的 GlassKit 底衬，
/// 代码量与「引入一个包再适配它的主题」相当，但可控性高得多 ——
/// 玻璃模式本身就依赖 GlassKit 的参数体系，外部包的主题模型接不进来。
class GlassPullToRefresh extends StatefulWidget {
  const GlassPullToRefresh({
    required this.onRefresh,
    required this.child,
    required this.restOffset,
    super.key,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  /// 刷新中指示器距屏幕顶部的距离（= `appBarInset + Gaps.s`）
  final double restOffset;

  @override
  State<GlassPullToRefresh> createState() => _GlassPullToRefreshState();
}

class _GlassPullToRefreshState extends State<GlassPullToRefresh>
    with SingleTickerProviderStateMixin {
  /// 下拉进度：0 = 收起，1 = 到达触发阈值
  double _pull = 0;

  /// 是否正在执行刷新（松手后、onRefresh 完成前）
  bool _refreshing = false;

  /// 刷新中圆弧的不定量旋转。
  ///
  /// **不在这里 repeat()**：那样会有一个永不停歇的 Ticker 持续申请帧，
  /// 玻璃模式下即使页面静止也在耗电（表现为「明明没动，帧率却一直有消耗」）。
  /// 只在真正刷新时 `repeat()`，结束即 `stop()`。
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  bool get _armed => _pull >= 1;

  Future<void> _handleRelease() async {
    if (!_armed || _refreshing) {
      // 没拉到阈值：回弹归零，不刷新
      if (_pull != 0) {
        setState(() => _pull = 0);
      }
      return;
    }
    setState(() => _refreshing = true);
    _spin.repeat();
    try {
      await widget.onRefresh();
    } finally {
      _spin.stop();
      if (mounted) {
        setState(() {
          _refreshing = false;
          _pull = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 位置系数：下拉中 0→1.5（到阈值即 1.5，见 _kDragSizeFactorLimit），
    // 刷新中固定 1.0（停回落点）
    final double factor = _refreshing ? 1.0 : math.min(_kDragSizeFactorLimit, _pull * _kDragSizeFactorLimit);
    final double top = widget.restOffset * factor;

    // 尺寸：下拉越多越大，刷新中保持最大
    final double size = _refreshing ? _kIndicatorSize : 24 + _pull * 12;
    final double opacity = _refreshing ? 1 : math.min(1, _pull * 1.6);

    return Stack(
      children: <Widget>[
        NotificationListener<ScrollNotification>(
          onNotification: (ScrollNotification n) {
            // 只认最外层滚动。页面里往往还有横向滚动（周次条、课程卡片横滑），
            // 它们的通知也会冒泡到这里 —— 不加这道判断，横滑一下就会触发刷新。
            // Material 的 RefreshIndicator 用的是同一个判据。
            if (n.depth != 0 || _refreshing) {
              return false;
            }
            if (n is OverscrollNotification && n.overscroll < 0) {
              // 负 overscroll = 在顶部继续下拉（内容被夹住，多出来的位移）
              final double next = math.min(1.2, _pull + (-n.overscroll) / _kArmDistance);
              // 一次轻微拖动会产生几十条通知，值几乎不变时跳过重建
              if (next - _pull > 0.004) {
                setState(() => _pull = next);
              }
            } else if (n is ScrollEndNotification) {
              _handleRelease();
            }
            return false;
          },
          child: widget.child,
        ),

        if (opacity > 0)
          Positioned(
            top: top,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Opacity(
                opacity: opacity.clamp(0.0, 1.0),
                child: Center(child: _pill(context, size)),
              ),
            ),
          ),
      ],
    );
  }

  /// 玻璃药丸 + 进度弧
  Widget _pill(BuildContext context, double size) {
    return GlassKit.fieldBackdrop(
      context,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: _armed
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: context.brandColor, width: 1.5),
              )
            : null,
        child: AnimatedBuilder(
          animation: _spin,
          builder: (BuildContext ctx, Widget? _) => CustomPaint(
            size: Size(size * 0.5, size * 0.5),
            painter: _ArcPainter(
              // 刷新中：不定量旋转的一段弧；否则按下拉进度填充整圈
              progress: _refreshing ? _spin.value : _pull.clamp(0.0, 1.0),
              indeterminate: _refreshing,
              color: context.brandColor,
              trackColor: context.dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆弧画笔：既支持「按进度填充」，也支持「不定量旋转」
class _ArcPainter extends CustomPainter {
  _ArcPainter({
    required this.progress,
    required this.indeterminate,
    required this.color,
    required this.trackColor,
  });

  final double progress;
  final bool indeterminate;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double stroke = math.max(2, size.width * 0.13);
    final Rect rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.width - stroke) / 2,
    );
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = trackColor,
    );

    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    const double start = -math.pi / 2; // 从正上方开始
    if (indeterminate) {
      // 不定量：画一段弧，靠 progress 当旋转相位
      canvas.drawArc(rect, start + progress * math.pi * 2, math.pi * 0.6, false, arc);
    } else {
      canvas.drawArc(rect, start, math.pi * 2 * progress, false, arc);
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.progress != progress ||
      old.indeterminate != indeterminate ||
      old.color != color ||
      old.trackColor != trackColor;
}
