/// 重新登录弹窗（居中、只挡必要区域）
///
/// 从鸿蒙版 `components/ReAuthDialog.ets` 移植。
///
/// 两种形态：
///   - 密钥库里**有**账号密码 → 只让用户补验证码（先自动识别一次）
///   - 密钥库里**没有** → 完整「账号 → 密码 → 验证码」三步表单
///
/// 关键行为：自动识别失败时，显示的是**识别用的那张图**并预填识别结果，
/// 用户只需改错的那一位。早先版本预填文本却另取一张新图，
/// 直接提交必然失败，还会被理解成「识别功能坏了」。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/captcha_solver.dart';
import '../data/credential_store.dart';
import '../data/re_auth_service.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import 'credentials_box.dart';

class ReAuthDialog extends StatefulWidget {
  const ReAuthDialog({required this.onDone, required this.onGiveUp, super.key});

  final VoidCallback onDone;
  final VoidCallback onGiveUp;

  @override
  State<ReAuthDialog> createState() => _ReAuthDialogState();
}

class _ReAuthDialogState extends State<ReAuthDialog> {
  final TextEditingController _account = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _captcha = TextEditingController();

  bool _busy = true;
  bool _hasCred = false;
  bool _remember = true;
  String _hint = '正在自动识别验证码…';
  String _error = '';

  Uint8List? _captchaBytes;

  /// 正在识别验证码
  bool _solving = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _captcha.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final Credential? cred = await CredentialStore.load();
    if (cred != null) {
      _account.text = cred.account;
      // 关键：密码也要恢复。鸿蒙版曾漏了这一行，导致提交时密码为空，
      // 服务端直接回「用户名或密码为空!」，表现为「验证码怎么输都登不上」。
      _password.text = cred.password;
      _hasCred = cred.password.isNotEmpty;
    }
    await ReAuthService.refreshCredentialFlag();

    if (!_hasCred) {
      setState(() {
        _busy = false;
        _hint = '登录状态已过期，请重新登录';
      });
      await _loadCaptcha();
      return;
    }

    // 有凭据：先自动识别一次（交互路径允许换图重试）
    setState(() {
      _busy = true;
      _hint = '正在自动识别验证码…';
    });
    final AutoLoginOutcome out =
        await ReAuthService.autoLoginWithRetry(kMaxLoginAttempts);
    if (out.ok) {
      widget.onDone();
      return;
    }
    // 显示识别用的同一张图，并预填识别结果
    setState(() {
      _busy = false;
      _hint = out.reason;
      if (out.captchaImage != null) {
        _captchaBytes = out.captchaImage!.bytes;
      }
      if (out.triedCaptcha.isNotEmpty) {
        _captcha.text = out.triedCaptcha;
      }
    });
    if (out.captchaImage == null) {
      await _loadCaptcha();
    }
  }

  /// 取一张新验证码并自动识别填入。
  ///
  /// 与登录页走同一个 [CaptchaSolver]，因此两处的识别与填充行为一致。
  /// 识别失败只提示、清空不放：用户可能已经手输了一部分，不该被抹掉。
  Future<void> _loadCaptcha() async {
    if (_solving) {
      return;
    }
    setState(() => _solving = true);

    final CaptchaSolve? r = await CaptchaSolver.solve(
      () => AppState.instance.api.fetchCaptcha(),
    );
    if (!mounted) {
      return;
    }
    if (r == null) {
      setState(() {
        _solving = false;
        _captchaBytes = null;
        _error = '验证码获取失败，请点击图片重试';
      });
      return;
    }
    setState(() {
      _solving = false;
      _captchaBytes = r.bytes;
      _error = '';
      if (r.ocrOk) {
        _captcha.text = r.text;
        _hint = '验证码已自动识别，如有误请直接修改';
      } else {
        _hint = '未能自动识别，请手动输入验证码';
      }
    });
  }

  Future<void> _submit() async {
    if (_busy) {
      return;
    }
    if (_account.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = '账号或密码缺失，请重新登录');
      return;
    }
    if (_captcha.text.trim().isEmpty) {
      setState(() => _error = '请输入验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final AutoLoginOutcome out = await ReAuthService.loginWith(
      _account.text.trim(),
      _password.text,
      _captcha.text.trim(),
    );
    if (!mounted) {
      return;
    }
    if (out.ok) {
      if (!_hasCred && _remember) {
        await CredentialStore.save(_account.text.trim(), _password.text);
      }
      widget.onDone();
      return;
    }
    setState(() {
      _busy = false;
      _error = out.reason;
      _captcha.text = '';
    });
    // 验证码已被消费，换一张
    await _loadCaptcha();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        // 近透明遮罩：弹窗只是「拦住必须联网的操作」，不该把整个界面压暗
        color: const Color(0x1A000000),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(Gaps.l),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('需要重新登录',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        )),
                    const SizedBox(height: 4),
                    Text(_hint,
                        style: TextStyle(
                            fontSize: 12, color: context.textTertiary)),
                    const SizedBox(height: 14),
                    if (!_hasCred) ...<Widget>[
                      // 药丸底衬：与下面的 CredentialsBox 同一形状，
                      // 也与全应用其它输入框一致（主题已给药丸描边，
                      // 这里补的是「两层输入并排时」所需的同款底）。
                      GlassKit.fieldBackdrop(
                        context,
                        child: TextField(
                          controller: _account,
                          decoration: const InputDecoration(hintText: '学号'),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    // 密码与验证码同框（与登录页共用同一组件）
                    CredentialsBox(
                      password: _password,
                      captcha: _captcha,
                      captchaBytes: _captchaBytes,
                      solving: _solving,
                      onRefreshCaptcha: () {
                        _captcha.text = '';
                        _loadCaptcha();
                      },
                      onSubmit: _submit,
                    ),
                    if (!_hasCred) ...<Widget>[
                      const SizedBox(height: 6),
                      Row(
                        children: <Widget>[
                          Checkbox(
                            value: _remember,
                            onChanged: (bool? v) =>
                                setState(() => _remember = v ?? true),
                          ),
                          const Text('记住账号密码',
                              style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ],
                    if (_error.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(_error,
                          style: TextStyle(
                              fontSize: 12, color: context.dangerColor)),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _busy ? null : widget.onGiveUp,
                            child: Text(_hasCred ? '退出登录' : '取消'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: _busy ? null : _submit,
                            child: Text(_busy ? '登录中…' : '继续'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

}
