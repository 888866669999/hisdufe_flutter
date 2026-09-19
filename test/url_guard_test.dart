/// SSRF 防护测试：URL / 主机校验
///
/// 这些断言锁的是**真实存在的绕过手法**，不是想象出来的：
/// IP 有大量等价写法（十进制、十六进制、八进制、省略段、IPv6 映射），
/// 只做字符串匹配的实现会被它们全部绕过，而它们都指回 127.0.0.1。
/// 另外还有云元数据地址 169.254.169.254 —— 拿到它往往等于拿到云凭证。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/common/url_guard.dart';

void main() {
  group('协议', () {
    test('允许 http 与 https', () {
      expect(UrlGuard.isAllowed('http://example.com/a'), isTrue);
      expect(UrlGuard.isAllowed('https://example.com/a'), isTrue);
    });

    test('拒绝非 http/https 协议', () {
      for (final String u in <String>[
        'file:///etc/passwd',
        'ftp://example.com/x',
        'gopher://example.com/',
        'data:text/html,<script>',
        'jar:http://example.com/a!/b',
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });
  });

  group('本机与环回', () {
    test('拒绝 localhost 及其子域', () {
      for (final String u in <String>[
        'http://localhost/',
        'http://localhost:8080/x',
        'http://LOCALHOST/',
        'http://a.localhost/',
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });

    test('拒绝环回地址的各种写法（绕过重灾区）', () {
      for (final String u in <String>[
        'http://127.0.0.1/',
        'http://127.0.0.1:8080/',
        'http://127.1/', // 省略中间段
        'http://127.0.1/', // 后两段合并
        'http://2130706433/', // 十进制整数
        'http://0x7f000001/', // 十六进制
        'http://017700000001/', // 八进制
        'http://0x7f.0.0.1/', // 混合进制
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });

    test('拒绝 IPv6 环回与映射写法', () {
      for (final String u in <String>[
        'http://[::1]/',
        'http://[::ffff:127.0.0.1]/',
        'http://[0:0:0:0:0:0:0:1]/',
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });
  });

  group('私有网段', () {
    test('拒绝 RFC1918 私有地址', () {
      for (final String u in <String>[
        'http://10.0.0.1/',
        'http://10.255.255.254/',
        'http://172.16.0.1/',
        'http://172.31.255.254/',
        'http://192.168.0.1/',
        'http://192.168.1.1:8080/admin',
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });

    test('私有段的边界值判定正确（172.15 与 172.32 应放行）', () {
      expect(UrlGuard.isAllowed('http://172.15.0.1/'), isTrue);
      expect(UrlGuard.isAllowed('http://172.32.0.1/'), isTrue);
      expect(UrlGuard.isAllowed('http://172.16.0.1/'), isFalse);
      expect(UrlGuard.isAllowed('http://172.31.255.255/'), isFalse);
    });
  });

  group('保留与特殊地址', () {
    test('拒绝链路本地 / 云元数据地址', () {
      for (final String u in <String>[
        'http://169.254.169.254/latest/meta-data/', // AWS/GCP/Azure 元数据
        'http://169.254.0.1/',
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });

    test('拒绝 0.0.0.0/8 与广播/组播/保留段', () {
      for (final String u in <String>[
        'http://0.0.0.0/',
        'http://255.255.255.255/',
        'http://224.0.0.1/',
        'http://240.0.0.1/',
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });

    test('拒绝运营商级 NAT 与文档保留段', () {
      for (final String u in <String>[
        'http://100.64.0.1/',
        'http://192.0.2.1/',
        'http://198.18.0.1/',
        'http://198.51.100.1/',
        'http://203.0.113.1/',
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });

    test('拒绝 IPv6 唯一本地与链路本地', () {
      for (final String u in <String>[
        'http://[fc00::1]/',
        'http://[fd12:3456::1]/',
        'http://[fe80::1]/',
        'http://[ff02::1]/',
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });
  });

  group('公网地址放行', () {
    test('普通域名与公网 IP 允许', () {
      for (final String u in <String>[
        'https://www.sdufe.edu.cn/xyfw/zxxl.htm',
        'http://jw.sdufe.edu.cn/jsxsd/',
        'https://example.com/x.jpg',
        'https://8.8.8.8/',
        'https://1.1.1.1/',
      ]) {
        expect(UrlGuard.isAllowed(u), isTrue, reason: u);
      }
    });
  });

  group('主机白名单', () {
    const Set<String> allow = <String>{'sdufe.edu.cn'};

    test('白名单内的域名与子域允许', () {
      expect(UrlGuard.isAllowed('https://sdufe.edu.cn/a', allowedHosts: allow),
          isTrue);
      expect(
          UrlGuard.isAllowed('https://www.sdufe.edu.cn/a', allowedHosts: allow),
          isTrue);
    });

    test('白名单外的域名拒绝', () {
      expect(UrlGuard.isAllowed('https://evil.com/a', allowedHosts: allow),
          isFalse);
      expect(UrlGuard.isAllowed('https://notsdufe.edu.cn/a', allowedHosts: allow),
          isFalse);
    });

    test('后缀伪装必须被拒绝（sdufe.edu.cn.evil.com）', () {
      for (final String u in <String>[
        'https://sdufe.edu.cn.evil.com/a',
        'https://www.sdufe.edu.cn.evil.com/a',
      ]) {
        expect(UrlGuard.isAllowed(u, allowedHosts: allow), isFalse, reason: u);
      }
    });

    test('即使白名单命中，内网地址仍被拒绝（防配置错误）', () {
      // 假设有人误把内网地址写进白名单，私网检查仍然生效
      expect(
          UrlGuard.isAllowed('http://127.0.0.1/a',
              allowedHosts: <String>{'127.0.0.1'}),
          isFalse);
      expect(
          UrlGuard.isAllowed('http://192.168.1.1/a',
              allowedHosts: <String>{'192.168.1.1'}),
          isFalse);
    });
  });

  group('畸形输入不崩', () {
    test('空串、无主机、非法地址返回拒绝而不是抛异常', () {
      for (final String u in <String>[
        '',
        'http://',
        'not a url',
        'http:///path',
        '://example.com',
        'http://999.999.999.999/',
        'http://256.1.1.1/',
      ]) {
        expect(UrlGuard.isAllowed(u), isFalse, reason: u);
      }
    });

    test('check() 对非法地址抛出 BlockedUrlException', () {
      expect(
        () => UrlGuard.check('http://127.0.0.1/'),
        throwsA(isA<BlockedUrlException>()),
      );
    });
  });

  group('IPv4 解析等价性', () {
    test('各种写法解析到同一个 32 位值', () {
      final int? a = UrlGuard.parseIpv4('127.0.0.1');
      expect(a, isNotNull);
      for (final String s in <String>[
        '127.1',
        '2130706433',
        '0x7f000001',
        '017700000001',
        '0x7f.0.0.1',
        '127.0.1',
      ]) {
        expect(UrlGuard.parseIpv4(s), a, reason: s);
      }
    });

    test('非 IPv4 字面量返回 null（域名不该被当成 IP）', () {
      expect(UrlGuard.parseIpv4('example.com'), isNull);
      expect(UrlGuard.parseIpv4('www.sdufe.edu.cn'), isNull);
      expect(UrlGuard.parseIpv4(''), isNull);
    });
  });
}