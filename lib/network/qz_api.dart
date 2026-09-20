/// 强智教务系统接口封装
///
/// 从鸿蒙版 `network/QzApi.ets` 移植。
///
/// ===== 登录链路（三段式，缺一不可）=====
///   1. POST `/Logon.do?method=logon&flag=sess`  → 拿 `scode#sxh`
///   2. 用 [QzEncoder] 生成 `encoded`
///   3. POST `/Logon.do?method=logon` 提交
///      `userAccount / userPassword / RANDOMCODE / encoded`
/// 成功后服务器**不直接返回页面**，而是 302 + `Location` 里的 `ticket`；
/// 必须再 GET 一次该地址，才会换成 `/jsxsd/` 下的学生端会话。
///
/// ===== 判定结果不能只看状态码 =====
/// 登录成功恰恰是 404/302（带 Location）这种「非 200」响应，
/// 因此 [checkResponse] 只在「状态码 >= 400 **且没有 Location**」时才报错。
/// 早期实现见到非 200 就判会话失效，导致登录永远失败。
library;

import 'dart:typed_data';

import '../common/constants.dart';
import '../common/result.dart';
import '../crypto/qz_encoder.dart';
import '../model/classroom_models.dart';
import '../model/models.dart';
import '../parser/classroom_parser.dart';
import '../parser/elective_parser.dart';
import '../parser/html_lite.dart';
import '../parser/plan_parser.dart';
import '../parser/profile_parser.dart';
import '../parser/score_parser.dart';
import '../parser/timetable_parser.dart';
import '../parser/week_calendar_parser.dart';
import 'cookie_jar.dart';
import 'http_client.dart';

/// 登录失败类别（供重试决策使用）。
///
/// **必须机器可读**：自动登录重试只能发生在「验证码错」这类可恢复失败上。
/// 若靠比对界面文案判断，服务端措辞一变就会把「密码错误」误判为可重试，
/// 那就变成拿错误凭据反复提交，有把账号打到临时锁定的实际风险。
enum LoginFailKind {
  none,

  /// 验证码不对（可换图重试）
  captcha,

  /// 账号或密码不对（绝不重试）
  credential,

  /// 会话/握手异常
  session,

  /// 服务端拒绝本次登录（限流/维护等）
  rejected,

  unknown,
}

class LoginResult {
  LoginResult(this.success, this.message, [this.kind = LoginFailKind.none]);

  final bool success;
  final String message;
  final LoginFailKind kind;

  factory LoginResult.fail(String message, LoginFailKind kind) =>
      LoginResult(false, message, kind);
}

/// 教室查询页的可选项
class ClassroomOptions {
  ClassroomOptions(this.campuses, this.semesters);

  /// 元素形如 `3|章丘校区`（value|label）
  final List<String> campuses;
  final List<String> semesters;
}

class QzApi {
  QzApi(this.jar) : _client = HttpClient(jar);

  final CookieJar jar;
  final HttpClient _client;

  /// 并发探测去重。
  ///
  /// 启动时「恢复会话」与「静默续期」会各自探测一次会话。两条请求带着
  /// **同一个 JSESSIONID** 并发打到服务器，服务端一旦轮换会话，
  /// 后到的那条就被判未登录 —— 于是出现「假失效」，触发一次完全不必要的
  /// 重新登录，而这次登录又会再轮换会话、干扰在途请求。
  /// 鸿蒙版实测有此现象，这里从一开始就去重。
  Future<bool>? _probeInFlight;

  String get cookieHeader => jar.toHeader();

  // ==================== 登录 ====================

  /// 取验证码原图（JPEG 字节）。
  ///
  /// 必须与后续登录请求共用同一会话，验证码才有效。
  Future<Uint8List> fetchCaptcha() async {
    final String before = jar.toHeader();
    final Uint8List buf =
        await _client.getBinary('$kBaseOrigin$kPathCaptcha', 'image/*,*/*;q=0.8');
    final String after = jar.toHeader();
    if (before != after) {
      // 会话被轮换：这是正常的，但验证码与登录必须用新会话，
      // 因此这里不做重试，只是让调用方知道“cookie 已更新”。
      // ignore: avoid_print
      print('[api] captcha refresh rotated session');
    }
    return buf;
  }

  /// 登录
  Future<LoginResult> login(String account, String password, String captcha) async {
    // 1) 会话握手
    final HttpResponse sessRes = await _client.postForm(
      '$kBaseOrigin$kPathLogonSess',
      const <FormField>[],
    );
    final String sessText = sessRes.body.trim();

    if (QzEncoder.isRejected(sessText)) {
      return LoginResult.fail('教务系统暂不允许登录，请稍后再试', LoginFailKind.rejected);
    }
    final String encoded = QzEncoder.buildEncoded(sessText, account, password);
    if (encoded.isEmpty) {
      return LoginResult.fail('登录握手失败，请重试', LoginFailKind.session);
    }

    // 2) 提交登录（不自动跟随重定向，要自己读 Location）
    final HttpResponse res = await _client.postFormNoRedirect(
      '$kBaseOrigin$kPathLogon',
      <FormField>[
        FormField('userAccount', account),
        FormField('userPassword', password),
        FormField('RANDOMCODE', captcha),
        FormField('encoded', encoded),
      ],
    );

    // 3) 判定
    final String location = res.header('location');
    if (location.isNotEmpty) {
      final String target = _absolute(location);
      final HttpResponse uni = await _client.get(target);
      if (HtmlLite.isLoginPage(uni.body)) {
        return LoginResult.fail('登录未能建立会话，请重试', LoginFailKind.session);
      }
      return LoginResult(true, '登录成功');
    }
    if (HtmlLite.isLoginPage(res.body)) {
      final String hint = _extractError(res.body);
      return LoginResult.fail(
        hint.isNotEmpty ? hint : '账号或密码或验证码有误',
        _classifyFail(hint),
      );
    }
    if (res.body.contains('xsMain') ||
        res.body.contains('教学一体化服务平台') ||
        res.body.contains('framework')) {
      return LoginResult(true, '登录成功');
    }
    return LoginResult.fail('登录失败，请检查账号密码与验证码', LoginFailKind.unknown);
  }

  /// 会话是否仍然有效。
  ///
  /// - true：服务器返回正常页面（顺带刷新 cookie）
  /// - false：明确要求登录
  /// - 抛出：网络失败，调用方应保持原状态而不是登出
  Future<bool> isSessionAlive() async {
    if (_probeInFlight != null) {
      return _probeInFlight!;
    }
    _probeInFlight = _probeSession();
    try {
      return await _probeInFlight!;
    } finally {
      _probeInFlight = null;
    }
  }

  Future<bool> _probeSession() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathMain');
    final String loc = res.header('location');
    if (loc.isNotEmpty &&
        (loc.contains('Logon') || loc.contains('logon'))) {
      return false;
    }
    if (HtmlLite.isLoginPage(res.body)) {
      return false;
    }
    return true;
  }

  // ==================== 业务接口 ====================

  Future<TimetableParseResult> getTimetable(String semester, String week) async {
    final List<FormField> fields = <FormField>[];
    if (semester.isNotEmpty) {
      fields.add(FormField('xnxq01id', semester));
    }
    if (week.isNotEmpty) {
      fields.add(FormField('zc', week));
    }
    final HttpResponse res = fields.isEmpty
        ? await _client.get('$kBaseOrigin$kPathTimetable')
        : await _client.postForm('$kBaseOrigin$kPathTimetable', fields);
    _checkResponse(res);
    return TimetableParser.parse(res.body, semester, week);
  }

  // ==================== 「取原文」与「解析」分开 ====================
  //
  // 下面每个接口都成对出现：
  //   `getXxxHtml()` —— 发请求、检查响应、返回**未解析的页面原文**
  //   `getXxx()`     —— 把 `getXxxHtml()` 的结果解析成模型
  //
  // 拆开的原因是页面缓存（见 data/page_cache.dart）：缓存要存的是原文，
  // 而不是解析后的模型 —— 这样缓存层只依赖「请求」这一件事，
  // 解析器的任何修改都会自动作用于缓存的旧数据。
  // 只做解析的那一层保持原样，调用方（不含缓存的场景）不受影响。

  /// 成绩列表页原文
  Future<String> getScoresHtml(String semester) async {
    final String url = semester.isEmpty
        ? '$kBaseOrigin$kPathScoreList'
        : '$kBaseOrigin$kPathScoreList?kksj=${Uri.encodeQueryComponent(semester)}';
    final HttpResponse res = await _client.get(url);
    _checkResponse(res);
    return res.body;
  }

  Future<List<ScoreRecord>> getScores(String semester) async =>
      ScoreParser.parse(await getScoresHtml(semester));

  /// 成绩查询页原文（学期下拉的来源）
  Future<String> getScoreSemestersHtml() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathScoreQuery');
    _checkResponse(res);
    return res.body;
  }

  Future<List<ChoiceItem>> getScoreSemesters() async =>
      ScoreParser.readSemesters(await getScoreSemestersHtml());

  /// 学籍卡片原文
  Future<String> getProfileHtml() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathProfile');
    _checkResponse(res);
    return res.body;
  }

  Future<StudentProfile> getProfile() async =>
      ProfileParser.parse(await getProfileHtml());

  /// 教学周历页原文。传 [semester] 则取指定学年的那学期。
  ///
  /// 这个页面是**唯一权威且能随年份自动更新**的校历数据源：
  /// 它给出「第 N 周 ←→ 周一日期」的完整对照，学校每学期排课时录入，
  /// 换学年后取到的自然是新数据。学校官网那张校历图只是它的图片版，
  /// 图里能算的（周次、起止、寒暑假边界）这里都有结构化字段。
  ///
  /// 服务端的表单是 `post xnxq01id=<学期>`（onchange 自动提交），
  /// 不传则返回当前学期。
  Future<String> getWeekCalendarHtml([String semester = '']) async {
    final HttpResponse res = semester.isEmpty
        ? await _client.get('$kBaseOrigin$kPathWeekCalendar')
        : await _client.postForm('$kBaseOrigin$kPathWeekCalendar', <FormField>[
            FormField('xnxq01id', semester),
          ]);
    _checkResponse(res);
    return res.body;
  }

  Future<List<WeekDate>> getWeekCalendar([String semester = '']) async =>
      WeekCalendarParser.parseWeekDates(await getWeekCalendarHtml(semester));

  /// 周历页上「可选学期」列表（形如 2026-2027-1）。
  ///
  /// 以服务端返回的为准，而不是自己按当前年份推算：只有真正排过课的学期
  /// 才会出现在这里，这样界面上就不会出现一个点进去空空如也的学期。
  Future<List<ChoiceItem>> getWeekCalendarSemesters() async =>
      WeekCalendarParser.parseSemesterOptions(await getWeekCalendarHtml());

  /// 培养方案明细页原文
  Future<String> getPlanHtml() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathPlanDetail');
    _checkResponse(res);
    return res.body;
  }

  Future<PlanDetail> getPlanDetail() async => PlanParser.parse(await getPlanHtml());

  /// 通选课修读情况原文
  Future<String> getElectiveHtml() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathElective');
    _checkResponse(res);
    return res.body;
  }

  Future<ElectiveReport> getElectiveReport() async =>
      ElectiveParser.parse(await getElectiveHtml());

  /// 教室查询页原文（校区/学期下拉的来源）
  Future<String> getClassroomOptionsHtml() async {
    final HttpResponse res = await _client.get('$kBaseOrigin$kPathClassroom');
    _checkResponse(res);
    return res.body;
  }

  Future<ClassroomOptions> getClassroomOptions() async =>
      parseClassroomOptions(await getClassroomOptionsHtml());

  /// 原文 → 选项。单独暴露是为了让缓存层用同一条解析路径
  /// （缓存里存的是原文，需要解析时用这个，而不是再走一遍网络方法）。
  static ClassroomOptions parseClassroomOptions(String body) => ClassroomOptions(
        ClassroomParser.parseCampuses(body),
        ClassroomParser.parseSemesters(body),
      );

  /// 教学楼列表原文（服务端 Content-Type 是 text/html，内容却是 JSON）
  Future<String> getBuildingsHtml(String campusId) async {
    final HttpResponse res = await _client.postForm(
      '$kBaseOrigin$kPathBuildings',
      <FormField>[FormField('xqid', campusId)],
    );
    _checkResponse(res);
    return res.body;
  }

  Future<List<ChoiceItem>> getBuildings(String campusId) async =>
      parseBuildings(await getBuildingsHtml(campusId));

  /// 原文 → 教学楼选项。同样单独暴露给缓存层复用。
  static List<ChoiceItem> parseBuildings(String body) {
    final List<ChoiceItem> out = <ChoiceItem>[ChoiceItem('全部教学楼', '')];
    final RegExp re = RegExp(r'"dm"\s*:\s*"([^"]*)"\s*,\s*"dmmc"\s*:\s*"([^"]*)"');
    for (final RegExpMatch m in re.allMatches(body)) {
      out.add(ChoiceItem(m.group(2) ?? '', m.group(1) ?? ''));
    }
    return out;
  }

  /// 查询某教学楼某节次的占用情况。
  ///
  /// **故意不传 zc1/zc2**：服务端的周次筛选不可靠 ——
  /// 「被借用」类记录不受周次影响，且筛选后会丢掉该周无占用记录的教室
  /// （而真正全周空闲的教室恰好都在被丢掉的那批里）。
  /// 拿到全学期占用文本后由客户端按周判断，见 classroom_models.dart 顶部说明。
  ///
  /// 返回**原文**：解析要带上 sectionRow（节次决定要读哪两列），
  /// 所以缓存层存的是原文，解析在取出时按当前的 sectionRow 做。
  Future<String> getClassroomUsageHtml(
    String semester,
    String campusId,
    String buildingId,
    int sectionRow,
  ) async {
    final List<String> codes = ClassroomFinder.sectionCodes(sectionRow);
    final HttpResponse res = await _client.postForm(
      '$kBaseOrigin$kPathClassroomIfr',
      <FormField>[
        FormField('xnxqh', semester),
        FormField('xqid', campusId),
        FormField('jzwid', buildingId),
        FormField('zc1', ''),
        FormField('zc2', ''),
        FormField('jc1', codes[0]),
        FormField('jc2', codes[1]),
      ],
    );
    _checkResponse(res);
    return res.body;
  }

  Future<ClassroomResult> getClassroomUsage(
    String semester,
    String campusId,
    String buildingId,
    int sectionRow,
  ) async =>
      ClassroomParser.parseResult(
          await getClassroomUsageHtml(semester, campusId, buildingId, sectionRow),
          sectionRow);

  // ==================== 内部 ====================

  /// 业务响应统一校验
  void _checkResponse(HttpResponse res) {
    if (res.statusCode >= 400 && res.header('location').isEmpty) {
      throw AppError(
        ErrKind.server,
        '教务系统响应异常，请稍后重试',
        'http=${res.statusCode}',
      );
    }
    _ensureAuthed(res.body);
  }

  /// 业务请求返回登录页 = 会话确实失效。
  ///
  /// 这里只抛「需要重新验证」，**不退出登录**；由界面在需要时弹重新验证弹窗。
  /// 这样「只看课表」永远安静 —— 课表来自本地缓存，不需要联网。
  void _ensureAuthed(String body) {
    if (!HtmlLite.isLoginPage(body)) {
      return;
    }
    throw AppError(ErrKind.authExpired, '登录状态已失效，需要重新验证');
  }

  /// 按服务端错误原文判定失败类别（保守归类）
  static LoginFailKind _classifyFail(String hint) {
    if (hint.isEmpty) {
      return LoginFailKind.unknown;
    }
    if (hint.contains('验证码')) {
      return LoginFailKind.captcha;
    }
    if (hint.contains('密码') || hint.contains('账号') || hint.contains('用户名')) {
      return LoginFailKind.credential;
    }
    if (hint.contains('会话') || hint.contains('超时')) {
      return LoginFailKind.session;
    }
    return LoginFailKind.unknown;
  }

  static String _extractError(String body) {
    final RegExpMatch? m =
        RegExp(r'id="showMsg"[^>]*>([^<]*)<', caseSensitive: false)
            .firstMatch(body);
    if (m != null) {
      final String t = HtmlLite.decode(m.group(1) ?? '').trim();
      if (t.isNotEmpty) {
        return t;
      }
    }
    if (body.contains('验证码')) {
      return '验证码错误，请重新输入';
    }
    return '';
  }

  static String _absolute(String loc) {
    if (loc.startsWith('http://') || loc.startsWith('https://')) {
      return loc;
    }
    if (loc.startsWith('/')) {
      return '$kBaseOrigin$loc';
    }
    return '$kBaseOrigin/$loc';
  }
}
