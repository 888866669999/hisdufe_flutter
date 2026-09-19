/// HTTP 客户端：表单提交、二进制下载、Cookie 注入
///
/// 从鸿蒙版 `network/HttpClient.ets` 移植。
///
/// ===== 三处必须保留的行为 =====
/// 1. **带 Cookie 头**：会话是 HttpOnly 的 JSESSIONID，必须手工回带。
/// 2. **禁用缓存**：鸿蒙版曾因底层缓存拿到旧主页，把「已失效的会话」
///    误判为有效。Dart 的 http 包默认不做磁盘缓存，但服务端可能返回
///    可缓存响应，因此统一加 `Cache-Control: no-cache`。
/// 3. **保留原始响应头**：登录判定依赖 `Location`（成功时是 302 +
///    ticket 重定向），不能只看状态码。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../common/constants.dart';
import '../common/result.dart';
import '../common/url_guard.dart';
import 'cookie_jar.dart';

/// 与鸿蒙版一致的 UA。教务系统对陌生 UA 没有明显拦截，
/// 但保持与浏览器同类可减少被 WAF 拦的风险。
const String _userAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/120.0.0.0 Mobile Safari/537.36';

const String _acceptHtml =
    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
const String _acceptLang = 'zh-CN,zh;q=0.9';

/// 表单字段
class FormField {
  const FormField(this.name, this.value);

  final String name;
  final String value;
}

/// 响应包装：body 必然是已解码的字符串
class HttpResponse {
  HttpResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
    required this.cookies,
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
  final List<String> cookies;

  /// 取响应头（大小写不敏感）
  String header(String name) {
    final String lower = name.toLowerCase();
    for (final MapEntry<String, String> e in headers.entries) {
      if (e.key.toLowerCase() == lower) {
        return e.value;
      }
    }
    return '';
  }

  bool get isRedirect => statusCode >= 300 && statusCode < 400;
}

class HttpClient {
  HttpClient(this.jar);

  final CookieJar jar;

  /// 建立带公共头的请求
  Map<String, String> _headers({
    required String accept,
    bool form = false,
  }) {
    final Map<String, String> h = <String, String>{
      'User-Agent': _userAgent,
      'Accept': accept,
      'Accept-Language': _acceptLang,
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
      'Origin': kBaseOrigin,
      'Referer': '$kBaseOrigin/',
    };
    if (form) {
      h['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    final String cookie = jar.toHeader();
    if (cookie.isNotEmpty) {
      h['Cookie'] = cookie;
    }
    return h;
  }

  /// 表单编码（与浏览器一致：对每个名值分别 URL 编码）
  String _encodeForm(List<FormField> fields) {
    return fields
        .map((FormField f) =>
            '${Uri.encodeQueryComponent(f.name)}=${Uri.encodeQueryComponent(f.value)}')
        .join('&');
  }

  /// 收下响应里的 Set-Cookie
  void _absorb(List<String> setCookies) {
    jar.absorbAll(setCookies);
  }

  Uri _uri(String url) => Uri.parse(url);

  /// GET，返回文本
  Future<HttpResponse> get(String url) async {
    try {
      final http.Response res = await http
          .get(_uri(url), headers: _headers(accept: _acceptHtml))
          .timeout(kReadTimeout);
      return _wrap(res);
    } on TimeoutException {
      throw AppError(ErrKind.network, '请求超时，请检查网络后重试');
    } catch (e) {
      throw _netError(e);
    }
  }

  /// POST 表单，返回文本
  Future<HttpResponse> postForm(String url, List<FormField> fields) async {
    try {
      final http.Response res = await http
          .post(
            _uri(url),
            headers: _headers(accept: _acceptHtml, form: true),
            body: _encodeForm(fields),
          )
          .timeout(kReadTimeout);
      return _wrap(res);
    } on TimeoutException {
      throw AppError(ErrKind.network, '请求超时，请检查网络后重试');
    } catch (e) {
      throw _netError(e);
    }
  }

  /// 不带重定向跟随的请求。
  ///
  /// 登录成功时服务器返回 302 + `Location`，**必须自己决定要不要跟随**
  /// （要先读 Location 里的 ticket 再请求一次），因此这里关掉自动跟随。
  Future<HttpResponse> postFormNoRedirect(
    String url,
    List<FormField> fields,
  ) async {
    final http.Request req = http.Request('POST', _uri(url));
    req.headers.addAll(_headers(accept: _acceptHtml, form: true));
    req.body = _encodeForm(fields);
    req.followRedirects = false;
    try {
      final http.StreamedResponse streamed =
          await req.send().timeout(kReadTimeout);
      final http.Response res = await http.Response.fromStream(streamed);
      return _wrap(res);
    } on TimeoutException {
      throw AppError(ErrKind.network, '请求超时，请检查网络后重试');
    } catch (e) {
      throw _netError(e);
    }
  }

  /// 取二进制（验证码图片、PDF）。
  ///
  /// `accept` 由调用方指定：验证码用 `image/*`，PDF 用 `application/pdf`。
  Future<Uint8List> getBinary(String url, String accept) async {
    try {
      final http.Response res = await http
          .get(_uri(url), headers: _headers(accept: accept))
          .timeout(kReadTimeout);
      _absorb(res.headers['set-cookie'] != null
          ? <String>[res.headers['set-cookie']!]
          : <String>[]);
      if (res.statusCode >= 400) {
        throw AppError(
          ErrKind.server,
          '教务系统响应异常，请稍后重试',
          'http=${res.statusCode}',
        );
      }
      return res.bodyBytes;
    } on TimeoutException {
      throw AppError(ErrKind.network, '请求超时，请检查网络后重试');
    } on AppError {
      rethrow;
    } catch (e) {
      throw _netError(e);
    }
  }

  /// 取二进制，并**逐跳校验 URL**（SSRF 防护）。
  ///
  /// 与 [getBinary] 的区别：不自动跟随重定向，而是手动跟，且**每一跳都过
  /// [UrlGuard]**。只校验首个 URL 是不够的 —— 一个合法公网主机可以 302 到
  /// `http://127.0.0.1:8080/`，那样防护就被绕过了。
  ///
  /// 用途：地址来自**远端页面解析结果**的两条链路（校历图、培养方案 PDF）。
  /// 这类地址完全由服务端内容决定，必须当作不可信输入。
  ///
  /// @param allowedHosts 若非空，则主机必须在此白名单内（更严格）
  Future<Uint8List> getBinaryValidated(
    String url,
    String accept, {
    Set<String>? allowedHosts,
  }) async {
    final Set<String> allow = _withOriginHost(allowedHosts);
    String current = url;
    try {
      for (int hop = 0; hop <= _maxRedirects; hop++) {
        // 每一跳都校验：协议、主机白名单、环回/私有/保留地址
        UrlGuard.check(current, allowedHosts: allow);

        final http.Request req = http.Request('GET', _uri(current));
        req.headers.addAll(_headers(accept: accept));
        req.followRedirects = false;
        final http.StreamedResponse streamed =
            await req.send().timeout(kReadTimeout);
        final http.Response res = await http.Response.fromStream(streamed);
        _absorb(_setCookiesOf(res.headers));

        if (res.statusCode >= 300 && res.statusCode < 400) {
          final String loc = res.headers['location'] ?? '';
          if (loc.isEmpty) {
            throw AppError(ErrKind.server, '下载失败：服务端返回了无目标的重定向');
          }
          // 相对 Location 需要按当前地址解析成绝对地址
          current = _uri(current).resolve(loc).toString();
          continue;
        }
        if (res.statusCode >= 400) {
          throw AppError(ErrKind.server, '下载失败，请稍后重试',
              'http=${res.statusCode}');
        }
        return res.bodyBytes;
      }
      throw AppError(ErrKind.server, '下载失败：重定向次数过多');
    } on TimeoutException {
      throw AppError(ErrKind.network, '请求超时，请检查网络后重试');
    } on AppError {
      rethrow;
    } catch (e) {
      throw _netError(e);
    }
  }

  /// 重定向上限。与浏览器常见默认值一致，足够正常跳转，
  /// 又能防止「A→B→A」这类循环把请求打成死循环。
  static const int _maxRedirects = 5;

  /// 始终把「本应用已知的教务系统域名」并入白名单：
  /// PDF/校历地址都从该域名的页面里解析出来，没有理由去别的域取。
  Set<String> _withOriginHost(Set<String>? allowedHosts) {
    final Set<String> out = <String>{...?allowedHosts};
    final String host = Uri.tryParse(kBaseOrigin)?.host.toLowerCase() ?? '';
    if (host.isNotEmpty) {
      out.add(host);
    }
    return out;
  }

  List<String> _setCookiesOf(Map<String, String> headers) {
    final List<String> out = <String>[];
    headers.forEach((String k, String v) {
      if (k.toLowerCase() == 'set-cookie') {
        out.add(v);
      }
    });
    return out;
  }

  HttpResponse _wrap(http.Response res) {
    // http 包把多个 Set-Cookie 合并成逗号分隔的单值，这里拆开发给 CookieJar；
    // CookieJar 自己会按 `;` 逐段处理，因此合并串同样能正确解析。
    final List<String> cookies = <String>[];
    res.headers.forEach((String k, String v) {
      if (k.toLowerCase() == 'set-cookie') {
        cookies.add(v);
      }
    });
    _absorb(cookies);

    // 中文页面多为 GBK/UTF-8 混用；该校页面实测是 UTF-8。
    // 若出现乱码，改用 gbk 解码（见 README 的已知问题）。
    final String body = _decode(res);
    return HttpResponse(
      statusCode: res.statusCode,
      body: body,
      headers: res.headers,
      cookies: cookies,
    );
  }

  String _decode(http.Response res) {
    try {
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (_) {
      return latin1.decode(res.bodyBytes, allowInvalid: true);
    }
  }

  AppError _netError(Object e) {
    // SocketException / ClientException / HandshakeException 等都归为网络问题。
    // 不细分的原因：对用户而言「网络不通」是同一件事，细分只会让文案更杂。
    return AppError(ErrKind.network, '无法连接教务系统，请检查网络', e.toString());
  }
}
