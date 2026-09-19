/// 把 PDF 交到用户能拿到的地方（「下载」的真正实现）。
///
/// ===== 为什么单独一个文件 =====
/// 「存哪里」在不同平台上答案不同，而且**Android 上必须走系统弹窗**：
///
///   - **Android**：走原生 `ACTION_CREATE_DOCUMENT`（见 MainActivity.kt）。
///     由系统弹窗让用户选位置（默认「下载」），全程免权限。
///     不能再用「复制进应用专属外部目录」那套 —— Android 11 起文件管理器
///     读不到 `Android/data`，用户存了也打不开。
///   - **桌面/其它平台**：没有 SAF 这套东西，就复制到应用文档目录下的
///     `exports/`，并如实把路径显示出来。
///
/// 调用方只关心「成功了/用户取消了/失败了」，不需要知道上面这些差异。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// 保存结果
class PdfSaveOutcome {
  PdfSaveOutcome(this.ok, this.cancelled, this.location, this.message);

  /// 是否保存成功
  final bool ok;

  /// 用户主动取消（不是错误，界面不该报错）
  final bool cancelled;

  /// 保存位置的可读描述（成功时有值）
  final String location;

  /// 失败原因（失败时有值）
  final String message;

  static PdfSaveOutcome success(String location) =>
      PdfSaveOutcome(true, false, location, '');

  static PdfSaveOutcome cancel() => PdfSaveOutcome(false, true, '', '');

  static PdfSaveOutcome failure(String message) =>
      PdfSaveOutcome(false, false, '', message);
}

class PdfSaver {
  /// 与 MainActivity 里的 CHANNEL 常量必须一致
  static const MethodChannel _channel =
      MethodChannel('com.sdufe.hisdufe_jw/pdf');

  /// 保存 PDF，返回结果供界面提示。
  ///
  /// [localPath] 是已经下载到沙箱的 PDF 路径（`PdfStore` 的缓存），
  /// 因此这里不会再触发一次网络下载 —— 同一份附件下载过一次就复用。
  static Future<PdfSaveOutcome> save({
    required String localPath,
    required String fileName,
  }) async {
    if (localPath.isEmpty || !File(localPath).existsSync()) {
      return PdfSaveOutcome.failure('PDF 尚未下载完成');
    }
    // 文件名来自页面解析结果，做一次清洗，避免路径分隔符注入
    final String safe = _sanitize(fileName);

    if (Platform.isAndroid) {
      try {
        final String? uri = await _channel.invokeMethod<String>('savePdf', {
          'sourcePath': localPath,
          'fileName': safe,
        });
        if (uri == null || uri.isEmpty) {
          return PdfSaveOutcome.cancel();
        }
        // 返回的是 content:// URI。它本身不适合展示给用户看，
        // 但文件名是用户选的，报出文件名最实在。
        return PdfSaveOutcome.success(safe);
      } on PlatformException catch (e) {
        if (e.code == 'NO_SOURCE') {
          return PdfSaveOutcome.failure('PDF 尚未下载完成');
        }
        // 用户取消在原生侧已经转成空串返回，走到这里都是真失败
        return PdfSaveOutcome.failure(e.message ?? '保存失败');
      } on MissingPluginException {
        // 理论上不会发生（原生代码与 Dart 一起打包）；
        // 真出现多半是热重载后引擎没重建，退回旧路径至少让它能存
        return _saveToAppDir(localPath, safe);
      } catch (e) {
        return PdfSaveOutcome.failure('$e');
      }
    }
    return _saveToAppDir(localPath, safe);
  }

  /// 非 Android 的兜底：复制到应用目录，并如实给出路径
  static Future<PdfSaveOutcome> _saveToAppDir(
    String localPath,
    String fileName,
  ) async {
    try {
      final Directory dir = File(localPath).parent;
      final Directory out = Directory('${dir.path}/exports');
      if (!await out.exists()) {
        await out.create(recursive: true);
      }
      final File target = File('${out.path}${Platform.pathSeparator}$fileName');
      await File(localPath).copy(target.path);
      return PdfSaveOutcome.success(target.path);
    } catch (e) {
      return PdfSaveOutcome.failure('$e');
    }
  }

  /// 只保留文件名本身，去掉任何路径成分与非法字符
  static String _sanitize(String name) {
    final String base = name.split(RegExp(r'[\\/]')).last;
    final String cleaned = base.replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_');
    return cleaned.isEmpty ? '培养方案.pdf' : cleaned;
  }
}
