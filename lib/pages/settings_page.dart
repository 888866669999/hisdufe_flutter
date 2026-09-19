/// 设置页
///
/// 从鸿蒙版 `pages/SettingsPage.ets` 移植，并**做了明显精简**。
///
/// ===== 只保留「用户会真的去改」的设置 =====
/// 正式上架的版本里不应出现任何测试性/开发期功能。因此以下内容
/// **一律不放进设置页**（两端同步遵守）：
///
///   1. **验证码识别（OCR）整组**：识别能力自检、模型自检、
///      识别率批量评测、语料目录准备 —— 这些是我用来量化识别率、
///      给模型选型的工具。识别率由自动化测试（`test/` 与 `testdata/`）
///      持续看守，不需要用户按按钮来验证。
///   2. **「发一条测试提醒」** —— 端到端调试通知链路用的，正式版无意义。
///   3. **「提醒能力诊断」** —— 输出的是「代理提醒被系统管控（1700002）」
///      这类实现细节。Android 的通知由系统托管，不存在这个诊断场景。
///   4. **「后续计划」** —— 把未实现的功能列在正式设置里是信息噪音，
///      而且会让用户以为这些功能已经「即将可用」。
///   5. **重复入口** —— 导航里「设置」只保留一处。
///   6. **缓存来源/技术细节文案** —— 例如「已就绪：今天 N 节课」
///      「显示上次缓存的版本」。用户只关心能不能用，不关心数据从哪来。
///
/// 保留：学期与周次（开学日期 / 节次作息 / 校历与作息表）、上课提醒
/// （开关 + 提前量）、桌面卡片、外观（M3 / 液态玻璃材质切换）、账号、
/// 关于（版本 / 开源地址 / 免责说明）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../common/constants.dart';
import '../data/app_state.dart';
import '../data/card_snapshot_store.dart';
import '../data/campus_calendar_service.dart';
import '../data/credential_store.dart';
import '../data/pref_store.dart';
import '../data/reminder_service.dart';
import '../data/section_time_store.dart';
import '../data/week_service.dart';
import '../theme/material_style.dart';
import '../theme/theme.dart';
import '../widgets/calendar_sheet.dart';
import '../widgets/glass_picker.dart';
import '../widgets/section_time_dialog.dart';
import '../widgets/state_views.dart';
import '../widgets/top_fade_blur.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AppState _app = AppState.instance;

  /// 当前外观材质（RadioGroup 的选中值）
  AppSurfaceStyle _surfaceStyle = SurfaceStyleController.style.value;

  bool _reminderOn = false;
  int _advance = 15;
  bool _notificationOk = false;
  int _reminderCount = 0;
  String _cardHint = '';
  String _hint = '';

  String _calendarHint = '从学校官网获取官方校历与作息表';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await SectionTimeStore.load();
    final bool notif = await ReminderService.notificationEnabled();
    final CardSnapshot? snap = CardSnapshotStore.load();
    final CampusCalendar camp = await CampusCalendarService.load();
    // 读回**系统里真正还挂着的**提醒条数。
    //
    // 早先这里没读，`_reminderCount` 一直是构造时的 0 ——
    // 于是「退出设置再进来」看到的就是「已排定 0 条」，
    // 而系统里其实还挂着十几条提醒（用户以为提醒失效了，
    // 反复开关开关去重排）。界面必须反映真实状态，所以问系统。
    final bool reminderOn = PrefStore.loadReminderOn();
    final int pending =
        reminderOn ? await ReminderService.pendingCount() : 0;
    if (!mounted) {
      return;
    }
    setState(() {
      _reminderOn = reminderOn;
      _reminderCount = pending;
      _advance = PrefStore.loadReminderAdvance();
      _notificationOk = notif;
      // 只在**还不能用**时才提示原因（需要用户先打开一次课表）；
      // 能正常工作时不再显示「已就绪：今天 N 节课」这类内部状态 ——
      // 用户看一眼桌面就知道有几节课，设置页里重复一遍是噪音。
      _cardHint = snap == null ? '打开一次课表后即可使用' : '';
      _calendarHint = CampusCalendarService.hint(camp);
    });
  }

  Future<void> _openCalendar() async {
    await showAcademicCalendarSheet(context,
        semesterCode: _app.timetable?.semester ?? PrefStore.loadLastSemester());
    // 弹窗里可能刷新过，回来同步一次摘要
    if (!mounted) {
      return;
    }
    final CampusCalendar camp = await CampusCalendarService.load();
    if (!mounted) {
      return;
    }
    setState(() => _calendarHint = CampusCalendarService.hint(camp));
  }

  // ==================== 学期与周次 ====================

  Future<void> _pickStartDate() async {
    final String cur = _app.semesterStart;
    // 用自绘的三列玻璃滚轮（年/月/日）替代系统日历对话框 ——
    // 系统弹窗与本应用其余玻璃弹窗风格割裂，且用户要求上下滑动的效果。
    final DateTime? picked = await showGlassDatePicker(
      context,
      initial: cur.isEmpty
          ? DateTime.now()
          : (DateTime.tryParse(cur) ?? DateTime.now()),
    );
    if (picked == null) {
      return;
    }
    try {
      await WeekService.setStartMonday(
          '${picked.year}-${_two(picked.month)}-${_two(picked.day)}');
      await WeekService.align(true);
      if (!mounted) {
        return;
      }
      setState(() => _hint = '已设为 ${_app.semesterStart}，当前第 ${_app.currentWeek} 周');
      // 开学日期变了：卡片与提醒都要跟着更新
      await CardSnapshotStore.refresh(_app.timetable, _app.semesterStart);
      if (_reminderOn) {
        await _reschedule();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _hint = '日期无效，保存失败');
      }
    }
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';

  // ==================== 上课提醒 ====================

  Future<void> _reschedule() async {
    final int n = await ReminderService.reschedule(_app.timetable, _app.semesterStart);
    if (!mounted) {
      return;
    }
    setState(() => _reminderCount = n);
  }

  Future<void> _toggleReminder(bool on) async {
    if (on) {
      final bool granted = await ReminderService.ensurePermission();
      if (!mounted) {
        return;
      }
      if (!granted) {
        setState(() => _hint = '未获得通知权限，无法发布上课提醒');
        return;
      }
      if (_app.semesterStart.isEmpty) {
        setState(() => _hint = '请先在「学期与周次」里设置开学日期');
        return;
      }
      if (_app.timetable == null) {
        setState(() => _hint = '请先打开一次课表');
        return;
      }
      await PrefStore.saveReminderOn(true);
      await _reschedule();
      setState(() {
        _reminderOn = true;
        _notificationOk = true;
        _hint = '已排定 $_reminderCount 条上课提醒';
      });
      return;
    }
    await PrefStore.saveReminderOn(false);
    await ReminderService.cancelAll();
    if (!mounted) {
      return;
    }
    setState(() {
      _reminderOn = false;
      _reminderCount = 0;
      _hint = '已关闭上课提醒';
    });
  }

  Future<void> _pickAdvance() async {
    final int? v = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: const Text('提前多久提醒'),
        children: <Widget>[
          for (final int m in <int>[5, 10, 15, 20, 30])
            ListTile(
              title: Text('课前 $m 分钟'),
              trailing: m == _advance
                  ? Icon(Icons.check, size: 18, color: ctx.brandColor)
                  : null,
              onTap: () => Navigator.pop(ctx, m),
            ),
        ],
      ),
    );
    if (v == null) {
      return;
    }
    await PrefStore.saveReminderAdvance(v);
    if (!mounted) {
      return;
    }
    setState(() => _advance = v);
    if (_reminderOn) {
      await _reschedule();
    }
  }

  // ==================== 桌面卡片 ====================

  /// 把卡片「钉」到桌面（一键添加）。
  ///
  /// 用系统的 requestPinAppWidget 流程：兼容的启动器会直接弹确认框，
  /// 用户点一下就把卡片放好，不必再去长按 → 找小部件 → 翻应用列表。
  ///
  /// 兼容性处理（国内启动器实现程度差别很大，必须有兜底）：
  ///   - 系统版本低于 8.0，或桌面没实现该接口 → 给一句操作指引，
  ///     让用户走长按那条路，而不是点了没反应；
  ///   - 接口存在但调用抛错（部分定制 ROM 会崩）→ 同样退到指引文案。
  Future<void> _addWidget() async {
    bool supported = false;
    try {
      supported = (await HomeWidget.isRequestPinWidgetSupported()) ?? false;
    } catch (_) {
      supported = false;
    }

    if (!supported) {
      if (mounted) {
        setState(() => _hint = '当前桌面不支持一键添加，请长按桌面空白处手动添加');
      }
      return;
    }

    try {
      await HomeWidget.requestPinWidget(
        androidName: 'TodayCourseWidgetProvider',
        qualifiedAndroidName: 'com.sdufe.hisdufe_jw.TodayCourseWidgetProvider',
      );
      // 确认框由系统弹，这里不假设用户点了「添加」——因此只给中性提示，
      // 不说「已添加」（他可能点了取消）。
      if (mounted) {
        setState(() => _hint = '已请求添加桌面卡片，请在桌面确认');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _hint = '添加失败，请长按桌面空白处手动添加');
      }
    }
  }

  // ==================== 账号 ====================

  Future<void> _confirmLogout() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('将清除本地会话，需重新登录。是否继续？'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: context.dangerColor),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    // 先停掉提醒，再清会话：否则会继续按旧课表弹通知
    await ReminderService.cancelAll();
    await CredentialStore.clear();
    await CardSnapshotStore.clear();
    await _app.logout();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(child: _buildList(context)),
        const TopFadeBlur(),
      ],
    );
  }

  Widget _buildList(BuildContext context) {
    return ListView(
      // 顶部让位放进**滚动内容**（不是视口），内容因此会从顶栏下经过、
      // 被上面的 TopFadeBlur 糊掉。见 shell.dart 的 _settingsScreen。
      //
      // 底部额外留出玻璃导航栏的高度：extendBody 后内容会滚到 dock 下面，
      // 不留这段空白最后一项会被玻璃压住
      padding: EdgeInsets.fromLTRB(Gaps.page, appBarInset(context) + Gaps.page,
          Gaps.page, Gaps.page + Gaps.scrollTail),
      children: <Widget>[
        if (_hint.isNotEmpty) ...<Widget>[
          Container(
            padding: const EdgeInsets.all(Gaps.m),
            decoration: BoxDecoration(
              color: context.brandSoftColor,
              borderRadius: BorderRadius.circular(Gaps.radiusSm),
            ),
            child: Text(_hint,
                style: TextStyle(fontSize: 12, color: context.brandColor)),
          ),
          const SizedBox(height: Gaps.m),
        ],

        // ---- 学期与周次 ----
        const GroupTitle('学期与周次'),
        GroupBox(
          children: <Widget>[
            SettingRow(
              label: '开学日期（第 1 周周一）',
              subtitle: _app.semesterStart.isEmpty
                  ? '未设置 —— 设置后可自动定位当前周'
                  : '已设为 ${_app.semesterStart}',
              value: _app.semesterStart.isEmpty ? '设置' : '修改',
              onTap: _pickStartDate,
            ),
            SettingRow(
              label: '当前教学周',
              value: _app.currentWeek > 0 ? '第 ${_app.currentWeek} 周' : '未知',
            ),
            SettingRow(
              label: '节次作息',
              subtitle: SectionTimeStore.isDefault()
                  ? '跟随学校官网时刻表'
                  : '已自定义',
              value: SectionTimeStore.hint(),
              onTap: _editSectionTimes,
            ),
            // 「恢复官方」只在自定义过之后出现 —— 没改过的用户不需要它，
            // 而改过的用户必须有一条回到「跟随官网」的路：
            // 否则一旦保存过，就再也不会被官网同步覆盖了。
            if (!SectionTimeStore.isDefault())
              SettingRow(
                label: '恢复官方作息',
                subtitle: '清除自定义，之后跟随学校官网自动更新',
                value: '恢复',
                onTap: _restoreOfficialSectionTimes,
              ),
            SettingRow(
              label: '校历与作息表',
              subtitle: _calendarHint,
              value: '查看',
              onTap: _openCalendar,
            ),
          ],
        ),
        const SizedBox(height: Gaps.m),

        // ---- 上课提醒 ----
        const GroupTitle('上课提醒'),
        GroupBox(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: Gaps.m, vertical: 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('开启上课提醒',
                            style: TextStyle(
                                fontSize: 15, color: context.textPrimary)),
                        const SizedBox(height: 2),
                        Text(
                          !_notificationOk
                              ? '未开启通知权限 —— 提醒必须先允许通知'
                              : (_reminderOn
                                  ? '已排定 $_reminderCount 条（应用关闭也会提醒）'
                                  : '按课表在课前自动提醒'),
                          style: TextStyle(
                            fontSize: 12,
                            color: !_notificationOk
                                ? context.dangerColor
                                : context.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _reminderOn,
                    onChanged: _toggleReminder,
                  ),
                ],
              ),
            ),
            SettingRow(
              label: '提前提醒',
              value: '课前 $_advance 分钟',
              onTap: _pickAdvance,
            ),
          ],
        ),
        const SizedBox(height: Gaps.m),

        // ---- 桌面卡片 ----
        const GroupTitle('桌面卡片'),
        GroupBox(
          children: <Widget>[
            SettingRow(
              label: '今日课程卡片',
              // 副标题在「还不能用」时说明原因，否则留空 ——
              // 卡片本身在桌面上一眼可见，这里不必重复它的内容。
              subtitle: _cardHint,
              // 「刷新」改成「添加桌面卡片」。
              //
              // ===== 为什么换 =====
              // 原来的「刷新」只是把快照重推一次，而课表**任何**改动都已经
              // 自动同步了（见 CardSnapshotStore 的调用点），用户没有需要
              // 手动刷新的场景 —— 它基本是空操作，反而让人以为
              // 「卡片不会自动更新，得点这里」。
              //
              // 用户真正会遇到的困难是**第一次怎么把卡片放到桌面**：
              // 要长按空白 → 找小部件 → 翻到「hi山财」，路径不直观。
              // 因此改成「一键添加」，点击直接向系统发起添加请求。
              //
              // 按钮用液态玻璃（`GlassButton.custom`），与校历按钮同一套 ——
              // 保持整个应用的控件语言一致，而不是混进一个 Material 文字按钮。
              // 这一行的 `onTap` 不再设置：交互收敛到按钮上，
              // 否则「点行」与「点按钮」是两件都触发添加的事，语义重复。
              action: GlassButton.custom(
                onTap: _addWidget,
                shape: const LiquidRoundedRectangle(borderRadius: 999),
                // 自管图层：它是独立元素，不在任何玻璃容器内部
                useOwnLayer: true,
                height: 32,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.add_to_home_screen_outlined,
                          size: 15, color: context.brandColor),
                      const SizedBox(width: 5),
                      Text('添加桌面卡片',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: context.brandColor,
                          )),
                    ],
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(Gaps.m, 0, Gaps.m, 12),
              child: Text(
                '长按桌面空白处添加桌面卡片，或点击「添加桌面卡片」按钮一键添加到桌面',
                style: TextStyle(fontSize: 11, height: 1.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gaps.m),

        const SizedBox(height: Gaps.m),

        // ---- 账号 ----
        const GroupTitle('账号'),
        GroupBox(
          children: <Widget>[
            SettingRow(
                label: '学号',
                value: _app.studentId.isNotEmpty
                    ? _app.studentId
                    : _app.account),
            if (_app.studentName.isNotEmpty)
              SettingRow(label: '姓名', value: _app.studentName),
            SettingRow(
              label: '退出登录',
              danger: true,
              onTap: _confirmLogout,
            ),
          ],
        ),
        const SizedBox(height: Gaps.m),

        // ---- 外观 ----
        const GroupTitle('外观'),
        GroupBox(
          children: <Widget>[
            // 材质切换：整棵界面重建（见 main.dart 的 ValueListenableBuilder）。
            //
            // 用 `RadioGroup` 包住（而不是每个 RadioListTile 各写 groupValue）：
            // 后者在当前 Flutter 版本上已废弃，官方要求由祖先 RadioGroup
            // 统一托管选中值与变更回调。
            RadioGroup<AppSurfaceStyle>(
              groupValue: _surfaceStyle,
              onChanged: (AppSurfaceStyle? v) async {
                if (v == null || v == _surfaceStyle) {
                  return;
                }
                setState(() => _surfaceStyle = v);
                await SurfaceStyleController.set(v);
              },
              child: Column(
                children: <Widget>[
                  for (final AppSurfaceStyle st in AppSurfaceStyle.values)
                    RadioListTile<AppSurfaceStyle>(
                      value: st,
                      title: Text(st.label,
                          style: TextStyle(
                            fontSize: 14,
                            color: context.textPrimary,
                          )),
                      subtitle: Text(st.subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.textTertiary,
                          )),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gaps.m),

        // ---- 关于 ----
        const GroupTitle('关于'),
        GroupBox(
          children: <Widget>[
            const SettingRow(label: 'hi山财 v1.0.0'),
            // 开源地址：点按用系统浏览器打开。
            //
            // 为什么放在这里（而不是项目主页那种独立入口）：它属于
            // 「这是谁做的、代码在哪」这类信息，与版本号同一层级；
            // 而设置页是用户想找这类信息的唯一去处。
            SettingRow(
              label: '开源地址',
              subtitle: kRepoUrl,
              onTap: _openRepo,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gaps.m, 0, Gaps.m, 12),
              child: Text(
                '数据来源：$kBaseOrigin\n'
                '本应用为个人学习用途的第三方客户端，仅供查询本人教务数据。'
                '应用不保存密码（除非你主动勾选记住），仅在本机保存会话与偏好设置。'
                '课表可离线查看。',
                style: TextStyle(fontSize: 11, height: 1.6, color: context.textTertiary),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 用系统浏览器打开开源仓库地址。
  ///
  /// 走原生通道（见 MainActivity 的 openUrl）而不是引 url_launcher：
  /// 本项目在插件兼容上多次踩坑，而这里只需一个 ACTION_VIEW Intent。
  ///
  /// 失败时给一条页面内提示 —— 本应用的壳是 GlassScaffold
  /// （内部 CupertinoPageScaffold），树里**没有 Material 的 Scaffold**，
  /// 而 `ScaffoldMessenger.showSnackBar` 断言必须有已注册的 Scaffold，
  /// 所以 SnackBar 在这里既显示不出来、debug 下还会直接抛断言
  /// （这个坑在 PDF 下载那里踩过）。
  Future<void> _openRepo() async {
    try {
      final bool? ok = await const MethodChannel('com.sdufe.hisdufe_jw/pdf')
          .invokeMethod<bool>('openUrl', <String, String>{'url': kRepoUrl});
      if (ok == true || !mounted) {
        return;
      }
      setState(() => _hint = '无法打开浏览器');
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _hint = '无法打开浏览器');
    }
  }

  /// 节次作息编辑（保留，因为提醒时间完全依赖它）
  Future<void> _editSectionTimes() async {
    final List<SectionTime> draft = SectionTimeStore.all()
        .map((SectionTime s) => SectionTime(s.index, s.label, s.start, s.end))
        .toList();
    final List<TextEditingController> start =
        draft.map((SectionTime s) => TextEditingController(text: s.start)).toList();
    final List<TextEditingController> end =
        draft.map((SectionTime s) => TextEditingController(text: s.end)).toList();

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => SectionTimeDialog(
        draft: draft,
        start: start,
        end: end,
      ),
    );

    if (saved == true) {
      // 校验与规范化交给 store 里的纯函数（见 validateAndBuild）。
      //
      // 这段逻辑曾经**写错过**：校验读输入框的新值，保存却写了打开弹窗时的
      // 旧 `draft`，表现为「改了时间点保存没反应」。抽成纯函数后可以直接
      // 对着契约写用例，不必再靠真机点。
      String? problem;
      final List<SectionTime>? edited = SectionTimeStore.validateAndBuild(
        starts: start.map((TextEditingController c) => c.text).toList(),
        ends: end.map((TextEditingController c) => c.text).toList(),
        labels: draft.map((SectionTime s) => s.label).toList(),
        error: (String m) => problem = m,
      );
      if (edited == null) {
        if (mounted && problem != null) {
          setState(() => _hint = problem!);
        }
        for (final TextEditingController c in <TextEditingController>[...start, ...end]) {
          c.dispose();
        }
        return;
      }
      await SectionTimeStore.saveAll(edited);
      if (_reminderOn) {
        // 时刻变了，已排定的提醒必须按新时刻重排，否则提醒仍指向旧时间
        await _reschedule();
      }
      // 卡片也要跟着变：它的「上课时刻」「已上完判断」都来自周级载荷里的
      // sections/sectionEnds。不推一次的话，作息改了卡片还按旧时刻显示
      // （用户改完回到桌面，看到的还是老时间）。
      await CardSnapshotStore.refresh(_app.timetable, _app.semesterStart);
      if (mounted) {
        // 一次 setState 同时更新提示与摘要行（「第1大节 … 起，共 N 段」）——
        // 摘要读的是 SectionTimeStore，不同步刷新的话保存成功了它还显示旧值，
        // 看起来仍像「没生效」。
        setState(() => _hint = '作息时间已保存');
      }
    }
    for (final TextEditingController c in <TextEditingController>[...start, ...end]) {
      c.dispose();
    }
  }

  /// 清除自定义作息，回到「跟随官网」。
  ///
  /// 两个作用：把时刻恢复成内置的官方值，并**清掉自定义标记**，
  /// 使后续的官网同步重新生效（判据见 [SectionTimeStore.isDefault]）。
  Future<void> _restoreOfficialSectionTimes() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('恢复官方作息'),
        content: const Text('将清除你自定义的节次时间，恢复为学校官方时刻表，'
            '之后随官网自动更新。是否继续？'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    await SectionTimeStore.resetToDefault();
    if (_reminderOn) {
      // 时刻变了，已排定的提醒必须按新时刻重排，否则提醒仍指向旧时间
      await _reschedule();
    }
    // 与手动编辑同理：作息变了，卡片的时刻也要跟着变
    await CardSnapshotStore.refresh(_app.timetable, _app.semesterStart);
    if (mounted) {
      setState(() => _hint = '已恢复官方作息');
    }
  }
}
