/// 课表「已修改」判定的回归测试
///
/// 锁住三件事，都是真机上出过问题的：
///   1. 新增 / 修改能被识别（原有行为，防止改坏）；
///   2. **删除服务器课程也能被识别** —— 早先只看条目的 `local` 标记，
///      而删除会连标记一起去掉，于是删完判定为「未修改」，
///      「已修改」入口不出现、用户也没法恢复；
///   3. 基线只在从服务器新鲜拉取时才写，缓存命中不覆盖它
///      （否则「已删掉的那门课」会被从基线里抹掉，删除又检测不出来）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/model/models.dart';

/// 造一门「服务器来的」课（id 用解析器的格式，基线靠它比对）
CourseEntry server(String name, {int row = 0, int col = 0}) => CourseEntry(
      id: 'srv-$row-$col-$name-1-18-0',
      courseName: name,
      startWeek: 1,
      endWeek: 18,
    );

/// 造一门「本地新增的」课
CourseEntry local(String name) => CourseEntry(
      id: 'local-1',
      courseName: name,
      startWeek: 1,
      endWeek: 18,
      local: true,
    );

Timetable withCourses(List<CourseEntry> list, {List<String>? baseline}) {
  final Timetable tt = Timetable();
  final CellData c = tt.ensureCell(0, 0);
  c.entries.addAll(list);
  if (baseline != null) {
    tt.serverIds = baseline;
  }
  return tt;
}

void main() {
  group('未改动', () {
    test('纯服务器课表：没有 local、基线完整 ⇒ 未修改', () {
      final CourseEntry a = server('数据结构');
      final CourseEntry b = server('离散数学', col: 1);
      final Timetable tt = withCourses(
        <CourseEntry>[a, b],
        baseline: <String>[a.id, b.id],
      );
      expect(tt.hasLocalEdits(), isFalse);
    });

    test('基线为空（旧缓存）时退化为只看 local —— 不误报', () {
      final Timetable tt = withCourses(<CourseEntry>[server('数据结构')]);
      expect(tt.serverIds, isEmpty);
      expect(tt.hasLocalEdits(), isFalse,
          reason: '宁可少报，也不能把干净的服务器课表判成已修改');
    });
  });

  group('新增与修改', () {
    test('新增一门本地课 ⇒ 已修改', () {
      final CourseEntry a = server('数据结构');
      final Timetable tt = withCourses(
        <CourseEntry>[a, local('新加的课')],
        baseline: <String>[a.id],
      );
      expect(tt.hasLocalEdits(), isTrue);
    });

    test('修改服务器课程（local 被置位）⇒ 已修改', () {
      final CourseEntry a = server('数据结构');
      a.local = true; // 编辑后由编辑器置位
      final Timetable tt = withCourses(<CourseEntry>[a], baseline: <String>[a.id]);
      expect(tt.hasLocalEdits(), isTrue);
    });

    test('打开弹窗但没改动 ⇒ 仍未修改（_flush 不该无条件置位）', () {
      final CourseEntry a = server('数据结构');
      final Timetable tt = withCourses(<CourseEntry>[a], baseline: <String>[a.id]);
      // 模拟「点开弹窗又直接保存」：内容没变，local 不该被置位
      expect(tt.hasLocalEdits(), isFalse);
      expect(a.local, isFalse);
    });
  });

  group('删除（本次修复的核心）', () {
    test('删掉一门服务器课程 ⇒ 已修改', () {
      final CourseEntry a = server('数据结构');
      final CourseEntry b = server('离散数学', col: 1);
      // 基线记下两门，但当前只剩一门（b 被删）
      final Timetable tt = withCourses(
        <CourseEntry>[a],
        baseline: <String>[a.id, b.id],
      );
      expect(tt.hasLocalEdits(), isTrue,
          reason: '删除必须能被识别 —— 这是「已修改」入口不出现的根因');
    });

    test('删掉整格的全部课 ⇒ 已修改', () {
      final CourseEntry a = server('数据结构');
      final Timetable tt = withCourses(<CourseEntry>[], baseline: <String>[a.id]);
      expect(tt.hasLocalEdits(), isTrue);
    });

    test('删掉一门又新增一门 ⇒ 仍然已修改', () {
      final CourseEntry a = server('数据结构');
      final CourseEntry b = server('离散数学', col: 1);
      final Timetable tt = withCourses(
        <CourseEntry>[a, local('替掉的课')],
        baseline: <String>[a.id, b.id],
      );
      expect(tt.hasLocalEdits(), isTrue);
    });
  });

  group('基线捕获', () {
    test('只收录服务器课程，不把本地新增的记进基线', () {
      final CourseEntry a = server('数据结构');
      final Timetable tt = withCourses(<CourseEntry>[a, local('新加的课')]);
      tt.captureServerBaseline();
      expect(tt.serverIds, <String>[a.id]);
    });

    test('捕获后再删一门，能被检出', () {
      final CourseEntry a = server('数据结构');
      final CourseEntry b = server('离散数学', col: 1);
      final Timetable tt = withCourses(<CourseEntry>[a, b]);
      tt.captureServerBaseline();
      expect(tt.hasLocalEdits(), isFalse, reason: '刚拉下来时应是干净的');

      tt.cells.first.entries.removeWhere((CourseEntry e) => e.id == b.id);
      expect(tt.hasLocalEdits(), isTrue);
    });
  });
}
