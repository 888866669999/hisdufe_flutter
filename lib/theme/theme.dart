/// 主题与设计令牌
///
/// 从鸿蒙版 `theme/Theme.ets` + `resources/*/element/color.json` 移植。
/// 颜色沿用同一套值，保证两版观感一致（截图可对照）。
library;

import 'package:flutter/material.dart';

class AppColors {
  // 浅色
  static const Color brand = Color(0xFF2957C9);
  static const Color brandSoft = Color(0xFFE8EEFC);
  static const Color onBrand = Color(0xFFFFFFFF);
  /// 页面底色。
  ///
  /// 与 `schedBg` 取同一个淡紫色：原先这里是中性灰 #F4F5F7，而
  /// `GlassScaffold` 给整页铺的是 `schedBg`（#E9EAF6，淡紫）——
  /// 于是登录页/弹窗（走 `scaffoldBackgroundColor`）与主界面底色不同，
  /// 切换页面时能看出色差。统一成淡紫后整机只有一个基调。
  static const Color bg = Color(0xFFE9EAF6);
  static const Color surface = Color(0xFFFFFFFF);
  /// 中性填充（进度条底、药丸底、描边、分隔）。
  ///
  /// 取淡紫灰而不是中性灰：它大量出现在卡片（#F2F3FA）与底色（#E9EAF6）
  /// 之上，若本身是灰的，会在紫色调里显出一块「脏」。
  static const Color surfaceVariant = Color(0xFFE9EBF6);
  static const Color textPrimary = Color(0xFF14161B);
  static const Color textSecondary = Color(0xFF5A6070);
  static const Color textTertiary = Color(0xFF8A909C);
  static const Color divider = Color(0xFFDFE2F0);
  static const Color danger = Color(0xFFD92D20);
  static const Color success = Color(0xFF12805C);
  static const Color warning = Color(0xFFB54708);

  /// 课表页统一背景色（**整页一个色号**）。
  ///
  /// 早先用的是「上浅下深」的渐变，本意是让彩卡浮起来；但实际用起来
  /// 页面出现三层不同底色（筛选栏白、表格渐变、底部栏白），看着不统一。
  /// 现在整页只用这一个色号 —— 筛选栏、表格、备注、底部栏全部同色，
  /// 分隔只靠留白与卡片本身的颜色，不再靠底色差异。
  static const Color schedBg = Color(0xFFE9EAF6);

  /// 深色
  static const Color dbrand = Color(0xFF7BA2FF);
  static const Color dbrandSoft = Color(0xFF1D2637);
  /// 深色页面底。同样与 `dschedBg` 统一（带一点紫调，避免纯灰黑）。
  static const Color dbg = Color(0xFF14161F);
  static const Color dsurface = Color(0xFF171A21);
  static const Color dsurfaceVariant = Color(0xFF232736);
  static const Color dtextPrimary = Color(0xFFE7E9ED);
  static const Color dtextSecondary = Color(0xFFA2A9B6);
  static const Color dtextTertiary = Color(0xFF79808D);
  static const Color ddivider = Color(0xFF2A2E3E);
  static const Color ddanger = Color(0xFFF97066);
  static const Color dsuccess = Color(0xFF4ED4A6);
  static const Color dwarning = Color(0xFFF5B45C);

  /// 课表页统一背景色（深色）：与浅色同样的「整页一个色号」策略。
  /// 与 [dbg] 取同一值，理由见 [bg] 的说明。
  static const Color dschedBg = Color(0xFF14161F);

  // ===== M3 层次色（浅色）=====
  //
  // ===== 为什么是「淡紫」而不是灰 =====
  // 页面底色（`schedBg` = #E9EAF6）是淡紫的，而早先这几档写成了灰
  // （#F1F3F7 等），于是 M3 卡片在紫底上显得发灰、像掉了一层色 ——
  // 两套材质的观感因此割裂。
  //
  // 现在三档都取自**与底色同一个色相**（约 237°），只差明度：
  //   底色 #E9EAF6 → 卡片 #F2F3FA → 工具条 #F7F8FC → 输入框 #FCFCFF
  // 越接近用户操作的元素越亮（M3 浅色下的 elevation 规则），
  // 于是卡片仍能从底色上「浮」起来，但整页是同一个紫色调，不再发灰。
  //
  // 深浅色关系：色相不变，明度按 M3 规则递增。
  static const Color surfaceContainer = Color(0xFFF2F3FA);
  static const Color surfaceContainerHigh = Color(0xFFF7F8FC);
  static const Color surfaceContainerHighest = Color(0xFFFCFCFF);

  // ===== M3 层次色（深色）=====
  // 深色下方向相反：卡片 `dsurface` 是 #171A21，页面底 `dbg` 是 #0F1115，
  // 因此容器色要比卡片**亮**一档才看得见边界。
  // 同样保持底色那支紫调（把蓝通道抬高、红通道压低）。
  static const Color dsurfaceContainer = Color(0xFF1E2130);
  static const Color dsurfaceContainerHigh = Color(0xFF242838);
  static const Color dsurfaceContainerHighest = Color(0xFF2A2F42);
}

/// 间距与圆角
class Gaps {
  static const double s = 6;
  static const double m = 12;
  static const double l = 20;
  static const double page = 16;

  static const double radius = 14;
  static const double radiusSm = 10;

  /// 药丸形圆角：取一个「足够大」的值即可 —— Flutter 会把超出半高的
  /// 圆角自动收敛为半高，因此不需要在每个控件上按高度算半径。
  /// 用于输入框与按钮（用户要求的样式）。
  static const double pill = 999;

  /// 滚动列表需要在底部额外留出的空白（导航栏高度 + 余量）。
  ///
  /// 为什么需要：`GlassScaffold` 用 `extendBody: true`（内容延伸到玻璃
  /// 导航栏下方），滚动时内容会从玻璃下面穿过 —— 这正是「透明 dock 能
  /// 看到被遮挡内容」的前提。代价是滚到底时最后一项会被玻璃压住，
  /// 因此滚动内容必须补这么高的底部内边距。
  ///
  /// 取值依据：`GlassTabBar.bottom` 的高度约 56vp，再加安全区与呼吸空间。
  /// 不用 MediaQuery 动态算，是因为页面拿不到栏高；固定 96 在所有机型上
  /// 都足够，多一点空白无害，少一点就会遮内容。
  static const double scrollTail = 96;
}

/// 课表卡片配色（成对：底色、字色）。
///
/// ===== 风格改为「实心彩卡 + 白字」（参照成熟课表 App）=====
/// 早先是「浅底 + 深字」，靠低饱和底色保证 8 门课同时出现也不打架，
/// 但视觉上偏平、像表格而不是课表。现在改成实心色块、白字压在上面，
/// 一眼就能按颜色认出「这门课」。
///
/// 取舍与依据：
///   - 实心块 + 白字要能够读，底色就不能太浅。参考同类 App 的取色大多
///     只有 1.8–2.7 的对比度（白字偏糊），这里把同一批**色相**主动加深，
///     把白字对比度提到 3.3–4.6。色相没变，所以观感仍是那一套配色，
///     但小字（教室/教师）也不会糊成一片。
///   - 深浅色模式**共用同一组值**：实心块本身就是「有颜色的面」，
///     在深色背景上同样是可读的亮色块，不必另配一套（另配反而容易漏项）。
class CoursePalette {
  /// [底色, 字色]。字色固定白色，仅保留数组结构以兼容既有调用方。
  static const List<List<Color>> pairs = <List<Color>>[
    <Color>[Color(0xFFC9556F), Color(0xFFFFFFFF)], // 玫瑰
    <Color>[Color(0xFF4A7BD4), Color(0xFFFFFFFF)], // 蓝
    <Color>[Color(0xFF2E9AA0), Color(0xFFFFFFFF)], // 青
    <Color>[Color(0xFFB8833C), Color(0xFFFFFFFF)], // 琥珀
    <Color>[Color(0xFF7A66D4), Color(0xFFFFFFFF)], // 紫
    <Color>[Color(0xFF3E9068), Color(0xFFFFFFFF)], // 绿
    <Color>[Color(0xFFB0568C), Color(0xFFFFFFFF)], // 品红
    <Color>[Color(0xFF5C7CB8), Color(0xFFFFFFFF)], // 蓝灰
  ];

  /// 按课程名散列出稳定的配色
  static List<Color> of(String seed) {
    int h = 0;
    for (int i = 0; i < seed.length; i++) {
      h = (h * 31 + seed.codeUnitAt(i)) % 100000;
    }
    return pairs[h % pairs.length];
  }
}

ThemeData buildTheme(Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  // ===== 为什么要把 M3 的层次色显式补齐 =====
  // 内容面的材质现在有两套（见 theme/material_style.dart），其中 M3 那套
  // 靠 `surfaceContainer / surfaceContainerHigh / surfaceContainerHighest`
  // 三档拉开层次。`ColorScheme.light()/dark()` 的默认构造只给 surface，
  // 其余几档由框架按色调推导 —— 推导结果在浅色下几乎看不出差别，
  // 卡片会「糊」在背景上。
  //
  // 这里直接按本项目既有色号显式给出，好处是与 `AppColors` 里的
  // 卡片色（surface）和底面色（bg）是同一套值，两套材质切换时
  // 页面底与卡片的关系不会突变。
  final ColorScheme scheme = dark
      ? const ColorScheme.dark(
          primary: AppColors.dbrand,
          onPrimary: AppColors.dbg,
          surface: AppColors.dsurface,
          onSurface: AppColors.dtextPrimary,
          error: AppColors.ddanger,
          surfaceContainer: AppColors.dsurfaceContainer,
          surfaceContainerHigh: AppColors.dsurfaceContainerHigh,
          surfaceContainerHighest: AppColors.dsurfaceContainerHighest,
        )
      : const ColorScheme.light(
          primary: AppColors.brand,
          onPrimary: AppColors.onBrand,
          surface: AppColors.surface,
          onSurface: AppColors.textPrimary,
          error: AppColors.danger,
          surfaceContainer: AppColors.surfaceContainer,
          surfaceContainerHigh: AppColors.surfaceContainerHigh,
          surfaceContainerHighest: AppColors.surfaceContainerHighest,
        );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? AppColors.dbg : AppColors.bg,
    dividerColor: dark ? AppColors.ddivider : AppColors.divider,
    cardTheme: CardThemeData(
      color: dark ? AppColors.dsurface : AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Gaps.radius),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? AppColors.dsurface : AppColors.surface,
      foregroundColor: dark ? AppColors.dtextPrimary : AppColors.textPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: dark ? AppColors.dtextPrimary : AppColors.textPrimary,
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: dark ? AppColors.dtextSecondary : AppColors.textSecondary,
    ),
    // 输入框统一药丸形（用户指定样式）。所有 OutlineInputBorder 的各个状态
    // 都要显式给圆角：只设 `border` 时，聚焦/错误态仍会用各自的默认形状。
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? AppColors.dsurfaceVariant : AppColors.surfaceVariant,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      border: _pillBorder,
      enabledBorder: _pillBorder,
      focusedBorder: _pillBorder,
      disabledBorder: _pillBorder,
      errorBorder: _pillBorder,
      focusedErrorBorder: _pillBorder,
      // 标签预留空间：药丸形里标签上浮会显得拥挤，统一内嵌显示
      floatingLabelBehavior: FloatingLabelBehavior.never,
    ),
    // 按钮统一药丸形
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 46),
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 46),
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 44),
        shape: const StadiumBorder(),
      ),
    ),
    // 下拉框也跟随药丸风格，避免同一页里方圆混用
    dropdownMenuTheme: DropdownMenuThemeData(
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? AppColors.dsurfaceVariant : AppColors.surfaceVariant,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        border: _pillBorder,
        enabledBorder: _pillBorder,
        focusedBorder: _pillBorder,
      ),
    ),
    // 各类 Chip 也做成药丸形。
    //
    // 为什么必须在这里统一：Chip 的默认形状是 8px 圆角矩形，
    // 与「输入框/按钮都是药丸」的整套风格明显不搭（课程编辑弹窗里
    // 课程 chip、单双周三连 chip 就是这么漏掉的）。
    // Chip 的 `shape` 只吃 `OutlinedBorder`，所以用 `StadiumBorder`
    // 而不是 `RoundedRectangleBorder`。
    //
    // 另外把 `side` 显式设为透明无宽：否则未选中的 Chip 会带一圈描边，
    // 与已选中的实心 Chip 放在一起显得脏。
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(side: BorderSide.none),
      side: BorderSide.none,
      backgroundColor: dark ? AppColors.dsurfaceVariant : AppColors.surfaceVariant,
      selectedColor: dark ? AppColors.dbrandSoft : AppColors.brandSoft,
      showCheckmark: true,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      labelStyle: TextStyle(
        fontSize: 12,
        color: dark ? AppColors.dtextPrimary : AppColors.textPrimary,
      ),
      secondaryLabelStyle: TextStyle(
        fontSize: 12,
        color: dark ? AppColors.dbrand : AppColors.brand,
      ),
    ),
  );
}

/// 无边框的药丸形输入框描边（各状态复用同一形状）
const OutlineInputBorder _pillBorder = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(Gaps.pill)),
  borderSide: BorderSide.none,
);

/// 文字色：随主题取 primary/secondary/tertiary，避免到处写 `Theme.of(context)` 判断
extension AppTextColors on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  Color get textPrimary =>
      isDark ? AppColors.dtextPrimary : AppColors.textPrimary;

  Color get textSecondary =>
      isDark ? AppColors.dtextSecondary : AppColors.textSecondary;

  Color get textTertiary =>
      isDark ? AppColors.dtextTertiary : AppColors.textTertiary;

  Color get surfaceColor => isDark ? AppColors.dsurface : AppColors.surface;

  Color get surfaceVariant =>
      isDark ? AppColors.dsurfaceVariant : AppColors.surfaceVariant;

  Color get dividerColor => isDark ? AppColors.ddivider : AppColors.divider;

  /// 课表页统一背景色（浅/深主题各一个）
  Color get schedBgColor => isDark ? AppColors.dschedBg : AppColors.schedBg;

  Color get brandColor => isDark ? AppColors.dbrand : AppColors.brand;

  Color get brandSoftColor =>
      isDark ? AppColors.dbrandSoft : AppColors.brandSoft;

  Color get dangerColor => isDark ? AppColors.ddanger : AppColors.danger;

  Color get successColor => isDark ? AppColors.dsuccess : AppColors.success;

  Color get warningColor => isDark ? AppColors.dwarning : AppColors.warning;
}

/// 顶栏（状态栏 + 应用栏）的总高度，单位 vp。
///
/// 页面内容从这条线以下开始 —— 外壳给 `pageBody` 加的就是这个内边距
/// （见 shell.dart 的 `pageBody`）。抽成函数是因为**不止一处需要它**：
/// 外壳用它做内边距，而顶部渐变模糊要用它把自己上探到屏幕顶端
/// （页面自己的 y=0 在顶栏之下，直接 `top: 0` 会把模糊画在内容中间）。
double appBarInset(BuildContext context) =>
    MediaQuery.paddingOf(context).top + kAppBarHeight;

/// 应用栏高度（不含状态栏），与 shell.dart 里给 pageBody 的内边距一致
const double kAppBarHeight = 52;
