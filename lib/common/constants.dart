/// 全局常量：域名、接口路径、断点、节次与作息
///
/// 从鸿蒙版 `common/Constants.ets` 移植。所有取值都经过真实抓包核对，
/// 改动前请先看 docs/技术笔记.md 的「接口与字段」。
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
/// 鸿蒙版未开源，所以没有第二处地址可指。
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

/// 学校官网「作息表 + 校历图」的缓存（抓取成功才写；离线时读这里）。
///
/// 作息表抓不到时退回 [kOfficialSections]（内置的时刻表）。
/// 校历图不再有内置兜底 —— 那东西一年一换，内置版换学年后会静默过期，
/// 界面上看不出来。见 data/semester_calendar_service.dart。
const String kKeyCampusSections = 'campus_sections';
const String kKeyCampusImages = 'campus_images';
const String kKeyCampusImageUrls = 'campus_image_urls';
const String kKeyCampusUpdated = 'campus_updated';
const String kKeyCampusFetchedAt = 'campus_fetched_at';


/// 上次「因系统时间已超出周历而自动拉取」的日期（`yyyy-MM-dd`）。
///
/// 用于把这种自动拉取限制为**每天一次**：触发条件（今天晚于周历最后一周）
/// 在放假期间持续成立，不限制就会每次启动/每次打开校历都联网。
const String kKeySemesterAutoFetchDay = 'semester_auto_fetch_day';

/// 周次与系统时间对齐的最小间隔（6 小时）
const Duration kWeekAlignInterval = Duration(hours: 6);

// ==================== 页面缓存 ====================
//
// 见 data/page_cache.dart。这里只放「缓存标识」与「新鲜期」。
// 集中定义的原因：这些值需要能一眼横向对比 —— 哪个页面缓存久、哪个短；
// 散在各页面里就只能一个个翻着看。

/// 缓存标识：页面名（参与缓存 key，不要随意改名，否则旧缓存会失配）
const String kCacheScoreList = 'score_list';
const String kCacheScoreSemesters = 'score_semesters';
const String kCachePlan = 'plan';
const String kCacheElective = 'elective';
const String kCacheProfile = 'profile';
const String kCacheClassroomOptions = 'classroom_options';
const String kCacheClassroomBuildings = 'classroom_buildings';
const String kCacheClassroomUsage = 'classroom_usage';
const String kCacheSemesterCalendar = 'semester_calendar';
const String kCacheSemesterList = 'semester_list';

/// 页面缓存的新鲜期（TTL）。
///
/// ===== 这些值是怎么定的 =====
/// 判据是「数据多久可能变一次」与「重复请求的代价」两者取平衡：
///   - **成绩 2 分钟**：出分时段学生会反复进来刷。2 分钟内连着切 tab
///     明显是同一件事的重复操作，没必要每次都打服务器；
///     超过 2 分钟又确实可能出新成绩，所以不能更长。
///   - **通选 10 分钟**：修读进度变动不频繁（一学期就那几门课）。
///   - **培养方案 / 个人信息 6 小时**：一学年才可能调整一次，
///     同一天内反复请求纯属浪费。培养方案页面还最大（70KB），
///     省下的流量最可观。
///   - **空教室**：选项（校区/学期/教学楼）是静态配置，给 6 小时；
///     查询结果反映「此刻哪间教室空着」，按节次变化，只给 2 分钟
///     且**仅做内存缓存**（见 classroom_page 的说明）。
///
/// 宁可偏保守（短）：实机观察后可调，而调长的风险只是多几次请求，
/// 调太长才会让用户看到过期数据。
const Duration kTtlScoreList = Duration(minutes: 2);
const Duration kTtlScoreSemesters = Duration(hours: 6);
const Duration kTtlElective = Duration(minutes: 10);
const Duration kTtlPlan = Duration(hours: 6);
const Duration kTtlProfile = Duration(hours: 6);
const Duration kTtlClassroomOptions = Duration(hours: 6);
const Duration kTtlClassroomBuildings = Duration(hours: 6);
const Duration kTtlClassroomUsage = Duration(minutes: 2);
const Duration kTtlSemesterCalendar = Duration(hours: 6);
const Duration kTtlSemesterList = Duration(hours: 6);
