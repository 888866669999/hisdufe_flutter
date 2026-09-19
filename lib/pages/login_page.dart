/// 登录页
///
/// ===== 流程（两步）=====
///   1. 账号
///   2. **密码与验证码同框** —— 两者放在同一个输入容器里，一起提交
///
/// 早先是「账号 → 密码 → 验证码」三步。合并成两步的原因：
/// 密码和验证码都是「登录的凭据组成部分」，分两步会让用户多按一次按钮，
/// 而验证码又需要配图片，单独占一屏反而不如与密码并排紧凑。
///
/// ===== 验证码自动识别 =====
/// 首次登录同样自动识别并**填入**输入框（不只是会话失效后的重登）。
/// 为什么是「填入」而不是「直接提交」：识别率约九成，
/// 剩下的一成必须让用户能看见并改正 —— 静默提交错误验证码只会白费一次登录尝试。
///
/// 识别与图片是**同一张**：图变了、文本也必须跟着变。
/// 早先鸿蒙版出现过「填的是识别结果、显示的却是另取的一张新图」，
/// 用户直接提交必然失败，还会被误认为识别功能坏了。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../common/result.dart';
import '../data/app_state.dart';
import '../data/captcha_solver.dart';
import '../widgets/credentials_box.dart';
import '../data/credential_store.dart';
import '../data/pref_store.dart';
import '../network/qz_api.dart';
import '../theme/theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({required this.onLoggedIn, super.key});

  final VoidCallback onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _account = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _captcha = TextEditingController();

  /// 1 = 账号；2 = 密码 + 验证码
  int _step = 1;
  bool _busy = false;
  bool _remember = false;
  String _error = '';

  Uint8List? _captchaBytes;

  /// 正在识别验证码
  bool _solving = false;

  /// 是否需要用户手动修正验证码（识别失败或识别结果被服务端拒绝）
  String _captchaHint = '';

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _captcha.dispose();
    super.dispose();
  }

  Future<void> _prefill() async {
    // 账号总是回填（它不算敏感信息，且能少了每次输 12 位学号）
    final String saved = PrefStore.loadAccount();
    if (saved.isNotEmpty) {
      _account.text = saved;
    }
    _remember = PrefStore.loadRemember();

    // 密码只在**密钥库里确实有凭据**时回填。
    // 判据用「密钥库里有东西」而不是「记住开关是开的」：
    // 开关有默认值，用它判断会把从没勾选过的用户也预填上密码。
    final Credential? cred = await CredentialStore.load();
    if (cred != null && cred.password.isNotEmpty) {
      _password.text = cred.password;
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// 取一张新验证码，并自动识别填入。
  ///
  /// 这是所有「需要验证码」时刻的统一入口：
  /// 进入第二步、点图刷新、登录失败后换图，都走它。
  Future<void> _refreshCaptcha() async {
    if (_solving) {
      return;
    }
    setState(() {
      _solving = true;
      _captchaHint = '正在识别验证码…';
    });

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
        _captchaHint = '';
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
        _captchaHint = '已自动识别，如有误请直接修改';
      } else {
        // 识别失败不清空已有输入（可能用户已手输），只提示
        _captchaHint = '未能自动识别，请手动输入';
      }
    });
  }

  void _next() {
    if (_step == 1) {
      if (_account.text.trim().isEmpty) {
        setState(() => _error = '请输入账号');
        return;
      }
      setState(() {
        _error = '';
        _step = 2;
      });
      // 进入第二步才取图：验证码与会话绑定，早取会因会话轮换而失效
      _refreshCaptcha();
      return;
    }
    _submit();
  }

  Future<void> _submit() async {
    if (_busy) {
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _error = '请输入密码');
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
    try {
      final LoginResult res = await AppState.instance.api.login(
        _account.text.trim(),
        _password.text,
        _captcha.text.trim(),
      );
      if (!mounted) {
        return;
      }
      if (res.success) {
        await PrefStore.saveAccount(_account.text.trim());
        await PrefStore.saveRemember(_remember);
        if (_remember) {
          await CredentialStore.save(_account.text.trim(), _password.text);
        } else {
          await CredentialStore.clear();
        }
        await AppState.instance.onLoggedIn(_account.text.trim());
        widget.onLoggedIn();
        return;
      }
      setState(() {
        _busy = false;
        _error = res.message.isNotEmpty ? res.message : '登录失败，请重试';
      });
      // 验证码是一次性的，失败后必须换一张；新图会重新自动识别
      _captcha.text = '';
      await _refreshCaptcha();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = _describeLoginError(e);
      });
    }
  }

  String _describeLoginError(Object e) {
    if (e is AppError) {
      return e.toUserText();
    }
    return '登录失败，请重试';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 键盘弹出时压缩布局，保证按钮可见
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gaps.l),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 校徽（与启动闪屏、桌面图标同一份源图）。
                  // 早先是 `Icons.school_outlined`——Material 的通用
                  // 「学士帽小人」占位图，与本校无关。
                  Image.asset('assets/logo.png', height: 56),
                  const SizedBox(height: 12),
                  Text('hi山财',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      )),
                  const SizedBox(height: 4),
                  Text('山东财经大学 · 教务系统',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: context.textTertiary)),
                  const SizedBox(height: 28),
                  _stepDots(),
                  const SizedBox(height: 8),
                  Text(
                    _step == 1 ? '请输入账号' : '请输入密码与验证码',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: context.textSecondary),
                  ),
                  const SizedBox(height: 18),
                  if (_step == 1)
                    TextField(
                      controller: _account,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(hintText: '学号'),
                      onSubmitted: (_) => _next(),
                    ),
                  if (_step == 2) ...<Widget>[
                    // 密码与验证码同框（与重新验证弹窗共用同一组件，保证两处一致）
                    CredentialsBox(
                      password: _password,
                      captcha: _captcha,
                      captchaBytes: _captchaBytes,
                      solving: _solving,
                      onRefreshCaptcha: () {
                        _captcha.text = '';
                        _refreshCaptcha();
                      },
                      onSubmit: _submit,
                    ),
                    if (_captchaHint.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          if (_solving)
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: context.textTertiary,
                              ),
                            ),
                          if (_solving) const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _captchaHint,
                              style: TextStyle(
                                  fontSize: 11, color: context.textTertiary),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        Checkbox(
                          value: _remember,
                          onChanged: (bool? v) =>
                              setState(() => _remember = v ?? false),
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
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _busy ? null : _next,
                    child: Text(_busy
                        ? '请稍候…'
                        : (_step == 1 ? '下一步' : '登 录')),
                  ),
                  if (_step > 1) ...<Widget>[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _error = '';
                                _captchaHint = '';
                                _step = 1;
                              }),
                      child: const Text('返回上一步'),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    '仅用于本人账号的正当学习用途',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: context.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepDots() {
    // 现在是两步
    const int total = 2;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (int i = 1; i <= total; i++)
          Container(
            width: i == _step ? 22 : 8,
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: i <= _step ? context.brandColor : context.surfaceVariant,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
