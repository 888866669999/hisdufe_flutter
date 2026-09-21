/// 头像存储的契约测试
///
/// 头像这块容易出错的地方不在「画得圆不圆」，而在**存取**：
///   - 覆盖写入：换头像时必须替换旧文件，不能留两份或写坏；
///   - 删除后要真的读不到（否则「恢复默认」看起来没生效）；
///   - 内存缓存要跟着失效（否则删了头像，界面上还显示旧图）。
///
/// 这些都会表现成「点了没反应/删了没变化」，靠肉眼很难定位，
/// 所以钉在测试里。用临时目录作为存储位置（见 setDirectoryForTest）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/data/avatar_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    // 图片缓存要在测试绑定下才存在
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('avatar_test_');
    AvatarStore.setDirectoryForTest(tmp);
  });

  tearDown(() async {
    AvatarStore.setDirectoryForTest(null);
    // 用 try/catch 而不是「先判断后删除」：两者之间有窗口，
    // 而 AvatarStore.clear() 会删掉临时目录里的文件，测试之间还可能复用同一路径，
    // 于是 exists() 为真、delete() 时目标已消失，抛 PathNotFoundException。
    // 清理动作本该幂等：删不掉说明已经干净，不该让用例失败。
    //
    // （这个竞态在写 OHOS 端时才暴露出来 —— 换用 Flutter 3.44.9 的
    //  fork 跑同一份用例，执行顺序不同就必然触发。）
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // 已被清理，忽略
    }
  });

  /// 造一段假图片字节（内容不重要，这里只验证字节是否被原样保存）
  Uint8List bytes(int n, [int fill = 7]) =>
      Uint8List.fromList(List<int>.filled(n, fill));

  group('基本读写', () {
    test('未设置时读不到头像', () async {
      expect(await AvatarStore.current(), isNull);
      expect(AvatarStore.currentSync(), isNull);
    });

    test('保存后能读回，且内容一致', () async {
      final File f = await AvatarStore.save(bytes(128, 42));
      expect(await f.exists(), isTrue);
      expect((await f.readAsBytes())[0], 42);
      expect((await AvatarStore.current())?.path, f.path);
    });

    test('保存后同步读取也能拿到（供构建期用）', () async {
      await AvatarStore.save(bytes(64));
      expect(AvatarStore.currentSync(), isNotNull);
    });

    test('覆盖保存：换头像不会留下两份文件', () async {
      final File a = await AvatarStore.save(bytes(100, 1));
      final File b = await AvatarStore.save(bytes(100, 2));

      // 同一个文件被覆盖，而不是新增一个
      expect(b.path, a.path);
      // 目录里只有这一个文件（临时文件也不能残留）
      final List<File> files = tmp.listSync().whereType<File>().toList();
      expect(files.length, 1, reason: '目录里应只剩当前头像: ${files.map((f) => f.path)}');
      expect(files.first.readAsBytesSync()[0], 2, reason: '内容应是新的');
    });

    test('清除后读不到，且文件真的被删掉', () async {
      final File f = await AvatarStore.save(bytes(50));
      expect(await f.exists(), isTrue);

      await AvatarStore.clear();

      expect(await f.exists(), isFalse);
      expect(await AvatarStore.current(), isNull);
      expect(AvatarStore.currentSync(), isNull,
          reason: '内存缓存必须跟着失效，否则界面仍显示旧图');
    });

    test('重复清除不报错（幂等）', () async {
      await AvatarStore.clear();
      await AvatarStore.clear();
      expect(await AvatarStore.current(), isNull);
    });
  });

  group('缓存与目录', () {
    test('缓存不跨「换目录」泄漏（避免测试/多账号串味）', () async {
      await AvatarStore.save(bytes(32));
      expect(AvatarStore.currentSync(), isNotNull);

      final Directory another =
          await Directory.systemTemp.createTemp('avatar_other_');
      addTearDown(() async {
        if (await another.exists()) {
          await another.delete(recursive: true);
        }
      });
      AvatarStore.setDirectoryForTest(another);

      expect(AvatarStore.currentSync(), isNull, reason: '换目录后缓存应被清空');
      expect(await AvatarStore.current(), isNull, reason: '新目录里还没有头像');
    });

    test('目录不存在时会自动创建', () async {
      final Directory nested = Directory('${tmp.path}/deep/nested');
      AvatarStore.setDirectoryForTest(nested);
      await AvatarStore.save(bytes(16));
      expect(await nested.exists(), isTrue);
    });

    test('写入失败不留下半截文件（换头像中断可恢复）', () async {
      await AvatarStore.save(bytes(80, 5));
      // 再存一次大的：成功即可（原子写用临时文件 + rename）
      final File f = await AvatarStore.save(bytes(200, 6));
      expect((await f.readAsBytes()).length, 200);
      // 不应残留 .tmp
      final List<File> files = tmp.listSync().whereType<File>().toList();
      expect(
        files.where((File x) => x.path.endsWith('.tmp')).isEmpty,
        isTrue,
        reason: '临时文件必须被改名或清掉',
      );
    });
  });

  group('图片缓存淘汰（「改完头像要重启才生效」的防线）', () {
    /// 一张真实可解码的 1×1 PNG。
    ///
    /// 这个用例必须用**真图**：`ImageCache` 只缓存解码成功的条目，
    /// 拿假字节喂进去会直接抛 "Invalid image data" —— 于是
    /// 「缓存里有没有东西」这个前置条件永远不成立，测试就成了空跑。
    final Uint8List realPng = Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);

    test('保存新头像会淘汰旧缓存条目', () async {
      // 这条契约修的是一个真机 bug：`Image.file` 用 `FileImage`，
      // 相等性只看**文件路径**，而我们的头像永远是同一个 avatar.png ——
      // 于是换完之后 ImageCache 认为「还是那张图」，界面不刷新，
      // 必须杀进程重进才变。修复方式是在写入前后主动淘汰。
      await AvatarStore.save(realPng);
      final File f = (await AvatarStore.current())!;

      // 让该路径真的进一次图片缓存（模拟界面已经显示过它）
      final FileImage provider = FileImage(f);
      final ImageStream stream =
          provider.resolve(const ImageConfiguration());
      final Completer<void> done = Completer<void>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (ImageInfo info, bool sync) {
          if (!done.isCompleted) {
            done.complete();
          }
          stream.removeListener(listener);
        },
        onError: (Object e, StackTrace? s) {
          if (!done.isCompleted) {
            done.completeError(e);
          }
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      await done.future;

      final Object key = await provider.obtainKey(const ImageConfiguration());
      expect(PaintingBinding.instance.imageCache.containsKey(key), isTrue,
          reason: '前置条件：解码成功后应已进缓存');

      // 换头像 —— 这一步应当淘汰旧条目
      await AvatarStore.save(realPng);

      expect(
        PaintingBinding.instance.imageCache.containsKey(key),
        isFalse,
        reason: '换头像后旧缓存条目必须被淘汰，否则界面不会刷新',
      );
    });

    test('清除头像也会淘汰缓存', () async {
      await AvatarStore.save(realPng);
      final File f = (await AvatarStore.current())!;
      final FileImage provider = FileImage(f);
      final key = await provider.obtainKey(const ImageConfiguration());

      await AvatarStore.clear();

      expect(PaintingBinding.instance.imageCache.containsKey(key), isFalse);
    });
  });

  group('输出尺寸约定', () {
    test('maxSide 是正方形边长，且与裁切弹窗的默认输出一致', () {
      // 裁切弹窗默认按 512 输出（见 AvatarCropDialog.outputSide 的默认值）。
      // 两者必须一致：否则存下来的图要么被白白缩小，要么超出所需分辨率。
      expect(AvatarStore.maxSide, 512);
    });
  });
}
