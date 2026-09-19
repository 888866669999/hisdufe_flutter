/// 用户头像：本地保存、读取、清除。
///
/// ===== 存哪里 =====
/// 复制到应用文档目录下的 `avatar/`，而不是存用户选中的那个原始路径。
/// 原因很实际：相册里的那张图随时可能被用户删掉或移动，而系统给的
/// content:// URI 也**不带持久读权限**（重启后就打不开了）——
/// 直接记路径的做法会在某次重启后让头像变成空白，且原因极难联想。
/// 复制一份（并缩到合理尺寸）之后，头像就是应用自己的资源了。
///
/// ===== 为什么只留一个文件 =====
/// 头像只有一个当前值。用固定文件名 `avatar.png` 覆盖写入，
/// 既省去清理逻辑，也不会积累垃圾文件。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart' show FileImage;
import 'package:path_provider/path_provider.dart';

class AvatarStore {
  /// 固定文件名（见类文档：头像只有一个当前值）
  static const String _fileName = 'avatar.png';

  /// 缓存文件的尺寸上限（正方形边长，像素）。
  ///
  /// 取 512 是因为：屏上最大也就显示到 100dp 上下，512 在 3x 屏上也够；
  /// 而用户从相册选的原图动辄 4000×3000（十几 MB），直接存会白占空间，
  /// 每次进页面解码它还要卡一下。
  static const int maxSide = 512;

  static File? _cached;

  /// 测试注入的存储目录。
  ///
  /// 为什么留这个口子：`getApplicationDocumentsDirectory()` 依赖平台通道，
  /// 在单测里要么起一堆桩、要么直接失败。把「目录从哪来」抽成一个可替换的
  /// 变量后，测试就能指向临时目录 —— 于是存取逻辑本身**真的**被测到了
  /// （覆盖写入、删除、缓存失效这些正是容易出错的地方）。
  static Directory? _overrideDir;

  @visibleForTesting
  static void setDirectoryForTest(Directory? dir) {
    _overrideDir = dir;
    _cached = null;
  }

  static Future<Directory> _dir() async {
    final Directory? injected = _overrideDir;
    if (injected != null) {
      if (!await injected.exists()) {
        await injected.create(recursive: true);
      }
      return injected;
    }
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory d = Directory('${base.path}/avatar');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  /// 当前头像文件；未设置时返回 null。
  ///
  /// 有内存缓存：这个方法会被头组件在每帧构建时调用，
  /// 每次都去 `exists()` 是同步 IO，会拖慢滚动。
  static Future<File?> current() async {
    final File? hit = _cached;
    if (hit != null) {
      return hit;
    }
    final Directory d = await _dir();
    final File f = File('${d.path}/$_fileName');
    if (!await f.exists()) {
      return null;
    }
    _cached = f;
    return f;
  }

  /// 同步版本，供已经确认过状态的调用方使用（如 `Image.file` 的构建）。
  static File? currentSync() => _cached;

  /// 清掉 Flutter 图片缓存里针对该文件的解码结果。
  ///
  /// ===== 为什么必须做（「改完头像要重启才生效」的根因）=====
  /// `Image.file` 内部用的是 `FileImage`，而它的相等性判断**只看文件路径**、
  /// 不看内容。我们的头像永远是同一个 `avatar.png`（覆盖写入），路径从不
  /// 变化 —— 于是换完之后 Flutter 的 ImageCache 认为「还是那张图」，
  /// 直接返回上一次的解码结果，界面纹丝不动，**必须杀进程重进**才更新。
  ///
  /// 给 `Image` 传 widget key 是没用的：那只影响 widget 树的重用，
  /// 连不到 ImageCache 的键上（ImageCache 的键是 ImageProvider 本身）。
  /// 正确做法就是在换图后显式把旧条目淘汰掉。
  static Future<void> evictImageCache(File file) async {
    try {
      await FileImage(file).evict();
    } catch (_) {
      // 淘汰失败不影响后续写入：最坏情况是这一次没刷新
    }
  }

  /// 写入新头像（覆盖旧的）。返回写入后的文件。
  static Future<File> save(Uint8List bytes) async {
    final Directory d = await _dir();
    final File f = File('${d.path}/$_fileName');

    // 先淘汰旧缓存，再写文件。顺序很重要：
    // 若先写、后淘汰，中间若发生重建（写入与淘汰都是异步的），
    // 界面可能先按旧缓存画一帧新文件的内容、再被淘汰重画，出现闪烁。
    await evictImageCache(f);

    // 先写临时文件再改名：中途失败（磁盘满、进程被杀）时，
    // 不会留下一个半截的图导致头像变成损坏的图。
    final File tmp = File('${d.path}/$_fileName.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await f.exists()) {
      await f.delete();
    }
    final File out = await tmp.rename(f.path);
    _cached = out;
    return out;
  }

  /// 删除头像（回到默认）。已无头像时也不报错。
  static Future<void> clear() async {
    final Directory d = await _dir();
    final File f = File('${d.path}/$_fileName');
    // 删之前也淘汰一次：留着旧条目没有意义，而且用户删掉后若立刻又设一张
    // 新图，残留条目理论上可能被命中（表现为「换了个寂寞」）。
    await evictImageCache(f);
    if (await f.exists()) {
      await f.delete();
    }
    _cached = null;
  }

  /// 启动时预热缓存，避免第一次进「我的」页时才做同步 IO。
  static Future<void> warmUp() async {
    await current();
  }
}
