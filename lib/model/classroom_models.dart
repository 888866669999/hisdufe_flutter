/// 教室查询的纯逻辑：周次说明解析、占用判定、空闲统计
///
/// 从鸿蒙版 `model/ClassroomModels.ets` 移植。
///
/// ===== 为什么周次过滤必须放在客户端做 =====
/// 服务端的 `zc1`/`zc2` 参数**不可靠**，实测有两处问题：
///   1. 「被借用」类记录不受周次参数影响，筛选后仍会返回；
///   2. 筛选后会把「该周完全没有占用记录」的教室整条丢掉 ——
///      而真正全周空闲的教室恰好都在被丢掉的那批里。
/// 因此请求时**故意不传周次**，拿回全学期占用文本，再由客户端按周判断。
/// 这个决定经过两次独立实现交叉验证（章丘校区第 4 周第一节次
/// [166,155,164,166,178,221,219] 两次结果一致）。
library;

import '../common/constants.dart';

/// 周次说明，例如 `1-18周`、`3-17周(双)`、`1-16,18周`
class WeekSpec {
  WeekSpec(this.ranges, this.parity, this.raw);

  /// 周次区间列表，每项 [start, end]
  final List<List<int>> ranges;

  /// 0 = 不限，1 = 单周，2 = 双周
  final int parity;
  final String raw;

  bool isActive(int week) {
    if (week <= 0) {
      return true;
    }
    if (ranges.isEmpty) {
      // 没有周次信息时保守判为占用
      return true;
    }
    bool inRange = false;
    for (final List<int> r in ranges) {
      if (week >= r[0] && week <= r[1]) {
        inRange = true;
        break;
      }
    }
    if (!inRange) {
      return false;
    }
    // 单双周只在「区间内」起过滤作用，且**必须与区间自洽**。
    //
    // 真实页面里存在 `(4单周)` 这种写法：第 4 周是偶数，却标了「单周」。
    // 若无条件按单双周过滤，这门课在任何一周都不会显示 —— 属于静默丢课。
    // 因此先判断「区间里是否真的存在符合该奇偶的周」，不存在就忽略奇偶标记，
    // 以显式写出的周次为准。
    if (parity == 0 || !_parityPossible()) {
      return true;
    }
    if (parity == 1 && week % 2 == 0) {
      return false;
    }
    if (parity == 2 && week % 2 == 1) {
      return false;
    }
    return true;
  }

  /// 区间里是否存在符合单双周标记的周次
  bool _parityPossible() {
    for (final List<int> r in ranges) {
      for (int w = r[0]; w <= r[1]; w++) {
        if (parity == 1 && w % 2 == 1) {
          return true;
        }
        if (parity == 2 && w % 2 == 0) {
          return true;
        }
      }
    }
    return false;
  }

  /// 是否覆盖整学期（用于「全学期占用」的展示）
  bool allowsAnyWeek() {
    if (parity != 0) {
      return false;
    }
    for (final List<int> r in ranges) {
      if (r[0] <= 1 && r[1] >= kMaxWeeks) {
        return true;
      }
    }
    return false;
  }

  String display() {
    final String p = parity == 1 ? '(单)' : (parity == 2 ? '(双)' : '');
    if (ranges.isEmpty) {
      return raw.isEmpty ? '周次未知$p' : '$raw$p';
    }
    final String body = ranges.map((List<int> r) => '${r[0]}-${r[1]}').join(',');
    return '$body周$p';
  }
}

/// 解析 `(3-18周)` / `(1-16,18周)` / `(5-18周(双))` 这类写法
class WeekSpecParser {
  static final RegExp _one = RegExp(r'\(([0-9][0-9,\-]*)\s*(单|双)?\s*周\)');
  static final RegExp _all = RegExp(r'\(([0-9][0-9,\-]*)\s*(单|双)?\s*周\)');

  /// 取第一个匹配
  static WeekSpec? first(String text) {
    final RegExpMatch? m = _one.firstMatch(text);
    if (m == null) {
      return null;
    }
    return _build(m.group(1) ?? '', m.group(2) ?? '', text);
  }

  /// 取全部匹配
  static List<WeekSpec> all(String text) {
    final List<WeekSpec> out = <WeekSpec>[];
    for (final RegExpMatch m in _all.allMatches(text)) {
      out.add(_build(m.group(1) ?? '', m.group(2) ?? '', m.group(0) ?? ''));
    }
    return out;
  }

  static WeekSpec _build(String digits, String parityText, String raw) {
    final List<List<int>> ranges = <List<int>>[];
    for (final String part in digits.split(',')) {
      final String p = part.trim();
      if (p.isEmpty) {
        continue;
      }
      final int dash = p.indexOf('-');
      if (dash > 0) {
        final int? a = int.tryParse(p.substring(0, dash));
        final int? b = int.tryParse(p.substring(dash + 1));
        if (a != null && b != null) {
          ranges.add(<int>[a < b ? a : b, a < b ? b : a]);
        }
      } else {
        final int? v = int.tryParse(p);
        if (v != null) {
          ranges.add(<int>[v, v]);
        }
      }
    }
    final int parity =
        parityText == '单' ? 1 : (parityText == '双' ? 2 : 0);
    return WeekSpec(ranges, parity, raw);
  }
}

/// 一条占用记录
class RoomBooking {
  RoomBooking({
    required this.label,
    this.person = '',
    this.className = '',
    this.borrowed = false,
    required this.spec,
  });

  /// 展示用（课程名或「借用：事由」）
  String label;

  /// 借用/授课人
  String person;
  String className;

  /// 是否是「被借用」
  bool borrowed;
  WeekSpec spec;

  bool isActive(int week) => spec.isActive(week);
}

/// 一间教室的全周占用
class RoomSlot {
  RoomSlot(this.room);

  final String room;

  /// 7 天的占用记录
  final List<List<RoomBooking>> days =
      List<List<RoomBooking>>.generate(7, (_) => <RoomBooking>[]);

  bool isBusy(int day, int week) {
    for (final RoomBooking b in days[day]) {
      if (b.isActive(week)) {
        return true;
      }
    }
    return false;
  }

  List<RoomBooking> bookingsOf(int day) => days[day];
}

class ClassroomResult {
  ClassroomResult({
    this.campus = '',
    this.building = '',
    this.semester = '',
    this.sectionRow = 0,
    List<RoomSlot>? rooms,
  }) : rooms = rooms ?? <RoomSlot>[];

  String campus;
  String building;
  String semester;
  int sectionRow;
  List<RoomSlot> rooms;
}

/// 空闲教室
class FreeRoom {
  FreeRoom(this.room, this.building);

  final String room;
  final String building;
}

/// 某天的空闲统计
class DayFreeStat {
  DayFreeStat(this.day, this.free, this.total);

  final int day;
  final int free;
  final int total;
}

class ClassroomFinder {
  /// 某周某天某节次的空闲教室
  static List<FreeRoom> freeRooms(ClassroomResult result, int day, int week) {
    final List<FreeRoom> out = <FreeRoom>[];
    for (final RoomSlot s in result.rooms) {
      if (!s.isBusy(day, week)) {
        out.add(FreeRoom(s.room, _buildingOf(s.room)));
      }
    }
    out.sort((FreeRoom a, FreeRoom b) => compareRoom(a.room, b.room));
    return out;
  }

  /// 某周某天被占用（上课或借用）的教室
  static List<FreeRoom> busyRooms(ClassroomResult result, int day, int week) {
    final List<FreeRoom> out = <FreeRoom>[];
    for (final RoomSlot s in result.rooms) {
      if (s.isBusy(day, week)) {
        out.add(FreeRoom(s.room, _buildingOf(s.room)));
      }
    }
    return out;
  }

  /// 各天的空闲数（用于「本周空闲速览」）
  static List<DayFreeStat> weekStats(ClassroomResult result, int week) {
    final List<DayFreeStat> out = <DayFreeStat>[];
    for (int d = 0; d < 7; d++) {
      int free = 0;
      for (final RoomSlot s in result.rooms) {
        if (!s.isBusy(d, week)) {
          free++;
        }
      }
      out.add(DayFreeStat(d, free, result.rooms.length));
    }
    return out;
  }

  /// 教室是否属于某教学楼。
  ///
  /// 严格比较，**绝不做后缀匹配**：`1` 不能匹配 `11-101`。
  /// 早期用 `contains` 导致选「1 号楼」时把 11 号楼的教室也算进来。
  static bool belongsTo(String room, String building) {
    if (building.isEmpty) {
      return true;
    }
    final String head = _buildingOf(room);
    if (head == building) {
      return true;
    }
    // 纯数字时要求完全相等
    final int? a = int.tryParse(head);
    final int? b = int.tryParse(building);
    if (a != null && b != null) {
      return a == b;
    }
    return false;
  }

  static String _buildingOf(String room) {
    final int i = room.indexOf('-');
    if (i > 0) {
      return room.substring(0, i);
    }
    // `操场` 这类没有分段的，整体作为「楼」
    return room;
  }

  /// 教室排序：数字楼号在前升序，非数字在后，再按字典序
  static int compareRoom(String a, String b) {
    final int? na = int.tryParse(_buildingOf(a));
    final int? nb = int.tryParse(_buildingOf(b));
    if (na != null && nb != null) {
      if (na != nb) {
        return na.compareTo(nb);
      }
    } else if (na != null) {
      return -1;
    } else if (nb != null) {
      return 1;
    }
    return a.compareTo(b);
  }

  /// 节次行对应的课节代码。
  ///
  /// 注意第 5 行（第九~十一节）是 `09`–`11`：服务端把三节并成一段，
  /// 查询参数用 `09`/`11`，不是 `09`/`10`。
  static List<String> sectionCodes(int row) {
    switch (row) {
      case 0:
        return <String>['01', '02'];
      case 1:
        return <String>['03', '04'];
      case 2:
        return <String>['05', '06'];
      case 3:
        return <String>['07', '08'];
      case 4:
        return <String>['09', '11'];
      default:
        return <String>['01', '02'];
    }
  }

  static const List<String> _dayLabels = <String>[
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  static String dayLabel(int day) =>
      (day >= 0 && day < 7) ? _dayLabels[day] : '';
}
