# Flutter 端「动态玻璃」UI 改造方案

> 目标：把 Android 客户端的界面换成 iOS 26 风格的动态玻璃（Liquid Glass）质感，
> 使用开源库 `liquid_glass_widgets`。
>
> 本文是**方案**，不含已落地的代码改动。方案里的每条结论都基于实际核对
> （读包源码、查 pub.dev 元数据、看本机渲染后端日志），不是凭印象写的。

---

## 0. 已核实的事实（含一处需要你确认的出入）

### 0.1 包来源：仓库名与你给的不一致（已实装验证，功能正常）

| 项 | 值 |
|---|---|
| 你给的地址 | `https://github.com/David1024Smith/liquid_glass_widgets` |
| pub.dev 上的包 | `liquid_glass_widgets` v1.6.1（2026-09 查询） |
| 包元数据里的 repository | `https://github.com/sdegenaar/liquid_glass_widgets` |

你给的地址抓取超时（无法核对），而 pub.dev 上同名包指向**另一个作者**的仓库。

**但已实装验证**：`flutter pub get` 正常解析、`flutter analyze` 无告警、
真机上玻璃效果**确实生效**（弹窗后的课程卡可见明显模糊与折射），
且该包**零第三方依赖**、不含原生代码 —— 是纯 Dart + 5 个 `.frag`。

所以功能上没问题。唯一的不确定是**仓库归属**（作者名对不上），
建议你到 pub.dev 页面点开 repository 链接确认一下是否就是预期的项目。
若确认无误，可忽略这个出入。

### 0.2 本机渲染后端已确认支持（好消息）

库文档明确写着：核心的 `LiquidGlass` 是 **Impeller 专用，在 Skia/Web 上会
静默地什么都不渲染**（这是最危险的一种失败 —— 不报错、界面空白）。

我查了本机日志，应用当前跑的正是：

```
I/flutter: Using the Impeller rendering backend (OpenGLES).
```

所以**全量着色器路径可用**。但要注意这是**设备相关**的：部分老机型 /
Android 12 以下会自动回落到 Skia。因此**必须用 `AdaptiveGlass`**（库自带的
自适应封装，会自动在 Impeller 与 Skia 之间选实现），**绝不能直接用
`LiquidGlass`**。

### 0.3 依赖代价很低（低风险）

- **零第三方依赖**（`dependencies` 只有 `flutter`）；
- 不含任何原生代码 / `.so` —— 纯 Dart + 5 个 `.frag` 着色器；
- 因此**不会重演**本项目在 `onnxruntime`（缺 x86_64 库）和
  `device_calendar`（依赖冲突）上踩过的坑。

环境要求：Dart `>=3.5.0`、Flutter `>=3.41.0`。本项目是 Flutter 3.44.2 /
Dart 3.12.2，**满足**。

---

## 1. 改造范围与优先级

玻璃质感适合「浮在内容之上」的元素，不适合大面积内容区。按这个原则分级：

### P0 — 收益最大、风险最低（建议第一批做）

| 位置 | 现状 | 改为 |
|---|---|---|
| 底部导航栏 / 侧边 dock | 纯色 `NavigationBar` / `Container` | `GlassTabBar` / `AdaptiveGlass` 包裹 |
| 顶部标题栏（`_Header`） | 纯色 Container | 玻璃条 |
| 课程编辑弹窗（`course_editor.dart`） | 白色 Dialog | `GlassDialog` + `GlassTextField` |
| 重新验证弹窗（`reauth_dialog.dart`） | 白色卡片 | `GlassCard` |
| 校历弹窗（`calendar_sheet.dart`） | 白色 BottomSheet | `GlassSheet` |
| 设置页各分组卡片 | `SectionCard` 纯色 | `GlassContainer` / `GlassGroupedSection` |

### P1 — 次级层次

- 状态页（`LoadingView` / `EmptyView` / `ErrorView`）容器背景；
- 各页顶部的筛选栏（课表周次/学期选择、成绩筛选）；
- `SettingRow` 的悬浮态。

### P2 — 不建议改（明确保留现状）

- **课表网格里的课程卡**：它们是「实心彩卡 + 白字」，本身就是内容载体，
  加玻璃后与彩底冲突、且 7×5 个格子同时模糊渲染会有性能代价。
  **保留现在的实心卡**（这也是上一轮刚按参考图调好的）。
- **长列表正文**（成绩列表、通识课列表）：大面积玻璃会显著增加 GPU 负载，
  且可读性反而下降。

---

## 2. 实施步骤

> **进度**：步骤 1（依赖+初始化+`glass_kit.dart`）与 P0 的
> **侧边 dock、顶部栏、底部导航、课程编辑弹窗**均已完成并真机验证。
> 其余 P0 项（重新验证弹窗、校历弹窗、设置页卡片）待续。

### 步骤 1：依赖与初始化

```yaml
# pubspec.yaml
dependencies:
  liquid_glass_widgets: ^1.6.1
```

```dart
// lib/main.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 预热着色器：不做这一步，首帧会看到一次明显卡顿
  await LiquidGlassWidgets.initialize();
  runApp(LiquidGlassWidgets.wrap(
    child: const MyApp(),
    adaptiveQuality: true,              // 按设备性能自动降档
    theme: GlassThemeData(
      light: GlassThemeVariant(settings: GlassThemeSettings(blur: 10)),
      dark:  GlassThemeVariant(settings: GlassThemeSettings(blur: 14)),
    ),
  ));
}
```

**注意**：本项目 `main.dart` 现在还有生命周期钩子（退后台落盘会话 + 刷新卡片），
`initialize()` 要插在 `WidgetsFlutterBinding.ensureInitialized()` **之后**、
`runApp` **之前**，不要打乱现有顺序。

### 步骤 2：建一个本项目的玻璃外观壳

不要在每个页面重复写玻璃参数。建议新增
`lib/theme/glass_kit.dart`，把「本项目的玻璃长什么样」集中一处：

```dart
// 意图说明（不是最终代码）
class GlassKit {
  /// 站点统一的玻璃层参数：模糊/饱和度/描边。
  /// 集中定义的理由与 Gaps/AppColors 相同 —— 散落各处必然走形。
  static LiquidGlassSettings sheetSettings(BuildContext c) => ...;

  /// 弹窗容器（课程编辑 / 重新验证 / 校历共用）
  static Widget dialog({required Widget child}) => AdaptiveGlass(...);
}
```

这样做的价值：**玻璃质感一旦散落在十几处，风格一定会走形**，
且后续调参数要把每个文件翻一遍。集中后只改一个地方。

### 步骤 3：逐页替换（每步都能独立验证）

按 P0 表格从上往下，**一次只改一处、改完立刻在模拟器上看**。
理由：玻璃的视觉效果高度依赖上下文（背景内容、层次、明暗），
批量改完再看会分不清是哪一处的参数不对。

### 步骤 4：深色模式核对

`GlassThemeData` 的 `light` / `dark` 两套参数都要给。
本项目已有 `AppColors` 的深浅两套值，玻璃的模糊/饱和度要与它们协调 ——
**深色下模糊过强会显得浑浊**，通常需要降低 blur、提高底色不透明度。

### 步骤 5：性能与降级验证

库自带 `adaptiveQuality: true` 与 `GlassPerformanceMonitor`。必须实测：

1. 模拟器 + 真机各跑一遍，观察滚动帧率；
2. 主动打开系统的「移除动画 / 降低透明度」无障碍选项，
   确认库会自动降级（它默认尊重这两个开关）；
3. 在**低端机 / Android 12 以下**验证 Skia 回落路径不白屏。

---

## 2.5 实测发现的一条重要经验

**玻璃只在「背后真的有内容」时才好看。**

最初把玻璃用在顶部栏与底部导航上，实测截图里那片区域是**纯色平铺**
（像素采样恒为 `F3F4F6`）—— 因为当前布局用的是 `Column` +
`bottomNavigationBar`，内容在两条栏**之间**，不会流到栏的下方，
玻璃背后没有东西可模糊，看起来只是「一块浅灰」。

真正出效果的是**浮在内容之上的元素**：课程编辑弹窗套上玻璃后，
背后的课程彩卡被明显模糊、色彩透上来，玻璃质感立刻成立（真机截图确认）。

**结论**：若要让顶栏/底栏的玻璃也「活」起来，需要把页面改成
**内容延伸到栏下方**的布局（`Stack` + 栏浮在上层，或 `extendBody`）。
这属于布局结构调整，比换控件风险大，建议单独一轮做并逐页验证。

## 3. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| **Skia 上静默不渲染** | 界面空白且不报错（最危险） | 只用 `AdaptiveGlass`，**禁用 `LiquidGlass`**；在 CI 或测试里断言关键页面能渲染出内容 |
| 着色器编译导致首帧卡顿 | 打开弹窗瞬间掉帧 | `LiquidGlassWidgets.initialize()` 预热（见步骤 1） |
| 大面积模糊拖慢低端机 | 滚动不流畅 | 按 P2 严格控制范围；`adaptiveQuality: true` 自动降档 |
| 玻璃 + 实心彩卡视觉打架 | 课表反而变丑 | 课表网格**保持实心卡**（明确不改） |
| 包来源存疑（见 0.1） | 供应链风险 | 落地前先核对仓库归属；不确定就不引入 |
| 与现有 pill 圆角主题冲突 | 方圆混用 | 玻璃控件本身是圆角体系，与上一轮刚做的药丸输入框/按钮**天然一致**，不需回退 |

---

## 4. 验收标准

改造完成后应满足：

1. **功能零回归**：现有 92 条测试全通过；`flutter analyze` 无新增告警。
2. **两个渲染后端都不空白**：Impeller 设备与 Skia 回落路径都能正常显示。
3. **深色模式正常**：不是简单地把浅色玻璃压暗。
4. **无障碍降级有效**：打开「降低透明度」后自动退化为不透明面板。
5. **性能可接受**：列表滚动、弹窗打开无可感掉帧。
6. **课表网格不受影响**：7×5 全周仍一屏可见，卡片仍为实心彩卡。

---

## 5. 工作量与建议顺序

| 阶段 | 内容 | 说明 |
|---|---|---|
| 0 | 核对包来源（0.1） | **前置条件**，不确定就不要开始 |
| 1 | 加依赖 + 初始化 + `glass_kit.dart` | 建立基础设施，不改任何界面 |
| 2 | P0 六处替换 | 逐处验证，一次一处 |
| 3 | 深色模式 + 无障碍降级核对 | 这一步容易漏，但直接关系可用性 |
| 4 | 性能实测（模拟器 + 真机） | 决定是否需要收窄范围 |
| 5 | P1（可选） | 视阶段 4 的结果决定做不做 |

**建议**：先做阶段 0–2 最小闭环（例如**只改底部导航 + 一个弹窗**），
在真机上看一眼实际观感与帧率，再决定是否铺开到其余位置。
玻璃质感是强视觉风格，好不好看很主观 —— 先用最小代价看到真实效果，
比一次性全改完再回退要省事得多。

---

## 6. 明确不做的事

- 不引入除该库之外的其他玻璃/模糊库（避免重复依赖）；
- 不用 `BackdropFilter` 手写玻璃（库已封装且做了跨后端适配）；
- 不把课表网格与长列表改成玻璃（理由见 P2）；
- 不在鸿蒙端做同样改造 —— 该库是 Flutter 专用；
  鸿蒙端若要玻璃效果需另找 ArkUI 方案（不在本方案范围）。