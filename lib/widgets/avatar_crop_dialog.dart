/// 头像裁切弹窗：圆形取景框，拖动选位 + 双指缩放。
///
/// ===== 为什么自己做，而不是用 image_cropper 之类的插件 =====
/// 这个项目在原生插件上已反复受挫（device_calendar、permission_handler、
/// flutter_local_notifications 都因 AGP/compileSdk 兼容问题回退过），
/// 而裁切本身不需要原生能力：它只是「在图片上取一个正方形区域」。
/// 少一个原生依赖，就少一条会随 SDK 升级断掉的风险。
///
/// ===== 上一版为什么裁出来和预览完全不同（已修）=====
/// 上一版用 `InteractiveViewer` + `FittedBox` 显示图片，裁剪时把
/// `TransformationController` 的逆矩阵直接当成「图片像素坐标」。
/// 但那个矩阵作用的对象是 **FittedBox（尺寸就是取景框 side×side）**，
/// 不是图片本身 —— FittedBox 内部的 cover 缩放与居中偏移**不在**这个矩阵里。
/// 于是逆变换算出的是一组 0..side 的坐标，被当成 0..4000 的图片像素去裁，
/// 结果永远是图片左上角的一小块。
///
/// 现在改成：不用 InteractiveViewer，自己维护「缩放倍率 + 偏移」，
/// 用 [CropGeometry] 统一做换算，并且**预览与裁剪调用同一个 sourceRect**。
/// 只要用的是同一个函数，两者就不可能不一致 —— 这类 bug 从结构上被排除。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/glass_kit.dart';
import '../theme/theme.dart';

/// 取景几何（纯逻辑，便于单测）
///
/// 坐标系统一约定：
///   - **取景框坐标系**：原点在取景框左上角，范围 `0..frameSide`；
///   - **图片像素坐标系**：原点在图片左上角，范围 `0..imageWidth/Height`。
///
/// `scale` 表示「1 个图片像素显示成多少逻辑像素」，
/// `offset` 表示「图片左上角在取景框坐标系里的位置」。
/// 于是图片上的点 P 显示在取景框坐标 `P * scale + offset` 处。
class CropGeometry {
  CropGeometry({
    required this.imageWidth,
    required this.imageHeight,
    required this.frameSide,
  });

  final double imageWidth;
  final double imageHeight;
  final double frameSide;

  /// 最大放大倍率（相对于「铺满取景框」那一档）
  static const double maxZoom = 6.0;

  bool get isValid =>
      imageWidth > 0 && imageHeight > 0 && frameSide > 0;

  /// 让图片刚好铺满取景框所需的倍率（cover 语义）。
  ///
  /// 取两者较大值：宽图按宽度铺、长图按高度铺，结果都是「铺满且不留空」。
  double get coverScale {
    if (!isValid) {
      return 1;
    }
    return math.max(frameSide / imageWidth, frameSide / imageHeight);
  }

  double get maxScale => coverScale * maxZoom;

  double clampScale(double scale) => scale.clamp(coverScale, maxScale);

  /// 指定倍率下把图片居中所需的偏移
  Offset centeredOffset(double scale) => Offset(
        (frameSide - imageWidth * scale) / 2,
        (frameSide - imageHeight * scale) / 2,
      );

  /// 把偏移夹住，保证图片始终**覆盖**取景框（不露出空白）。
  ///
  /// 这是「取景框内永远有图可裁」的前提：夹住之后
  /// [sourceRect] 必定落在图片范围内。
  Offset clampOffset(Offset offset, double scale) {
    double axis(double v, double shown) {
      if (shown <= frameSide) {
        // 理论上不会发生（scale 下界就是 coverScale），保险起见居中
        return (frameSide - shown) / 2;
      }
      // 图片比框大：允许拖动的范围是 [frameSide - shown, 0]
      return v.clamp(frameSide - shown, 0.0);
    }

    return Offset(
      axis(offset.dx, imageWidth * scale),
      axis(offset.dy, imageHeight * scale),
    );
  }

  /// 取景框内对应的**图片像素**区域。
  ///
  /// ===== 这是预览与裁剪的唯一共同来源 =====
  /// 预览把它画到 `frameSide` 见方的画布上；裁剪把它画到输出边长见方的
  /// 画布上。同一份 `src`、不同的目标矩形 —— 因此「看到的」与「裁出的」
  /// 必然一致。
  Rect sourceRect(double scale, Offset offset) {
    if (scale <= 0) {
      return Rect.zero;
    }
    // 取景框的四条边（框坐标 0 与 frameSide）反解到图片坐标：
    //   框坐标 = 图片坐标 * scale + offset
    //   ⇒ 图片坐标 = (框坐标 - offset) / scale
    return Rect.fromLTRB(
      (0 - offset.dx) / scale,
      (0 - offset.dy) / scale,
      (frameSide - offset.dx) / scale,
      (frameSide - offset.dy) / scale,
    );
  }
}

class AvatarCropDialog extends StatefulWidget {
  const AvatarCropDialog({
    required this.imageBytes,
    this.outputSide = 512,
    super.key,
  });

  /// 用户选中的原图字节
  final Uint8List imageBytes;

  /// 输出正方形边长（像素）。默认与 [AvatarStore.maxSide] 一致。
  final int outputSide;

  @override
  State<AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<AvatarCropDialog> {
  ui.Image? _image;
  String _error = '';

  /// 取景框边长（逻辑像素），由布局给出
  double _frameSide = 0;

  /// 几何换算器（图片与框尺寸就绪后创建）
  CropGeometry? _geo;

  /// 1 个图片像素显示成多少逻辑像素
  double _scale = 1;

  /// 图片左上角在取景框坐标里的位置
  Offset _offset = Offset.zero;

  // 手势开始时的快照（用于换算，避免逐帧累积误差）
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(widget.imageBytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
      _initTransform();
    } catch (_) {
      if (!mounted) {
        return;
      }
      // 常见于「用户选的其实不是图片」（改了扩展名的文件）
      setState(() => _error = '这张图无法读取，请换一张');
    }
  }

  /// 把变换重置为「铺满取景框并居中」。
  ///
  /// 图片尺寸或取景框尺寸变化时都要重来一次（后者发生在旋转屏幕时）。
  void _initTransform() {
    final ui.Image? img = _image;
    if (img == null || _frameSide <= 0) {
      return;
    }
    final CropGeometry geo = CropGeometry(
      imageWidth: img.width.toDouble(),
      imageHeight: img.height.toDouble(),
      frameSide: _frameSide,
    );
    if (!geo.isValid) {
      return;
    }
    _geo = geo;
    _scale = geo.coverScale;
    _offset = geo.centeredOffset(_scale);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = d.localFocalPoint;
  }

  /// 拖动 / 捏合的统一处理。
  ///
  /// 用 `onScale*` 一套手势同时覆盖两者：单指时 `details.scale == 1`，
  /// 只剩焦点位移，效果就是平移；双指时才有缩放。
  ///
  /// 缩放的中心按「**手势开始时焦点下的那个图片点，始终留在当前焦点下**」
  /// 来解算 —— 这是图片查看器的标准做法，符合直觉（手指按住哪里，
  /// 那里就钉住不动）。
  void _onScaleUpdate(ScaleUpdateDetails d) {
    final CropGeometry? geo = _geo;
    final ui.Image? img = _image;
    if (geo == null || img == null) {
      return;
    }

    final double newScale = geo.clampScale(_startScale * d.scale);

    // 手势开始时焦点对应的图片点：
    //   起始焦点 = P * startScale + startOffset  ⇒  P = (起始焦点 - startOffset) / startScale
    final Offset imgPoint = (_startFocal - _startOffset) / _startScale;

    // 要求它此刻仍落在当前焦点下：当前焦点 = P * newScale + newOffset
    final Offset newOffset = geo.clampOffset(
      d.localFocalPoint - imgPoint * newScale,
      newScale,
    );

    setState(() {
      _scale = newScale;
      _offset = newOffset;
    });
  }

  /// 按当前取景把内容画成一张正方形位图。
  ///
  /// 与预览用的是同一个 [CropGeometry.sourceRect]，只是目标矩形从
  /// 「取景框大小」换成「输出边长」—— 因此输出的是**原图分辨率的真实像素**，
  /// 而不是把屏幕上的缩略图截下来放大。
  Future<Uint8List?> _crop() async {
    final ui.Image? img = _image;
    final CropGeometry? geo = _geo;
    if (img == null || geo == null) {
      return null;
    }
    final Rect src = geo.sourceRect(_scale, _offset);

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final double side = widget.outputSide.toDouble();
    final Canvas canvas = Canvas(recorder);
    canvas.drawImageRect(
      img,
      src,
      Rect.fromLTWH(0, 0, side, side),
      Paint()..filterQuality = FilterQuality.high,
    );
    final ui.Picture pic = recorder.endRecording();
    final ui.Image out = await pic.toImage(widget.outputSide, widget.outputSide);
    pic.dispose();

    final ByteData? bd = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    return bd?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: GlassKit.surface(
          context,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
                child: Row(
                  children: <Widget>[
                    Text('调整头像',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        )),
                    const Spacer(),
                    Text('拖动选位 · 双指缩放',
                        style: TextStyle(
                            fontSize: 11, color: context.textTertiary)),
                  ],
                ),
              ),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(_error,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13, color: context.textSecondary)),
                )
              else if (_image == null)
                const Padding(
                  padding: EdgeInsets.all(48),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    // 取景框取「可用宽度」与「屏高的 42%」中较小者，
                    // 保证小屏上弹窗不超出屏幕
                    final double side = math.min(
                      c.maxWidth - 32,
                      MediaQuery.sizeOf(context).height * 0.42,
                    );
                    if (side != _frameSide) {
                      _frameSide = side;
                      // 尺寸变了要重算几何（旋转屏幕等）。
                      // 布局阶段不能 setState，延到帧后。
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(_initTransform);
                        }
                      });
                    }
                    // _geo 还没就绪时不画（等上面那个回调）
                    final CropGeometry? geo = _geo;
                    if (geo == null) {
                      return SizedBox(width: side, height: side);
                    }
                    return SizedBox(
                      width: side,
                      height: side,
                      child: GestureDetector(
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        child: CustomPaint(
                          painter: _CropPainter(
                            image: _image!,
                            src: geo.sourceRect(_scale, _offset),
                            frameSide: side,
                            maskColor:
                                Colors.black.withValues(alpha: 0.55),
                            ringColor:
                                Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    _pillButton(
                      context,
                      label: '取消',
                      onTap: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 10),
                    _pillButton(
                      context,
                      label: '确认',
                      primary: true,
                      onTap: _image == null
                          ? null
                          : () async {
                              final Uint8List? out = await _crop();
                              if (!context.mounted) {
                                return;
                              }
                              Navigator.pop(context, out);
                            },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pillButton(
    BuildContext context, {
    required String label,
    required VoidCallback? onTap,
    bool primary = false,
  }) {
    final bool enabled = onTap != null;
    final Color fg = !enabled
        ? context.textTertiary
        : (primary
            ? Theme.of(context).colorScheme.onPrimary
            : context.textPrimary);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary
              ? (enabled
                  ? Theme.of(context).colorScheme.primary
                  : context.textTertiary.withValues(alpha: 0.3))
              : Colors.white.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: fg)),
      ),
    );
  }
}

/// 取景预览：把 `src`（图片像素区域）画进取景框，圆外压暗。
///
/// 刻意**不用** `RawImage`/`FittedBox`/`InteractiveViewer` 这些 widget：
/// 它们各自带一套布局与变换逻辑，叠在一起时「屏幕上看到的」与
/// 「代码以为的」很容易对不上（这正是上一版裁错区域的原因）。
/// 直接 `drawImageRect` 让绘制路径与裁剪路径完全同源。
class _CropPainter extends CustomPainter {
  const _CropPainter({
    required this.image,
    required this.src,
    required this.frameSide,
    required this.maskColor,
    required this.ringColor,
  });

  final ui.Image image;

  /// 要在框内显示的图片像素区域（由 [CropGeometry.sourceRect] 给出）
  final Rect src;

  final double frameSide;
  final Color maskColor;
  final Color ringColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect dst = Rect.fromLTWH(0, 0, frameSide, frameSide);

    // 图片：把 src 铺满取景框。
    // filterQuality 用 medium：拖动/缩放时每帧都要重采样，
    // high 在这个尺寸下收益很小却明显更耗。
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // 圆外压暗：even-odd 用「整个方形 + 内切圆」挖出中间的圆
    final Path mask = Path()
      ..addRect(Offset.zero & size)
      ..addOval(dst)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(mask, Paint()..color = maskColor);

    // 圆形描边
    canvas.drawOval(
      dst.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ringColor,
    );
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      old.image != image ||
      old.src != src ||
      old.frameSide != frameSide ||
      old.maskColor != maskColor ||
      old.ringColor != ringColor;
}
