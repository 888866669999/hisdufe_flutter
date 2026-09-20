/// 页面接入缓存后的行为测试
///
/// 这些不是「缓存层自己」的测试（那在 page_cache_test.dart 里，覆盖 key、TTL、
/// 磁盘读写、损坏恢复），而是**页面用缓存的方式**是否正确 ——
/// 也就是本次改动的实质：切页不该重新联网、失败不该清掉已有内容。
///
/// 用假的 fetch（计数）驱动 [PageDataLoader]，因此完全不碰网络与 UI，
/// 跑得很快；UI 层面的验证交给真机（见 README 的实测记录）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/data/page_cache.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hisdufe_pagecache_flow');
    PageCache.debugSetDirForTest(tmp);
    PageCache.clearMemoryForTest();
  });

  tearDown(() async {
    PageCache.debugSetDirForTest(null);
    PageCache.clearMemoryForTest();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  /// 造一个受控的 loader：fetch 计数，parse 直接返回原文
  PageDataLoader<String> makeLoader({
    String key = 'u1|page',
    required Duration ttl,
    required Future<String> Function() fetch,
  }) =>
      PageDataLoader<String>(key: key, fetch: fetch, parse: (String s) => s, ttl: ttl);

  group('切页不重新联网（本次改动的核心）', () {
    test('同一页面反复进入：只有第一次联网，其余全走内存', () async {
      int fetches = 0;
      Future<String> fetch() async {
        fetches++;
        return 'body-$fetches';
      }

      // 模拟「切走再切回」四次：每次新建 loader（页面每次 initState 都会新建）
      for (int i = 0; i < 4; i++) {
        final PageLoadResult<String> r =
            await makeLoader(ttl: const Duration(minutes: 5), fetch: fetch).load();
        expect(r.data, 'body-1', reason: '第 ${i + 1} 次进入应当拿到同一份数据');
      }
      expect(fetches, 1, reason: '四次进入只该联网一次');
    });

    test('peek() 能同步拿到数据（页面首帧据此避免闪加载态）', () async {
      await makeLoader(ttl: const Duration(minutes: 5), fetch: () async => 'cached').load();
      // 模拟页面 initState：新建 loader 后立刻 peek
      final PageDataLoader<String> fresh =
          makeLoader(ttl: const Duration(minutes: 5), fetch: () async => 'x');
      expect(fresh.peek(), 'cached');
    });

    test('没有缓存时 peek() 返回 null（页面应当显示加载态）', () {
      expect(
        makeLoader(ttl: const Duration(minutes: 5), fetch: () async => 'x').peek(),
        isNull,
      );
    });

    test('超过 TTL 后再进入会真的联网', () async {
      int fetches = 0;
      Future<String> fetch() async {
        fetches++;
        return 'v$fetches';
      }

      // 用 writeForTest 造一条 10 分钟前的记录，而 TTL 是 5 分钟
      await PageCache.writeForTest(
        'u1|page',
        'old',
        DateTime.now().subtract(const Duration(minutes: 10)),
      );
      final PageLoadResult<String> r =
          await makeLoader(ttl: const Duration(minutes: 5), fetch: fetch).load();
      expect(r.data, 'v1');
      expect(r.fromNetwork, isTrue);
      expect(fetches, 1);
    });

    test('下拉刷新（force）跳过缓存直接联网', () async {
      int fetches = 0;
      Future<String> fetch() async {
        fetches++;
        return 'v$fetches';
      }

      await makeLoader(ttl: const Duration(hours: 1), fetch: fetch).load();
      expect(fetches, 1);
      // 数据还在 TTL 内，但用户主动下拉了
      final PageLoadResult<String> r =
          await makeLoader(ttl: const Duration(hours: 1), fetch: fetch).load(force: true);
      expect(r.data, 'v2');
      expect(fetches, 2, reason: '强制刷新必须真的发请求');
    });
  });

  group('刷新失败时保留已有内容', () {
    test('网络抛异常：异常向上传，但缓存内容原样保留', () async {
      // 先放一条**已过期**的缓存（过期的才最需要被保护：它可能是用户唯一的
      // 离线数据）
      await PageCache.writeForTest(
        'u1|page',
        'offline-body',
        DateTime.now().subtract(const Duration(hours: 3)),
      );

      final PageDataLoader<String> loader = makeLoader(
        ttl: const Duration(minutes: 5),
        fetch: () async => throw const SocketException('offline'),
      );

      await expectLater(loader.load(), throwsA(isA<SocketException>()));
      // 关键：load 抛异常之后，旧内容仍在（页面可以继续显示它）
      expect(PageCache.peek('u1|page')?.body, 'offline-body');
      expect(loader.peek(), 'offline-body');
    });

    test('刷新失败不会被写进缓存（避免把失败当数据存下来）', () async {
      final PageDataLoader<String> loader = makeLoader(
        ttl: const Duration(minutes: 5),
        fetch: () async => throw const SocketException('offline'),
      );
      await expectLater(loader.load(), throwsA(isA<SocketException>()));
      expect(PageCache.peek('u1|page'), isNull);
    });

    test('缓存原文解析不出来时不硬塞给页面，而是回落网络', () async {
      // 模拟「缓存文件是别的版本写的 / 内容被截断」
      await PageCache.write('u1|page', 'garbage');
      int fetches = 0;
      final PageDataLoader<int> loader = PageDataLoader<int>(
        key: 'u1|page',
        fetch: () async {
          fetches++;
          return '42';
        },
        // 只有合法的 "42" 能解析；"garbage" 抛异常
        parse: (String s) => int.parse(s),
        ttl: const Duration(minutes: 5),
      );
      final PageLoadResult<int> r = await loader.load();
      expect(r.data, 42);
      expect(fetches, 1, reason: '内存与磁盘都解析失败，应当回落网络');
    });
  });

  group('条件变化时缓存不串味', () {
    test('不同查询条件各自缓存（空教室的「条件变则换数据」）', () async {
      int fetches = 0;
      Future<PageLoadResult<String>> loadFor(String building) => PageDataLoader<String>(
            key: PageCache.keyOf('u1', 'classroom_usage', <String>['sem', 'campus', building, '0']),
            fetch: () async {
              fetches++;
              return 'usage-$building';
            },
            parse: (String s) => s,
            ttl: const Duration(minutes: 2),
          ).load();

      expect((await loadFor('A')).data, 'usage-A');
      expect((await loadFor('B')).data, 'usage-B');
      expect((await loadFor('A')).data, 'usage-A');
      expect(fetches, 2, reason: 'A 的第二次应当命中缓存，只 A、B 各联网一次');
    });

    test('换个学期就是另一份成绩，不会读到上个学期的', () async {
      Future<String> loadSemester(String sem) async {
        final PageDataLoader<String> loader = PageDataLoader<String>(
          key: PageCache.keyOf('u1', 'score_list', <String>[sem]),
          fetch: () async => 'scores-$sem',
          parse: (String s) => s,
          ttl: const Duration(minutes: 2),
        );
        return (await loader.load()).data;
      }

      expect(await loadSemester('2025-2026-1'), 'scores-2025-2026-1');
      expect(await loadSemester('2025-2026-2'), 'scores-2025-2026-2');
      // 切回第一个学期：应当是它自己的数据
      expect(await loadSemester('2025-2026-1'), 'scores-2025-2026-1');
    });
  });

  group('换账号后看不到上一个账号的数据', () {
    test('登出清缓存后，新账号进入页面必须联网', () async {
      int fetches = 0;
      Future<String> fetch() async {
        fetches++;
        return 'v$fetches';
      }

      // A 登录并缓存
      await PageDataLoader<String>(
        key: PageCache.keyOf('u1', 'profile'),
        fetch: fetch,
        parse: (String s) => s,
        ttl: const Duration(hours: 6),
      ).load();
      expect(fetches, 1);

      // 登出：AppState.clearAccountScopedState 会调这个
      await PageCache.clearAccount('u1');

      // B 登录
      final PageLoadResult<String> r = await PageDataLoader<String>(
        key: PageCache.keyOf('u2', 'profile'),
        fetch: fetch,
        parse: (String s) => s,
        ttl: const Duration(hours: 6),
      ).load();
      expect(r.data, 'v2');
      expect(fetches, 2, reason: 'B 不能命中任何缓存');
    });

    test('清缓存是幂等的（账号为空、目录不存在都不该抛）', () async {
      await PageCache.clearAccount('');
      await PageCache.clearAccount('u-not-exist');
    });
  });
}
