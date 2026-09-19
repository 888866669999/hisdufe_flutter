/// 通用状态视图与卡片容器
library;

import 'package:flutter/material.dart';

import '../theme/glass_kit.dart';
import '../theme/theme.dart';

/// 加载中
class LoadingView extends StatelessWidget {
  const LoadingView({this.message = '正在加载…', super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: context.brandColor,
            ),
          ),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(fontSize: 13, color: context.textTertiary)),
        ],
      ),
    );
  }
}

/// 空态
class EmptyView extends StatelessWidget {
  const EmptyView({this.title = '暂无数据', this.hint = '', super.key});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('—', style: TextStyle(fontSize: 36, color: context.textTertiary)),
          const SizedBox(height: 8),
          Text(title, style: TextStyle(fontSize: 14, color: context.textSecondary)),
          if (hint.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                hint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: context.textTertiary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 错误态（可重试）
class ErrorView extends StatelessWidget {
  const ErrorView({required this.message, this.onRetry, super.key});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.error_outline, size: 36, color: context.dangerColor),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: context.textSecondary),
            ),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 14),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}

/// 自适应卡片容器：**液态玻璃**。
///
/// 这是全应用最通用的卡片容器（成绩行、课程明细、通选分组、
/// 培养方案统计条等都走它），因此把玻璃做在这里，各页自动获得统一观感，
/// 不必逐页改 —— 也就不会出现「有的页玻璃、有的页纯白」的不一致。
///
/// 质量档用 [GlassKit.listCard]（minimal）：这些卡片常常成百地出现在
/// 滚动列表里，用完整折射着色器会掉帧。
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.child,
    this.padding,
    this.quality = SectionCardQuality.list,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// 玻璃档位。列表里用 [SectionCardQuality.list]（省 GPU），
  /// 少量大面积的面板用 [SectionCardQuality.panel]（带折射，更好看）。
  final SectionCardQuality quality;

  @override
  Widget build(BuildContext context) {
    final EdgeInsetsGeometry pad = padding ?? const EdgeInsets.all(Gaps.m);
    return SizedBox(
      width: double.infinity,
      child: quality == SectionCardQuality.panel
          ? GlassKit.panel(context, padding: pad, child: child)
          : GlassKit.listCard(context, padding: pad, child: child),
    );
  }
}

/// 卡片玻璃档位
enum SectionCardQuality {
  /// 列表项（默认）：省 GPU，适合成批出现
  list,

  /// 独立面板：带折射与高光，适合少量大块元素
  panel,
}

/// 设置式行：左标题 + 右值 + 箭头
class SettingRow extends StatelessWidget {
  const SettingRow({
    required this.label,
    this.value = '',
    this.subtitle = '',
    this.onTap,
    this.danger = false,
    this.action,
    super.key,
  });

  final String label;
  final String value;
  final String subtitle;
  final VoidCallback? onTap;
  final bool danger;

  /// 右侧的**自定义控件**（如液态玻璃按钮）。
  ///
  /// 给了它就不再显示 [value] 与右箭头：那些是「这行整体可点」的表达，
  /// 而自定义控件自带交互语义，两者同时出现会让人不知道点哪个。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: 14),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      color: danger ? context.dangerColor : context.textPrimary,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 12, color: context.textTertiary),
                    ),
                  ],
                ],
              ),
            ),
            if (action != null)
              action!
            else ...<Widget>[
              if (value.isNotEmpty)
                Text(value,
                    style:
                        TextStyle(fontSize: 13, color: context.textTertiary)),
              if (onTap != null)
                Icon(Icons.chevron_right,
                    size: 18, color: context.textTertiary),
            ],
          ],
        ),
      ),
    );
  }
}

/// 分组标题
class GroupTitle extends StatelessWidget {
  const GroupTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gaps.m, Gaps.m, Gaps.m, 6),
      child: Text(text,
          style: TextStyle(fontSize: 12, color: context.textSecondary)),
    );
  }
}

/// 分组容器（圆角卡片；材质由主题决定）
///
/// 设置页的各分组用它。外观走 [GlassKit.listCard]：
/// 液态玻璃材质下是玻璃，M3 材质下是实心 `surfaceContainer`
/// （见 theme/material_style.dart 的说明）。
///
/// 内部的 [SettingRow] 刻意**不参与**材质绘制 —— 无论哪种材质，
/// 分组已经有背景，行再画一层都是多余：玻璃材质下是「玻璃套玻璃」
/// （库作者明确禁止：交互玻璃自带折射面，嵌套会双重折射、
/// 裁掉弹性动画并浪费 GPU 填充率），实心材质下则纯属浪费。
class GroupBox extends StatelessWidget {
  const GroupBox({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GlassKit.listCard(
      context,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Gaps.radius),
        child: Column(children: children),
      ),
    );
  }
}
