/// 学校官方的校历与作息数据
///
/// 从鸿蒙版 `data/AcademicCalendar.ets` 移植。
///
/// 数据来源：山东财经大学「校园服务 → 最新校历」页面
///   https://www.sdufe.edu.cn/xyfw/zxxl.htm
///   页面正文给出「日常教学时刻表」，校历以两张图片形式挂在页面上。
///
/// 为什么要把它内置成数据、而不是每次去网上抓：
///   1. 该页面是**图片 + JS 反爬挑战**，实时抓取的正文里拿不到任何时刻数字，
///      解析必然失败；内置一份权威值比每次联网更可靠。
///   2. 作息时间直接决定「上课提醒」的触发时刻，抓不到就会算错。
///   3. 校历图片虽然随包内置（`assets/calendar_2026_{1,2}.jpg`），但
///      **周次与开学日期**这类需要参与计算的字段必须结构化，图片没法直接算。
///
/// 注意：作息时间与教务系统课表页面**并不一致**。
///   课表页面只给节次名称（「第一、二节」），不给时刻；
///   官方作息表才是真正的时间依据。
library;

import '../common/constants.dart';

/// 节次作息的权威默认值（官方「日常教学时刻表」，2026 年 7 月更新）
class OfficialSection {
  const OfficialSection(this.row, this.label, this.start, this.end);

  /// 课表中的行号（0 起）
  final int row;
  final String label;
  final String start;
  final String end;
}

/// 官方日常教学时刻表，按课表的 5 个行归并。
///
///   第一、二节      8:30-10:00
///   第三、四节      10:20-11:50   （10:00-10:20 课间休息）
///   第五、六节      14:00-15:30
///   第七、八节      15:50-17:20   （15:30-15:50 课间休息）
///   第九~十一节     18:40-21:05   （第九、十节 18:40-20:10，休息 10 分钟，
///                                   第十一节 20:20-21:05）
///
/// 与 `kSections`（本地可改的那份默认值）内容一致；这里保留一份，
/// 是为了让「官方值」这个概念在代码里是独立可引用的 —— 设置页里
/// 「恢复官方默认」要有明确的对象。
const List<OfficialSection> kOfficialSections = <OfficialSection>[
  OfficialSection(0, '第一、二节', '08:30', '10:00'),
  OfficialSection(1, '第三、四节', '10:20', '11:50'),
  OfficialSection(2, '第五、六节', '14:00', '15:30'),
  OfficialSection(3, '第七、八节', '15:50', '17:20'),
  OfficialSection(4, '第九~十一节', '18:40', '21:05'),
];

/// 课间休息。
/// 用 `followsRow` 指向「排在哪个节次之后」，而不是按名称匹配 ——
/// 官方表里写的是「第九、十节」休息，而课表行名是「第九~十一节」，
/// 两者字面不同，按名称匹配会把这个课间悄悄漏掉。
class OfficialBreak {
  const OfficialBreak(this.followsRow, this.start, this.end);

  /// 排在第几行（0 起的课表行号）之后
  final int followsRow;
  final String start;
  final String end;
}

/// 官方课间休息安排
const List<OfficialBreak> kOfficialBreaks = <OfficialBreak>[
  OfficialBreak(0, '10:00', '10:20'),
  OfficialBreak(2, '15:30', '15:50'),
  OfficialBreak(4, '20:10', '20:20'),
];

/// 一个学期的校历信息。
class SemesterCalendar {
  const SemesterCalendar({
    required this.code,
    required this.name,
    required this.firstMonday,
    required this.lastDay,
    required this.totalWeeks,
    required this.notes,
  });

  /// 学期代码，与教务系统一致，如 2026-2027-1
  final String code;

  /// 展示名，如 2026—2027 学年第一学期
  final String name;

  /// 第 1 周周一，格式 YYYY-MM-DD。全部周次计算的基准，必须准确。
  final String firstMonday;

  /// 结束日期（最后一周周日）
  final String lastDay;

  /// 总周数
  final int totalWeeks;

  /// 假期说明等备注
  final List<String> notes;
}

/// 已录入的校历。
///
/// 数值来自官方校历图片：
///   第一学期：八月行末为 22、23（周六、周日），第 1 周为 8/24–8/30。
///            教学周共 21 周（第 21 周 1/11–1/17），其后为寒假。
///   第二学期：二月行末为 27、28，第 1 周为 3/1–3/7。
///            教学周共 19 周（第 19 周 7/5–7/11），第 19 周周一起为暑假。
const List<SemesterCalendar> kSemesterCalendars = <SemesterCalendar>[
  SemesterCalendar(
    code: '2026-2027-1',
    name: '2026—2027 学年第一学期',
    firstMonday: '2026-08-24',
    lastDay: '2027-01-17',
    totalWeeks: 21,
    notes: <String>[
      '在校生 8 月 22 日报到，8 月 24 日上课',
      '本科新生 8 月 28 日至 8 月 29 日报到，8 月 30 日至 9 月 20 日入学教育及军训，9 月 21 日上课',
      '研究生新生 8 月 28 日至 8 月 29 日报到，8 月 30 日入学教育，8 月 31 日上课',
      '中秋节、国庆节、元旦放假按学校节假日安排执行',
      '寒假自 1 月 18 日（农历腊月十一）开始，至 2 月 26 日（农历正月二十一）结束',
    ],
  ),
  SemesterCalendar(
    code: '2026-2027-2',
    name: '2026—2027 学年第二学期',
    firstMonday: '2027-03-01',
    lastDay: '2027-07-11',
    totalWeeks: 19,
    notes: <String>[
      '2 月 27 日（农历正月二十二）报到，3 月 1 日上课',
      '清明节、劳动节、端午节放假按学校节假日安排执行',
      '5 月第二周为劳动周，课堂授课按照教学计划正常执行',
      '4 月下旬举行校春季运动会',
      '毕业典礼 6 月中下旬举行',
      '暑假自 7 月 12 日开始，至 8 月 20 日结束',
    ],
  ),
];

/// 校历页面（校历图片随包内置，离线也能看；此链接供需要核对最新版时打开）
const String kCampusCalendarPage = 'https://www.sdufe.edu.cn/xyfw/zxxl.htm';

/// 校历数据访问。
class AcademicCalendar {
  /// 按学期代码取校历；找不到返回 null
  static SemesterCalendar? forSemester(String code) {
    for (final SemesterCalendar c in kSemesterCalendars) {
      if (c.code == code) {
        return c;
      }
    }
    return null;
  }

  /// 猜测某个学期代码对应的校历。
  ///
  /// 教务系统的学期代码形如 2026-2027-1 / 2026-2027-2；
  /// 若没有精确匹配，退化为「同学期」（只看末尾的 -1 / -2），
  /// 便于跨学年复用规则（例如 2027-2028-1 沿用第一学期的日期区间规律）。
  ///
  /// 注意：退化匹配得到的是**往年**的日期，界面上必须说明是沿用的，
  /// 不能冒充本年度的准确信息 —— 见 [isSameYear]。
  static SemesterCalendar? guess(String code) {
    final SemesterCalendar? exact = forSemester(code);
    if (exact != null) {
      return exact;
    }
    if (code.isEmpty) {
      return null;
    }
    final String tail = code[code.length - 1];
    if (tail != '1' && tail != '2') {
      return null;
    }
    for (final SemesterCalendar c in kSemesterCalendars) {
      if (c.code.isNotEmpty && c.code[c.code.length - 1] == tail) {
        return c;
      }
    }
    return null;
  }

  /// 该学期是否精确匹配（false 表示是沿用往年同学期的日期）
  static bool isSameYear(String code, SemesterCalendar cal) => cal.code == code;

  /// 官方作息表的纯文本行，用于设置页与课表页展示。
  /// 课间休息插在对应节次之后（按行号匹配，见 [OfficialBreak] 的说明）。
  static List<String> sectionLines() {
    final List<String> out = <String>[];
    for (int i = 0; i < kOfficialSections.length; i++) {
      final OfficialSection s = kOfficialSections[i];
      out.add('${s.label}  ${s.start} - ${s.end}');
      for (final OfficialBreak b in kOfficialBreaks) {
        if (b.followsRow == i) {
          out.add('课间休息  ${b.start} - ${b.end}');
        }
      }
    }
    return out;
  }

  /// 默认展示哪一学期（0=第一学期，1=第二学期）；无法判断时给 0
  static int termIndexOf(String code) {
    if (code.isNotEmpty && code[code.length - 1] == '2') {
      return 1;
    }
    return 0;
  }

  /// 与 [kSections] 是否一致（用于确认「官方值未被改动」）
  static bool matchesLocal() {
    if (kSections.length != kOfficialSections.length) {
      return false;
    }
    for (int i = 0; i < kSections.length; i++) {
      if (kSections[i].start != kOfficialSections[i].start ||
          kSections[i].end != kOfficialSections[i].end) {
        return false;
      }
    }
    return true;
  }
}
