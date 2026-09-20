/// 从学校官网获取校历与作息表
///
/// 数据来源：山东财经大学「校园服务 → 最新校历」
///   https://www.sdufe.edu.cn/xyfw/zxxl.htm
///
/// 这个页面**是可以直接抓的**（实测无 UA / Referer / Cookie 要求），
/// 正文里就有一张 HTML 表格「日常教学时刻表」，两张校历图片挂在
/// `/virtual_attach_file.vsb?...e=.jpg` 这类地址上。因此这里的策略是：
///   **联网抓最新 → 落盘缓存 → 离线用缓存 → 首次无网用内置兜底**。
///
/// 为什么要缓存而不每次都联网：
///   1. 作息时刻决定「上课提醒」的触发时间，网络抖动不该让提醒算错；
///   2. 校历图是两张 1.4MB 的大图，每次打开都下载既慢又费流量；
///   3. 学校一学期才更新一次，没必要每次刷新。
///
/// 安全：**刻意不复用教务系统的 HttpClient**。那个客户端的 CookieJar
/// 是按「整串 Cookie 头」存的、不带域名作用域，请求头里还硬编码了教务系统的
/// Origin/Referer。用它访问公网校网，等于把教务系统的会话 JSESSIONID
/// 发给第三方站点。这里用独立的裸 http 客户端，不带任何 Cookie。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../common/url_guard.dart';
import 'academic_calendar.dart';
import 'pref_store.dart';
import 'section_time_store.dart';
import '../common/constants.dart';

/// 官网校历页地址（与内置常量同源，此处独立一份便于单测替换）
const String kCalendarPageUrl = 'https://www.sdufe.edu.cn/xyfw/zxxl.htm';

/// 校历抓取允许访问的主机（含子域）。
///
/// 校历页上的图片地址**由页面内容决定**，属不可信输入；
/// 限定域名可以把「页面被篡改后指向任意站点」这条路径直接掐断。
const Set<String> kCalendarAllowedHosts = <String>{'sdufe.edu.cn'};

/// 重定向上限：防止「A→B→A」循环把请求打成死循环
const int _maxRedirects = 5;

/// 与教务系统无关的抓取所用的 UA（不带 Cookie、不带教务 Origin）
const String _userAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 抓取结果：一张在线得到的作息表 + 若干张校历图片本地路径
class CampusCalendar {
  CampusCalendar({
    required this.sections,
    required this.images,
    required this.updated,
    required this.live,
  });

  /// 作息行（形如 `第一、二节  08:30 - 10:00` / `课间休息  10:00 - 10:20`）
  final List<String> sections;

  /// 校历图片的**本地文件路径**（下载成功后的缓存；失败时为空）
  final List<String> images;

  /// 官网标注的更新时间，如 `2026年7月`
  final String updated;

  /// true = 本次成功联网抓到的；false = 缓存的（或内置兜底）
  final bool live;

  /// 能否显示校历图
  bool get hasImages => images.isNotEmpty;
}

class CampusCalendarService {
  static const Duration _timeout = Duration(seconds: 25);

  /// 缓存目录名（在应用私有目录下，不需要任何存储权限）
  static const String _dirName = 'campus';

  static CampusCalendar? _mem;

  /// 最近一次已知数据（内存 → 偏好 → 内置）
  static CampusCalendar? get current => _mem;

  /// 上次刷新的错误信息（供设置页展示，空表示没问题）
  static String lastError = '';

  static Future<Directory> _dir() async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory d = Directory('${base.path}${Platform.pathSeparator}$_dirName');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  /// 从内置 / 缓存构造数据（不联网）
  static Future<CampusCalendar> _offline() async {
    final List<String> lines = _cachedSections() ?? AcademicCalendar.sectionLines();
    final List<String> imgs = await _cachedImages();
    return CampusCalendar(
      sections: lines,
      images: imgs,
      updated: _cachedUpdated(),
      live: false,
    );
  }

  /// 读取当前可用的校历（优先内存，其次缓存 + 内置兜底）
  static Future<CampusCalendar> load() async {
    if (_mem != null) {
      return _mem!;
    }
    _mem = await _offline();
    return _mem!;
  }

  /// 联网抓最新校历与作息；成功则落盘并返回，失败返回 null（保留原缓存）
  ///
  /// 从不抛异常：校历抓不到不该影响任何主流程。
  static Future<CampusCalendar?> refresh() async {
    lastError = '';
    try {
      final http.Client client = http.Client();
      try {
        // 首跳也要校验（虽然 kCalendarPageUrl 是我们自己写的常量，
      // 但保持一致：所有出站请求都过一次 UrlGuard）
      UrlGuard.check(kCalendarPageUrl, allowedHosts: kCalendarAllowedHosts);
      final http.Response res = await client.get(
          Uri.parse(kCalendarPageUrl),
          headers: const <String, String>{
            // 只带最小必要头；实测该站对 UA 不挑剔，但给个常规值更稳妥
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml',
            'Accept-Language': 'zh-CN,zh;q=0.9',
          },
        ).timeout(_timeout);

        if (res.statusCode != 200) {
          lastError = '校历页返回 ${res.statusCode}';
          return null;
        }
        // 该页实测是 UTF-8（响应头未声明 charset 时按 UTF-8 解）
        final String html = utf8.decode(res.bodyBytes, allowMalformed: true);

        final List<String> sections = parseSectionLines(html);
        final List<String> urls = parseImageUrls(html, kCalendarPageUrl);
        final String updated = parseUpdated(html);

        final List<String> local = <String>[];
        for (int i = 0; i < urls.length && i < 2; i++) {
          final String? p = await _downloadIfChanged(urls[i], 'calendar_${i + 1}.jpg', i);
          if (p != null) {
            local.add(p);
          }
        }

        // 作息表解析不到（学校改版）就不要覆盖已有缓存，宁可继续用旧的
        if (sections.isEmpty && local.isEmpty) {
          lastError = '未能从校历页解析出作息表或校历图';
          return null;
        }

        final CampusCalendar out = CampusCalendar(
          sections: sections.isEmpty
              ? (await _offline()).sections
              : sections,
          images: local.isEmpty ? await _cachedImages() : local,
          updated: updated,
          live: true,
        );

        await _savePrefs(out, urls);
        // 官网作息「顺手」同步到本地（仅在用户没自定义过时），
        // 这样上课提醒用的是官网最新时刻，而不是随包固化的旧值。
        if (out.sections.isNotEmpty) {
          await applyOfficialSectionsIfDefault(out.sections);
        }
        _mem = out;
        return out;
      } finally {
        client.close();
      }
    } catch (e) {
      lastError = e.toString();
      return null;
    }
  }

  /// 下载一张校历图；**地址与上次相同且本地文件还在时直接跳过**。
  ///
  /// ===== 为什么值得单独做这一步 =====
  /// 这两张图是**原始上传版**（实测 1.42MB + 1.32MB，共 2.74MB）。
  /// 而校历图由学校 CMS 生成，地址与附件绑定：图片没换时 URL 完全一致
  /// （已核对：相隔数日两次抓取，两张图的 `afc` 签名与 `nid` 逐字相同）。
  /// 不比较就会每次刷新都重下这 2.74MB，而学校一学期才换一次图。
  ///
  /// 判据用 URL 而不是文件时间/大小：URL 变了才意味着学校换了附件，
  /// 这是**内容变了**的直接证据，比任何启发式都可靠。
  /// 上一次的 URL 本来就存着（[kKeyCampusImageUrls]），此前只写不读。
  ///
  /// [index] 用于把本次 URL 与上次同位置的 URL 对比。
  static Future<String?> _downloadIfChanged(
      String url, String name, int index) async {
    try {
      final Directory d = await _dir();
      final File f = File('${d.path}${Platform.pathSeparator}$name');
      final List<String> prev = _splitLines(PrefStore.getText(kKeyCampusImageUrls)) ??
          <String>[];
      final bool sameUrl = index < prev.length && prev[index] == url;
      if (sameUrl && f.existsSync() && f.lengthSync() > 1024) {
        return f.path;
      }
      return await _download(url, name);
    } catch (_) {
      return null;
    }
  }

  /// 下载一张校历图到缓存目录。
  ///
  /// 地址来自**官网页面解析结果**，因此按不可信输入处理：
  ///   1. 主机必须在校历站白名单内（[kCalendarAllowedHosts]）；
  ///   2. 拒绝环回/私有/保留地址（SSRF 防护，见 `UrlGuard`）；
  ///   3. 手动跟随重定向并**逐跳校验** —— 否则合法主机可以 302 到内网。
  ///
  /// 只带 `Accept`，不带任何 Cookie：这是公网站点，不该收到教务系统会话。
  static Future<String?> _download(String url, String name) async {
    try {
      final Directory d = await _dir();
      final File f = File('${d.path}${Platform.pathSeparator}$name');

      final Uint8List b = await _getValidated(url, since: _lastFetchedAt());
      if (b.isEmpty) {
        // 服务端应答 304（未修改）：本地文件就是最新的
        return f.existsSync() ? f.path : null;
      }
      if (b.length < 1024) {
        return f.existsSync() ? f.path : null;
      }
      // JPEG 魔数校验：抓回来的可能是 HTML 错误页，别把错误页当图片存下来
      if (b.length < 3 || b[0] != 0xFF || b[1] != 0xD8) {
        return f.existsSync() ? f.path : null;
      }
      await f.writeAsBytes(b, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// 上次成功抓取的时刻（毫秒）；从未抓过返回 0
  static int _lastFetchedAt() => PrefStore.getInt(kKeyCampusFetchedAt);

  /// 取字节，逐跳校验主机（SSRF 防护）。
  ///
  /// 独立实现而不复用教务系统的 `HttpClient`：
  /// 那个客户端的 CookieJar 不带域名作用域、请求头还硬编码了教务系统的
  /// Origin/Referer —— 用它访问公网校网等于把 JSESSIONID 发给第三方站点。
  ///
  /// [since] 非 0 时带上 `If-Modified-Since`：站点支持就省掉一次 2.7MB 传输，
  /// 返回空字节表示 304。**不依赖它**（学校 CMS 未必实现），
  /// 真正的省流手段是上面的 URL 比对。
  static Future<Uint8List> _getValidated(String url, {int since = 0}) async {
    final http.Client client = http.Client();
    try {
      String current = url;
      for (int hop = 0; hop <= _maxRedirects; hop++) {
        UrlGuard.check(current, allowedHosts: kCalendarAllowedHosts);
        final http.Request req = http.Request('GET', Uri.parse(current));
        req.headers['Accept'] = 'image/*';
        req.headers['User-Agent'] = _userAgent;
        if (since > 0) {
          req.headers['If-Modified-Since'] =
              HttpDate.format(DateTime.fromMillisecondsSinceEpoch(since));
        }
        req.followRedirects = false;
        final http.StreamedResponse st =
            await req.send().timeout(_timeout);
        final http.Response res = await http.Response.fromStream(st);

        if (res.statusCode >= 300 && res.statusCode < 400) {
          final String loc = res.headers['location'] ?? '';
          if (loc.isEmpty) {
            throw const FormatException('redirect without location');
          }
          current = Uri.parse(current).resolve(loc).toString();
          continue;
        }
        if (res.statusCode == 304) {
          return Uint8List(0);
        }
        if (res.statusCode != 200) {
          throw FormatException('http=${res.statusCode}');
        }
        return res.bodyBytes;
      }
      throw const FormatException('too many redirects');
    } finally {
      client.close();
    }
  }

  static Future<void> _savePrefs(CampusCalendar c, List<String> urls) async {
    await PrefStore.putText(kKeyCampusSections, c.sections.join('\n'));
    await PrefStore.putText(kKeyCampusImages, c.images.join('\n'));
    await PrefStore.putText(kKeyCampusImageUrls, urls.join('\n'));
    await PrefStore.putText(kKeyCampusUpdated, c.updated);
    await PrefStore.putInt(
        kKeyCampusFetchedAt, DateTime.now().millisecondsSinceEpoch);
  }

  static List<String>? _cachedSections() => _splitLines(
      PrefStore.getText(kKeyCampusSections));

  static String _cachedUpdated() => PrefStore.getText(kKeyCampusUpdated);

  static Future<List<String>> _cachedImages() async {
    final List<String> paths =
        _splitLines(PrefStore.getText(kKeyCampusImages)) ?? <String>[];
    final List<String> ok = <String>[];
    for (final String p in paths) {
      if (p.isNotEmpty && File(p).existsSync()) {
        ok.add(p);
      }
    }
    return ok;
  }

  static List<String>? _splitLines(String raw) {
    if (raw.trim().isEmpty) {
      return null;
    }
    final List<String> out = raw
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    return out.isEmpty ? null : out;
  }

  static int lastFetchedAt() => PrefStore.getInt(kKeyCampusFetchedAt);

  /// 缓存是否已过期（从未抓过也算过期）。默认 7 天。
  static bool isStale({Duration maxAge = const Duration(days: 7)}) {
    final int at = lastFetchedAt();
    if (at <= 0) {
      return true;
    }
    final DateTime then =
        DateTime.fromMillisecondsSinceEpoch(at, isUtc: false);
    return DateTime.now().difference(then) > maxAge;
  }

  /// 设置页一行摘要：让用户知道现在用的是联网版、缓存还是内置版
  /// 设置页的副标题：只说「能不能看」，不暴露数据来源与缓存细节。
  ///
  /// 刻意**不**显示「已获取官网最新版 / 显示上次缓存的版本 / 更新于 x」——
  /// 那些是内部策略，用户看到只会产生「是不是数据过期了」的额外疑问。
  /// 唯一值得外显的是「学校官网更新到哪一版」这个**官方信息**。
  static String hint(CampusCalendar c) {
    if (c.updated.isEmpty) {
      return '查看官方校历与作息表';
    }
    return '官网 ${c.updated} 版';
  }

  /// 缓存占用（字节），供设置页展示
  static Future<int> cacheBytes() async {
    try {
      final Directory d = await _dir();
      int total = 0;
      await for (final FileSystemEntity e in d.list()) {
        if (e is File) {
          total += await e.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clearCache() async {
    try {
      final Directory d = await _dir();
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    } catch (_) {}
    _mem = null;
    await PrefStore.putText(kKeyCampusSections, '');
    await PrefStore.putText(kKeyCampusImages, '');
    await PrefStore.putText(kKeyCampusImageUrls, '');
    await PrefStore.putText(kKeyCampusUpdated, '');
  }

  // ==================== 纯解析逻辑（可单测，不碰网络）====================

  /// 从 HTML 里取「日常教学时刻表」。
  ///
  /// 返回形如 `['第一、二节  08:30 - 10:00', '课间休息  10:00 - 10:20', ...]`。
  /// 注意**不能**依赖原始 HTML 里的顺序假设 —— 课间休息必须按官方给出的
  /// 行序插入，否则「第九、十节后休息 10 分钟」这一条会错位。
  static List<String> parseSectionLines(String html) {
    final List<List<String>> rows = parseSectionRows(html);
    final List<String> out = <String>[];
    for (final List<String> r in rows) {
      if (r.length < 2) {
        continue;
      }
      final String label = r[0];
      final String range = _normalizeRange(r[1]);
      if (label.isEmpty || range.isEmpty) {
        continue;
      }
      out.add('$label  $range');
    }
    return out;
  }

  /// 解析作息表的原始行（[节次, 起止时间]），表头行会被剔除
  static List<List<String>> parseSectionRows(String html) {
    final String? table = _findTable(html, '起止时间');
    if (table == null) {
      return <List<String>>[];
    }
    final List<List<String>> rows = <List<String>>[];
    final RegExp rowRe = RegExp(r'<tr[^>]*>([\s\S]*?)</tr>', caseSensitive: false);
    for (final RegExpMatch rm in rowRe.allMatches(table)) {
      final String rowHtml = rm.group(1) ?? '';
      final List<String> cells = <String>[];
      final RegExp cellRe =
          RegExp(r'<t[dh][^>]*>([\s\S]*?)</t[dh]>', caseSensitive: false);
      for (final RegExpMatch cm in cellRe.allMatches(rowHtml)) {
        cells.add(_text(cm.group(1) ?? ''));
      }
      if (cells.length >= 2) {
        rows.add(cells);
      }
    }
    // 去掉表头（含「节次」或「起止时间」的那一行）
    return rows
        .where((List<String> r) =>
            !r[0].contains('节次') && !r[1].contains('起止时间'))
        .toList();
  }

  /// 从 HTML 里取校历图片地址（绝对化），按出现顺序、去重。
  ///
  /// 页面里每张图有两个地址：
  ///   - `src`      —— 站内展示用的版本（实测 800px、约 380KB）；
  ///   - `orisrc`   —— 原始上传版本（像素尺寸相同但压缩更轻，约 1.4MB）。
  /// 这里**优先取原始版本**：日历图用户会放大看，少一层 JPEG 压缩明显更清楚，
  /// 而且图片只缓存在本机、不进安装包，多出来的体积只影响一次下载。
  /// 属性名在 CMS 里拼作 `orisrc`（少一个 g），两种拼法都认。
  static List<String> parseImageUrls(String html, String pageUrl) {
    final List<String> out = <String>[];
    final RegExp imgRe = RegExp(r'<img[^>]*>', caseSensitive: false);
    for (final RegExpMatch m in imgRe.allMatches(html)) {
      final String tag = m.group(0) ?? '';
      if (!tag.contains('virtual_attach_file')) {
        continue;
      }
      // 注意第一个参数必须能区分 src 与 orisrc：标签里 "orisrc=" 的结尾
      // 恰好是 "src="，用朴素的子串匹配会在属性顺序变化时取错值。
      final String? ori = _attr(tag, 'origsrc') ?? _attr(tag, 'orisrc');
      final String? src = _attr(tag, 'src');
      final String? pick = (ori != null && ori.isNotEmpty) ? ori : src;
      if (pick == null || pick.isEmpty) {
        continue;
      }
      // `&amp;` 是 HTML 转义，URL 里必须是 `&`
      final String abs = _absolutize(pick.replaceAll('&amp;', '&'), pageUrl);
      if (!out.contains(abs)) {
        out.add(abs);
      }
    }
    return out;
  }

  /// 取官网标注的更新时间，如 `2026年7月`；取不到返回空串
  static String parseUpdated(String html) {
    final String t = _text(html);
    final RegExpMatch? m = RegExp(r'更新时间[:：]\s*([0-9]{4}\s*年\s*[0-9]{1,2}\s*月)')
        .firstMatch(t);
    if (m == null) {
      return '';
    }
    return (m.group(1) ?? '').replaceAll(RegExp(r'\s+'), '');
  }

  /// 把官网作息行归并成课表的 5 行（`kSectionRows`），返回 `[start, end]` 列表。
  ///
  /// 为什么需要归并：官网表把它自己的「节」逐个列出（第九、十节 与 第十一节 各一行），
  /// 而课表里把「第九~十一节」合成一行。归并规则：
  ///   - 先剔除「课间休息」行，只留上课节次；
  ///   - 上课行数 **恰好等于** 5 → 一一对应；
  ///   - 上课行数 **多于** 5 → 前 4 行一一对应，多出来的全部并进第 5 行
  ///     （取第一行的起点、最后一行的终点）；
  ///   - 少于 5 行 → 说明官网改版成别的结构，**不做映射**（返回 null），
  ///     宁可继续用本地值，也不要按错位的时间算提醒。
  ///
  /// 返回 null 时调用方必须放弃更新。
  static List<List<String>>? mapToGridRows(List<String> sectionLines) {
    final List<List<String>> teach = <List<String>>[];
    for (final String line in sectionLines) {
      if (line.contains('课间')) {
        continue;
      }
      final RegExpMatch? m =
          RegExp(r'^(\S+)\s+(\d{2}:\d{2})\s*-\s*(\d{2}:\d{2})$').firstMatch(line);
      if (m == null) {
        continue;
      }
      teach.add(<String>[m.group(2)!, m.group(3)!]);
    }
    if (teach.length < kSectionRows) {
      return null;
    }
    if (teach.length == kSectionRows) {
      return teach;
    }
    final List<List<String>> out = <List<String>>[];
    for (int i = 0; i < kSectionRows - 1; i++) {
      out.add(teach[i]);
    }
    out.add(<String>[teach[kSectionRows - 1][0], teach.last[1]]);
    return out;
  }

  /// 若用户**没有自定义过**作息，就用官网最新值刷新本地作息。
  ///
  /// 只在 `SectionTimeStore.isDefault()` 为真时写入 —— 用户手动调过的时间
  /// 是用户意图，不能被一次联网静默覆盖。
  ///
  /// 返回是否发生了更新。
  static Future<bool> applyOfficialSectionsIfDefault(
      List<String> sectionLines) async {
    final List<List<String>>? rows = mapToGridRows(sectionLines);
    if (rows == null || rows.length != kSectionRows) {
      return false;
    }
    await SectionTimeStore.load();
    if (!SectionTimeStore.isDefault()) {
      return false;
    }
    bool changed = false;
    for (int i = 0; i < kSectionRows; i++) {
      if (kSections[i].start != rows[i][0] || kSections[i].end != rows[i][1]) {
        changed = true;
        break;
      }
    }
    if (!changed) {
      return false;
    }
    final List<SectionTime> list = <SectionTime>[];
    for (int i = 0; i < kSectionRows; i++) {
      list.add(SectionTime(i, kSections[i].label, rows[i][0], rows[i][1]));
    }
    // 用 saveOfficial 而不是 saveAll：这是**官网**的值，
    // 不能置位「已自定义」标记 —— 否则同步一次就再也不跟随官网了
    // （这个 bug 曾让「官网改动会不会同步」的答案变成「只同步一次」）。
    await SectionTimeStore.saveOfficial(list);
    return true;
  }

  // ---------- 小型 HTML 工具（不引入 DOM，够用即可）----------

  /// 找到含 [headerText] 的那张表，返回从 `<table` 到配平的 `</table>` 的片段
  static String? _findTable(String html, String headerText) {
    final RegExp openRe = RegExp(r'<table[^>]*>', caseSensitive: false);
    for (final RegExpMatch m in openRe.allMatches(html)) {
      final int start = m.start;
      final String? t = _balance(html, start);
      if (t != null && t.contains(headerText)) {
        return t;
      }
    }
    return null;
  }

  /// 从 `<table` 处按嵌套深度配平取出整张表
  static String? _balance(String html, int start) {
    final RegExp tagRe = RegExp(r'<(/?)table[^>]*>', caseSensitive: false);
    int depth = 0;
    for (final RegExpMatch m in tagRe.allMatches(html.substring(start))) {
      final bool closing = (m.group(1) ?? '').isNotEmpty;
      if (closing) {
        depth--;
        if (depth == 0) {
          return html.substring(start, start + m.end);
        }
      } else {
        depth++;
      }
    }
    return null;
  }

  /// 去标签 + 解实体 + 压空白
  static String _text(String html) => html
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// 取属性值（支持 `name="v"` 与 `name='v'`）。
  ///
  /// 用负向回顾断言保证 `src` **不会**匹配到 `orisrc=`/`origsrc=` 里的尾部，
  /// 也不匹配 `data-src` 这类带前缀的属性 —— 学校 CMS 的属性顺序不保证。
  static String? _attr(String tag, String name) {
    final RegExpMatch? m = RegExp(
      '(?<![A-Za-z0-9_-])$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')',
      caseSensitive: false,
    ).firstMatch(tag);
    if (m == null) {
      return null;
    }
    return m.group(2) ?? m.group(3) ?? '';
  }

  /// 相对地址 → 绝对地址
  static String _absolutize(String url, String pageUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    final Uri base = Uri.parse(pageUrl);
    if (url.startsWith('/')) {
      return '${base.scheme}://${base.authority}$url';
    }
    return base.resolve(url).toString();
  }

  /// `8:30-10:00` → `08:30 - 10:00`（补齐前导零，统一展示形态）。
  ///
  /// 兼容学校 CMS 可能出现的全角冒号/连字符/波浪线，以及全角数字 ——
  /// 这类字符在富文本编辑器里很容易被误输入，一旦出现就会让整行解析为空，
  /// 表现为「作息表突然少了几行」而没有任何报错。
  static String _normalizeRange(String raw) {
    final String s = _normalizeWidth(raw);
    final RegExpMatch? m =
        RegExp(r'(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})').firstMatch(s);
    if (m == null) {
      return '';
    }
    String two(String v) => v.length == 1 ? '0$v' : v;
    return '${two(m.group(1)!)}:${m.group(2)} - ${two(m.group(3)!)}:${m.group(4)}';
  }

  /// 全角 → 半角，并把各种「横线」统一成 `-`
  static String _normalizeWidth(String raw) {
    final StringBuffer sb = StringBuffer();
    for (final int c in raw.runes) {
      if (c == 0xFF1A) {
        sb.write(':'); // 全角冒号
      } else if (c >= 0xFF10 && c <= 0xFF19) {
        sb.writeCharCode(c - 0xFF10 + 0x30); // 全角数字
      } else if (c == 0x3000) {
        sb.write(' '); // 全角空格
      } else if (c == 0xFF0D || c == 0x2013 || c == 0x2014 || c == 0x2015 ||
          c == 0xFF5E || c == 0x301C || c == 0x2212 || c == 0x7E) {
        // － – — ― ～ 〜 − 以及半角 ~ 都当连字符（半角 ~ 在 admin 里最常被误用）
        sb.write('-');
      } else if (c == 0x223C || c == 0xFF5F || c == 0xFF60) {
        sb.write('-'); // ∼ 与全角括号（排字变体），一并容忍
      } else {
        sb.writeCharCode(c);
      }
    }
    return sb.toString();
  }
}
