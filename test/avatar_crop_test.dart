/// 头像取景几何的契约测试
///
/// 这组测试锁的是一个**真机上暴露过**的 bug：裁切预览与最终头像完全不同。
/// 根因是坐标换算算错了坐标系（把「取景框坐标系」的坐标当成
/// 「图片像素坐标」用），于是永远裁到图片左上角一小块。
///
/// 这里不去测 UI，而是把换算本身钉住 —— 因为这类错误在界面上看着
/// 「有个图、能拖动」，只有把结果和预期对上才看得出来。
///
/// 坐标约定（与 CropGeometry 一致）：
///   - scale：1 个图片像素显示成多少逻辑像素
///   - offset：图片左上角在取景框坐标里的位置
///   - 图片点 P 显示于 `P * scale + offset`
library;

import 'package:flutter/painting.dart' show Offset, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/widgets/avatar_crop_dialog.dart';

void main() {
  /// 一张常见的手机横拍照片：4:3 横向
  CropGeometry wide() => CropGeometry(
        imageWidth: 4000,
        imageHeight: 3000,
        frameSide: 300,
      );

  /// 一张竖拍照片：3:4 纵向
  CropGeometry tall() => CropGeometry(
        imageWidth: 3000,
        imageHeight: 4000,
        frameSide: 300,
      );

  /// 方形图（此时 cover 倍率与图片比例无关）
  CropGeometry square() => CropGeometry(
        imageWidth: 500,
        imageHeight: 500,
        frameSide: 300,
      );

  group('coverScale：让图片刚好铺满取景框', () {
    test('横向图按高度铺满（宽度会溢出）', () {
      final CropGeometry g = wide();
      // 300/4000 = 0.075，300/3000 = 0.1 → 取大的 0.1
      expect(g.coverScale, closeTo(0.1, 1e-9));
      // 显示尺寸：4000*0.1 = 400 宽（>300，溢出），3000*0.1 = 300 高（正好）
      expect(g.imageWidth * g.coverScale, greaterThan(g.frameSide));
      expect(g.imageHeight * g.coverScale, closeTo(g.frameSide, 1e-6));
    });

    test('纵向图按宽度铺满（高度会溢出）', () {
      final CropGeometry g = tall();
      // 300/3000 = 0.1，300/4000 = 0.075 → 取大的 0.1
      expect(g.coverScale, closeTo(0.1, 1e-9));
      expect(g.imageWidth * g.coverScale, closeTo(g.frameSide, 1e-6));
      expect(g.imageHeight * g.coverScale, greaterThan(g.frameSide));
    });

    test('方形图两个方向都正好铺满', () {
      final CropGeometry g = square();
      expect(g.coverScale, closeTo(300 / 500, 1e-9));
      expect(g.imageWidth * g.coverScale, closeTo(g.frameSide, 1e-6));
      expect(g.imageHeight * g.coverScale, closeTo(g.frameSide, 1e-6));
    });

    test('尺寸非法时不崩，返回 1', () {
      expect(
        CropGeometry(imageWidth: 0, imageHeight: 0, frameSide: 0).coverScale,
        1,
      );
      expect(
        CropGeometry(imageWidth: 100, imageHeight: 100, frameSide: 0).coverScale,
        1,
      );
    });
  });

  group('centeredOffset：初始居中', () {
    test('横向图左右各溢出相同的量，上下为 0', () {
      final CropGeometry g = wide();
      final double s = g.coverScale;
      final Offset o = g.centeredOffset(s);
      // 显示宽 400，框 300 → 左边距 -50（左半溢出 50）
      expect(o.dx, closeTo(-50, 1e-6));
      // 显示高 300，框 300 → 正好贴边
      expect(o.dy, closeTo(0, 1e-6));
    });

    test('纵向图上下各溢出相同的量，左右为 0', () {
      final CropGeometry g = tall();
      final double s = g.coverScale;
      final Offset o = g.centeredOffset(s);
      expect(o.dx, closeTo(0, 1e-6));
      expect(o.dy, closeTo(-50, 1e-6));
    });
  });

  group('sourceRect：预览与裁剪共用的那块区域', () {
    test('初始状态取到图片**正中**的正方形（而不是左上角）', () {
      // 这是那个 bug 的核心断言。
      // 旧实现算出的 src 是 (0,0,300,300) 之类 —— 图片的左上角，
      // 与用户看到的「正中区域」完全不同。
      final CropGeometry g = wide();
      final double s = g.coverScale;
      final Rect src = g.sourceRect(s, g.centeredOffset(s));

      // 图片 4000×3000，框是正方形 → 取到的应是 3000×3000（全高）
      expect(src.width, closeTo(3000, 1e-6));
      expect(src.height, closeTo(3000, 1e-6));
      // 水平居中：(4000-3000)/2 = 500
      expect(src.left, closeTo(500, 1e-6));
      expect(src.top, closeTo(0, 1e-6));
      expect(src.right, closeTo(3500, 1e-6));
      expect(src.bottom, closeTo(3000, 1e-6));
    });

    test('横向图的初始区域在水平方向居中，纵向取满', () {
      final CropGeometry g = wide();
      final double s = g.coverScale;
      final Rect src = g.sourceRect(s, g.centeredOffset(s));
      // 到左右两边的距离应当相等
      expect(src.left, closeTo(g.imageWidth - src.right, 1e-6));
      expect(src.top, closeTo(0, 1e-6));
      expect(src.bottom, closeTo(g.imageHeight, 1e-6));
    });

    test('纵向图的初始区域在垂直方向居中，横向取满', () {
      final CropGeometry g = tall();
      final double s = g.coverScale;
      final Rect src = g.sourceRect(s, g.centeredOffset(s));
      expect(src.top, closeTo(g.imageHeight - src.bottom, 1e-6));
      expect(src.left, closeTo(0, 1e-6));
      expect(src.right, closeTo(g.imageWidth, 1e-6));
    });

    test('永远是正方形（取景框是正方形）', () {
      // 无论怎么缩放平移，框永远是正方形 → 取到的区域也必须正方形。
      // 一旦不是，头像就会被拉伸变形。
      final CropGeometry g = wide();
      for (final double factor in <double>[1.0, 1.7, 3.0, 6.0]) {
        final double s = g.clampScale(g.coverScale * factor);
        for (final Offset o in <Offset>[
          g.centeredOffset(s),
          Offset(-10, -20),
          Offset(-100, -50),
        ]) {
          final Rect src = g.sourceRect(s, g.clampOffset(o, s));
          expect(src.width, closeTo(src.height, 1e-6),
              reason: 'scale=$s offset=$o 时取到的不是正方形');
        }
      }
    });

    test('放大后取到的区域变小（看到更小的一块）', () {
      final CropGeometry g = wide();
      final Rect base = g.sourceRect(
        g.coverScale,
        g.centeredOffset(g.coverScale),
      );
      final double s2 = g.coverScale * 2;
      final Rect zoomed = g.sourceRect(s2, g.clampOffset(g.centeredOffset(s2), s2));
      expect(zoomed.width, closeTo(base.width / 2, 1e-6));
      expect(zoomed.height, closeTo(base.height / 2, 1e-6));
    });

    test('各倍率下取到的区域都落在图片范围内', () {
      final CropGeometry g = wide();
      for (final double factor in <double>[1.0, 1.5, 2.0, 4.0, 6.0]) {
        final double s = g.clampScale(g.coverScale * factor);
        final Rect src = g.sourceRect(s, g.centeredOffset(s));
        expect(src.left, greaterThanOrEqualTo(-1e-6));
        expect(src.top, greaterThanOrEqualTo(-1e-6));
        expect(src.right, lessThanOrEqualTo(g.imageWidth + 1e-6));
        expect(src.bottom, lessThanOrEqualTo(g.imageHeight + 1e-6));
      }
    });
  });

  group('平移方向：拖动的方向要与内容移动方向一致', () {
    test('把图片向右拖 → 看到的是图片更左边的部分', () {
      final CropGeometry g = wide();
      final double s = g.coverScale;
      final Rect base = g.sourceRect(s, g.centeredOffset(s));

      // offset.dx 增大 = 图片右移 = 露出图片更靠左的内容
      final Rect moved = g.sourceRect(s, const Offset(-40, 0));
      expect(moved.left, lessThan(base.left));
    });

    test('把图片向下拖 → 看到的是图片更上边的部分', () {
      final CropGeometry g = tall();
      final double s = g.coverScale;
      final Rect base = g.sourceRect(s, g.centeredOffset(s));

      final Rect moved = g.sourceRect(s, const Offset(0, -40));
      expect(moved.top, lessThan(base.top));
    });
  });

  group('clampOffset：图片始终盖满取景框', () {
    test('横向拖动到极限时正好贴住图片边缘，不会露白', () {
      final CropGeometry g = wide();
      final double s = g.coverScale;

      // 使劲往右拖（图片右移）
      final Offset right = g.clampOffset(const Offset(9999, 0), s);
      expect(right.dx, closeTo(0, 1e-6), reason: '最多拖到图片左边缘对齐框左边缘');

      // 使劲往左拖
      final Offset left = g.clampOffset(const Offset(-9999, 0), s);
      // 显示宽 400，框 300 → 最多左移 -100
      expect(left.dx, closeTo(g.frameSide - g.imageWidth * s, 1e-6));
      expect(left.dx, closeTo(-100, 1e-6));
    });

    test('夹取后的偏移一定不会让 sourceRect 越界', () {
      final CropGeometry g = wide();
      for (final double factor in <double>[1.0, 2.5, 6.0]) {
        final double s = g.clampScale(g.coverScale * factor);
        for (final Offset wild in <Offset>[
          const Offset(1e6, 1e6),
          const Offset(-1e6, -1e6),
          const Offset(500, -500),
        ]) {
          final Rect src = g.sourceRect(s, g.clampOffset(wild, s));
          expect(src.left, greaterThanOrEqualTo(-1e-6), reason: '$wild');
          expect(src.top, greaterThanOrEqualTo(-1e-6), reason: '$wild');
          expect(src.right, lessThanOrEqualTo(g.imageWidth + 1e-6),
              reason: '$wild');
          expect(src.bottom, lessThanOrEqualTo(g.imageHeight + 1e-6),
              reason: '$wild');
        }
      }
    });
  });

  group('缩放倍率的边界', () {
    test('缩放下界是「铺满」，上界是它的 6 倍', () {
      final CropGeometry g = wide();
      expect(g.clampScale(0.0001), closeTo(g.coverScale, 1e-9));
      expect(g.clampScale(999), closeTo(g.maxScale, 1e-9));
      expect(g.maxScale, closeTo(g.coverScale * CropGeometry.maxZoom, 1e-9));
    });

    test('区间内的倍率原样保留', () {
      final CropGeometry g = wide();
      final double mid = g.coverScale * 2.5;
      expect(g.clampScale(mid), closeTo(mid, 1e-9));
    });
  });

  group('自洽性：屏幕上看的那一点，就是裁出来的那一点', () {
    test('取景框中心映射回图片，正好等于 sourceRect 的中心', () {
      // 这是「预览与裁剪一致」的数学表达，也是这次 bug 的本质：
      // 若两者不等，用户看到的中心与实际裁到的中心就不是同一个位置。
      final CropGeometry g = wide();
      for (final double factor in <double>[1.0, 1.8, 3.3, 6.0]) {
        final double s = g.clampScale(g.coverScale * factor);
        for (final Offset raw in <Offset>[
          g.centeredOffset(s),
          const Offset(-30, -10),
          const Offset(-150, 0),
        ]) {
          final Offset o = g.clampOffset(raw, s);
          final Rect src = g.sourceRect(s, o);

          // 框中心 (frameSide/2, frameSide/2) 反解到图片坐标
          final double cx = (g.frameSide / 2 - o.dx) / s;
          final double cy = (g.frameSide / 2 - o.dy) / s;

          expect(cx, closeTo(src.center.dx, 1e-6),
              reason: 'scale=$s offset=$o 时中心不重合');
          expect(cy, closeTo(src.center.dy, 1e-6),
              reason: 'scale=$s offset=$o 时中心不重合');
        }
      }
    });

    test('取景框四角映射回图片，等于 sourceRect 的四角', () {
      final CropGeometry g = tall();
      final double s = g.coverScale * 1.5;
      final Offset o = g.clampOffset(const Offset(-20, -60), s);
      final Rect src = g.sourceRect(s, o);

      Offset imagePoint(Offset framePoint) =>
          Offset((framePoint.dx - o.dx) / s, (framePoint.dy - o.dy) / s);

      expect(imagePoint(Offset.zero).dx, closeTo(src.left, 1e-6));
      expect(imagePoint(Offset.zero).dy, closeTo(src.top, 1e-6));
      expect(imagePoint(Offset(g.frameSide, g.frameSide)).dx,
          closeTo(src.right, 1e-6));
      expect(imagePoint(Offset(g.frameSide, g.frameSide)).dy,
          closeTo(src.bottom, 1e-6));
    });
  });

  group('输出尺寸与长宽比', () {
    test('输出是正方形，且取到的区域是正方形 —— 头像不会被拉伸', () {
      // sourceRect 是正方形 + 目标矩形是正方形 → 等比，不变形。
      // 若 sourceRect 不是正方形，头像会被拉扁/拉长。
      final CropGeometry g = wide();
      final Rect src = g.sourceRect(
        g.coverScale,
        g.centeredOffset(g.coverScale),
      );
      expect(src.width / src.height, closeTo(1.0, 1e-9));
    });
  });
}
