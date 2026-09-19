/// 全局常量：域名、接口路径、断点、节次与作息
///
/// 从鸿蒙版 `common/Constants.ets` 移植。所有取值都经过真实抓包核对，
/// 改动前请先看 README 的「已核实的接口清单」。
library;

/// 教务系统基地址。
///
/// 注意：学校**只提供明文 HTTP**，没有可用的 HTTPS 入口，
/// 因此 Android 侧必须允许明文流量（见 AndroidManifest 的
/// `android:usesCleartextTraffic`），否则请求会被系统直接拦掉。
const String kBaseOrigin = 'http://jw.sdufe.edu.cn';

/// 登录相关
const String kPathCaptcha = '/verifycode.servlet';
const String kPathLogon = '/Logon.do?method=logon';
const String kPathLogonSess = '/Logon.do?method=logon&flag=sess';
const String kPathMain = '/jsxsd/framework/xsMain.jsp';

/// 业务页面
const String kPathTimetable = '/jsxsd/xskb/xskb_list.do';
const String kPathScoreList = '/jsxsd/kscj/cjcx_list';

/// 成绩查询页（用于取学期下拉；与列表页不是同一个地址）
const String kPathScoreQuery = '/jsxsd/kscj/cjcx_query';
const String kPathProfile = '/jsxsd/grxx/xsxx';
const String kPathWeekCalendar = '/jsxsd/jxzl/jxzl_query';

/// 培养方案明细（只有表格，不再有 PDF —— 见 pages/plan_page.dart 顶部说明）
const String kPathPlanDetail = '/jsxsd/pyfa/topyfamx';

/// 通选课修读情况
const String kPathElective = '/jsxsd/xxwcqk/xstxkxdqk.do';

/// 全校性教室课表（空教室查询的数据源）
const String kPathClassroom = '/jsxsd/kbcx/kbxx_classroom';

/// 教室查询结果（HTML 片段）
const String kPathClassroomIfr = '/jsxsd/kbcx/kbxx_classroom_ifr';

/// 按校区取教学楼列表（返回 JSON 数组）
const String kPathBuildings = '/jsxsd/kbcx/getJxlByAjax';

/// 请求超时
const Duration kConnectTimeout = Duration(seconds: 10);
const Duration kReadTimeout = Duration(seconds: 15);

/// 一学期最多周数
const int kMaxWeeks = 30;

/// 开源仓库地址（设置页「关于」组里展示，点按用系统浏览器打开）。
///
/// 只放**本端**（Flutter/Android）仓库：用户装的哪个端，想看的通常就是哪个端的源码。
/// 另一端的地址写在 README 里，需要的人自然找得到。
const String kRepoUrl = 'https://github.com/888866669999/hisdufe_flutter';

/// 响应式断点（逻辑像素）。与鸿蒙版保持同一组数值，
/// 便于对照两版布局；Material 3 的窗口尺寸等级也大致落在这两个点上。
const double kBpMedium = 600;
const double kBpLarge = 840;

/// 节次定义：与教务课表行一一对应。
///
/// 时刻取自学校官方的「日常教学时刻表」，而非教务课表页面
/// —— 课表页面只给节次名称、不给时刻。
const List<String> kWeekdayLabels = <String>[
  '星期一',
  '星期二',
  '星期三',
  '星期四',
  '星期五',
  '星期六',
  '星期日',
];

/// 节次：索引 → 名称 → 起止时刻
class SectionDef {
  const SectionDef(this.index, this.label, this.start, this.end);

  final int index;
  final String label;
  final String start;
  final String end;
}

const List<SectionDef> kSections = <SectionDef>[
  SectionDef(0, '第一、二节', '08:30', '10:00'),
  SectionDef(1, '第三、四节', '10:20', '11:50'),
  SectionDef(2, '第五、六节', '14:00', '15:30'),
  SectionDef(3, '第七、八节', '15:50', '17:20'),
  SectionDef(4, '第九~十一节', '18:40', '21:05'),
];

/// 节次行数（课表的行数）
const int kSectionRows = 5;

/// 星期列数
const int kWeekdayCols = 7;

// ============ 本地存储键 ============
//
// 与鸿蒙版同名，便于两版对照排查。
const String kKeySessionCookie = 'session_cookie';
const String kKeyAccount = 'remembered_account';
const String kKeyRemember = 'remember_account';
const String kKeyLastSemester = 'last_semester';
const String kKeySemesterStart = 'semester_start_monday';
const String kKeyWeekAlignAt = 'week_align_at';
const String kKeyWeekAlignValue = 'week_align_value';
const String kKeyLastWeek = 'last_timetable_week';

/// 周次选择的「自动跟随本周」标记。
///
/// 为什么需要它：周次有三种状态 —— 自动跟随本周 / 全部 / 指定第 N 周，
/// 而「空串」只能表示其中一种。早先没有这个标记，于是「默认跟随本周」
/// 无法与「用户手动选了全部」区分：一旦把「默认」写成空串，
/// 用户选过「全部」之后就再也回不到自动跟随了。
const String kWeekAuto = 'auto';
const String kKeyLastScoreSemester = 'last_score_semester';

/// 桌面卡片数据快照
const String kKeyCardSnapshot = 'card_snapshot';

/// 桌面卡片的**周级**快照（应用侧留一份）。
///
/// 单独存一份的用途不是渲染（渲染那份走 home_widget 插件的 preferences），
/// 而是让 [CardSnapshotStore.refresh] 能判断「上一次写下的数据里有没有课」——
/// 从而在拿到一张**空表**时跳过写入，不把桌面卡片上的课程抹掉。
const String kKeyCardWeek = 'card_week_snapshot';

/// 节次作息（用户可自定义）
const String kKeySectionTimes = 'section_times';

/// 节次作息**是否被用户手动改过**（`'1'` = 改过）。
///
/// ===== 为什么必须单独存这个标记 =====
/// 早先靠「存储值是否等于包内常量 [kSections]」来判断有没有自定义。
/// 那个判据是错的：官网改了作息后我们会自动同步一次，同步完存储值就
/// **不再等于**包内常量 —— 于是下一次刷新被判成「用户自定义」而跳过，
/// 此后官网再改多少次都同步不进来。设置页还会错误地显示「已自定义」。
///
/// 现在把「谁写的」与「写了什么」分开记：用户在设置里保存时才置位，
/// 自动同步不置位，从而一直保持可同步。
const String kKeySectionTimesCustom = 'section_times_custom';

/// 上课提醒
const String kKeyReminderOn = 'reminder_enabled';
const String kKeyReminderAdvance = 'reminder_advance_min';


/// 外观材质：'m3'（默认）或 'glass'。
///
/// 见 theme/material_style.dart。只影响内容区的表面材质；
/// 底部 dock 与顶部渐变模糊不受它控制。
const String kKeySurfaceStyle = 'surface_style';

/// 用户自录的「通选课各大类要求学分」。
///
/// 学校页面的「要求学分（大于等于）」一列是空的，用户可按培养方案自行录入，
/// 见 data/elective_requirement_store.dart。按账号分片存储。
const String kKeyElectiveRequired = 'elective_required';

/// 官网校历缓存（抓取成功才写；离线时读这里，再退回内置数据）
const String kKeyCampusSections = 'campus_sections';
const String kKeyCampusImages = 'campus_images';
const String kKeyCampusImageUrls = 'campus_image_urls';
const String kKeyCampusUpdated = 'campus_updated';
const String kKeyCampusFetchedAt = 'campus_fetched_at';


/// 周次与系统时间对齐的最小间隔（6 小时）
const Duration kWeekAlignInterval = Duration(hours: 6);
