/// 课程卡的尺寸规划（纯逻辑 + 真实文本度量）
///
/// ===== 为什么需要这个文件 =====
/// 课表要求「整周固定一屏」，因此格子高度是**确定值**，而卡片内容
/// （课名、教室、单双周）行数不定。若直接按「估算行数」排，
/// 估算一旦偏低就会撑破格子 —— 表现为画面里的黄黑警告条
/// （`BOTTOM OVERFLOWED BY N PIXELS`），在横屏等矮屏上必然出现。
///
/// 早先就是这么坏的：估算只减去了「一个常数 14」，却漏算了
/// 卡片上下内边距、外边距、行间距与单双周那一行，于是**每次都低估**。
/// 这里改为：
///   1. 用 `TextPainter` 拿**真实**排版高度（不再是拍脑袋的系数）；
///   2. 从「信息最全」到「只留课名」逐个方案试，取第一个装得下的；
///   3. 全部装不下时只保留课名一行 —— 宁可少显示，也绝不撑破格子。
///
/// 另外 `courseCardBody` 会用 `OverflowBox` 兜底：即使系统字体被放大
/// （无障碍设置）导致度量与实际渲染有偏差，也只会被裁掉，不会溢出报错。
library;

import 'package:flutter/material.dart';

/// 卡片内容的排布方案
class CardPlan {
  const CardPlan({
    required this.nameLines,
    required this.metaLines,
    required this.showParity,
  });

  /// 课名最多显示几行（至少 1）
  final int nameLines;

  /// 教室/教师最多显示几行（0 = 不显示）
  final int metaLines;

  /// 是否显示单双周（空间不够时优先牺牲它 —— 它只是限定条件，
  /// 课名与教室才是「这门课是什么、在哪上」）
  final bool showParity;

  /// 实际占用高度（含内边距与间距），用于断言不超预算
  double usedHeight(double nameFs, double metaFs) {
    double h = _padV * 2;
    h += nameLines * _lineH(nameFs);
    if (metaLines > 0) {
      h += 1 + metaLines * _lineH(metaFs);
    }
    if (showParity) {
      h += metaFs * 1.15 + _gapBeforeParity;
    }
    return h;
  }
}

const double _padV = 4; // 卡片上下内边距
const double _gapBeforeParity = 2;

double _lineH(double fs) => fs * 1.15;

/// 用真实排版测出 [text] 在 [maxWidth] 下最多占几行，并被 [maxLines] 限制
///
/// [textScaler] 必须传入真实的文字缩放（`MediaQuery.textScalerOf`）：
/// 无障碍大字号下同一段文字会占更多行，若仍按 1.0 度量就会低估而溢出。
int measuredLines(
  String text,
  double fs,
  double maxWidth,
  int maxLines, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (text.isEmpty || maxWidth <= 0) {
    return 0;
  }
  final double scaledFs = textScaler.scale(fs);
  final TextPainter tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
          fontSize: scaledFs, height: 1.15, fontWeight: FontWeight.w700),
    ),
    maxLines: maxLines,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  final int n = tp.computeLineMetrics().length;
  tp.dispose();
  return n.clamp(0, maxLines);
}

/// 规划一张课程卡的内容。
///
/// @param availH  卡片可用高度（已扣掉外层 margin）
/// @param innerW  卡片内容可用宽度（已扣掉左右内边距）
/// @param nameText 课名；[metaText] 形如 `@7-120(章丘)`；`hasParity` 是否有单双周
CardPlan planCard({
  required double availH,
  required double innerW,
  required String nameText,
  required String metaText,
  required bool hasParity,
  required double nameFs,
  required double metaFs,
  required int maxNameLines,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  // 用**缩放后**的字号计算，保证度量与实际渲染一致
  final double nFs = textScaler.scale(nameFs);
  final double mFs = textScaler.scale(metaFs);
  // 课名实际需要几行（受 maxNameLines 与宽度限制）
  final int needName = measuredLines(
    nameText,
    nameFs,
    innerW,
    maxNameLines,
    textScaler: textScaler,
  ).clamp(1, maxNameLines);
  final bool hasMeta = metaText.isNotEmpty;

  bool fits(int n, int m, bool p) {
    double h = _padV * 2 + n * _lineH(nFs);
    if (m > 0) {
      h += 1 + m * _lineH(mFs);
    }
    if (p) {
      h += mFs * 1.15 + _gapBeforeParity;
    }
    return h <= availH;
  }

  // 从信息最全开始降级。顺序有讲究：
  //   先减教室行数 → 再砍单双周 → 最后才减课名行数。
  //   课名是识别「这是哪门课」的唯一依据，最后动。
  final List<CardPlan> candidates = <CardPlan>[
    CardPlan(nameLines: needName, metaLines: hasMeta ? 2 : 0, showParity: hasParity),
    CardPlan(nameLines: needName, metaLines: hasMeta ? 1 : 0, showParity: hasParity),
    CardPlan(nameLines: needName, metaLines: hasMeta ? 1 : 0, showParity: false),
    CardPlan(nameLines: needName, metaLines: 0, showParity: false),
    CardPlan(nameLines: 1, metaLines: 0, showParity: false),
  ];
  for (final CardPlan p in candidates) {
    if (fits(p.nameLines, p.metaLines, p.showParity)) {
      return p;
    }
  }
  return const CardPlan(nameLines: 1, metaLines: 0, showParity: false);
}