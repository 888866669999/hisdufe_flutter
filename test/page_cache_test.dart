/// 页面缓存层：内存 / 磁盘 / 取数规则
///
/// 这些用例守的是「切 dock 不再重复请求」赖以成立的几条性质。
/// 它们都不容易靠肉眼发现 —— 比如账号隔离失效时，界面会先闪出
/// 上一个账号的数据再被网络覆盖，只有细看才察觉。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/data/page_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PageCache.clearMemoryForTest();
  });

  group('缓存 key', () {
    test('包含账号与页面名', () {
      expect(PageCache.keyOf('u1', 'scores'), 'u1|scores');
    });

    test('变体按顺序拼入（成绩按学期分片靠它）', () {
      expect(PageCache.keyOf('u1', 'scores', <String>['2025-2026-2']),
          'u1|scores|2025-2026-2');
      expect(PageCache.keyOf('u1', 'classroom', <String>['3', '5', '2']),
          'u1|classroom|3|5|2');
    });

    test('不同账号 / 不同变体互不相等', () {
      expect(PageCache.keyOf('u1', 'x'), isNot(PageCache.keyOf('u2', 'x')));
      expect(PageCache.keyOf('u1', 'x', <String>['a']),
          isNot(PageCache.keyOf('u1', 'x', <String>['b'])));
    });

    test('账号为空时用占位符，避免退化成全局共享', () {
      expect(PageCache.keyOf('', 'scores'), '_|scores');
    });
  });

  group('内存层', () {
    test('写入后可同步读到', () async {
      await PageCache.write('u1|p', '<html>1</html>');
      final CachedPage? hit = PageCache.peek('u1|p');
      expect(hit, isNotNull);
      expect(hit!.body, '<html>1</html>');
    });

    test('未写入时读不到（返回 null 而不是空对象）', () {
      expect(PageCache.peek('u1|never'), isNull);
    });

    test('覆盖写入后读到的是新内容', () async {
      await PageCache.write('u1|p', 'old');
      await PageCache.write('u1|p', 'new');
      expect(PageCache.peek('u1|p')!.body, 'new');
    });
  });

  group('CachedPage 的过期判断', () {
    test('新写的记录不算过期', () {
      final CachedPage p = CachedPage('x', DateTime.now().millisecondsSinceEpoch);
      expect(p.isStale(const Duration(hours: 1)), isFalse);
    });

    test('超出 TTL 即算过期', () {
      final CachedPage p = CachedPage(
        'x',
        DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
      );
      expect(p.isStale(const Duration(minutes: 1)), isTrue);
      expect(p.isStale(const Duration(hours: 1)), isFalse);
    });

    test('恰好等于 TTL 时不算过期（边界取「大于」而不是「大于等于」）', () {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final CachedPage p = CachedPage('x', now - 1000);
      expect(p.isStale(const Duration(seconds: 1)), isFalse);
    });
  });

  group('账号隔离', () {
    test('clearAccount 只清该账号的内存条目', () async {
      await PageCache.write('u1|scores', 'A');
      await PageCache.write('u2|scores', 'B');
      await PageCache.clearAccount('u1');
      expect(PageCache.peek('u1|scores'), isNull, reason: 'A 的缓存应被清掉');
      expect(PageCache.peek('u2|scores'), isNotNull, reason: '不该清 B 的缓存');
    });

    test('清账号时按前缀匹配，不会误伤名字相近的账号', () async {
      await PageCache.write('u1|scores', 'A');
      await PageCache.write('u12|scores', 'C');
      await PageCache.clearAccount('u1');
      expect(PageCache.peek('u1|scores'), isNull);
      expect(PageCache.peek('u12|scores'), isNotNull,
          reason: 'key 前缀是 "u1|"，"u12|" 不该被命中');
    });

    test('空账号调用是安全的空操作', () async {
      await PageCache.write('u1|scores', 'A');
      await PageCache.clearAccount('');
      expect(PageCache.peek('u1|scores'), isNotNull);
    });
  });

  group('remove', () {
    test('删除单个 key 后读不到', () async {
      await PageCache.write('u1|p', 'x');
      await PageCache.remove('u1|p');
      expect(PageCache.peek('u1|p'), isNull);
    });
  });

  group('PageDataLoader', () {
    test('无缓存时走网络，并把结果写进内存层', () async {
      int fetches = 0;
      final PageDataLoader<int> loader = PageDataLoader<int>(
        key: 'u1|n',
        fetch: () async {
          fetches++;
          return '42';
        },
        parse: int.parse,
        ttl: const Duration(minutes: 1),
      );
      final PageLoadResult<int> r = await loader.load();
      expect(r.data, 42);
      expect(r.source, PageDataSource.network);
      expect(r.fromNetwork, isTrue);
      expect(fetches, 1);
      expect(PageCache.peek('u1|n')!.body, '42');
    });

    test('TTL 内二次加载走内存，**不再请求网络**（这就是切页不刷新的关键）', () async {
      int fetches = 0;
      final PageDataLoader<int> loader = PageDataLoader<int>(
        key: 'u1|n',
        fetch: () async {
          fetches++;
          return '7';
        },
        parse: int.parse,
        ttl: const Duration(minutes: 10),
      );
      await loader.load();
      final PageLoadResult<int> second = await loader.load();
      expect(second.data, 7);
      expect(second.source, PageDataSource.memory);
      expect(second.fromNetwork, isFalse);
      expect(fetches, 1, reason: 'TTL 内不该再打服务器');
    });

    test('force=true 时即使缓存新鲜也重新请求（手动刷新）', () async {
      int fetches = 0;
      final PageDataLoader<int> loader = PageDataLoader<int>(
        key: 'u1|n',
        fetch: () async {
          fetches++;
          return fetches.toString();
        },
        parse: int.parse,
        ttl: const Duration(hours: 1),
      );
      await loader.load();
      final PageLoadResult<int> forced = await loader.load(force: true);
      expect(forced.fromNetwork, isTrue);
      expect(forced.data, 2, reason: '应拿到第二次请求的结果');
      expect(fetches, 2);
    });

    test('peek 同步返回解析结果（供首帧直接渲染）', () async {
      await PageCache.write('u1|n', '99');
      final PageDataLoader<int> loader = PageDataLoader<int>(
        key: 'u1|n',
        fetch: () async => '0',
        parse: int.parse,
        ttl: const Duration(minutes: 1),
      );
      expect(loader.peek(), 99);
    });

    test('peek 在无缓存时返回 null', () {
      final PageDataLoader<int> loader = PageDataLoader<int>(
        key: 'u1|none',
        fetch: () async => '1',
        parse: int.parse,
        ttl: const Duration(minutes: 1),
      );
      expect(loader.peek(), isNull);
    });

    test('网络失败时异常上抛，且**不清掉已有缓存**', () async {
      // 构造「缓存已过期」：直接写一个很旧的时间戳。
      //
      // 不能用 `ttl: Duration.zero` 来达意 —— `isStale` 是
      // `age > ttl`，刚写的记录 age 恰好为 0，会被判成「新鲜」而根本不联网，
      // 于是这个用例测不到「联网失败」这条路径（实测踩到）。
      await PageCache.writeForTest('u1|n', '5',
          DateTime.now().subtract(const Duration(hours: 2)));
      final PageDataLoader<int> loader = PageDataLoader<int>(
        key: 'u1|n',
        fetch: () async => throw StateError('offline'),
        parse: int.parse,
        ttl: const Duration(minutes: 1),
      );
      await expectLater(loader.load(), throwsA(isA<StateError>()));
      // 关键：失败不该把旧数据丢掉 —— 界面还要靠它继续显示
      expect(PageCache.peek('u1|n'), isNotNull,
          reason: '联网失败后旧缓存必须保留，否则界面会从「有内容」变成空白');
    });

    test('解析失败的内存条目不会被当成有效缓存', () async {
      // 故意存一个解析不了的内容
      await PageCache.write('u1|n', 'not-a-number');
      int fetches = 0;
      final PageDataLoader<int> loader = PageDataLoader<int>(
        key: 'u1|n',
        fetch: () async {
          fetches++;
          return '8';
        },
        parse: int.parse,
        ttl: const Duration(hours: 1),
      );
      final PageLoadResult<int> r = await loader.load();
      expect(r.data, 8);
      expect(fetches, 1, reason: '内存解析失败后应回落到网络');
    });
  });

  group('磁盘层的健壮性', () {
    /// 磁盘测试用一个临时目录替掉默认目录：
    /// 默认目录要 path_provider 的平台通道，单测环境里没有。
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pagecache_test');
      PageCache.debugSetDirForTest(tmp);
      PageCache.clearMemoryForTest();
    });

    tearDown(() async {
      PageCache.debugSetDirForTest(null);
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('写入后能重新读出来（清掉内存层以证明读的是磁盘）', () async {
      await PageCache.write('u1|p', '<html>disk</html>');
      PageCache.clearMemoryForTest();
      final CachedPage? hit = await PageCache.readDisk('u1|p');
      expect(hit, isNotNull);
      expect(hit!.body, '<html>disk</html>');
    });

    test('读盘命中后会顺手放进内存层（同进程再读不再碰磁盘）', () async {
      await PageCache.write('u1|p', 'x');
      PageCache.clearMemoryForTest();
      expect(PageCache.peek('u1|p'), isNull);
      await PageCache.readDisk('u1|p');
      expect(PageCache.peek('u1|p'), isNotNull, reason: '应已回填内存层');
    });

    test('内容损坏时返回 null 并删掉坏文件', () async {
      await PageCache.write('u1|p', 'good');
      // 找到那个文件并写坏它
      final List<File> files = tmp
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.json'))
          .toList();
      expect(files, isNotEmpty);
      await files.first.writeAsString('{ this is not json');
      PageCache.clearMemoryForTest();

      expect(await PageCache.readDisk('u1|p'), isNull);
      // 坏文件应被删掉（否则每次进页面都白等一次 IO）
      expect(await files.first.exists(), isFalse,
          reason: '损坏的缓存文件应被清理');
    });

    test('版本号比当前高时当作不可用（不拿格式不明的数据渲染）', () async {
      await PageCache.write('u1|p', 'good');
      final List<File> files = tmp
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.json'))
          .toList();
      final Map<String, Object> bad = <String, Object>{
        'v': 999,
        'at': DateTime.now().millisecondsSinceEpoch,
        'body': 'future-format',
      };
      await files.first.writeAsString(jsonEncode(bad));
      PageCache.clearMemoryForTest();
      expect(await PageCache.readDisk('u1|p'), isNull);
    });

    test('clearAccount 也清磁盘文件', () async {
      await PageCache.write('u1|a', 'A');
      await PageCache.write('u1|b', 'B');
      await PageCache.write('u2|a', 'C');
      PageCache.clearMemoryForTest();

      await PageCache.clearAccount('u1');
      expect(await PageCache.readDisk('u1|a'), isNull);
      expect(await PageCache.readDisk('u1|b'), isNull);
      expect(await PageCache.readDisk('u2|a'), isNotNull, reason: '不该清别的账号');
    });

    test('过期的磁盘数据：不 force 时会走网络刷新', () async {
      await PageCache.write('u1|p', 'stale');
      // 手改时间戳让它过期
      final List<File> files = tmp
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.json'))
          .toList();
      final Map<String, dynamic> j =
          jsonDecode(await files.first.readAsString()) as Map<String, dynamic>;
      j['at'] = DateTime.now()
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch;
      await files.first.writeAsString(jsonEncode(j));
      PageCache.clearMemoryForTest();

      int fetches = 0;
      final PageDataLoader<String> loader = PageDataLoader<String>(
        key: 'u1|p',
        fetch: () async {
          fetches++;
          return 'fresh';
        },
        parse: (String s) => s,
        ttl: const Duration(minutes: 5),
      );
      final PageLoadResult<String> r = await loader.load();
      expect(r.data, 'fresh');
      expect(fetches, 1);
    });
  });
}
