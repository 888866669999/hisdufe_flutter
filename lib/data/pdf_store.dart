/// PDF 下载与本地缓存（培养方案附件）
///
/// 从鸿蒙版 `data/PdfStore.ets` 移植。
///
/// ===== 为什么必须缓存 =====
/// 培养方案 PDF 有几 MB，而培养方案页可能被反复打开。
/// 每次都重新下载既慢又浪费流量（学校的服务器也不快），因此下载到应用私有目录，
/// 按「账号 + 附件路径」的哈希命名，并限制总占用上限。
///
/// ===== 附件路径是动态的（不要写死）=====
/// `PlanParser` 从页面里正则提取 PDF 链接。不同专业、不同年份的培养方案
/// 附件名都不一样（例如 `/ewebeditor/uploadfile/2025033110250359448.pdf`），
/// 而且页数也各不相同 —— 因此这里只认「页面给出的路径」，
/// 页数由 PDF 文档自身决定，任何环节都不假设固定的文件名或页数。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../common/constants.dart';
import '../common/result.dart';
import '../network/cookie_jar.dart';
import '../network/http_client.dart';

/// 缓存占用统计（设置页展示用）
class PdfUsage {
  PdfUsage(this.files, this.bytes);

  final int files;
  final int bytes;
}

class PdfStore {
  /// 缓存上限：超过就按最后访问时间淘汰最旧的
  static const int maxCacheBytes = 50 * 1024 * 1024;

  /// 小于这个大小视为下载不完整
  static const int _minValidBytes = 1024;

  static Future<Directory> _dir() async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory d = Directory('${base.path}/pdf');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  /// 文件名：账号 + 附件路径 的稳定哈希
  static String _hashOf(String account, String pdfPath) {
    int h = 0;
    final String src = '$account|$pdfPath';
    for (int i = 0; i < src.length; i++) {
      h = (h * 31 + src.codeUnitAt(i)) % 2147483647;
    }
    return h.toString();
  }

  static Future<File> fileFor(String account, String pdfPath) async {
    final Directory d = await _dir();
    return File('${d.path}/doc_${_hashOf(account, pdfPath)}.pdf');
  }

  /// 是否已有可用缓存
  static Future<bool> has(String account, String pdfPath) async {
    if (account.isEmpty || pdfPath.isEmpty) {
      return false;
    }
    final File f = await fileFor(account, pdfPath);
    if (!await f.exists()) {
      return false;
    }
    return await f.length() > _minValidBytes;
  }

  /// 下载并落盘；返回本地文件路径（失败抛 AppError）
  static Future<String> download(
    CookieJar jar,
    String account,
    String pdfPath,
  ) async {
    final File target = await fileFor(account, pdfPath);
    if (await target.exists() && await target.length() > _minValidBytes) {
      return target.path; // 命中缓存
    }

    final String url = pdfPath.startsWith('http')
        ? pdfPath
        : '$kBaseOrigin$pdfPath';
    // 附件地址来自**远端页面解析结果**，属不可信输入：
    // 走逐跳校验的下载（拒绝环回/私网/保留地址，且重定向每一跳都校验），
    // 避免页面被篡改时把应用当成内网扫描器（SSRF）。
    final Uint8List bytes = await HttpClient(jar)
        .getBinaryValidated(url, 'application/pdf,*/*;q=0.8');

    if (bytes.length < _minValidBytes) {
      throw AppError(ErrKind.server, 'PDF 下载失败或内容为空');
    }
    // 校验魔数：拿到的可能是登录页 HTML（会话失效时常见）
    if (bytes.length < 4 ||
        bytes[0] != 0x25 ||
        bytes[1] != 0x50 ||
        bytes[2] != 0x44 ||
        bytes[3] != 0x46) {
      throw AppError(ErrKind.authExpired, '取到的不是 PDF（可能需要重新登录）');
    }

    try {
      await target.writeAsBytes(bytes, flush: true);
    } catch (e) {
      if (await target.exists()) {
        await target.delete();
      }
      throw AppError(ErrKind.unknown, 'PDF 保存失败');
    }
    await prune();
    return target.path;
  }

  /// 清空缓存（设置页入口）
  static Future<int> clearAll() async {
    final Directory d = await _dir();
    int n = 0;
    await for (final FileSystemEntity e in d.list()) {
      if (e is File && e.path.endsWith('.pdf')) {
        await e.delete();
        n++;
      }
    }
    return n;
  }

  static Future<PdfUsage> usage() async {
    final Directory d = await _dir();
    int files = 0;
    int bytes = 0;
    await for (final FileSystemEntity e in d.list()) {
      if (e is File && e.path.endsWith('.pdf')) {
        files++;
        bytes += await e.length();
      }
    }
    return PdfUsage(files, bytes);
  }

  /// 超限时按「最后修改时间」淘汰最旧的，直到降到上限以内
  static Future<void> prune() async {
    final Directory d = await _dir();
    final List<File> files = <File>[];
    int total = 0;
    await for (final FileSystemEntity e in d.list()) {
      if (e is File && e.path.endsWith('.pdf')) {
        files.add(e);
        total += await e.length();
      }
    }
    if (total <= maxCacheBytes) {
      return;
    }
    // 按 mtime 升序（最旧在前），逐个删到达标
    final List<List<Object>> meta = <List<Object>>[];
    for (final File f in files) {
      meta.add(<Object>[await f.lastModified(), f]);
    }
    meta.sort((List<Object> a, List<Object> b) =>
        (a[0] as DateTime).compareTo(b[0] as DateTime));
    for (final List<Object> m in meta) {
      if (total <= maxCacheBytes) {
        break;
      }
      final File f = m[1] as File;
      try {
        final int size = await f.length();
        await f.delete();
        total -= size;
      } catch (_) {
        // 单个删除失败不影响其余
      }
    }
  }
}
