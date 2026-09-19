/// 顶栏插槽的单元测试
///
/// 课表页把「周次/学期/校历」提交到顶栏，与标题和设置按钮同一行 ——
/// 这样页面内省下一整行，底部备注不再被挤掉。
///
/// 这条通道的关键契约是**调度阶段区分**，用测试钉住：
///   - 构建期间（`persistentCallbacks`）提交必须延到帧后，否则
///     AppShell 会在构建过程中被要求重建，Flutter 直接报错；
///   - 帧空闲时同步生效，便于确定性断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/pages/top_bar_slot.dart';

void main() {
  setUp(() {
    TopBarSlot.controls.value = null;
  });

  tearDown(() {
    TopBarSlot.controls.value = null;
  });

  testWidgets('帧空闲时提交同步生效', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    // pump 结束后调度已回到 idle，此时提交应当立即写入
    expect(SchedulerBinding.instance.schedulerPhase, SchedulerPhase.idle);
    TopBarSlot.submit(const Text('周次'));
    expect(TopBarSlot.controls.value, isA<Text>());
  });

  testWidgets('clear 同步清空插槽', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    TopBarSlot.submit(const Text('学期'));
    expect(TopBarSlot.controls.value, isNotNull);

    TopBarSlot.clear();
    expect(TopBarSlot.controls.value, isNull,
        reason: '离开课表后顶栏不该还挂着它的控件');
  });

  testWidgets('构建期间提交不抛异常，并在帧后生效', (WidgetTester tester) async {
    // 复现真实调用路径：页面在 build() 里提交。若实现是同步写 notifier，
    // 这里会直接抛 setState-during-build —— 这正是要防住的回归。
    late StateSetter rebuild;
    int builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            builds++;
            TopBarSlot.submit(Text('第 $builds 次'));
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );
    // 首次构建期间提交 → 延后；泵一帧后应当生效
    await tester.pump();
    expect(TopBarSlot.controls.value, isA<Text>(),
        reason: '构建期间提交必须最终生效，且不能抛异常');

    // 触发一次重建，确认不会因重复提交而报错
    rebuild(() {});
    await tester.pump();
    expect(TopBarSlot.controls.value, isA<Text>());
  });

  testWidgets('重复提交同一实例不触发额外通知', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    const Text w = Text('校历');
    TopBarSlot.submit(w);

    int notified = 0;
    void listener() => notified++;
    TopBarSlot.controls.addListener(listener);
    // 同一个实例再次提交：值未变，应当跳过，避免无意义的整树重建
    TopBarSlot.submit(w);
    TopBarSlot.controls.removeListener(listener);
    expect(notified, 0);
  });
}
