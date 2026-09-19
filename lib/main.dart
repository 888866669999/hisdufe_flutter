/// 应用入口
library;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'data/app_state.dart';
import 'data/card_snapshot_store.dart';
import 'data/pref_store.dart';
import 'data/reminder_service.dart';
import 'pages/shell.dart';
import 'theme/material_style.dart';
import 'theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 预先编译玻璃着色器。不做这一步，首次打开带玻璃的界面会明显卡一下
  // （着色器编译发生在首帧）。失败也不该阻止启动 —— 玻璃只是外观。
  try {
    await LiquidGlassWidgets.initialize();
  } catch (_) {
    // 忽略：拿不到玻璃就退化为普通界面，不影响任何功能
  }
  await PrefStore.init();
  // 外观材质要在 build 之前读出来：否则首帧会以默认 M3 渲染，
  // 用户选的是玻璃时会看到一次闪烁。
  SurfaceStyleController.load();
  await AppState.instance.init();
  // 通知初始化尽早做：越早注册，系统越不容易把排定的提醒丢掉
  await ReminderService.init();
  runApp(const SdufeApp());
}

class SdufeApp extends StatefulWidget {
  const SdufeApp({super.key});

  @override
  State<SdufeApp> createState() => _SdufeAppState();
}

class _SdufeAppState extends State<SdufeApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 前后台切换时维护会话与卡片快照。
  ///
  /// 为什么需要：服务器可能在交互过程中轮换过 JSESSIONID，及时写回本地
  /// 才能保住登录态；卡片快照同理（桌面卡片由系统进程读取）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final AppState app = AppState.instance;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      app.persistSession();
      CardSnapshotStore.refresh(app.timetable, app.semesterStart);
    } else if (state == AppLifecycleState.resumed) {
      // 回到前台也同步一次卡片。
      //
      // 为什么两处都要：退到后台那次推送**可能来不及完成** ——
      // 进程随时会被系统冻结或回收，异步的「写盘 + 通知卡片」就断在半路，
      // 桌面于是停在旧内容。回到前台时应用确定还活着，补一次几乎必然成功。
      // 这是纯本地计算（不联网），开销可以忽略。
      CardSnapshotStore.refresh(app.timetable, app.semesterStart);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 玻璃主题包裹整个应用。`adaptiveQuality: true` 让库按设备性能自动降档，
    // 避免低端机上因大面积模糊而掉帧。
    //
    // 注意：这里**不**用 `LiquidGlass` 直接包 —— 它是 Impeller 专用，
    // 在 Skia 上会静默不渲染。玻璃元素统一走 `GlassKit`
    // （内部用 AdaptiveGlass 自动适配后端）。
    // 材质切换要**整棵树重建**：各页面在 build 里读
    // `SurfaceStyleController.isGlass` 决定表面怎么画，
    // 而 MaterialApp 本身还带着主题色。所以在这里监听一次。
    return ValueListenableBuilder<AppSurfaceStyle>(
      valueListenable: SurfaceStyleController.style,
      builder: (BuildContext context, AppSurfaceStyle style, _) =>
          LiquidGlassWidgets.wrap(
      adaptiveQuality: true,
      child: MaterialApp(
        title: 'hi山财',
        debugShowCheckedModeBanner: false,
        // ===== 去掉滚动到边界时的「变白再恢复」 =====
        //
        // Android 12+ 默认的 overscroll 效果是 **stretch**：滚到顶/底时把
        // 整个列表内容拉伸，并在边缘叠一层系统色 —— 浅色下就是明显的
        // 一条白，深色模式反差更大（用户反馈「短时间变白然后恢复」）。
        // 这个效果对本应用是纯干扰：玻璃 UI 上出现一条不透明的白色拉伸带
        // 非常突兀，而且列表在边界处本就不该有视觉变化。
        //
        // 修法是换掉 `ScrollBehavior`：`buildOverscrollIndicator` 直接返回
        // 子树，不叠任何指示器。同时保留 BouncingScrollPhysics 之外的
        // 平台默认物理（不改滚动手感，只去掉那层视觉）。
        scrollBehavior: const _NoOverscrollBehavior(),
        // liquid_glass_widgets 刻意不依赖 Material，因此它内部**不提供**
        // Material 祖先。而 Flutter 的 Text 在 MaterialApp 下要求树里有
        // 一个 Material —— 缺了会整屏抛
        // 「No Material widget found」并显示黄黑警告（实测踩到过）。
        // 官方 README 给的修法就是这一行：包一个透明 Material。
        builder: (BuildContext context, Widget? child) => Material(
          type: MaterialType.transparency,
          child: child!,
        ),
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        // 跟随系统深浅色
        themeMode: ThemeMode.system,
        home: const AppShell(),
      ),
    ),
    );
  }
}

/// 不绘制 overscroll 指示器的滚动行为。
///
/// 只覆盖 `buildOverscrollIndicator`：滚动物理、手势、回弹全部沿用平台默认，
/// 因此只去掉「到边界时那层拉伸/发光」的视觉效果，不改操作手感。
class _NoOverscrollBehavior extends MaterialScrollBehavior {
  const _NoOverscrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // 直接返回子树 = 不叠任何指示器
    return child;
  }
}
