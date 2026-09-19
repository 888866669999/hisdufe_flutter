/// 数据模型
///
/// 从鸿蒙版 `model/Models.ets` 移植。字段名保持与本地缓存文件一致，
/// 便于两版互查（缓存不跨平台共用，但字段语义要能对上）。
library;

/// 一门课（课表格子里的一个条目）
class CourseEntry {
  CourseEntry({
    required this.id,
    required this.courseName,
    this.teacher = '',
    this.room = '',
    this.campus = '',
    this.weekText = '',
    this.startWeek = 1,
    this.endWeek = 18,
    this.parity = 0,
    this.local = false,
    this.rev = 0,
  });

  String id;
  String courseName;
  String teacher;
  String room;
  String campus;

  /// 原始周次文本（页面上的写法）
  String weekText;

  /// 起始周 / 结束周
  int startWeek;

  int endWeek;

  /// 0 = 每周，1 = 单周，2 = 双周
  int parity;

  /// 是否是用户在本地手工添加/修改的
  bool local;

  /// 修订号：本地编辑时自增，用于强制界面刷新
  int rev;

  /// 本周是否上这门课。
  ///
  /// 这是整个课表功能的核心判定，边界必须严格：
  ///   - 周次未知（<=0）时一律显示，宁可多显示也不要漏；
  ///   - 区间外不显示；
  ///   - 单周/双周按奇偶过滤。
  bool isActiveInWeek(int week) {
    if (week <= 0) {
      return true;
    }
    if (week < startWeek || week > endWeek) {
      return false;
    }
    if (parity == 1 && week % 2 == 0) {
      return false;
    }
    if (parity == 2 && week % 2 == 1) {
      return false;
    }
    return true;
  }

  String parityText() {
    if (parity == 1) {
      return '单周';
    }
    if (parity == 2) {
      return '双周';
    }
    return '';
  }

  /// 形如 `1-18周` / `1-18周(双周)`
  String weekSummary() {
    final String base = '$startWeek-$endWeek周';
    final String p = parityText();
    return p.isEmpty ? base : '$base($p)';
  }

  CourseEntry clone() => CourseEntry(
        id: id,
        courseName: courseName,
        teacher: teacher,
        room: room,
        campus: campus,
        weekText: weekText,
        startWeek: startWeek,
        endWeek: endWeek,
        parity: parity,
        local: local,
        rev: rev,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': courseName,
        'teacher': teacher,
        'room': room,
        'campus': campus,
        'startWeek': startWeek,
        'endWeek': endWeek,
        'parity': parity,
        'local': local,
        'rev': rev,
      };

  static CourseEntry fromJson(Map<String, dynamic> j) => CourseEntry(
        id: (j['id'] ?? '') as String,
        courseName: (j['name'] ?? '') as String,
        teacher: (j['teacher'] ?? '') as String,
        room: (j['room'] ?? '') as String,
        campus: (j['campus'] ?? '') as String,
        startWeek: (j['startWeek'] ?? 1) as int,
        endWeek: (j['endWeek'] ?? 18) as int,
        parity: (j['parity'] ?? 0) as int,
        local: (j['local'] ?? false) as bool,
        rev: (j['rev'] ?? 0) as int,
      );
}

/// 课表格子（第 row 节、第 col 天，都是 0 基）
class CellData {
  CellData({required this.row, required this.col, List<CourseEntry>? entries})
      : entries = entries ?? <CourseEntry>[];

  int row;
  int col;
  List<CourseEntry> entries;
}

/// 一张课表
class Timetable {
  Timetable({
    this.semester = '',
    this.week = '',
    List<String>? semesters,
    List<String>? weeks,
    List<CellData>? cells,
    this.remark = '',
    this.cachedAt = 0,
    this.edited = false,
    List<String>? serverIds,
  })  : semesters = semesters ?? <String>[],
        weeks = weeks ?? <String>[],
        cells = cells ?? <CellData>[],
        serverIds = serverIds ?? <String>[];

  String semester;

  /// 当前查看的周次（'' 表示全部）
  String week;
  List<String> semesters;
  List<String> weeks;
  List<CellData> cells;
  String remark;
  int cachedAt;

  /// 是否含本地改动
  bool edited;

  /// **服务器原始课程的 id 基线**（拉取那一刻记下，之后不再变）。
  ///
  /// ===== 为什么需要它 =====
  /// 早先判断「是否改过」只看每个条目自己的 `local` 标记
  /// （见 [hasLocalEdits]）。那个标记对「新增」和「修改」有效，
  /// 但**删除**服务器课程时，条目连同标记一起消失了 ——
  /// 于是删完之后一个 `local` 都不剩，界面判定为「未修改」，
  /// 「已修改」入口不出现，用户也没有办法恢复（真机反馈）。
  ///
  /// 有了这条基线就能表达「原本有什么、现在缺了什么」：
  /// 只要基线里有 id 在当前课表里找不到，就说明被删过。
  ///
  /// 只存 id 而不是整份原始数据：id 由「行/列/课名/周次」拼成，
  /// 已经足以标识一门课（见 TimetableParser 的 id 生成），
  /// 而整份副本会让缓存体积翻倍。
  List<String> serverIds;

  CellData? findCell(int row, int col) {
    for (final CellData c in cells) {
      if (c.row == row && c.col == col) {
        return c;
      }
    }
    return null;
  }

  CellData ensureCell(int row, int col) {
    final CellData? found = findCell(row, col);
    if (found != null) {
      return found;
    }
    final CellData c = CellData(row: row, col: col);
    cells.add(c);
    return c;
  }

  /// 删掉没有任何课程的格子（保持缓存干净）
  void pruneEmptyCells() {
    cells.removeWhere((CellData c) => c.entries.isEmpty);
  }

  bool hasAnyCourse(String week) {
    final int w = int.tryParse(week) ?? 0;
    for (final CellData c in cells) {
      for (final CourseEntry e in c.entries) {
        if (e.isActiveInWeek(w)) {
          return true;
        }
      }
    }
    return false;
  }

  /// 当前课表是否与「服务器给的那份」不同。
  ///
  /// 三种改动都要能识别出来：
  ///   1. **新增/修改** —— 条目带 `local` 标记（由编辑弹窗写入）；
  ///   2. **删除** —— 基线里的某个 id 在当前课表里已经不存在。
  ///      这是早先漏掉的一类：删除会把条目连标记一起去掉，
  ///      只看 `local` 就永远判定为「未修改」。
  ///
  /// 基线为空时（旧缓存、或还没从服务器取过）退化为只看 `local` ——
  /// 宁可少报，也不能把一份干净的服务器课表误判成「已修改」。
  bool hasLocalEdits() {
    final Set<String> alive = <String>{};
    for (final CellData c in cells) {
      for (final CourseEntry e in c.entries) {
        // 本地新增的课本来就不在基线里，不该参与「缺失」判定
        if (e.local) {
          return true;
        }
        alive.add(e.id);
      }
    }
    if (serverIds.isEmpty) {
      return false;
    }
    for (final String id in serverIds) {
      if (!alive.contains(id)) {
        return true; // 服务器有、现在没有 = 被删过
      }
    }
    return false;
  }

  /// 记录当前课表里的服务器课程作为基线。
  ///
  /// **只在从服务器新鲜拉取时调用一次**，之后不再覆盖 ——
  /// 否则每次保存都把「已删掉的那门课」从基线里抹掉，
  /// 删除就再也检测不出来了。
  void captureServerBaseline() {
    final List<String> ids = <String>[];
    for (final CellData c in cells) {
      for (final CourseEntry e in c.entries) {
        if (!e.local) {
          ids.add(e.id);
        }
      }
    }
    serverIds = ids;
  }
}

/// 一条成绩
class ScoreRecord {
  ScoreRecord({
    this.index = '',
    this.semester = '',
    this.courseCode = '',
    this.courseName = '',
    this.score = '',
    this.credit = '',
    this.gpa = '',
    this.examType = '',
    this.courseNature = '',
    this.courseAttr = '',
    this.minor = '',
  });

  String index;
  String semester;
  String courseCode;
  String courseName;
  String score;
  String credit;
  String gpa;
  String examType;
  String courseNature;
  String courseAttr;
  String minor;

  double creditNumber() => double.tryParse(credit) ?? 0;

  /// 绩点缺失时返回 -1（而不是 0），以便统计时区分「没绩点」与「绩点为 0」
  double gpaNumber() => double.tryParse(gpa) ?? -1;

  bool get isFail => (double.tryParse(score) ?? 100) < 60;
}

/// 成绩汇总
class ScoreSummary {
  ScoreSummary(this.count, this.totalCredit, this.weightedGpa);

  final int count;
  final double totalCredit;
  final double weightedGpa;
}

/// 个人信息字段
class ProfileField {
  ProfileField(this.label, this.value);

  final String label;
  final String value;
}

class ProfileSection {
  ProfileSection(this.title, this.fields);

  final String title;
  final List<ProfileField> fields;
}

class StudentProfile {
  StudentProfile({this.name = '', this.studentId = '', List<ProfileSection>? sections})
      : sections = sections ?? <ProfileSection>[];

  String name;
  String studentId;
  List<ProfileSection> sections;
}

/// 下拉项
class ChoiceItem {
  ChoiceItem(this.label, this.value);

  final String label;
  final String value;
}

/// 周次 → 该周周一日期（YYYY-MM-DD）
class WeekDate {
  WeekDate(this.week, this.monday);

  final int week;
  final String monday;
}

/// 培养方案里的一门课
class PlanCourse {
  PlanCourse({
    this.system = '',
    this.group = '',
    this.courseCode = '',
    this.courseName = '',
    this.category = '',
    this.credit = '',
    this.semester = '',
    this.lectureHours = '',
    this.practiceHours = '',
    this.seminarHours = '',
    this.labHours = '',
    this.computerHours = '',
    this.totalHours = '',
  });

  String system;
  String group;
  String courseCode;
  String courseName;
  String category;
  String credit;
  String semester;
  String lectureHours;
  String practiceHours;
  String seminarHours;
  String labHours;
  String computerHours;
  String totalHours;

  double creditNumber() => double.tryParse(credit) ?? 0;
}

class PlanGroup {
  PlanGroup(this.system, List<PlanCourse>? courses, this.totalCredit)
      : courses = courses ?? <PlanCourse>[];

  final String system;
  final List<PlanCourse> courses;
  double totalCredit;
}

/// 培养方案明细
class PlanDetail {
  PlanDetail({
    List<String>? introParagraphs,
    List<String>? detailParagraphs,
    List<PlanCourse>? courses,
    List<PlanGroup>? groups,
    this.totalCredit = 0,
    this.totalHours = 0,
    this.pdfPath = '',
  })  : introParagraphs = introParagraphs ?? <String>[],
        detailParagraphs = detailParagraphs ?? <String>[],
        courses = courses ?? <PlanCourse>[],
        groups = groups ?? <PlanGroup>[];

  List<String> introParagraphs;
  List<String> detailParagraphs;
  List<PlanCourse> courses;
  List<PlanGroup> groups;
  double totalCredit;
  double totalHours;

  /// 培养方案附件（PDF）的相对地址，从页面解析得到。
  ///
  /// 空串表示该方案没有附件。**不同专业/年份的附件名与页数都不同**，
  /// 因此这里只存「页面给出的路径」，绝不写死文件名；页数由 PDF 文档自身决定。
  String pdfPath;

  void buildGroups() {
    final Map<String, PlanGroup> map = <String, PlanGroup>{};
    for (final PlanCourse c in courses) {
      final String key = c.system.isEmpty ? '未分类' : c.system;
      final PlanGroup g = map.putIfAbsent(key, () => PlanGroup(key, null, 0));
      g.courses.add(c);
      g.totalCredit += c.creditNumber();
    }
    groups = map.values.toList();
  }
}

/// 通选课类别
class ElectiveCategory {
  ElectiveCategory({
    required this.name,
    this.required = '',
    this.earned = '',
    this.ongoing = '',
  });

  final String name;
  String required;
  String earned;
  String ongoing;

  /// 学校确实留空了「要求学分」（实测），此时不能判为「未达标」。
  bool satisfied() {
    final double req = double.tryParse(required) ?? -1;
    if (req < 0) {
      return false;
    }
    final double e = double.tryParse(earned) ?? 0;
    final double o = double.tryParse(ongoing) ?? 0;
    return e + o >= req;
  }

  bool get hasRequirement => (double.tryParse(required) ?? -1) >= 0;
}

/// 通选课记录
class ElectiveCourse {
  ElectiveCourse({
    this.courseCode = '',
    this.courseName = '',
    this.credit = '',
    this.score = '',
    this.category = '',
  });

  String courseCode;
  String courseName;
  String credit;
  String score;
  String category;

  bool get isOngoing => score.contains('正在修读');
}

/// 一个大类 + 它下面的课程（界面按这个分组展示）
///
/// 学校原页面是两张独立的表：「类别修读情况」和「课程明细」，
/// 学生要自己按类别名对照。分组把两者合成一条时间线。
class ElectiveGroup {
  ElectiveGroup(this.name);

  final String name;
  final List<ElectiveCourse> courses = <ElectiveCourse>[];

  /// 汇总表里的要求信息；只在课程明细里出现、汇总表没有的大类为 null。
  ElectiveCategory? info;

  /// 用户自录的要求学分（>=0 时生效，-1 表示未设置）。
  ///
  /// 为什么要这个覆盖值：学校「要求学分（大于等于）」那一列实测是空的，
  /// 于是界面只能显示「学校未设置要求」、也画不出进度条 ——
  /// 学生明明可以从培养方案查到自己要修多少，App 却帮不上忙。
  /// 用户录一次后，达标判断与进度条都以这个值为准。
  ///
  /// 优先级：**用户自录 > 服务器**。用户手填的是他自己专业的准确要求，
  /// 而服务器那一列要么为空、要么是学校统一口径，以用户为准更符合预期。
  double customRequired = -1;

  bool get hasCourses => courses.isNotEmpty;

  /// 是否使用用户自录的要求（界面据此显示「修改」而不是「设置」）
  bool get hasCustomRequired => customRequired >= 0;

  /// 能画进度条的前提：有正的分母（分母为 0 画出来没有意义）
  bool get canShowProgress => requiredNumber > 0;

  double get requiredNumber {
    if (customRequired >= 0) {
      return customRequired;
    }
    final ElectiveCategory? c = info;
    if (c == null) {
      return -1;
    }
    return double.tryParse(c.required) ?? -1;
  }

  double get earnedNumber => double.tryParse(info?.earned ?? '') ?? 0;

  double get ongoingNumber => double.tryParse(info?.ongoing ?? '') ?? 0;
}

class ElectiveReport {
  ElectiveReport({
    List<ElectiveCategory>? categories,
    List<ElectiveCourse>? courses,
    this.totalEarned = '',
    this.totalOngoing = '',
  })  : categories = categories ?? <ElectiveCategory>[],
        courses = courses ?? <ElectiveCourse>[];

  List<ElectiveCategory> categories;
  List<ElectiveCourse> courses;
  String totalEarned;
  String totalOngoing;

  double earnedNumber() => double.tryParse(totalEarned) ?? 0;

  double ongoingNumber() => double.tryParse(totalOngoing) ?? 0;

  /// 按「大类 → 具体课程」归并。
  ///
  /// 两条刻意的规则：
  ///   1. 汇总表里的大类**全都保留**（即使本学期没有课）—— 修读要求挂在
  ///      大类上，藏起来学生就看不到还差多少学分；
  ///   2. 课程明细里出现、汇总表却没有的大类（学校数据不同步时会发生）
  ///      也追加进来，避免课程凭空消失。
  ///
  /// 两边都保持学校给出的原始顺序，不重排。
  List<ElectiveGroup> grouped() {
    final List<ElectiveGroup> out = <ElectiveGroup>[];
    final Map<String, ElectiveGroup> byName = <String, ElectiveGroup>{};
    for (final ElectiveCategory c in categories) {
      if (byName.containsKey(c.name)) {
        continue; // 汇总表出现重名时只认第一条，不重复建组
      }
      final ElectiveGroup g = ElectiveGroup(c.name)..info = c;
      byName[c.name] = g;
      out.add(g);
    }
    for (final ElectiveCourse c in courses) {
      final String key = c.category.isEmpty ? '未标注类别' : c.category;
      ElectiveGroup? g = byName[key];
      if (g == null) {
        g = ElectiveGroup(key);
        byName[key] = g;
        out.add(g);
      }
      g.courses.add(c);
    }
    return out;
  }
}
