package com.sdufe.hisdufe_jw

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 「把 PDF 保存到用户选的位置」—— 用系统的「创建文档」流程（SAF）。
 *
 * ===== 为什么需要原生代码（而不是纯 Dart）=====
 * 早先的实现是把文件复制进应用专属外部目录
 * （`Android/data/<包名>/files/exports`）。那条路有两个问题：
 *
 *   1. **用户找不到文件**。代码注释里写「文件管理器能进去看到」——
 *      这在 Android 10 及以前成立，**Android 11 起系统禁止文件管理器访问
 *      `Android/data`**，用户存完根本打不开，等于白存。
 *   2. 没有任何权限能补救（MANAGE_EXTERNAL_STORAGE 属特殊权限，
 *      应用商店基本不给教育类应用批）。
 *
 * 正解是 SAF：发一个 `ACTION_CREATE_DOCUMENT`，由**系统弹窗**让用户选保存
 * 位置（默认就是「下载」），再把数据写进返回的 Uri。全程免权限，
 * 且文件落在用户自己选的地方 —— 这才是真正可用的「下载」。
 *
 * ===== 为什么不引第三方插件 =====
 * 本项目在插件与 AGP / compileSdk 的兼容上已多次吃亏（device_calendar、
 * permission_handler、flutter_local_notifications 都回退过）。这里只需要
 * 一个系统 Intent，自己写通道比再引一个插件更可控，也不增加依赖风险。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.sdufe.hisdufe_jw/pdf"

        /** 只在本 Activity 内使用，与其它插件的结果码不会冲突 */
        private const val SAVE_REQUEST_CODE = 4711
    }

    /**
     * 等待用户选择的这一次请求。
     *
     * 用字段而非局部变量：系统弹窗是异步的，结果通过 `onActivityResult` 回来，
     * 两者之间没有别的关联通道。
     */
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSourcePath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "savePdf" -> savePdf(
                        call.argument<String>("sourcePath"),
                        call.argument<String>("fileName") ?: "培养方案.pdf",
                        result,
                    )
                    "openUrl" -> openUrl(call.argument<String>("url"), result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 用系统浏览器打开一个链接（目前用于「开源地址」那一行）。
     *
     * 为什么要自己写而不是引 url_launcher：本项目在插件兼容上多次踩坑
     * （见 pubspec 里 device_calendar / permission_handler 的记录），
     * 而这里只需要一个 `ACTION_VIEW` Intent —— 自己写比再引一个插件可控。
     *
     * **安全约束**：只允许 http/https。否则 `file://` 之类会被用来读本地文件
     * （Dart 侧传什么就开什么，等于把 Intent 的构造权交给了上游）。
     */
    private fun openUrl(url: String?, result: MethodChannel.Result) {
        if (url.isNullOrEmpty()) {
            result.error("NO_URL", "缺少网址", null)
            return
        }
        val uri = Uri.parse(url)
        if (uri.scheme != "http" && uri.scheme != "https") {
            result.error("BAD_SCHEME", "只允许 http/https 链接", null)
            return
        }
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
            result.success(true)
        } catch (e: Exception) {
            // 设备上没有浏览器（极罕见）
            result.error("NO_BROWSER", e.message, null)
        }
    }

    private fun savePdf(
        sourcePath: String?,
        fileName: String,
        result: MethodChannel.Result,
    ) {
        if (sourcePath.isNullOrEmpty() || !File(sourcePath).exists()) {
            result.error("NO_SOURCE", "要保存的文件不存在", null)
            return
        }
        // 同一时刻只允许一次：pendingResult 是单槽位，并发会把结果串到一起
        if (pendingResult != null) {
            result.error("BUSY", "上一次保存还没结束", null)
            return
        }
        pendingResult = result
        pendingSourcePath = sourcePath

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            // EXTRA_TITLE 是系统弹窗里预填的文件名
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            startActivityForResult(intent, SAVE_REQUEST_CODE)
        } catch (e: Exception) {
            // 极少数精简 ROM 没有可处理该 Intent 的 Activity
            pendingResult = null
            pendingSourcePath = null
            result.error("NO_PICKER", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == SAVE_REQUEST_CODE) {
            val result = pendingResult
            val source = pendingSourcePath
            pendingResult = null
            pendingSourcePath = null

            val uri = data?.data
            if (result == null) {
                return // 不该发生，静默忽略
            }
            if (resultCode != Activity.RESULT_OK || uri == null) {
                // 用户取消：返回空串表达「没保存」。
                // 取消是正常操作，不该当成错误弹提示。
                result.success("")
                return
            }
            try {
                val stream = contentResolver.openOutputStream(uri)
                if (stream == null) {
                    result.error("WRITE_FAILED", "无法打开目标文件", null)
                    return
                }
                stream.use { output ->
                    File(source!!).inputStream().use { input ->
                        input.copyTo(output)
                    }
                }
                result.success(uri.toString())
            } catch (e: Exception) {
                result.error("WRITE_FAILED", e.message, null)
            }
            return
        }
        // 其它结果码必须交回父类：image_picker 等插件靠这条链路拿结果
        super.onActivityResult(requestCode, resultCode, data)
    }
}
