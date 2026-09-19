/// 桌面卡片快照：`done` 的判定语义
///
/// 这个用例锁住一条**很容易搞错、且错了不易察觉**的规则：
/// 「已上完」必须按这节课的**下课时刻**判断，不能用上课时刻。
///
/// 按上课时刻算的话，正在上的课也会被标成已上完（14:23 时 14:00 那节
/// 还在进行中），卡片会给它画删除线并置灰 —— 用户以为这节课结束了。
/// 实测出过一次：Dart 侧用了 startMinutes，而 Kotlin 侧与鸿蒙端都用结束时刻。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/data/section_time_store.dart';

void main() {
  group('SectionTime 的起止时刻', () {
    test('endMinutes 解析下课时刻', () {
      final SectionTime st = SectionTime(0, '第一、二节', '08:30', '10:00');
      expect(st.startMinutes(), 8 * 60 + 30);
      expect(st.endMinutes(), 10 * 60);
    });

    test('结束时刻晚于开始时刻（正常作息）', () {
      final SectionTime st = SectionTime(2, '第五、六节', '14:00', '15:30');
      expect(st.endMinutes(), greaterThan(st.startMinutes()));
    });

    test('非法时刻返回 -1（调用方据此跳过判断）', () {
      final SectionTime bad = SectionTime(0, 'x', '', 'nope');
      expect(bad.startMinutes(), -1);
      expect(bad.endMinutes(), -1);
    });
  });

  group('「已上完」的判据', () {
    /// 复刻 CardSnapshotStore.build 里的判据：endMin <= nowMin
    bool doneAt(SectionTime st, int nowMinutes) {
      final int end = st.endMinutes();
      return end >= 0 && end <= nowMinutes;
    }

    final SectionTime s2 = SectionTime(2, '第五、六节', '14:00', '15:30');

    test('课还没开始 → 未上完', () {
      expect(doneAt(s2, 13 * 60 + 59), isFalse);
    });

    test('**正在上课** → 未上完（这是修复的关键点）', () {
      // 14:23：课已开始 23 分钟，但 15:30 才下课
      expect(doneAt(s2, 14 * 60 + 23), isFalse,
          reason: '按上课时刻算会误判成已上完，卡片会给进行中的课画删除线');
      // 用旧的错误判据（startMin < nowMin）在这里会得到 true，正是要避免的
      final int start = s2.startMinutes();
      expect(start < 14 * 60 + 23, isTrue, reason: '旧判据确实会误判');
    });

    test('刚下课 → 已上完', () {
      expect(doneAt(s2, 15 * 60 + 30), isTrue);
    });

    test('下课后很久 → 已上完', () {
      expect(doneAt(s2, 23 * 60 + 59), isTrue);
    });
  });
}
