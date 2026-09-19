/// 内容区的表面：**Material 3 实心面** 与 **液态玻璃** 两套，集中定义。
///
/// ===== 为什么单独一个文件 =====
/// 表面观感由一堆参数共同决定（模糊、厚度、饱和度、折射、光照角度…）。
/// 如果每个页面各写一份，风格一定会走形，后续调参还要把十几个文件翻一遍 ——
/// 与 `Gaps` / `AppColors` 集中定义是同一个理由。
///
/// ===== 两套材质怎么共存（重要）=====
/// 每个方法都是**同一份对外签名**：内部按 `SurfaceStyleController.style`
/// 分派到「M3 实心面」或「玻璃」。因此**调用方一行都不用改** ——
/// 15 个页面/组件继续调 `GlassKit.surface(...)`，切换材质时整棵树重建即可。
///
/// 这样做而不是「让每个页面自己 if 判断」，是为了让「有哪些表面类型」
/// 这件事只有一处定义：新增一种表面（比如将来的 elevated 卡片）时，
/// 只要在这里加一个方法，不会散落到十几个文件里。
///
/// 例外（不参与切换，始终是玻璃）：底部 dock 与顶部渐变模糊，
/// 理由见 material_style.dart。
///
/// ===== 两个必须遵守的约束 =====
/// 1. **只用 `AdaptiveGlass`，绝不用 `LiquidGlass`**。
///    库的文档写得很明确：`LiquidGlass` 是 Impeller 专用，
///    **在 Skia 上会静默地什么都不渲染** —— 界面空白且不报错，
///    是最难排查的一类失败。`AdaptiveGlass` 会在 Impeller 与 Skia
///    之间自动选实现（Impeller 走全套着色器，Skia 走轻量着色器）。
/// 2. **玻璃只用于「浮在内容之上」的元素**（导航栏、弹窗、卡片），
///    不要用于大面积内容区与课表网格本身 —— 后者是实心彩卡，
///    加玻璃既与彩底冲突，7×5 个格子同时模糊渲染也有性能代价。
library;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'material_style.dart';

/// 玻璃的圆角与厚度档位，与项目既有的 `Gaps` 对齐
class GlassKit {
  /// 弹窗/卡片的圆角（与 `Gaps.radius` 一致，避免同页方圆混用）
  static const double radius = 18;
  static const double radiusSm = 14;

  /// 导航栏等贴边元素的圆角
  static const double radiusBar = 22;

  /// 顶栏控件的统一高度与字号。
  ///
  /// 抽成常量是因为课表顶栏里并排着四个控件（周次/学期/校历/设置），
  /// 高度差 1px 就会看出参差。字号比正文小一档：顶栏属导航层，
  /// 信息密度高，且要与页面标题拉开层级。
  static const double topBarControlH = 32;
  static const double topBarControlFs = 12.5;

  /// 一层玻璃的通用参数。
  ///
  /// 深浅色各一套：**深色下模糊过强会显得浑浊**，因此降低 blur、
  /// 提高底色不透明度（glassColor 的 alpha）。
  static LiquidGlassSettings settings(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return LiquidGlassSettings(
      // 厚度与模糊的配比决定「玻璃感」：厚度给折射留出空间，模糊负责磨砂。
      //
      // 数值刻意取小：这两个参数直接决定 GPU 填充率（模糊半径越大越贵），
      // 而本应用同一屏上常有多个玻璃件（导航栏 + 若干卡片）。
      // 实测观感在白底/浅色页面上与更大数值几乎无差别，
      // 但滚动流畅度差别明显 —— 因此取「刚够看出玻璃感」的值。
      thickness: dark ? 12 : 14,
      blur: dark ? 6 : 8,
      // 折射：越小越像普通磨砂，越大越有「厚玻璃压住背景」的形变
      refractiveIndex: 1.2,
      chromaticAberration: 0.008,
      // 饱和度略提升，让透过来的颜色不发灰
      saturation: 1.4,
      // 玻璃自身的底色：极淡，主要靠背景透出
      glassColor: dark ? const Color(0x2EFFFFFF) : const Color(0x3DFFFFFF),
      // 光照：左上打光，与 Material 的默认光照方向一致
      lightAngle: GlassDefaults.lightAngle,
      lightIntensity: dark ? 0.4 : 0.5,
      fresnelStrength: 1.0,
    );
  }

  /// 通用玻璃容器（卡片、分组、面板）
  ///
  /// @param child       内容
  /// @param radius      圆角
  /// @param interactive 是否启用「按下时光效反馈」（仅按钮类需要）
  static Widget surface(
    BuildContext context, {
    required Widget child,
    double radius = radius,
    bool interactive = false,
  }) {
    if (!SurfaceStyleController.isGlass) {
      // M3：实心面 + 极轻的层次（用 surfaceContainer 而不是纯 surface，
      // 这样「面板」与「页面底」之间有一档可见的层次，不需要描边）。
      return _m3Surface(context, radius: radius, child: child);
    }
    return AdaptiveGlass(
      shape: LiquidRoundedRectangle(borderRadius: radius),
      settings: settings(context),
      // standard 档位：兼顾观感与性能；high 仅用于少数焦点元素
      quality: GlassQuality.standard,
      isInteractive: interactive,
      child: child,
    );
  }

  /// M3 实心面。所有 M3 分支共用它，保证圆角与层次只有一处定义。
  ///
  /// 用 `surfaceContainer`（而不是 `surface`）：内容卡片需要与页面底
  /// 分得开。M3 的层次体系正是为此设计的，比自己调透明度更稳。
  /// 深浅色由 `ColorScheme` 自动给出对应值，不必分两套常量。
  static Widget _m3Surface(
    BuildContext context, {
    required double radius,
    required Widget child,
    EdgeInsetsGeometry? padding,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(radius),
      ),
      padding: padding,
      child: child,
    );
  }

  /// **列表项 / 分组卡片**用的玻璃。
  ///
  /// 与 [surface] 的区别只在质量档位：这里用 [GlassQuality.minimal]。
  ///
  /// 为什么必须降档：成绩、课程明细、通选这些页面动辄几十上百行，
  /// 每行都跑一遍完整的折射着色器会明显掉帧。库文档对 minimal 档的说明
  /// 正是「用在 ListView / 表单里，比 BackdropFilter 快 5–10 倍，
  /// 且滚动时表现正确」—— 视觉上仍是玻璃（模糊 + 提饱和），
  /// 只少了折射与菲涅尔高光，而这种细粒度差别在成片的小卡片上本就看不出来。
  static Widget listCard(
    BuildContext context, {
    required Widget child,
    double radius = radius,
    EdgeInsetsGeometry? padding,
  }) {
    if (!SurfaceStyleController.isGlass) {
      return _m3Surface(context, radius: radius, padding: padding, child: child);
    }
    return AdaptiveGlass(
      shape: LiquidRoundedRectangle(borderRadius: radius),
      settings: settings(context),
      quality: GlassQuality.minimal,
      child: padding == null
          ? child
          : Padding(padding: padding, child: child),
    );
  }

  /// 顶部统计条 / 独立面板等**少量、面积大**的元素，用标准档（带折射）。
  static Widget panel(
    BuildContext context, {
    required Widget child,
    double radius = radius,
    EdgeInsetsGeometry? padding,
  }) {
    if (!SurfaceStyleController.isGlass) {
      return _m3Surface(context, radius: radius, padding: padding, child: child);
    }
    return AdaptiveGlass(
      shape: LiquidRoundedRectangle(borderRadius: radius),
      settings: settings(context),
      quality: GlassQuality.standard,
      child: padding == null
          ? child
          : Padding(padding: padding, child: child),
    );
  }

  /// 底部 dock 专用：比 [settings] **更透明、更薄**。
  ///
  /// 为什么单独一档：dock 是常驻且面积不小的浮层，用默认参数会显得「实」，
  /// 把下方内容整块挡住 —— 用户明确要求能透出被遮挡的内容。
  /// 做法是把底色接近全透明、只保留轻微模糊与折射，
  /// 于是内容能透上来但仍然读得清图标与文字。
  static LiquidGlassSettings tabBarSettings(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return LiquidGlassSettings(
      // 厚度取到接近下限：它决定边缘折射的「外壳」厚度，
      // 壳越厚，dock 看起来越像一块有体积的板而不是一层薄膜。
      thickness: dark ? 3 : 4,
      // 模糊压到 2：模糊是「发蒙」的主要原因 —— 它把背景糊成一片，
      // 内容虽然透过来但认不出是什么。留一点点是为了让图标有可读的底。
      blur: 2,
      refractiveIndex: 1.04,
      chromaticAberration: 0.002,
      saturation: 1.15,
      // 底色几乎完全透明。还能看清图标与文字，靠的是图标本身的深色
      // 与下方内容的对比，而不是底色遮挡 —— 这正是「看见被 dock 遮住
      // 的内容」的前提。
      glassColor: dark ? const Color(0x06FFFFFF) : const Color(0x0AFFFFFF),
      lightAngle: GlassDefaults.lightAngle,
      // 光照与菲涅尔压低：高光会在玻璃表面形成一层白色「膜」，
      // 是通透感的另一个杀手。
      lightIntensity: dark ? 0.12 : 0.16,
      fresnelStrength: 0.3,
      // **按原值合成 alpha**，不做亮度归一化。
      //
      // 默认的 adaptive 模式有一段 alpha 下限（约 0.05），也就是给
      // 「透明」设了个地板：无论把 glassColor 调到多低，它都会被抬回来。
      // clear 模式跳过这层归一化，上面那两个极低 alpha 才真正生效，
      // 同时仍保留高光与边缘折射。
      bodyMode: GlassBodyMode.clear,
      // 去掉投影。投影会把 dock 与背景「切开」，视觉上像一块浮起的实心板，
      // 与「通透」的诉求相反。
      shadowElevation: 0,
    );
  }

  /// **筛选栏 / 工具条**用的玻璃。
  ///
  /// 与 [listCard] 的区别：这里是一整条横栏（铺满宽度、高度固定），
  /// 因此用更大的圆角、更低的厚度 —— 它承担的是「工具层」语义，
  /// 不该比内容卡片更抢眼。
  static Widget toolbar(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry? padding,
  }) {
    if (!SurfaceStyleController.isGlass) {
      // M3 工具条：比卡片再亮一档（surfaceContainerHigh），
      // 表达「这是工具层、浮在内容之上但不抢戏」
      final ColorScheme cs = Theme.of(context).colorScheme;
      return Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: padding,
        child: child,
      );
    }
    return AdaptiveGlass(
      shape: const LiquidRoundedRectangle(borderRadius: 18),
      settings: settings(context),
      quality: GlassQuality.minimal,
      child: padding == null
          ? child
          : Padding(padding: padding, child: child),
    );
  }

  /// 输入框 / 选择器底衬：**药丸状玻璃**。
  ///
  /// 为什么要有它（而不是用不透明的浅色块）：
  /// 纯色块浮在玻璃弹窗上会像「贴了一张纸」，与整体玻璃语言割裂。
  /// 这里用与 [settings] 同族但更淡、更薄的参数，既保留透过背景的观感，
  /// 又让**上面的文字**依然清楚。
  ///
  /// 圆角取 999（Flutter 会把超出半高的圆角收敛为半高），因此是标准药丸形。
  static Widget fieldBackdrop(BuildContext context, {required Widget child}) {
    if (!SurfaceStyleController.isGlass) {
      // M3：输入框/药丸按钮的底衬用 surfaceContainerHighest
      // （M3 里「最贴近用户操作的那一档」），配合主题里已统一设置的
      // 药丸形 InputDecoration，观感一致。
      final ColorScheme cs = Theme.of(context).colorScheme;
      return Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: child,
      );
    }
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return AdaptiveGlass(
      shape: const LiquidRoundedRectangle(borderRadius: 999),
      settings: LiquidGlassSettings(
        // 比卡片薄一点：表单里一行常有多个输入框，
        // 每个都跑重玻璃会拖慢弹窗内的滚动
        thickness: 10,
        blur: 6,
        refractiveIndex: 1.08,
        chromaticAberration: 0.004,
        saturation: 1.2,
        // 底色偏实：这是**读写字**的地方，可读性优先于通透。
        // 但比改造前更透一些 —— 之前 0xB3 的白几乎是不透明的纯色块。
        glassColor: dark ? const Color(0x3DFFFFFF) : const Color(0x8AFFFFFF),
        lightAngle: GlassDefaults.lightAngle,
        lightIntensity: 0.3,
        fresnelStrength: 0.6,
      ),
      quality: GlassQuality.minimal,
      child: child,
    );
  }

  /// 扁平药丸：**不依赖玻璃**的输入框底衬。
  ///
  /// 用在「字段本身很矮、需要精确控制高度」的地方（如节次作息的两个时刻框）：
  /// 那里靠 `isCollapsed` + 外层 `Center` 做垂直居中，若套
  /// [fieldBackdrop] 的多层装饰器反而会把高度算歪。
  ///
  /// 两种材质下都给**同一个药丸形状**，只换颜色：
  ///   - M3：`surfaceContainerHighest`（与其它输入框一致）
  ///   - 玻璃：半透明白 + 细描边（原先硬编码的那套）
  /// 这样「所有输入框都是药丸」这条规则在两种材质下都成立。
  static Widget flatPill(
    BuildContext context, {
    required Widget child,
    double? height,
    EdgeInsetsGeometry? padding,
  }) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool glass = SurfaceStyleController.isGlass;
    final Color bg = glass
        ? (dark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.60))
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    final Border? border = glass
        ? Border.all(
            color: dark
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.black.withValues(alpha: 0.08),
          )
        : null;
    return Container(
      height: height,
      // 统一去掉边框宽度对内容的影响，字段内部不用再关心描边
      padding: padding ?? const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: border,
      ),
      child: child,
    );
  }

  /// 药丸状玻璃「分段控件」底衬（弹窗里的「每周/单周/双周」这类选择）。
  ///
  /// 选中态刻意**不用玻璃**，而是实心品牌色：一是选中要一眼可见，
  /// 二是避免「玻璃套玻璃」（库作者明确列为反模式）。未选中态才是玻璃药丸。
  static Widget pill(
    BuildContext context, {
    required Widget child,
    bool selected = false,
  }) {
    if (selected) {
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(999),
        ),
        child: child,
      );
    }
    return fieldBackdrop(context, child: child);
  }
}
