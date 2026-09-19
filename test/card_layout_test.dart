/// 课程卡尺寸规划测试
///
/// 这一块是「整周固定一屏」的关键：格子高度固定，而内容行数不定。
/// 规划一旦低估就会撑破格子 —— 画面上会出现黄黑 overflow 警告条。
/// 早先的实现正是如此（估算漏算了内边距、行距与单双周那行），
/// 在横屏等矮屏上每次都溢出。这些断言把它钉住。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/model/card_layout.dart';

void main() {
  const double nameFs = 11;
  const double metaFs = 9;

  group('装得下时保留最多信息', () {
    test('空间充足：课名多行 + 教室两行 + 单双周都显示', () {
      final CardPlan p = planCard(
        availH: 200,
        innerW: 60,
        nameText: '概率统计原理及应用',
        metaText: '7-316(章丘)',
        hasParity: true,
        nameFs: nameFs,
        metaFs: metaFs,
        maxNameLines: 6,
      );
      expect(p.nameLines, greaterThan(1));
      expect(p.metaLines, 2);
      expect(p.showParity, isTrue);
    });
  });

  group('空间不足时按固定优先级降级', () {
    test('降级是单调的：随高度降低，信息只减不增', () {
      // 逐档收紧高度，观察降级顺序。实测的档位（见断言里的注释）：
      //   高 → 教室两行 + 单双周
      //   中 → 教室一行 + 单双周（先减教室行数，因为教室仍需可读）
      //   低 → 教室一行、舍单双周
      //   极低 → 只留课名
      CardPlan at(double h) => planCard(
            availH: h,
            innerW: 60,
            nameText: '数据结构',
            metaText: '9-316(章丘)',
            hasParity: true,
            nameFs: nameFs,
            metaFs: metaFs,
            maxNameLines: 6,
          );

      final CardPlan tall = at(200);
      expect(tall.metaLines, 2, reason: '高格应给教室两行');
      expect(tall.showParity, isTrue);

      final CardPlan mid = at(50);
      expect(mid.metaLines, 1, reason: '中等高度先把教室收到一行');

      final CardPlan low = at(38);
      expect(low.metaLines, 1);
      expect(low.showParity, isFalse, reason: '再矮才牺牲单双周');
      expect(low.nameLines, greaterThanOrEqualTo(1));

      final CardPlan tiny = at(24);
      expect(tiny.metaLines, 0, reason: '极矮时只留课名');
      expect(tiny.nameLines, 1);

      // 单调性：信息量不能随高度降低而增加
      final List<CardPlan> ladder = <CardPlan>[tall, mid, low, tiny];
      for (int i = 1; i < ladder.length; i++) {
        final int prevInfo = ladder[i - 1].metaLines * 10 +
            (ladder[i - 1].showParity ? 1 : 0);
        final int curInfo =
            ladder[i].metaLines * 10 + (ladder[i].showParity ? 1 : 0);
        expect(curInfo, lessThanOrEqualTo(prevInfo),
            reason: '第 $i 档信息量不应超过前一档');
      }
    });

    test('无论多矮，课名至少保留一行（不能说不出这是哪门课）', () {
      for (final double h in <double>[0, 1, 5, 12, 20]) {
        final CardPlan p = planCard(
          availH: h,
          innerW: 60,
          nameText: '大学物理Ⅰ',
          metaText: '7-120(章丘)',
          hasParity: true,
          nameFs: nameFs,
          metaFs: metaFs,
          maxNameLines: 6,
        );
        expect(p.nameLines, greaterThanOrEqualTo(1), reason: 'availH=$h');
      }
    });
  });

  group('占用高度不超预算（这是「不溢出」的充要条件）', () {
    test('各种可用高度下，规划出的占用都不超过可用高度', () {
      for (final double h in <double>[18, 24, 32, 48, 64, 96, 140, 220]) {
        for (final bool parity in <bool>[true, false]) {
          for (final String meta in <String>['', '7-120(章丘)']) {
            final CardPlan p = planCard(
              availH: h,
              innerW: 55,
              nameText: '毛泽东思想和中国特色社会主义理论体系概论',
              metaText: meta,
              hasParity: parity,
              nameFs: nameFs,
              metaFs: metaFs,
              maxNameLines: 6,
            );
            // 唯一的例外：连「一行课名」都放不下时，只能让它略微超出并由
            // ClipRect 裁掉（总比看不见课名好）。此时要求 ≥1 行即可。
            final double minNeeded = 8 + 1 * (nameFs * 1.15);
            if (h >= minNeeded) {
              expect(p.usedHeight(nameFs, metaFs), lessThanOrEqualTo(h + 0.01),
                  reason: 'availH=$h parity=$parity meta="$meta" '
                      'plan=$p');
            }
          }
        }
      }
    });
  });

  group('真实文本度量', () {
    test('短文本只占一行', () {
      expect(measuredLines('篮球', nameFs, 80, 6), 1);
    });

    test('长文本在窄宽度下会占多行', () {
      final int n = measuredLines(
          '毛泽东思想和中国特色社会主义理论体系概论', nameFs, 55, 6);
      expect(n, greaterThan(1));
    });

    test('受 maxLines 限制，不会超过上限', () {
      final int n = measuredLines(
          '毛泽东思想和中国特色社会主义理论体系概论', nameFs, 40, 2);
      expect(n, lessThanOrEqualTo(2));
    });

    test('空文本占 0 行（不白占高度）', () {
      expect(measuredLines('', nameFs, 80, 6), 0);
    });

    test('宽度为 0 时不崩，返回 0', () {
      expect(measuredLines('大学物理', nameFs, 0, 6), 0);
    });
  });

  group('同格多门课', () {
    test('两门课时每门分到的高度减半，仍满足「不超过预算」', () {
      const double rowH = 80;
      const double cellPad = 1.5;
      final double innerH = rowH - cellPad * 2;
      final double per = (innerH - 2.0) / 2;
      final CardPlan p = planCard(
        availH: per,
        innerW: 50,
        nameText: '数据结构',
        metaText: '9-316(章丘)',
        hasParity: true,
        nameFs: nameFs,
        metaFs: metaFs,
        maxNameLines: 6,
      );
      expect(p.usedHeight(nameFs, metaFs), lessThanOrEqualTo(per + 0.01));
    });
  });

  group('文字缩放（无障碍大字号）', () {
    test('放大字号后需要更多（或相同）行数，不会反而变少', () {
      final int at1 = measuredLines(
          '毛泽东思想和中国特色社会主义理论体系概论', 11, 55, 6);
      final int at2 = measuredLines(
          '毛泽东思想和中国特色社会主义理论体系概论', 11, 55, 6,
          textScaler: const TextScaler.linear(2.0));
      expect(at2, greaterThanOrEqualTo(at1));
    });

    test('放大字号后规划结果仍不超预算', () {
      const double availH = 70;
      final CardPlan p = planCard(
        availH: availH,
        innerW: 50,
        nameText: '数据结构',
        metaText: '9-316(章丘)',
        hasParity: true,
        nameFs: 11,
        metaFs: 9,
        maxNameLines: 6,
        textScaler: const TextScaler.linear(1.8),
      );
      // 断言用的行高也要按同样缩放算，才是可比的口径
      expect(p.usedHeight(11 * 1.8, 9 * 1.8), lessThanOrEqualTo(availH + 0.01));
    });
  });
}
