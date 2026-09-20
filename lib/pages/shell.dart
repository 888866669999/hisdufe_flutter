/// 应用外壳：响应式布局 + 登录门卫
///
/// 从鸿蒙版 `pages/Index.ets` 移植。
///
/// ===== 响应式策略（手机 / 平板 / 折叠屏）=====
/// 用断点而不是设备类型判断，因此**折叠屏展开/折叠、分屏、自由窗口
/// 都能实时切换布局**，不需要任何设备特判：
///   - 宽度 < 600：底部导航栏（手机竖屏）
///   - 600–840：左侧导航 + 内容（小平板 / 折叠屏展开 / 手机横屏）
///   - >= 840：左侧导航更宽 + 内容限制最大宽度（大平板）
///
/// ===== 会话失效的处理 =====
/// 会话失效**不会**把用户踢回登录页：课表来自本地缓存，只看课表必须安静。
/// 只有用户点到需要联网的功能、请求被打回登录页时，才弹重新验证弹窗。
library;

import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/campus_calendar_service.dart';
import '../data/credential_store.dart';
import '../data/pref_store.dart';
import '../data/reminder_service.dart';
import '../data/re_auth_service.dart';
import '../data/semester_calendar_service.dart';
import '../data/week_service.dart';
import '../model/models.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import '../widgets/reauth_dialog.dart';
import '../widgets/top_fade_blur.dart';
import 'classroom_page.dart';
import 'elective_page.dart';
import 'login_page.dart';
import 'plan_page.dart';
import 'profile_page.dart';
import 'schedule_page.dart';
import 'score_page.dart';
import 'settings_page.dart';
import 'top_bar_slot.dart';

class NavItem {
  const NavItem(this.key, this.label, this.icon);

  final String key;
  final String label;
  final IconData icon;
}

/// 底部 dock 与宽屏侧栏的导航项。
///
/// **不含「空教室」**：它只保留课表页右上角那一个入口。
/// 早先三个地方都能进空教室（顶栏、dock、侧栏），属于重复入口；
/// 收敛到一个之后，dock 少一项、每项也宽一些。
/// 「空教室」页面本身仍在（见 _pageFor），只是到达路径只剩一条。
const List<NavItem> kNavItems = <NavItem>[
  NavItem('schedule', '课表', Icons.calendar_month_outlined),
  NavItem('score', '成绩', Icons.bar_chart_outlined),
  NavItem('plan', '培养', Icons.menu_book_outlined),
  NavItem('elective', '通选', Icons.extension_outlined),
  NavItem('profile', '我的', Icons.person_outline),
];

/// 不在导航项里、但有独立标题的页面。
///
/// 这些页面通过别的入口到达（设置从「我的」进、空教室从课表顶栏进），
/// 因此不在 kNavItems 中，但顶栏标题仍要正确显示 —— 否则会统一落到
/// 「hi山财」这个兜底文案上。
const Map<String, String> kExtraPageTitles = <String, String>{
  'settings': '设置',
  'classroom': '空教室',
};

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final AppState _app = AppState.instance;
  bool _restoring = true;
  String _active = 'schedule';

  /// 每个页面的重建代数：切账号/重新验证后自增，强制页面重建以丢弃旧数据
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _app.addListener(_onAppChanged);
    _restore();
  }

  @override
  void dispose() {
    _app.removeListener(_onAppChanged);
    super.dispose();
  }

  void _onAppChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 切换页面（**用户主动**导航的唯一入口）。
  ///
  /// 除了改 `_active`，还要给 ReAuthService 留一个「这次是用户发起的」标记：
  /// 新页面的 `initState` 会自动拉数据，若此时会话已失效，需要立刻尝试
  /// 静默续期而不是等用户再点一次「重试」。见 ReAuthService.noteUserIntent。
  void _go(String key) {
    if (key == _active) {
      return;
    }
    ReAuthService.noteUserIntent();
    setState(() => _active = key);
  }

  /// 进入/退出设置时记住来路，实现「从哪来到哪去」。
  ///
  /// 早先点设置后关闭只会回课表 —— 用户从「成绩」进设置、关掉却落到课表，
  /// 得再点一次才能回到原处。这里在**进入**设置前记下来路，
  /// 退出时回到它；若来路本身就是设置（不该发生）则退回课表兜底。
  void _toggleSettings() {
    if (_active == 'settings') {
      final String back = _settingsFrom;
      _settingsFrom = 'schedule';
      _go(back);
    } else {
      _settingsFrom = _active;
      _go('settings');
    }
  }

  /// 进入设置前的页面（仅用于退出设置时回退）
  String _settingsFrom = 'schedule';

  Future<void> _restore() async {
    await _app.restoreSession();
    // 有凭据时刷新标记，供重新验证弹窗决定形态
    final bool hasCred = await CredentialStore.exists();
    _app.hasCredential = hasCred;

    // 本地**没有会话**但密钥库里有账号密码 → 直接自动登录。
    //
    // 这是用户明确要求的「不需要有任何感知」：以前这种情况会停在登录页，
    // 要求用户重新输入账号密码（甚至还要填验证码）—— 而凭据明明已经保存了。
    // 现在把这几秒花在启动页上，用户看到的只是「加载久一点」，
    // 登进去之后一切照旧。
    //
    // 为什么要包超时：自动登录最多要跑两轮「取验证码 + 识别 + 提交」，
    // 网络极差时可能拖很久；启动页不能无限期停住。超时后先落到登录页，
    // 而那次登录仍在后台进行 —— 一旦成功，AppState 会通知界面自动进入应用，
    // 所以用户不会白等，也不会卡死。
    if (!_app.loggedIn && hasCred) {
      try {
        await ReAuthService.autoLoginAtStartup(attempts: 2)
            .timeout(const Duration(seconds: 30));
      } catch (_) {
        // 超时或异常都按「没登上」处理，让下面的流程正常收尾。
        // 注意：底层那次登录不会被取消，成功时仍会通知界面自动进入应用。
      }
    }

    // 与系统时间对齐当前周（超过 6 小时才真正重算）
    await WeekService.align();
    // 开学日期没设过时，从教务系统的教学周历里取 —— 那份数据学校每学期录入，
    // 因此**换学年会自动跟上**，用户不必手动填日期。
    // 放在 align 之后：先让用户手填的值生效，只在空缺时才去补。
    await _deriveSemesterStartIfMissing();
    if (mounted) {
      setState(() => _restoring = false);
    }
    // 启动时做一次静默续期尝试：**成功则无感，失败什么都不做**（不弹窗）
    _trySilentRenewal();
    // 重排上课提醒（课表可能已变、也可能跨周了）
    _rescheduleReminders();
    // 校历/作息：只在缓存过期时才联网（学校一学期才更新一次，
    // 每次启动都抓纯属浪费流量与电量）
    _refreshCampusCalendarIfStale();
  }

  /// 开学日期为空时，用教学周历补上。
  ///
  /// 为什么值得做：周次显示、上课提醒、桌面卡片全都依赖开学日期，
  /// 而在此之前它**只能靠用户手动设置** —— 不设就一律算不出周次，
  /// 首次安装的用户看到的就是「第 1 周」这种默认值。
  /// 权威值本来就在教务系统的周历里，取一次即可。
  ///
  /// 失败静默：断网时什么都不做，界面与以前一致。
  Future<void> _deriveSemesterStartIfMissing() async {
    if (_app.semesterStart.isNotEmpty) {
      return;
    }
    // 优先用课表里带的学期（更贴合用户当前看的那个），
    // 课表还没加载过则退回上次用过的学期
    String code = _app.timetable?.semester ?? '';
    if (code.isEmpty) {
      code = PrefStore.loadLastSemester();
    }
    if (code.isEmpty) {
      // 两个都没有（全新安装、还没进过课表）→ 交给服务端给的当前学期
      final List<ChoiceItem> sems = await SemesterCalendarService.semesters();
      if (sems.isEmpty) {
        return;
      }
      code = sems.first.value;
    }
    await SemesterCalendarService.load(code);
  }

  /// 校历缓存超过 7 天就后台静默刷新一次。
  /// 失败什么都不做 —— 会继续用上次缓存或内置数据，绝不打扰用户。
  Future<void> _refreshCampusCalendarIfStale() async {
    try {
      if (!CampusCalendarService.isStale()) {
        return;
      }
      await CampusCalendarService.refresh();
    } catch (_) {
      // 校历抓取失败不应影响任何主流程
    }
  }

  /// 启动时的**静默**续期。
  ///
  /// 行为约定（用户要求「登录后到退出登录前不要有任何打扰」）：
  ///   - 会话还有效 → 顺手把服务器轮换过的 cookie 写回本地；
  ///   - 会话失效 → 用已保存的账号密码 + OCR 自动登录，成功则无感续上，
  ///     页面照常可用；
  ///   - 续期失败 → **什么都不做**：不弹窗、不置标记、不退出登录。
  ///     课表来自本地缓存，所以此时界面依旧正常；等用户真正点到需要
  ///     联网的功能时，才由那一次请求的失败去提示（见 recoverIfExpired）。
  ///
  /// 这里刻意**不**调用 markReauthPending：早先那样做会导致一启动就弹
  /// 「需要重新登录」，而用户可能只是想看一眼课表。
  Future<void> _trySilentRenewal() async {
    try {
      await ReAuthService.renewSilently();
    } catch (_) {
      // 任何异常都不该影响进入界面
    }
  }

  Future<void> _rescheduleReminders() async {
    try {
      if (!_app.loggedIn) {
        return;
      }
      if (_app.timetable == null) {
        return;
      }
      if (!await ReminderService.notificationEnabled()) {
        return;
      }
      await ReminderService.reschedule(_app.timetable, _app.semesterStart);
    } catch (_) {
      // 提醒失败不应影响主流程
    }
  }

  Widget _pageFor(String key) {
    switch (key) {
      case 'schedule':
        return SchedulePage(
          key: ValueKey<String>('schedule-$_epoch'),
          onOpenClassroom: () => _go('classroom'),
        );
      case 'score':
        return ScorePage(key: ValueKey<String>('score-$_epoch'));
      case 'plan':
        return PlanPage(key: ValueKey<String>('plan-$_epoch'));
      case 'elective':
        return ElectivePage(key: ValueKey<String>('elective-$_epoch'));
      case 'classroom':
        return ClassroomPage(key: ValueKey<String>('classroom-$_epoch'));
      case 'profile':
        return ProfilePage(
          key: ValueKey<String>('profile-$_epoch'),
          onOpenSettings: _toggleSettings,
        );
      case 'settings':
        return SettingsPage(key: ValueKey<String>('settings-$_epoch'));
      default:
        return SchedulePage(key: ValueKey<String>('schedule-$_epoch'));
    }
  }

  String _titleOf() {
    final String? extra = kExtraPageTitles[_active];
    if (extra != null) {
      return extra;
    }
    for (final NavItem n in kNavItems) {
      if (n.key == _active) {
        return n.label;
      }
    }
    return 'hi山财';
  }

  @override
  Widget build(BuildContext context) {
    // 处理系统返回键 / 返回手势。
    //
    // 早先**完全没有返回键处理**：AppShell 用 `_active` 切换页面（不是
    // push 路由），因此系统返回一律直接退出应用 —— 在设置页按返回会
    // 把整个应用关掉，而不是回到进来的那一页。这与「从哪来到哪去」
    // 直接冲突（真机实测：从「我的」进设置，按系统返回直接回到桌面）。
    //
    // 现在的行为按惯例分三档：
    //   - 设置页：回到进来之前的那一页（见 _toggleSettings 的 _settingsFrom）
    //   - 其它非课表页：回到课表（tab 导航的通用约定）
    //   - 课表页：交还系统 → 退出应用（首页该有的行为）
    //
    // canPop 用 `_active == 'schedule'` 表达「只有首页允许真退出」，
    // 其余页面通过 onPopInvokedWithResult 自行处理。
    return PopScope(
      canPop: _active == 'schedule',
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return; // 已经真的退出，无需再处理
        }
        if (_active == 'settings') {
          _toggleSettings();
        } else {
          _go('schedule');
        }
      },
      child: _buildScaffold(context),
    );
  }

  /// 设置页：整屏的玻璃页面（顶栏 + 内容），不带 dock / 侧栏。
  Widget _settingsScreen(BuildContext context) {
    return GlassScaffold(
      extendBody: true,
      backgroundColor: context.schedBgColor,
      contentAwareBrightness: false,
      edgeFade: false,
      appBar: GlassAppBar(
        centerTitle: false,
        leading: GlassIconButton(
          onPressed: _toggleSettings,
          size: 32,
          iconSize: 18,
          icon: Icon(Icons.arrow_back, color: context.textPrimary),
        ),
        title: Text(
          '设置',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: context.textPrimary,
          ),
        ),
      ),
      // 无 bottomBar：整屏归设置页
      body: Stack(
        children: <Widget>[
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              // 顶部让位由设置页自己放进**滚动内容**里（见 SettingsPage.build），
              // 这样内容会从顶栏下经过、被下面的 TopFadeBlur 糊掉。
              // 若由外壳加在这里（视口上），那块区域永远是背景色，模糊无物可糊。
              child: SettingsPage(key: ValueKey<String>('settings-$_epoch')),
            ),
          ),
          const TopFadeBlur(),
        ],
      ),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    if (_restoring) {
      // ===== 这就是「进应用时的那个闪屏」=====
      // 早先这里放的是 `Icons.school_outlined` —— 它是 Material 自带的
      // 「带学士帽的小人」通用图标，和本校没关系，看起来就像没做完。
      // 现在换成真实校徽（`assets/logo.png`，由 tools/make_app_icon.py
      // 从原始笔触图反解白底得到，与桌面图标同一份源）。
      //
      // 高度写死而不是给宽度：校徽是 1.44:1 的横图，锁定**高度**才能让
      // 它在不同屏幕上视觉体量一致；给宽度的话窄屏上会显得很矮。
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Image.asset('assets/logo.png', height: 64),
              const SizedBox(height: 12),
              Text(
                'hi山财',
                style: TextStyle(fontSize: 18, color: context.textPrimary),
              ),
            ],
          ),
        ),
      );
    }

    if (!_app.loggedIn) {
      return LoginPage(
        onLoggedIn: () {
          setState(() {
            _epoch++;
            _active = 'schedule';
          });
          _rescheduleReminders();
        },
      );
    }

    // 设置页**整屏覆盖**，不显示 dock 与侧栏。
    //
    // 为什么单独处理：设置是「离开当前工作区」的模态页面，不是与课表/成绩
    // 并列的第五个 tab。原先它走同一套 GlassScaffold，于是：
    //   1. 底部 dock 仍然显示，而设置不在 kNavItems 里 → `_navIndex()`
    //      找不到就回落到 0 → **dock 上「课表」被高亮**，
    //      看起来像「我还在课表，只是内容变了」；
    //   2. 宽屏下左侧导航栏也还在，设置只占了右边一块。
    // 现在它自己撑满整屏（顶栏带返回箭头），语义与观感都正确。
    if (_active == 'settings') {
      return _settingsScreen(context);
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        final bool wide = w >= kBpMedium;
        final bool veryWide = w >= kBpLarge;

        // 页面内容（不含顶栏 —— 顶栏交给 GlassScaffold 的 appBar，
        // 这样内容会滚动到它下方，玻璃才有东西可折射）
        //
        // 顶部让位：默认由外壳补出「状态栏 + 顶栏」的高度，把页面首行
        // 推到顶栏下方。
        //
        // ⚠️ 注意这是加在**视口**上的内边距，因此该区域永远是背景色，
        // 内容到不了那里（也就谈不上从顶栏下滚过）。需要「内容从顶栏下
        // 穿过 + 顶部渐变模糊」的页面必须自己接管这段让位：
        // 把内边距放进**滚动内容**里（与底部的 `Gaps.scrollTail` 对称），
        // 这样首项仍从栏下开始，而滚动时内容会经过顶栏区域。
        //
        // 目前接管的是培养方案与通选两页（它们的顶栏下有滚动列表，
        // 模糊才有实际内容可糊）；其余页面顶部是统计栏/固定网格，
        // 没有可滚过的内容，继续由外壳让位即可。
        final bool pageHandlesTopInset =
            _active == 'plan' || _active == 'elective' || _active == 'profile';
        final Widget pageBody = Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            // 超宽屏限制内容宽度，避免一行文字横跨整屏难以阅读
            constraints: BoxConstraints(
              maxWidth: veryWide ? 980 : double.infinity,
            ),
            child: pageHandlesTopInset
                ? _pageFor(_active)
                : Padding(
                    padding: EdgeInsets.only(top: appBarInset(context)),
                    child: _pageFor(_active),
                  ),
          ),
        );

        // 宽屏：侧栏 + 内容；窄屏：只有内容
        final Widget body = wide
            ? Row(
                children: <Widget>[
                  _SideNav(
                    // 侧栏宽度随可用宽度收缩：横屏时屏幕高、宽都紧张，
                    // 固定 180/220 会把课表 7 列挤得很窄。
                    // 下限 132 仍能放下「空教室」这样的 3 字标签。
                    width: (c.maxWidth * (veryWide ? 0.14 : 0.17)).clamp(
                      132.0,
                      veryWide ? 220.0 : 180.0,
                    ),
                    active: _active,
                    onSelect: (String k) => _go(k),
                    onSettings: _toggleSettings,
                    settingsActive: _active == 'settings',
                    name: _app.studentName,
                  ),
                  Expanded(child: pageBody),
                ],
              )
            : pageBody;

        return Stack(
          children: <Widget>[
            // 用 GlassScaffold 而不是 Scaffold，原因是它默认
            // `extendBody: true` —— **内容会延伸到顶栏/底栏下方**。
            // 这是玻璃能否「活」起来的前提：玻璃要把背后的内容模糊透出，
            // 若内容只占两条栏之间的区域，玻璃背后什么都没有，
            // 看起来就只是一块浅灰（这是实测踩过的坑）。
            // 它还顺带处理了层级顺序与滚动边缘淡出。
            GlassScaffold(
              // 关键：`extendBody: true` —— 内容延伸到顶栏/底栏下方。
              //
              // **这是「透明 dock」能成立的前提**：只有内容能从玻璃下面
              // 滚过，玻璃中心透明才有意义 —— 用户要的正是「能看到被 dock
              // 遮挡的内容」。曾一度设为 false（库会把 body 用 Positioned
              // 精确裁到两条栏之间），后果是内容永远到不了 dock 下方，
              // 玻璃背后只剩纯色底。真机实测：滚动时 dock 带内像素极差为 0
              // （上方内容带为 10–17），即内容从未穿过玻璃。
              //
              // 代价与对策：
              //   1. 顶栏会压住页面自己的筛选栏 → 页面顶部由
              //      `PaddedPageTop` 补一条安全内边距。
              //   2. 滚到底时最后一项被玻璃压住 → 各页滚动内容补
              //      `Gaps.scrollTail`（见各页 ListView 的 padding）。
              extendBody: true,
              // 渐变底：玻璃需要一个有层次、有颜色的背景才显得出通透感；
              // 纯色底会让玻璃看起来像「一块稍微不同色的板」。
              // 统一底色：与课表表格同一色号（此前是渐变，导致整页出现
              // 三种底色 —— 筛选栏白、表格渐变、底部栏白，看着不统一）。
              backgroundColor: context.schedBgColor,
              // **刻意关闭** contentAwareBrightness：
              // 它会在每帧对整块内容做一次截图式采样来判断明暗，再翻转顶栏文字色。
              // 对一个「浅色/深色固定」的应用来说这个能力用不上，
              // 但代价是实打实的每帧全屏重绘 + 额外离屏层 —— 这是流畅度差的主因之一。
              // 顶栏文字色由主题决定即可，不需要按背景动态翻转。
              contentAwareBrightness: false,
              // 同理关掉滚动边缘淡出：它同样依赖离屏层采样。
              // 视觉上只少了「内容滚到栏下方时的一点渐隐」，收益远小于代价。
              edgeFade: false,
              appBar: GlassAppBar(
                centerTitle: false,
                // 设置页的返回箭头。
                //
                // 为什么需要它：设置入口现在有两个（「我的」卡片右侧、课表页
                // 右上角的空教室旁边不再是设置），进来之后顶栏必须有出路。
                // 系统返回键能退（见 build 里的 PopScope），但手势导航的机器
                // 上返回手势不总是显式可见，给一个明确箭头更稳妥。
                // 只在设置页出现，其余页面顶栏保持干净。
                leading: _active == 'settings'
                    ? GlassIconButton(
                        // 注意：GlassIconButton 用 onPressed，GlassButton 用
                        // onTap —— 两者相反，容易写错。
                        onPressed: _toggleSettings,
                        size: 32,
                        iconSize: 18,
                        icon: Icon(Icons.arrow_back,
                            color: context.textPrimary),
                      )
                    : null,
                // 标题与「当前页面提交的控件」并排放在 title 槽里。
                //
                // 为什么不能把控件放到 actions：`GlassAppBar` 的布局代理
                // 先用 `BoxConstraints.loose` 量出 actions 的**固有宽度**，
                // 再把标题限制为 `栏宽 − 2 × actions宽`（居中标题的等边距
                // 约束）。actions 里一旦有 Expanded/Flexible 这类「占满可用
                // 宽度」的子节点，量出来的 actions 宽就等于整条栏宽，
                // 标题被压成 0 宽 —— 真机表现为「课表」两个字直接消失。
                //
                // 放进 title 槽则相反：title 拿到的是「扣掉 actions 之后的
                // 剩余宽度」，随我们分配。
                title: ValueListenableBuilder<Widget?>(
                  valueListenable: TopBarSlot.controls,
                  builder: (BuildContext context, Widget? controls, _) {
                    // ===== 课表页为什么不要标题 =====
                    // 课表页的顶栏里已经排了「周次 / 学期 / 校历 / 空教室」
                    // 四个控件，它们才是这一页真正要操作的东西；左边再挂一个
                    // 「课表」二字，既占掉一行里最紧俏的横向空间，又是纯冗余
                    // ——当前在哪一页，底部 dock 的高亮已经说明了。
                    //
                    // 去掉标题后收回的宽度全部给控件，周次与学期不再被压缩。
                    // 其余页面（培养/成绩/通选/我的）顶栏没有控件，标题是
                    // 唯一的方位标识，保留。
                    //
                    // 条件里带上 `controls != null`：课表页在加载中或加载失败时
                    // 不会提交控件（见 schedule_page 的 build），那种情况下顶栏
                    // 会整条空掉，只剩个标题反而更好。
                    final bool bare = _active == 'schedule' && controls != null;
                    return Row(
                      children: <Widget>[
                        if (!bare) ...<Widget>[
                          Text(
                            _titleOf(),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        // 页面控件占满剩余宽度。
                        //
                        // 早先这里还套了一层 Align(centerRight)，控件只能按自身
                        // 固有宽度靠右排 —— 于是周次/学期被挤成「26-…」这种截断。
                        // 去掉 Align 后 Expanded 把整段宽度交给页面，页面自己用
                        // Expanded 分配（见 schedule_page 的 _topBarControls）。
                        Expanded(
                          child: controls ?? const SizedBox.shrink(),
                        ),
                      ],
                    );
                  },
                ),
                actions: <Widget>[
                  // 顶栏右侧不再放任何按钮。
                  //
                  // 设置入口已移到「我的」页个人卡片右侧；课表页右上角的
                  // 位置让给空教室快捷入口（由页面自己通过 TopBarSlot 提交，
                  // 见 schedule_page 的 _topBarControls）。
                  // 腾出来的 44+8px 全部还给周次与学期两个选择器。
                  //
                  // 姓名只在宽屏显示：窄屏顶栏本来就挤，而「我的」页首屏
                  // 就有姓名，顶栏再重复一遍是噪音。
                  if (_app.studentName.isNotEmpty && wide)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Center(
                        child: Text(
                          _app.studentName,
                          style: TextStyle(
                            fontSize: 13,
                            color: context.textTertiary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              // 窄屏底部导航：玻璃胶囊标签栏（iOS 26 风格）
              bottomBar: wide
                  ? null
                  : GlassTabBar.bottom(
                      // 更透明的玻璃：用户要求「能看到被 dock 遮挡的内容」。
                      // 默认参数在白底页面上偏实，会挡住下方文字；
                      // 这里把底色透明度调低、厚度调小，让内容透出来。
                      settings: GlassKit.tabBarSettings(context),
                      // 去掉选中标签底下那层胶囊。
                      //
                      // 库默认给选中项画一层「标签色 × 10% 透明度」的实心胶囊
                      // （浅色主题下就是 10% 的黑），它把背景**压暗**，
                      // 是 dock 通透感最大的障碍 —— 玻璃再透，那层黑还在。
                      //
                      // 代价与对策见下面的 tabs：库的选中/未选中图标与文字
                      // **默认是同一个颜色**（只差 1.15 倍放大与字重），
                      // 所以去掉胶囊后必须自己把选中态用颜色表达出来，
                      // 否则看不出当前在哪个 tab。
                      indicatorColor: Colors.transparent,
                      selectedIndex: _navIndex(),
                      onTabSelected: (int i) {
                        if (i < kNavItems.length) {
                          _go(kNavItems[i].key);
                        }
                      },
                      tabs: <GlassTab>[
                        for (int i = 0; i < kNavItems.length; i++)
                          GlassTab(
                            // 选中态用品牌蓝、未选中用次级文字色 —— 与应用
                            // 其它地方（鸿蒙端 dock、桌面侧边栏）同一套语言：
                            // 高亮的那个是当前页。
                            //
                            // 直接给 Icon 上色，而不是用库的
                            // selectedIconColor 等参数：自己着色不依赖
                            // 具体版本的参数名，升级更安全。
                            icon: Icon(
                              kNavItems[i].icon,
                              color: _navIndex() == i
                                  ? context.brandColor
                                  : context.textSecondary,
                            ),
                            label: kNavItems[i].label,
                          ),
                      ],
                    ),
              body: body,
            ),
            // 重新验证弹窗仍浮在最上层
            if (_app.reauthPending)
              ReAuthDialog(
                onDone: () {
                  setState(() {
                    _epoch++;
                    _app.clearReauthPending();
                  });
                },
                onGiveUp: () async {
                  await ReAuthService.giveUp();
                  setState(() {});
                },
              ),
          ],
        );
      },
    );
  }

  int _navIndex() {
    final int i = kNavItems.indexWhere((NavItem n) => n.key == _active);
    return i < 0 ? 0 : i;
  }
}

class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.width,
    required this.active,
    required this.onSelect,
    required this.onSettings,
    required this.settingsActive,
    required this.name,
  });

  final double width;
  final String active;
  final ValueChanged<String> onSelect;
  final VoidCallback onSettings;
  final bool settingsActive;
  final String name;

  @override
  Widget build(BuildContext context) {
    // 侧边 dock 与头部同属浮层：玻璃让下层内容透出来
    return SizedBox(
      width: width,
      child: GlassKit.surface(
        context,
        radius: 0,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gaps.m,
                  Gaps.m,
                  Gaps.m,
                  Gaps.m,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'hi山财',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                    ),
                    if (name.isNotEmpty)
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textTertiary,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    for (final NavItem n in kNavItems)
                      _navTile(
                        context,
                        n.icon,
                        n.label,
                        n.key == active,
                        () => onSelect(n.key),
                      ),
                    const SizedBox(height: 8),
                    const Divider(height: 1),
                    _navTile(
                      context,
                      Icons.settings_outlined,
                      '设置',
                      settingsActive,
                      onSettings,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navTile(
    BuildContext context,
    IconData icon,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? context.brandSoftColor : Colors.transparent,
          borderRadius: BorderRadius.circular(Gaps.radiusSm),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 20,
              color: selected ? context.brandColor : context.textSecondary,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? context.brandColor : context.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 断点常量（与鸿蒙版同一组数值）
const double kBpMedium = 600;
const double kBpLarge = 840;
