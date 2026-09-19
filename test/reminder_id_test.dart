/// 上课提醒的 id 契约测试
///
/// 这里锁住的是一个**真机上暴露过**的 bug：设置页退出再进来，
/// 「上课提醒」显示「已排定 0 条」，而系统里其实挂着十几条提醒。
///
/// 根因有两层，两层都要防：
///   1. 设置页从来没向系统**读回**真实条数，只用了内存计数（重进页面即为 0）；
///   2. 幂等分配的 id 曾经用 `% 1000000` 回绕，算出的值远超「自己排的
///      通知」的识别区间 —— 就算去读系统，也会一条都认不出来。
///
/// 第 1 层属于页面行为（由 `_load` 里调用 `pendingCount()` 保证）；
/// 第 2 层是纯逻辑，正是这里要锁住的。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/data/reminder_service.dart';

void main() {
  setUp(ReminderService.resetForTest);

  group('通知 id 与识别区间', () {
    test('分配出的每个 id 都能被认作自己排的通知', () {
      // 这是核心契约：分配与识别必须自洽。
      // 早先两者用了不同的模数，分配出来的 id 一律落在识别区间之外。
      for (int i = 0; i < 200; i++) {
        final int id = ReminderService.nextIdForTest();
        expect(ReminderService.isOursForTest(id), isTrue,
            reason: '第 $i 个分配的 id=$id 识别失败');
      }
    });

    test('id 互不重复（重复会让新通知覆盖旧通知）', () {
      final Set<int> seen = <int>{};
      for (int i = 0; i < 500; i++) {
        final int id = ReminderService.nextIdForTest();
        expect(seen.add(id), isTrue, reason: 'id=$id 重复出现');
      }
    });

    test('大量分配仍在区间内回绕，不会越界', () {
      // 回绕是允许的（一学期远用不到一万条），但**越界**不行 ——
      // 越界就等于「这条提醒再也不会被统计到」。
      for (int i = 0; i < 25000; i++) {
        final int id = ReminderService.nextIdForTest();
        expect(ReminderService.isOursForTest(id), isTrue,
            reason: '第 $i 次分配越出区间: id=$id');
      }
    });

    test('重置后重新从区间开头分配', () {
      for (int i = 0; i < 10; i++) {
        ReminderService.nextIdForTest();
      }
      final int before = ReminderService.nextIdForTest();
      ReminderService.resetForTest();
      final int after = ReminderService.nextIdForTest();
      expect(after, lessThan(before),
          reason: '重排（reschedule）会把计数器归零，避免一路涨出区间');
      expect(ReminderService.isOursForTest(after), isTrue);
    });

    test('区间外的 id 不算自己的（别的功能排的通知不该被统计）', () {
      expect(ReminderService.isOursForTest(0), isFalse);
      expect(ReminderService.isOursForTest(1), isFalse);
      expect(ReminderService.isOursForTest(-1), isFalse);
      expect(ReminderService.isOursForTest(99999999), isFalse);
    });
  });
}
