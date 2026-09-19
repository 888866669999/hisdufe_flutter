/// 顶部渐变模糊（progressive blur）
///
/// ===== 它解决什么 =====
/// 顶栏（状态栏 + 应用栏）是透明的，内容会从其下方滚过。若不处理，
/// 文字会**清晰**地从透明顶栏下划过，与顶栏标题叠在一起，读不清也难看。
/// iOS 的做法是让越靠近顶部的越糊、向下连续渐变消失。
///
/// ===== 实现：引擎的模糊 + 自定义着色器做渐变 =====
/// 一次 `BackdropFilter`，滤镜由两部分 **组合** 而成：
///
///   `ImageFilter.compose(outer: 渐变压暗着色器, inner: ImageFilter.blur)`
///
///   - `inner` 是真·高斯模糊 —— 交给引擎内置实现（可分离卷积，高度优化）；
///   - `outer` 是 `shaders/top_fade_blur.frag`，只按纵向位置压暗 alpha。
///
/// 覆盖范围**正好是顶栏高度**（= 以前页面顶部那块空白），
/// 在栏内渐变到 0，于是顶栏之外的内容保持清晰。
/// 于是「模糊层」与「下层未模糊内容」之间形成**连续**的交叉淡入。
///
/// ===== 走过的弯路（都真机验证过，记下来避免重犯）=====
/// 1. **`ShaderMask` 套 `BackdropFilter`：完全无效**。
///    `RenderShaderMask` 会 `pushLayer(ShaderMaskLayer)` 新建隔离图层，
///    而 `BackdropFilter` 采样的是「当前图层之下」的内容 —— 在空图层里
///    采样不到页面内容，模糊结果为空。
/// 2. **多条不同 sigma 的模糊带叠加：段落感明显**。
///    相邻带的 sigma 是跳变的，而人眼对 sigma 的感知接近比值而非差值，
///    等差/等比分带都藏不住台阶（加到 24 条仍有可见条纹）。
///    公开的 `progressive_blur` 包同样不这么做，而是用分片着色器。
///
/// 现在这条路是官方支持的组合：`ImageFilter.shader` 的文档明确说明
/// 引擎会自动绑定第一个 `sampler2D` 为滤镜输入、第一个 `vec2` 为纹理尺寸。
/// 唯一限制是该 API **仅 Impeller 支持**，因此用
/// `ImageFilter.isShaderFilterSupported` 做降级（见下）。
///
/// ===== 降级策略 =====
/// 非 Impeller 后端（如桌面的 Skia）上 `ImageFilter.shader` 会抛
/// `UnsupportedError`。这种设备上退化成「一条均匀模糊」——
/// 观感略差但没有分割线，也不会崩。
///
/// ===== 前提：页面必须自己接管顶部让位 =====
/// 外壳默认把 `appBarInset` 加在**视口**上，那块区域永远是背景色 ——
/// 内容到不了，模糊也就没东西可糊，只会显示成一条很宽的乳白带。
/// 因此本组件只用在把让位放进滚动内容的页面上
/// （见 shell.dart 的 `pageHandlesTopInset`）。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// 顶部渐变模糊浮层。
class TopFadeBlur extends StatefulWidget {
  const TopFadeBlur({
    this.fadeStart = 0.62,
    this.sigma = 14,
    super.key,
  });

  /// 渐变起点，占**顶栏高度**的比例（0..1）。
  ///
  /// 这段之前保持满强度模糊，之后衰减到 0（正好落在顶栏下缘）。
  ///
  /// ===== 模糊区高度为什么正好等于顶栏 =====
  /// 早先的版本是「顶栏 + 额外 44vp」，理由是让过渡更缓。但那会明显
  /// 侵入正文 —— 用户看到的是「凭空多了一条毛玻璃挡住内容」，
  /// 反馈要求「与以前顶部空白区域同高」。确实应当如此：
  /// 顶栏之外的内容本来就该是清晰的，模糊只需要解决
  /// 「内容从透明顶栏下滚过时与标题叠在一起」这一个问题。
  ///
  /// 取 0.62 而不是 1.0：顶栏中上部（状态栏 + 标题行）需要满强度，
  /// 只在最下沿留一段衰减，避免在栏下缘出现「糊 / 清晰」的硬边界。
  final double fadeStart;

  /// 模糊强度（高斯 sigma）。
  ///
  /// 目标是「认得出有内容在动，但读不出是什么」。14 在实机上刚好：
  /// 能盖住文字细节，又不至于糊成没有信息量的色块。
  final double sigma;

  @override
  State<TopFadeBlur> createState() => _TopFadeBlurState();
}

class _TopFadeBlurState extends State<TopFadeBlur> {
  /// 渐变着色器。加载是异步的（要读 asset 并编译），因此允许为 null。
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ui.FragmentProgram p =
          await ui.FragmentProgram.fromAsset('shaders/top_fade_blur.frag');
      if (!mounted) {
        return;
      }
      setState(() => _shader = p.fragmentShader());
    } catch (_) {
      // 加载失败时保持 null，build 走降级分支
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 页面坐标从**屏幕顶端**算起（接管让位的页面把 inset 放进了滚动内容，
    // 视口本身不再偏移），因此这里 top: 0 就正好盖住状态栏 + 顶栏。
    final double inset = appBarInset(context);
    // 高度**正好等于顶栏**（= 以前页面顶部那块空白的高度）。
    // 不再往下多延伸：顶栏之外的内容应当保持清晰。
    final double totalH = inset;

    ui.ImageFilter? filter;
    final ui.FragmentShader? shader = _shader;
    if (shader != null && ui.ImageFilter.isShaderFilterSupported) {
      // uniform 顺序必须与 .frag 中声明一致：
      //   0 号是 u_size —— 由**引擎**写入纹理尺寸，这里绝不能碰；
      //   1 号 u_keep：满强度区结束、开始衰减的位置（归一化到整块高度）
      //   2 号 u_fade：衰减到 0 的位置（= 底部，即 1.0）
      shader
        ..setFloat(1, widget.fadeStart)
        ..setFloat(2, 1.0);
      filter = ui.ImageFilter.compose(
        // 外层：按纵向渐变压暗 alpha（我们的着色器）
        outer: ui.ImageFilter.shader(shader),
        // 内层：真正的高斯模糊，交给引擎
        inner: ui.ImageFilter.blur(
          sigmaX: widget.sigma,
          sigmaY: widget.sigma,
        ),
      );
    } else {
      // 降级：非 Impeller 后端。均匀模糊，没有渐变，但不会崩。
      filter = ui.ImageFilter.blur(
        sigmaX: widget.sigma,
        sigmaY: widget.sigma,
      );
    }

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: totalH,
      child: IgnorePointer(
        child: ClipRect(
          child: BackdropFilter(
            filter: filter,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}
