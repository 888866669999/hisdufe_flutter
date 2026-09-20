/// 学校官方的作息数据
///
/// 从鸿蒙版 `data/AcademicCalendar.ets` 移植。
///
/// 数据来源：山东财经大学「校园服务 → 最新校历」页面
///   https://www.sdufe.edu.cn/xyfw/zxxl.htm
///   页面正文给出「日常教学时刻表」；校历以两张**图片**形式挂在页面上。
///
/// 为什么要把它内置成数据、而不是每次去网上抓：
///   1. 该页面是**图片 + JS 反爬挑战**，实时抓取的正文里拿不到任何时刻数字，
///      解析必然失败；内置一份权威值比每次联网更可靠。
///   2. 作息时间直接决定「上课提醒」的触发时刻，抓不到就会算错。
///
/// 注意：作息时间与教务系统课表页面**并不一致**。
///   课表页面只给节次名称（「第一、二节」），不给时刻；
///   官方作息表才是真正的时间依据。
///
/// ===== 这里只有作息，没有校历日期（2026-09 改）=====
/// 早先这里还硬编码了 `kSemesterCalendars`（开学日、总周数、假期备注），
/// 那是人工从校历图片上转录的：**录一次就固定了**，换学年后就是错的，
/// 而界面上看不出来。那部分已删除，改由教务系统的教学周历实时提供 ——
/// 见 [SemesterCalendarService]。校历图片本身也不再随包内置，原因同理。
library;

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

/// 官方作息数据访问。
///
/// **只负责作息时刻**。校历日期（开学日、周次）不在这里 ——
/// 那份数据必须能随年份更新，见 [SemesterCalendarService]。
class AcademicCalendar {
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
}
