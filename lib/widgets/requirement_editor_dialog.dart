/// 通选课「要求学分」编辑弹窗
///
/// 从鸿蒙版 `pages/ElectivePage.ets` 的 requirementEditor 浮层移植，
/// 差异只在承载方式：Flutter 用 `Dialog` + 玻璃面板（与课程编辑弹窗同一套），
/// 鸿蒙用页面内 GlassOverlay —— 两端的观感一致，实现各按本平台的习惯。
///
/// ===== 为什么提示里要说「培养方案」=====
/// 用户第一次看到这个入口时最自然的疑问是「我该填多少」。
/// 学校那一列是空的，答案只能来自他自己专业的培养方案，
/// 因此直接在界面上点明来源，而不是留一个空输入框让人猜。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/elective_requirement_store.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';

/// 编辑结果
class RequirementEditResult {
  const RequirementEditResult(this.value);

  /// >= 0 表示设为该值；< 0 表示清除自定义要求
  final double value;

  bool get isClear => value < 0;
}

/// 打开「要求学分」编辑弹窗。
///
/// [category] 为所在大类名；[current] 是当前生效的要求（未设置传 -1），
/// [hasCustom] 表示当前值是否来自用户自录（决定是否显示「清除」）。
/// 用户取消时返回 null。
Future<RequirementEditResult?> showRequirementEditor(
  BuildContext context, {
  required String category,
  required double current,
  required bool hasCustom,
}) {
  return showDialog<RequirementEditResult>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (BuildContext ctx) => _RequirementEditorDialog(
      category: category,
      current: current,
      hasCustom: hasCustom,
    ),
  );
}

class _RequirementEditorDialog extends StatefulWidget {
  const _RequirementEditorDialog({
    required this.category,
    required this.current,
    required this.hasCustom,
  });

  final String category;
  final double current;
  final bool hasCustom;

  @override
  State<_RequirementEditorDialog> createState() =>
      _RequirementEditorDialogState();
}

class _RequirementEditorDialogState extends State<_RequirementEditorDialog> {
  late final TextEditingController _input;
  String _error = '';

  @override
  void initState() {
    super.initState();
    // 已有要求（无论来自用户还是学校）就预填，方便微调
    _input = TextEditingController(
      text: widget.current >= 0 ? _trim(widget.current) : '',
    );
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 去掉无意义的小数尾巴：12.0 显示成 12
  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  void _submit() {
    final double v = ElectiveRequirementStore.parseInput(_input.text);
    if (v < 0) {
      setState(() => _error = '请输入 0 ~ 200 之间的学分，最多一位小数');
      return;
    }
    Navigator.pop(context, RequirementEditResult(v));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: GlassKit.surface(
          context,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('要求学分',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    )),
                const SizedBox(height: 2),
                Text(widget.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: context.brandColor)),
                const SizedBox(height: 10),
                Text('填写培养方案里这一大类要求修满的总学分，填好后即可算出还差多少。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: context.textTertiary,
                    )),
                const SizedBox(height: 14),
                GlassKit.fieldBackdrop(
                  context,
                  child: TextField(
                    controller: _input,
                    autofocus: true,
                    // 数字 + 小数点键盘；仍然自己做严格校验
                    // （键盘类型只是输入便利，不是校验）
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    style: TextStyle(fontSize: 15, color: context.textPrimary),
                    cursorColor: context.brandColor,
                    decoration: InputDecoration(
                      isDense: true,
                      // 外层是药丸底衬，这里不许再画方角填充（见 course_editor）
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 13),
                      hintText: '例如 12',
                      hintStyle: TextStyle(
                        fontSize: 14,
                        color: context.textSecondary.withValues(alpha: 0.75),
                      ),
                    ),
                    onSubmitted: (_) => _submit(),
                    onChanged: (_) {
                      if (_error.isNotEmpty) {
                        setState(() => _error = '');
                      }
                    },
                  ),
                ),
                if (_error.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(_error,
                      style: TextStyle(
                          fontSize: 12, color: context.dangerColor)),
                ],
                // 已设置过才给「清除」：否则这里只是「取消」的重复
                if (widget.hasCustom) ...<Widget>[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        const RequirementEditResult(-1),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: Text('清除该要求',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.dangerColor,
                          )),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _button(
                        label: '取消',
                        onTap: () => Navigator.pop(context),
                        filled: false,
                      ),
                    ),
                    const SizedBox(width: Gaps.s),
                    Expanded(
                      child: _button(
                        label: '保存',
                        onTap: _submit,
                        filled: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _button({
    required String label,
    required VoidCallback onTap,
    required bool filled,
  }) {
    return SizedBox(
      height: 44,
      child: Material(
        color: filled ? context.brandColor : context.surfaceVariant,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: filled ? Colors.white : context.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
