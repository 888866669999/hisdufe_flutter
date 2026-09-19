/// 出站请求的 URL/主机校验（SSRF 防护）
///
/// ===== 为什么需要它 =====
/// 本应用有两处**从远端 HTML 里解析出 URL 再发请求**的地方：
///   1. 校历图：从官网页面 `<img src=...>` 取地址后下载；
///   2. 培养方案 PDF：从页面里正则出附件路径后下载。
/// 这两条链路的 URL 完全由**服务端返回的内容**决定。若页面被篡改、
/// 或链路被中间人改写，攻击者就能让应用去请求
/// `http://127.0.0.1:8080/...`、`http://192.168.1.1/...` 这类**内网地址** ——
/// 手机上的应用一旦能访问内网，就变成了扫描器/跳板（经典 SSRF）。
///
/// 因此规则是（按约束要求）：**只允许 http/https、发请求前校验 host、
/// 拒绝 localhost / 环回 / 私有 / 保留地址**。
///
/// ===== 为什么不能只做字符串匹配 =====
/// IP 有大量等价写法，只按字面判断会被绕过：
///   `http://2130706433/`（十进制）、`http://0x7f000001/`（十六进制）、
///   `http://017700000001/`（八进制）、`http://127.1/`（省略段）、
///   `http://[::ffff:127.0.0.1]/`（IPv6 映射）。
/// 它们全都会连到 127.0.0.1。所以这里先把各种写法**归一化成 32 位整数**
/// 再按网段判断，而不是比对字符串。
///
/// ===== 重定向同样要校验 =====
/// 只校验首个 URL 是不够的：一个合法公网主机可以 302 到内网地址。
/// 因此本模块配合手动跟随重定向（见 `HttpClient.getBinaryValidated`），
/// **每一跳都校验**。
library;

/// 校验失败时抛出的异常
class BlockedUrlException implements Exception {
  BlockedUrlException(this.reason, this.url);

  final String reason;
  final String url;

  @override
  String toString() => 'BlockedUrlException($reason, $url)';
}

class UrlGuard {
  /// 允许的协议
  static const Set<String> _allowedSchemes = <String>{'http', 'https'};

  /// 明确禁止的主机名（大小写不敏感）。`.local` 用于 mDNS，
  /// 在手机上常指向局域网设备，一并拒绝。
  static const Set<String> _blockedNames = <String>{
    'localhost',
    'localhost.localdomain',
    'ip6-localhost',
    'ip6-loopback',
  };

  /// 校验一个 URL 是否允许请求。
  ///
  /// @param url            待校验的绝对地址
  /// @param allowedHosts   若非空，则**主机必须在此白名单内**（更严格）。
  ///                       用于「本来就知道该从哪个域名取数据」的场景
  ///                       （校历、教务附件都只应来自学校域名）。
  /// @throws BlockedUrlException 校验不通过
  static void check(String url, {Set<String>? allowedHosts}) {
    final Uri? u = Uri.tryParse(url);
    if (u == null) {
      throw BlockedUrlException('无法解析的地址', url);
    }
    final String scheme = u.scheme.toLowerCase();
    if (!_allowedSchemes.contains(scheme)) {
      throw BlockedUrlException('协议不允许（只允许 http/https）', url);
    }
    if (!u.hasAuthority) {
      throw BlockedUrlException('缺少主机', url);
    }
    final String host = u.host.toLowerCase();
    if (host.isEmpty) {
      throw BlockedUrlException('主机为空', url);
    }

    // 白名单优先：命中即可放行（但仍会继续做私网检查，
    // 避免「白名单里写了内网地址」这种配置错误）
    if (allowedHosts != null && allowedHosts.isNotEmpty) {
      final bool ok = allowedHosts
          .map((String h) => h.toLowerCase())
          .any((String h) => host == h || host.endsWith('.$h'));
      if (!ok) {
        throw BlockedUrlException('主机不在允许列表内', url);
      }
    }

    if (_blockedNames.contains(host) ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal')) {
      throw BlockedUrlException('禁止访问本机/本地网络主机', url);
    }

    // IP 字面量：先尝试解析，再按网段判断。
    // 这里必须区分「解析成功」与「根本没解析成 IP」，否则会把
    // 8.8.8.8 这类**合法公网 IP** 一起误杀。
    final int? v4 = parseIpv4(host);
    if (v4 != null) {
      if (isBlockedIpv4(v4)) {
        throw BlockedUrlException('禁止访问环回/私有/保留地址', url);
      }
      return; // 合法公网 IPv4
    }
    if (host.contains(':')) {
      if (isBlockedIpv6(host)) {
        throw BlockedUrlException('禁止访问环回/私有/保留地址', url);
      }
      return; // 合法公网 IPv6
    }
    // 走到这里说明**不是可解析的 IP**。若它「看起来像 IP 字面量」
    // （只由数字/点/冒号/十六进制字符组成），说明是「想写 IP 却写错」，
    // 一律拒绝（fail-closed）——`http://999.999.999.999/`、`http://256.1.1.1/`
    // 不拦的话会被当成「域名」放行，而某些底层解析器会宽容地按 IP 处理。
    if (_looksLikeIpLiteral(host)) {
      throw BlockedUrlException('非法的 IP 字面量', url);
    }
  }

  /// 主机是否「看起来是 IP 字面量」而非域名：只含数字、点、冒号、
  /// 十六进制字符，且不含字母 g-z（域名至少会有一个字母）。
  static bool _looksLikeIpLiteral(String host) {
    if (host.isEmpty) {
      return false;
    }
    final String t = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    if (t.isEmpty) {
      return false;
    }
    // 允许出现的字符：0-9 . : a-f x（0x 前缀）以及 IPv6 的 zone id 前缀 %
    for (final int c in t.codeUnits) {
      final bool digit = c >= 0x30 && c <= 0x39;
      final bool hex = (c >= 0x61 && c <= 0x66) || c == 0x78; // a-f, x
      final bool sep = c == 0x2E || c == 0x3A || c == 0x25; // . : %
      if (!digit && !hex && !sep) {
        return false;
      }
    }
    return true;
  }

  /// 校验通过返回 true，不通过返回 false（不打异常，便于调用方自定义处理）
  static bool isAllowed(String url, {Set<String>? allowedHosts}) {
    try {
      check(url, allowedHosts: allowedHosts);
      return true;
    } on BlockedUrlException {
      return false;
    }
  }

  /// 把主机名按 IPv4 解析成 32 位整数；不是 IPv4 字面量则返回 null。
  ///
  /// 兼容各种等价写法（这是本模块的关键，见文件头说明）：
  ///   `a.b.c.d`、`a.b.c`、`a.b`、`a`（省略的段按低位补齐）、
  ///   十进制整数、`0x` 十六进制、前导 0 的八进制。
  static int? parseIpv4(String host) {
    if (host.isEmpty) {
      return null;
    }
    // 允许 `127.1` 这种省略写法：把最后一段当作「剩余 24 位」
    final List<String> parts = host.split('.');
    if (parts.length > 4) {
      return null;
    }
    final List<int> nums = <int>[];
    for (int i = 0; i < parts.length; i++) {
      final int? n = _parseIpv4Part(parts[i]);
      if (n == null) {
        return null;
      }
      nums.add(n);
    }
    // 最后一段（或唯一一段）承载其余位
    final int last = nums.removeLast();
    int value = 0;
    for (final int n in nums) {
      if (n > 255) {
        return null;
      }
      value = (value << 8) | n;
    }
    final int remainingBytes = 4 - nums.length - 1;
    if (remainingBytes < 0) {
      return null;
    }
    final int maxLast = remainingBytes >= 3
        ? 0xFFFFFFFF
        : (1 << (8 * (remainingBytes + 1))) - 1;
    if (last > maxLast) {
      return null;
    }
    value = (value << (8 * (remainingBytes + 1))) | last;
    return value & 0xFFFFFFFF;
  }

  /// 解析单个 IPv4 片段：支持十进制 / 0x 十六进制 / 前导 0 八进制
  static int? _parseIpv4Part(String s) {
    if (s.isEmpty) {
      return null;
    }
    final String t = s.toLowerCase();
    int? v;
    if (t.startsWith('0x')) {
      v = int.tryParse(t.substring(2), radix: 16);
    } else if (t.length > 1 && t.startsWith('0')) {
      // 前导 0 按八进制（与 inet_aton 行为一致）
      v = int.tryParse(t.substring(1), radix: 8);
    } else {
      v = int.tryParse(t);
    }
    if (v == null || v < 0) {
      return null;
    }
    return v;
  }

  /// 私网 / 环回 / 保留的 IPv4 段
  static bool isBlockedIpv4(int v) {
    final int a = (v >> 24) & 0xFF;
    final int b = (v >> 16) & 0xFF;
    // 0.0.0.0/8        本网络
    if (a == 0) {
      return true;
    }
    // 10.0.0.0/8       私有
    if (a == 10) {
      return true;
    }
    // 127.0.0.0/8      环回
    if (a == 127) {
      return true;
    }
    // 100.64.0.0/10    运营商级 NAT
    if (a == 100 && b >= 64 && b <= 127) {
      return true;
    }
    // 169.254.0.0/16   链路本地（云元数据 169.254.169.254 就在此段）
    if (a == 169 && b == 254) {
      return true;
    }
    // 172.16.0.0/12    私有
    if (a == 172 && b >= 16 && b <= 31) {
      return true;
    }
    // 192.0.0.0/24     保留；192.0.2.0/24 文档用
    if (a == 192 && (b == 0 || b == 2)) {
      return true;
    }
    // 192.168.0.0/16   私有
    if (a == 192 && b == 168) {
      return true;
    }
    // 198.18.0.0/15    基准测试保留
    if (a == 198 && (b == 18 || b == 19)) {
      return true;
    }
    // 198.51.100.0/24、203.0.113.0/24 文档用
    if (a == 198 && b == 51) {
      return true;
    }
    if (a == 203 && b == 0) {
      return true;
    }
    // 224.0.0.0/4      组播
    if (a >= 224 && a <= 239) {
      return true;
    }
    // 240.0.0.0/4      保留（含 255.255.255.255 广播）
    if (a >= 240) {
      return true;
    }
    return false;
  }

  /// 私网 / 环回 / 保留的 IPv6
  static bool isBlockedIpv6(String host) {
    // 去掉方括号与 zone id（fe80::1%eth0）
    String s = host;
    if (s.startsWith('[') && s.endsWith(']')) {
      s = s.substring(1, s.length - 1);
    }
    final int pct = s.indexOf('%');
    if (pct >= 0) {
      s = s.substring(0, pct);
    }
    final String t = s.toLowerCase();
    if (t.isEmpty) {
      return true;
    }
    // IPv4 映射与兼容写法：取后 32 位按 IPv4 判断
    for (final String prefix in <String>['::ffff:', '::']) {
      if (t.startsWith(prefix) && t.contains('.')) {
        final int? v4 = parseIpv4(t.substring(prefix.length));
        if (v4 != null) {
          return isBlockedIpv4(v4);
        }
      }
    }
    final List<int>? g = _groupsOfIpv6(t);
    if (g == null) {
      return false;
    }
    // 未指定（::）与环回（::1）——**必须按展开后的 8 组判断**，
    // 否则 `0:0:0:0:0:0:0:1` 这种全写形式会漏过去（实测踩到过）。
    bool allZeroExceptLast(int last) {
      for (int i = 0; i < 7; i++) {
        if (g[i] != 0) {
          return false;
        }
      }
      return g[7] == last;
    }

    if (allZeroExceptLast(0) || allZeroExceptLast(1)) {
      return true;
    }
    final int first = g[0];
    // fc00::/7 唯一本地
    if ((first & 0xFE00) == 0xFC00) {
      return true;
    }
    // fe80::/10 链路本地
    if ((first & 0xFFC0) == 0xFE80) {
      return true;
    }
    // ff00::/8 组播
    if ((first & 0xFF00) == 0xFF00) {
      return true;
    }
    // 2001:db8::/32 文档用
    if (g[0] == 0x2001 && g[1] == 0x0DB8) {
      return true;
    }
    return false;
  }

  /// 展开 IPv6 为 8 组 16 位；无法解析返回 null
  static List<int>? _groupsOfIpv6(String t) {
    final List<String> halves = t.split('::');
    if (halves.length > 2) {
      return null;
    }
    List<int> parse(String part) {
      final List<int> out = <int>[];
      for (final String g in part.split(':')) {
        if (g.isEmpty) {
          continue;
        }
        final int? v = int.tryParse(g, radix: 16);
        if (v == null) {
          return <int>[];
        }
        out.add(v);
      }
      return out;
    }

    final List<int> head = parse(halves[0]);
    if (halves.length == 1) {
      return head.length == 8 ? head : null;
    }
    final List<int> tail = parse(halves[1]);
    final int fill = 8 - head.length - tail.length;
    if (fill < 0) {
      return null;
    }
    return <int>[...head, ...List<int>.filled(fill, 0, growable: false), ...tail];
  }
}