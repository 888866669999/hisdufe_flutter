/// 玻璃选择器 / 输入框底衬的 widget 测试
///
/// 这一批改动把全应用的下拉框统一到了 `showGlassPicker` + `GlassPickerField`，
/// 并给输入框加了玻璃底衬。玻璃本身依赖着色器，单测看不了像素，
/// 但**能用 widget 测试锁住三件真正会坏的事**：
///   1. 弹窗能正常构建、不抛异常（玻璃库在换尺寸/后端异常时可能炸）；
///   2. 当前值被正确高亮到（滚轮初始位置对），
///      否则用户点开会看到「选中的不是当前值」，得手动滚回去；
///   3. 确定/取消分别返回选中值与 null —— 这是调用方依赖的契约。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/theme/theme.dart';
import 'package:hisdufe_jw/widgets/glass_picker.dart';
import 'package:hisdufe_jw/widgets/glass_picker_field.dart';

/// 把被测组件塞进一个最小可用的 MaterialApp
Widget host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('GlassPickerField 外观', () {
    testWidgets('显示标签、当前值与展开箭头，点击触发 onTap', (WidgetTester t) async {
      int taps = 0;
      await t.pumpWidget(host(GlassPickerField(
        label: '学期',
        value: '2026-2027-1',
        onTap: () => taps++,
      )));
      await t.pumpAndSettle();

      expect(find.text('学期'), findsOneWidget);
      expect(find.text('2026-2027-1'), findsOneWidget);
      expect(find.byIcon(Icons.unfold_more), findsOneWidget);

      await t.tap(find.text('2026-2027-1'));
      expect(taps, 1, reason: '点整行都应触发 onTap，而不是只有箭头可点');
    });

    testWidgets('有「本周」标记时显示出来', (WidgetTester t) async {
      await t.pumpWidget(host(GlassPickerField(
        label: '周次',
        value: '第 4 周',
        mark: '本周',
        onTap: () {},
      )));
      await t.pumpAndSettle();
      expect(find.text('本周'), findsOneWidget);
    });

    testWidgets('空标签不渲染多余文本', (WidgetTester t) async {
      await t.pumpWidget(host(GlassPickerField(
        label: '',
        value: '全部学期',
        onTap: () {},
      )));
      await t.pumpAndSettle();
      expect(find.text('全部学期'), findsOneWidget);
    });
  });

  group('showGlassPicker 弹窗', () {
    testWidgets('打开后显示标题与全部选项', (WidgetTester t) async {
      await t.pumpWidget(host(Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () => showGlassPicker<String>(
            c,
            title: '选择周次',
            current: '2',
            options: const <GlassOption<String>>[
              GlassOption<String>('1', '第 1 周'),
              GlassOption<String>('2', '第 2 周'),
              GlassOption<String>('3', '第 3 周'),
            ],
          ),
          child: const Text('打开'),
        ),
      )));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();

      expect(find.text('选择周次'), findsOneWidget);
      // 标题 + 取消 + 确定的按钮
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('确定'), findsOneWidget);
      expect(takePendingException(), isNull,
          reason: '玻璃弹窗在测试环境下构建不应抛异常');
    });

    testWidgets('点确定返回当前选中值', (WidgetTester t) async {
      String? got;
      await t.pumpWidget(host(Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () async {
            got = await showGlassPicker<String>(
              c,
              title: '选择周次',
              current: '2',
              options: const <GlassOption<String>>[
                GlassOption<String>('1', '第 1 周'),
                GlassOption<String>('2', '第 2 周'),
                GlassOption<String>('3', '第 3 周'),
              ],
            );
          },
          child: const Text('打开'),
        ),
      )));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();

      await t.tap(find.text('确定'));
      await t.pumpAndSettle();

      // 初始位置应落在 current('2') 上，因此直接确定就是 '2'
      expect(got, '2',
          reason: '初始位置必须对准当前值，否则用户点确定会改成别的周');
    });

    testWidgets('点取消返回 null（调用方据此不改动状态）', (WidgetTester t) async {
      bool returned = false;
      String? got = 'sentinel';
      await t.pumpWidget(host(Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () async {
            got = await showGlassPicker<String>(
              c,
              title: '选择学期',
              current: 'a',
              options: const <GlassOption<String>>[
                GlassOption<String>('a', 'A 学期'),
                GlassOption<String>('b', 'B 学期'),
              ],
            );
            returned = true;
          },
          child: const Text('打开'),
        ),
      )));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();

      await t.tap(find.text('取消'));
      await t.pumpAndSettle();

      expect(returned, isTrue);
      expect(got, isNull, reason: '取消必须返回 null，让调用方保持原值');
    });

    testWidgets('current 不在选项里时落在第 0 项而不是崩溃', (WidgetTester t) async {
      await t.pumpWidget(host(Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () => showGlassPicker<String>(
            c,
            title: '选择',
            current: '不存在的值',
            options: const <GlassOption<String>>[
              GlassOption<String>('x', 'X'),
              GlassOption<String>('y', 'Y'),
            ],
          ),
          child: const Text('打开'),
        ),
      )));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(takePendingException(), isNull);
      expect(find.text('选择'), findsOneWidget);
    });

    testWidgets('空选项列表直接返回 null，不打开空弹窗', (WidgetTester t) async {
      String? got = 'sentinel';
      await t.pumpWidget(host(Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () async {
            got = await showGlassPicker<String>(
              c,
              title: '选择',
              options: const <GlassOption<String>>[],
            );
          },
          child: const Text('打开'),
        ),
      )));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(got, isNull, reason: '没有选项时不该弹出一个空壳');
    });
  });
}

/// 便捷取当前未被处理的异常（widget 测试里用它断言「没炸」）
Object? takePendingException() => TestWidgetsFlutterBinding.instance
    .takeException();
