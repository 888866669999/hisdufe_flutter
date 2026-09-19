/// 密码 + 验证码「同框」输入组件
///
/// ===== 为什么要抽成组件 =====
/// 登录页与重新验证弹窗都要用这个布局。抽出来才能保证两处**完全一致** ——
/// 否则改了一处、另一处忘改，用户会在「首次登录」和「重登」看到不同的界面。
///
/// ===== 布局 =====
/// 一个圆角容器装两行：
///
///     ┌────────────────────────────────┐
///     │ 🔒  密码                       │
///     ├────────────────────────────────┤
///     │ ✅  验证码          [ 图片 ]    │
///     └────────────────────────────────┘
///
/// 两行共用一个背景与边框，因此视觉上是「一个登录框」而不是两个独立输入项。
/// 验证码图片可点，点击触发换图（换图后由调用方重新识别并填入）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/theme.dart';

class CredentialsBox extends StatelessWidget {
  const CredentialsBox({
    required this.password,
    required this.captcha,
    required this.captchaBytes,
    required this.onRefreshCaptcha,
    this.solving = false,
    this.onSubmit,
    this.showPassword = true,
    super.key,
  });

  final TextEditingController password;
  final TextEditingController captcha;

  /// 当前验证码图片；null 表示还没取到
  final Uint8List? captchaBytes;

  /// 点击图片时换一张
  final VoidCallback onRefreshCaptcha;

  /// 正在识别验证码（图片位置显示「识别中」）
  final bool solving;

  /// 验证码输入框回车时触发
  final VoidCallback? onSubmit;

  /// 是否显示密码行。
  /// 无凭据场景下密码需要用户输入，必须显示；
  /// 有凭据场景下密码已自动填入，同样显示（这样填错了还能改）。
  final bool showPassword;

  @override
  Widget build(BuildContext context) {
    // 药丸形（而不是圆角矩形）：与全应用其它输入框统一。
    // 密码/验证码是“两个输入框叠在一起”，外层用胶囊包住，
    // 内部两行之间的分隔线仍是直的 —— 视觉上就是「一个药丸里两行」。
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceVariant,
        borderRadius: BorderRadius.circular(Gaps.pill),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          if (showPassword) ...<Widget>[
            _row(
              context,
              icon: Icons.lock_outline,
              child: TextField(
                controller: password,
                obscureText: true,
                textInputAction: TextInputAction.next,
                decoration: _bareInput('密码'),
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: context.dividerColor),
          ],
          _row(
            context,
            icon: Icons.verified_outlined,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: captcha,
                    textInputAction: TextInputAction.done,
                    decoration: _bareInput('验证码'),
                    onSubmitted: (_) {
                      if (onSubmit != null) {
                        onSubmit!();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                _captchaImage(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 去掉 TextField 自带的边框与填充，让它「融进」外层容器
  InputDecoration _bareInput(String hint) => InputDecoration(
        hintText: hint,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
      );

  Widget _row(BuildContext context,
      {required IconData icon, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: context.textTertiary),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _captchaImage(BuildContext context) {
    return GestureDetector(
      onTap: onRefreshCaptcha,
      child: Container(
        width: 96,
        height: 38,
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: captchaBytes == null
            ? Center(
                child: Text(
                  solving ? '识别中' : '点击刷新',
                  style: TextStyle(fontSize: 10, color: context.textTertiary),
                ),
              )
            : Image.memory(captchaBytes!,
                fit: BoxFit.contain, gaplessPlayback: true),
      ),
    );
  }
}
