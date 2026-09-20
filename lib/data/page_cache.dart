/// 页面数据的缓存层（内存 + 磁盘）
///
/// ===== 为什么需要它 =====
/// 框架里同一时刻**只挂载一个页面**（没有 IndexedStack、没有保活），
/// 切一次底部导航 → 旧页 dispose → 新页重走 `initState` → 重新发请求。
/// 于是「课表→成绩→课表」这样来回切两次，就要打四个网络请求 ——
/// 而其中三次的数据大概率一个字都没变。
///
/// 课表页早就有自己的缓存（[TimetableStore]：缓存优先、网络兜底），
/// 所以切到它从不闪加载态。本文件把这套做法抽成通用的两层缓存，
/// 供其余页面复用。
///
/// ===== 为什么缓存**服务器原文**而不是解析后的模型 =====
/// 一个自然的想法是「缓存解析结果」，但那要手写每个模型的 toJson/fromJson
/// （成绩记录、培养方案、通选修读…十来个类）。那会引入一类很难发现的
/// 静默错误：**模型加了字段，序列化器忘了同步** —— 症状是「在线正常、
/// 离线缺字段」，而且不会有任何报错。本仓库已经吃过同类亏
/// （数据流两处不同步，见 docs/技术笔记.md「移植中修掉的缺陷」）。
///
/// 缓存原文则完全没有序列化代码：解析器本来就是「解读这些页面」的
/// 唯一真相，缓存的数据也走同一条解析路径。代价是进页面时解析一次
/// （实测课表 3ms、成绩 0.8ms、培养方案 17ms、个人信息 2.4ms），
/// 相比省下的网络往返可以忽略；而修好解析器的 bug 后，**缓存里的旧数据
/// 会自动被重新正确解读**，不需要刷新缓存或改版本号。
///
/// ===== 三层结构与取数规则 =====
/// ```
/// 内存层（进程内）  → 切页即时，不闪加载态
/// 磁盘层（按账号分片）→ 冷启动、离线时仍有内容
/// 网络层            → 只在「需要」时请求
/// ```
/// 「需要」的判据见 [PageDataLoader.load]：手动刷新、数据过期、或压根没数据。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// 一条缓存记录：原文 + 抓取时刻
class CachedPage {
  CachedPage(this.body, this.fetchedAt);

  /// 服务器返回的**原始页面文本**
  final String body;

  /// 抓取时刻（毫秒时间戳）。TTL 判断只用它 ——
  /// 不用文件 mtime：写盘时间与「数据从服务器来的时刻」不是一回事
  /// （例如从磁盘读出来又原样写回，mtime 会更新，数据却更旧了）。
  final int fetchedAt;

  /// 数据年龄是否已超过 [ttl]。
  ///
  /// 收 [Duration] 而不是毫秒数：调用方（[PageDataLoader]）手里就是 Duration，
  /// 收 Duration 可以避免「谁负责乘 1000」这种低级错误，
  /// 也与外部传入的 TTL 常量类型一致。
  bool isStale(Duration ttl) {
    final int age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
    return age > ttl.inMilliseconds;
  }
}

/// 页面数据缓存的统一入口。
///
/// 内存与磁盘用**同一个 key**，key 里必须包含账号 —— 同机多账号时
/// 不能让 B 看到 A 的缓存（这是本项目一直守的边界，见 AppState 的登出清理）。
class PageCache {
  /// 内存层：key → 记录。进程内共享，切页不丢。
  static final Map<String, CachedPage> _memory = <String, CachedPage>{};

  /// 磁盘目录名
  static const String _dirName = 'pagecache';

  /// 缓存文件版本。**改缓存的文件格式时才需要动它** ——
  /// 缓存的是服务器原文，解析器改了不影响这里（见文件头说明）。
  static const int _version = 1;

  static Directory? _cachedDir;

  /// 拼缓存 key。
  ///
  /// 用 `|` 分隔各段，顺序固定为「账号 | 页面名 | 变体…」。
  /// 变体用于有参数的数据：成绩按学期、空教室按查询条件。
  static String keyOf(String account, String name, [List<String> variants = const <String>[]]) {
    final StringBuffer b = StringBuffer();
    b.write(account.isEmpty ? '_' : account);
    b.write('|');
    b.write(name);
    for (final String v in variants) {
      b.write('|');
      b.write(v);
    }
    return b.toString();
  }

  /// 读内存层（同步，供首帧直接渲染）
  static CachedPage? peek(String key) => _memory[key];

  /// 读磁盘层；不存在或损坏返回 null，并顺手清掉坏文件
  static Future<CachedPage?> readDisk(String key) async {
    final File? f = await _fileFor(key);
    if (f == null || !await f.exists()) {
      return null;
    }
    try {
      final String text = await f.readAsString();
      if (text.isEmpty) {
        return null;
      }
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('not an object');
      }
      final Object? ver = decoded['v'];
      // 版本不符：直接丢弃（宁可重新请求，也不用格式不明的旧数据）
      if (ver is! int || ver > _version) {
        await _deleteQuietly(f);
        return null;
      }
      final Object? body = decoded['body'];
      final Object? at = decoded['at'];
      if (body is! String || body.isEmpty || at is! int) {
        await _deleteQuietly(f);
        return null;
      }
      final CachedPage page = CachedPage(body, at);
      // 读出来就放进内存层：同一次进程内再进这个页面就不用再读盘
      _memory[key] = page;
      return page;
    } catch (e) {
      // 文件损坏（写到一半被杀、磁盘满…）→ 删掉它，让下次走网络。
      // 不删的话每次进页面都会重复解析失败、白等一次 IO。
      debugPrint('[cache] read failed, dropping: $key');
      await _deleteQuietly(f);
      return null;
    }
  }

  /// 写入两层（磁盘失败不影响内存层：本次会话仍然受益）
  static Future<void> write(String key, String body) async {
    final CachedPage page = CachedPage(body, DateTime.now().millisecondsSinceEpoch);
    _memory[key] = page;
    final File? f = await _fileFor(key);
    if (f == null) {
      return;
    }
    try {
      final Map<String, Object> out = <String, Object>{
        'v': _version,
        'at': page.fetchedAt,
        'body': body,
      };
      await f.writeAsString(jsonEncode(out), flush: true);
    } catch (e) {
      debugPrint('[cache] write failed: $key');
    }
  }

  /// 删除某个 key 的两层缓存
  static Future<void> remove(String key) async {
    _memory.remove(key);
    final File? f = await _fileFor(key);
    if (f != null) {
      await _deleteQuietly(f);
    }
  }

  /// 清掉某账号的**全部**缓存（登出时调用）。
  ///
  /// 内存层按 key 前缀匹配（key 以账号开头）；磁盘层靠文件名前缀匹配。
  /// 这个动作是「换账号后 B 不能看到 A 的数据」这条边界的最后一环 ——
  /// 漏了它，B 进成绩页会先看到 A 的成绩、再被网络响应覆盖。
  static Future<void> clearAccount(String account) async {
    if (account.isEmpty) {
      return;
    }
    final String prefix = '$account|';
    _memory.removeWhere((String k, CachedPage _) => k.startsWith(prefix));

    final Directory? d = await _dir();
    if (d == null) {
      return;
    }
    try {
      final String filePrefix = '${_safe(account)}_';
      await for (final FileSystemEntity e in d.list()) {
        final String name = e.uri.pathSegments.last;
        if (name.startsWith(filePrefix)) {
          await _deleteQuietly(File(e.path));
        }
      }
    } catch (e) {
      debugPrint('[cache] clear failed for account');
    }
  }

  /// 仅供测试：清空内存层（磁盘层由测试自己控制临时目录）
  static void clearMemoryForTest() => _memory.clear();

  /// 仅供测试：写入一条**指定抓取时刻**的记录。
  ///
  /// 用于构造「缓存已过期」的场景 —— 直接写时间戳比调时间函数更可靠：
  /// `ttl: Duration.zero` 达不到目的（刚写的记录 age 为 0，不算过期）。
  @visibleForTesting
  static Future<void> writeForTest(String key, String body, DateTime at) async {
    final CachedPage page = CachedPage(body, at.millisecondsSinceEpoch);
    _memory[key] = page;
    final File? f = await _fileFor(key);
    if (f == null) {
      return;
    }
    try {
      await f.writeAsString(jsonEncode(<String, Object>{
        'v': _version,
        'at': page.fetchedAt,
        'body': body,
      }), flush: true);
    } catch (e) {
      // 忽略
    }
  }

  /// 仅供测试：替换磁盘目录。
  ///
  /// 存在的理由：默认目录来自 `getApplicationDocumentsDirectory()`
  /// （要走平台通道），单元测试里没有平台实现，拿不到目录。
  /// 传 null 恢复默认。生产代码不得调用。
  @visibleForTesting
  static void debugSetDirForTest(Directory? d) {
    _cachedDir = d;
  }

  // ==================== 内部 ====================

  static Future<Directory?> _dir() async {
    if (_cachedDir != null) {
      return _cachedDir;
    }
    try {
      final Directory base = await getApplicationDocumentsDirectory();
      final Directory d = Directory('${base.path}/$_dirName');
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
      _cachedDir = d;
      return d;
    } catch (e) {
      // 拿不到目录就退化为「只有内存缓存」：功能不变，只是冷启动要联网
      debugPrint('[cache] dir unavailable');
      return null;
    }
  }

  /// key → 文件
  static Future<File?> _fileFor(String key) async {
    final Directory? d = await _dir();
    if (d == null) {
      return null;
    }
    return File('${d.path}/${_safe(key)}.json');
  }

  /// 把 key 变成安全的文件名，形如 `<账号>_<其余部分的编码>`。
  ///
  /// 账号放在最前面是为了 [clearAccount] 能按前缀清理。
  ///
  /// 其余部分**用十六进制编码而不是 hashCode**：哈希有碰撞可能，
  /// 而碰撞的后果是「两个不同页面互相覆盖缓存」—— 症状是进 A 页看到 B 页的
  /// 内容，且只在特定页面组合下复现，极难排查。文件名的长度上限
  /// （255 字节）在十六进制编码下也够用：key 里最长的是空教室的查询条件
  /// （学期+校区+教学楼+节次+周+日，约 40 字符），编码后约 80 字符。
  static String _safe(String key) {
    final int bar = key.indexOf('|');
    final String account = bar > 0 ? key.substring(0, bar) : key;
    final String rest = bar > 0 ? key.substring(bar) : '';
    final String safeAccount = account.replaceAll(RegExp(r'[^0-9a-zA-Z._-]'), '_');
    if (rest.isEmpty) {
      return safeAccount;
    }
    // 只对「非字母数字」的字节做转义，可读性比纯 hex 好一些
    final StringBuffer b = StringBuffer();
    for (final int c in rest.codeUnits) {
      final bool plain = (c >= 0x30 && c <= 0x39) ||   // 0-9
          (c >= 0x41 && c <= 0x5A) ||                   // A-Z
          (c >= 0x61 && c <= 0x7A) ||                   // a-z
          c == 0x2E || c == 0x2D || c == 0x5F;          // . - _
      if (plain) {
        b.writeCharCode(c);
      } else {
        b.write('%');
        b.write(c.toRadixString(16).padLeft(4, '0'));
      }
    }
    return '${safeAccount}_${b.toString()}';
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) {
        await f.delete();
      }
    } catch (e) {
      // 忽略：删不掉不影响主流程
    }
  }
}

/// loader 取数的结果：数据从哪来
enum PageDataSource {
  /// 内存缓存（本次进程内已有）
  memory,

  /// 磁盘缓存
  disk,

  /// 网络
  network,
}

/// 一次加载的结果
class PageLoadResult<T> {
  const PageLoadResult(this.data, this.source, {this.fromNetwork = false});

  final T data;
  final PageDataSource source;

  /// 与 [PageDataSource.network] 同义，单独留一个布尔是为了调用方读起来直白
  final bool fromNetwork;
}

/// 页面数据加载器：把「三层缓存 + 取数规则」编排成一个方法。
///
/// 每个页面只写三件事：
///   1. 缓存 key（[PageCache.keyOf]，含账号与页面参数）；
///   2. 怎么从服务器拿原文（`() => api.getXxxHtml()`）；
///   3. 怎么把原文解析成模型（`(html) => XxxParser.parse(html)`）。
///
/// 其余（读内存、读盘、判断要不要联网、写回两层）都由本类负责，
/// 这样五个页面的取数逻辑完全一致，不会各写各的、渐渐走偏。
class PageDataLoader<T> {
  const PageDataLoader({
    required this.key,
    required this.fetch,
    required this.parse,
    required this.ttl,
  });

  /// 缓存 key（必须含账号，见 [PageCache.keyOf]）
  final String key;

  /// 请求服务器**原文**
  final Future<String> Function() fetch;

  /// 原文 → 模型
  final T Function(String body) parse;

  /// 数据在这个时长内视为新鲜（不联网）
  final Duration ttl;

  /// 同步读内存层：用于**首帧**判断能否直接渲染。
  ///
  /// 单独提供是因为 `load()` 是异步的（磁盘 IO），而页面希望第一帧就有内容。
  /// 页面可以在 `initState` 里先 `peek()` 到内容就 setState 渲染，
  /// 再 `await load()` 决定要不要联网 —— 这样切页完全没有加载态闪烁。
  T? peek() {
    final CachedPage? hit = PageCache.peek(key);
    if (hit == null) {
      return null;
    }
    try {
      return parse(hit.body);
    } catch (e) {
      // 内存里的原文解析失败（解析器改过了？）→ 当作没有，
      // 让 load() 去读磁盘或走网络。不删内存，磁盘层还有机会。
      debugPrint('[cache] parse failed (memory): $key');
      return null;
    }
  }

  /// 只读缓存（内存 → 磁盘），**绝不联网**；没有缓存返回 null。
  ///
  /// 存在的理由是「强制刷新失败后回退到上次成功的数据」：
  /// 那种场景下不能复用 [load] —— load 在缓存过期时会去联网，
  /// 而这时联网正是刚刚失败的那件事，再走一遍只是白等一次超时。
  Future<T?> loadCached() async {
    final CachedPage? hit = PageCache.peek(key) ?? await PageCache.readDisk(key);
    if (hit == null) {
      return null;
    }
    try {
      return parse(hit.body);
    } catch (e) {
      debugPrint('[cache] parse failed (cached): $key');
      return null;
    }
  }

  /// 按「缓存优先、网络兜底」取数。
  ///
  /// [force] 为 true 表示这是用户主动刷新（下拉或点重试）：
  /// 只要网络成功就用新数据，失败则把异常抛给调用方 ——
  /// 但**不会**因为失败就把已有缓存丢掉（调用方拿到异常后
  /// 仍然可以继续显示 `peek()` 到的旧内容）。
  Future<PageLoadResult<T>> load({bool force = false}) async {
    // 1) 内存层
    final CachedPage? mem = PageCache.peek(key);
    if (mem != null && !force && !mem.isStale(ttl)) {
      try {
        return PageLoadResult<T>(parse(mem.body), PageDataSource.memory);
      } catch (e) {
        debugPrint('[cache] parse failed (memory), falling back: $key');
      }
    }

    // 2) 磁盘层（readDisk 命中时会写回内存层）
    final CachedPage? disk = await PageCache.readDisk(key);
    if (disk != null && !force && !disk.isStale(ttl)) {
      try {
        return PageLoadResult<T>(parse(disk.body), PageDataSource.disk);
      } catch (e) {
        debugPrint('[cache] parse failed (disk), falling back: $key');
      }
    }

    // 3) 网络。到达这里说明：没有缓存、缓存过期、或用户要求强制刷新。
    final String body = await fetch();
    // 只有成功才写缓存 —— 失败时保留旧的（可能已过期，但比没有强）
    await PageCache.write(key, body);
    return PageLoadResult<T>(parse(body), PageDataSource.network, fromNetwork: true);
  }
}
