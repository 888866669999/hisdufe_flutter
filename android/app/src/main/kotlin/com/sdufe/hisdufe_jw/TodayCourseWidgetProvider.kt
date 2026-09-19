package com.sdufe.hisdufe_jw

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * 桌面「今日课程」卡片。
 *
 * ===== 它自己算「今天」，而不是重画一份快照 =====
 * 卡片由系统进程触发渲染，不能联网，但做「按今天日期筛课、按时段标已上完」
 * 这类纯算术完全没问题 —— 而且**必须**在这里算，否则必然不及时：
 *
 * 早期版本由主应用把「今天」算好写进 preferences，卡片只负责重画。
 * 那样有三个改不掉的毛病：
 *   1. `done`（已上完）与「下一节」冻结在写入那一刻，一整天不再变化；
 *   2. 平台的 `updatePeriodMillis`（最短 30 分钟）回调只是把同一份旧 JSON
 *      再画一遍，等于在做无用功；
 *   3. **跨天后仍显示昨天的课**，非得打开一次应用才纠正。
 *
 * 现在主应用写的是**整周**课表（含每门课的周次区间与单双周，键名
 * `week_snapshot`，见 lib/data/card_snapshot_store.dart 的 buildWeek），
 * 卡片每次 onUpdate 都按当前时间重新筛选与排序。于是平台每次定时回调、
 * 每次主应用通知，得到的都是**当下正确**的内容，跨天自愈，
 * 并且全程不需要应用在后台运行。
 *
 * 读不到周级数据时回退到旧的今日快照（`card_snapshot`），
 * 这样升级过程中桌面上的旧卡片不会空白。
 */
class TodayCourseWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (id in appWidgetIds) {
            val views = buildViews(context, id)
            appWidgetManager.updateAppWidget(id, views)
        }
        // 每次系统回调都顺手把下一次自刷新排上
        scheduleNextRefresh(context)
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        scheduleNextRefresh(context)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        cancelRefresh(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_SELF_REFRESH) {
            // 自刷新：把桌面上的卡片全部按「现在」重画一遍
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(
                ComponentName(context, TodayCourseWidgetProvider::class.java)
            )
            for (id in ids) {
                mgr.updateAppWidget(id, buildViews(context, id))
            }
            scheduleNextRefresh(context)
        }
    }

    /**
     * 排下一次自刷新。
     *
     * ===== 为什么不能只靠平台的 `updatePeriodMillis` =====
     * 它最短只能 30 分钟，而且是**系统批量调度**的，实际触发时刻可能明显
     * 晚于预期。卡片虽然已经会按当前时间重算（见类注释），但「重算」得有
     * 人触发 —— 否则一节课 10:00 下课后，状态要拖到 11:00 或更晚才变，
     * 看起来就是「卡片和实际时间对不上」。
     *
     * ===== 为什么瞄着「节次边界」而不是整点 =====
     * 卡片上会变的只有三件事：跨天、某节课开始、某节课结束。它们**全部**
     * 发生在作息表的起止时刻上。因此把下一次唤醒定在「下一个尚未到达的
     * 节次起止时刻」，就做到了「状态一变，卡片立刻跟上」，而且一天只有
     * 十来次唤醒 —— 比按小时轮询（24 次）更省，也更准。
     *
     * 用 `AlarmManager.set()`（**非精确**闹钟）：不需要任何权限、不受
     * Android 12+ 精确闹钟开关影响，代价是可能晚几分钟。
     * 对「一节课下课」这件事，晚几分钟完全可接受。
     *
     * 候选取更早的那个：
     *   - 下一个节次起止时刻（当天已全部过去就取次日第一个）；
     *   - 次日 00:00:30 —— 跨天切换必须及时。
     */
    private fun scheduleNextRefresh(context: Context) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val targetMs = nextBoundaryMs(context)

            val pi = pendingIntent(context)
            am.set(AlarmManager.RTC, targetMs, pi)
        } catch (e: Exception) {
            // 排闹钟失败不影响本次渲染：卡片仍会在下次平台回调时更新
        }
    }

    /**
     * 下一次应该唤醒的时刻（毫秒）。
     *
     * 取「下一个节次起止时刻」与「次日零点」中更早的那个。
     * 作息时刻从周级载荷里读（用户自定义过就用自定义值）；
     * 读不到就用内置的官方时刻，保证这个函数**永远**能返回一个合理时刻
     * ——否则闹钟链会断掉，卡片从此再不自动更新。
     */
    private fun nextBoundaryMs(context: Context): Long {
        val now = Calendar.getInstance()

        // 收集今天的节次边界（起、止都算）
        val mins = ArrayList<Int>()
        for (t in sectionTimes(context)) {
            val m = toMinutes(t)
            if (m >= 0) mins.add(m)
        }
        if (mins.isEmpty()) {
            // 极端兜底：读不到作息就退回「下一个整点」
            val fallback = Calendar.getInstance()
            fallback.add(Calendar.HOUR_OF_DAY, 1)
            fallback.set(Calendar.MINUTE, 0)
            fallback.set(Calendar.SECOND, 5)
            fallback.set(Calendar.MILLISECOND, 0)
            return fallback.timeInMillis
        }
        mins.sort()

        val nowMin = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
        for (m in mins) {
            if (m > nowMin) {
                val c = Calendar.getInstance()
                c.set(Calendar.HOUR_OF_DAY, m / 60)
                c.set(Calendar.MINUTE, m % 60)
                // 多给 20 秒：确保系统时间已经越过那个边界，避免在同分钟内
                // 反复被唤醒（闹钟触发时 nowMin 仍等于 m，就又算出同一个时刻）
                c.set(Calendar.SECOND, 20)
                c.set(Calendar.MILLISECOND, 0)
                return c.timeInMillis
            }
        }

        // 今天的边界都过了 → 次日第一个节次边界
        val next = Calendar.getInstance()
        next.add(Calendar.DAY_OF_MONTH, 1)
        next.set(Calendar.HOUR_OF_DAY, mins[0] / 60)
        next.set(Calendar.MINUTE, mins[0] % 60)
        next.set(Calendar.SECOND, 20)
        next.set(Calendar.MILLISECOND, 0)
        val firstBoundary = next.timeInMillis

        // 与「次日零点」取更早者：跨天切换不能等到早上第一节
        val midnight = Calendar.getInstance()
        midnight.add(Calendar.DAY_OF_MONTH, 1)
        midnight.set(Calendar.HOUR_OF_DAY, 0)
        midnight.set(Calendar.MINUTE, 0)
        midnight.set(Calendar.SECOND, 30)
        midnight.set(Calendar.MILLISECOND, 0)

        return if (midnight.timeInMillis < firstBoundary) {
            midnight.timeInMillis
        } else {
            firstBoundary
        }
    }

    /**
     * 当前的作息时刻表（起止混在一起，顺序无所谓 —— 调用方会排序）。
     *
     * 优先用用户自定义/官网同步的值（周级载荷里的 `sections` + `sectionEnds`）；
     * 读不到就退回内置的官方时刻，保证永远有值可用。
     */
    private fun sectionTimes(context: Context): List<String> {
        val out = ArrayList<String>()
        try {
            val raw = prefs(context)?.getString("week_snapshot", "")
            if (!raw.isNullOrEmpty()) {
                val json = JSONObject(raw)
                for (key in arrayOf("sections", "sectionEnds")) {
                    val arr = json.optJSONArray(key)
                    if (arr != null) {
                        for (i in 0 until arr.length()) {
                            val s = arr.optString(i, "")
                            if (s.isNotEmpty()) out.add(s)
                        }
                    }
                }
            }
        } catch (_: Exception) {
            // 落到下面的内置值
        }
        if (out.isEmpty()) {
            // 内置官方时刻（与 lib/common/constants.dart 的 kSections 一致）。
            // 这里硬编码一份是对的：闹钟排期不能依赖「应用是否写过数据」，
            // 否则全新安装、还没打开过应用时闹钟链就断了。
            out.addAll(
                listOf(
                    "08:30", "10:00",
                    "10:20", "11:50",
                    "14:00", "15:30",
                    "15:50", "17:20",
                    "18:40", "21:05"
                )
            )
        }
        return out
    }

    private fun cancelRefresh(context: Context) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(pendingIntent(context))
        } catch (e: Exception) {
            // 忽略
        }
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, TodayCourseWidgetProvider::class.java).apply {
            action = ACTION_SELF_REFRESH
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, 0, intent, flags)
    }

    private fun prefs(context: Context): SharedPreferences? {
        // 必须读 home_widget 插件的私有 preferences。
        //
        // 这里是最容易错的一处：Flutter 的 shared_preferences 用的是
        // "FlutterSharedPreferences"（且键名带 "flutter." 前缀），
        // 而 home_widget 插件把数据存在自己的 "HomeWidgetPreferences" 里。
        // 两者互不相通 —— 早期版本读错了文件，卡片永远显示
        // 「打开应用后自动显示今日课程」，而且不会有任何报错。
        // 主应用侧对应地用 HomeWidget.saveWidgetData 写入（见
        // lib/data/card_snapshot_store.dart）。
        return context.getSharedPreferences(
            "HomeWidgetPreferences",
            Context.MODE_PRIVATE
        )
    }

    /** 一行要显示的内容 */
    private class Row(
        val time: String,
        val name: String,
        val room: String,
        val end: String,
        val done: Boolean
    )

    private fun buildViews(context: Context, widgetId: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.today_course_widget)

        // 点击卡片任意位置 → 打开应用。
        //
        // 为什么必须有：卡片显示的是「今天要上什么」，用户看完的自然动作
        // 就是「进去看看详细课表」。没有点击响应时整张卡片是「死」的，
        // 用户会以为应用卡住了。
        views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context))

        val options = AppWidgetManager.getInstance(context).getAppWidgetOptions(widgetId)
        val maxRows = maxRowsFor(context, options)

        val p = prefs(context)
        val weekRaw = p?.getString("week_snapshot", "")
        val todayRaw = p?.getString("card_snapshot", "")

        if (weekRaw.isNullOrEmpty() && todayRaw.isNullOrEmpty()) {
            showEmpty(views, "打开应用后自动显示今日课程")
            return views
        }

        // 优先：用整周数据当场算今天
        if (!weekRaw.isNullOrEmpty()) {
            try {
                renderWeek(views, weekRaw, maxRows)
                return views
            } catch (e: Exception) {
                // 解析失败就落到今日快照的兜底分支
            }
        }
        try {
            renderLegacyToday(views, todayRaw ?: "", maxRows)
        } catch (e: Exception) {
            showEmpty(views, "数据解析失败")
        }
        return views
    }

    /**
     * 这张卡片当前能显示几行。
     *
     * ===== 为什么要同时看 min/max 两个尺寸 =====
     * 早先只看 `OPTION_APPWIDGET_MIN_HEIGHT`，阈值是「>220 给 6 行、
     * >150 给 4 行、否则 2 行」。两处都不对：
     *   1. 3×2 的卡片在多数启动器上报的 minHeight 约 110dp，于是**永远
     *      只显示 2 行** —— 一天有四节课时后两节根本看不到，
     *      用户看到的就是「课程消失」；
     *   2. 卡片的实际高度是会被用户拖动改的，只看 min 会一直按最小算。
     *
     * 现在取 `max(minHeight, maxHeight)` 作为可用高度（max 才是「当前
     * 单元格能有多高」，min 是防御性下限），并把阈值调细一些。
     * 每行约 24dp + 表头约 46dp + 内边距 24dp，所以：
     *   110dp → 2 行；160dp → 4 行；220dp → 6 行。
     */
    private fun maxRowsFor(
        context: Context,
        options: android.os.Bundle
    ): Int {
        val minH = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 110)
        val maxH = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, minH)
        val h = if (maxH > minH) maxH else minH
        return when {
            h >= 220 -> 6
            h >= 160 -> 4
            h >= 130 -> 3
            else -> 2
        }
    }

    /** 点击卡片 → 启动主界面 */
    private fun openAppIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            // 从桌面点击要复用已有任务，而不是叠一个新的 Activity
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        // requestCode 与自刷新用的 0 区分开
        return PendingIntent.getActivity(context, 1, intent, flags)
    }

    private fun showEmpty(views: RemoteViews, text: String) {
        views.setTextViewText(R.id.widget_title, "hi山财")
        views.setTextViewText(R.id.widget_count, "")
        views.setTextViewText(R.id.widget_empty, text)
        views.setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
        views.setViewVisibility(R.id.widget_next, android.view.View.GONE)
        clearRows(views)
    }

    /** 今天星期几，0=周一 .. 6=周日（与课表的列顺序一致） */
    private fun todayDow(): Int {
        val cal = Calendar.getInstance()
        // Calendar.MONDAY == 2；换算成 0 起的课表列号
        return (cal.get(Calendar.DAY_OF_WEEK) + 5) % 7
    }

    /** 从「第 1 周周一」推算当前教学周；算不出或超范围返回 0 */
    private fun weekNumber(startMonday: String, maxWeeks: Int): Int {
        if (startMonday.isEmpty()) return 0
        val parts = startMonday.split("-")
        if (parts.size != 3) return 0
        val y = parts[0].toIntOrNull() ?: return 0
        val m = parts[1].toIntOrNull() ?: return 0
        val d = parts[2].toIntOrNull() ?: return 0

        val startCal = Calendar.getInstance()
        startCal.set(y, m - 1, d, 0, 0, 0)
        startCal.set(Calendar.MILLISECOND, 0)
        // 归一到该周周一
        val startDow = (startCal.get(Calendar.DAY_OF_WEEK) + 5) % 7
        startCal.add(Calendar.DAY_OF_MONTH, -startDow)
        val startMs = startCal.timeInMillis

        val nowCal = Calendar.getInstance()
        nowCal.set(Calendar.HOUR_OF_DAY, 0)
        nowCal.set(Calendar.MINUTE, 0)
        nowCal.set(Calendar.SECOND, 0)
        nowCal.set(Calendar.MILLISECOND, 0)
        val nowMs = nowCal.timeInMillis

        val diffDays = ((nowMs - startMs) / 86400000L).toInt()
        if (diffDays < 0) return 0
        val week = diffDays / 7 + 1
        if (maxWeeks > 0 && week > maxWeeks) return 0
        return week
    }

    /** "08:30" -> 510（当天第几分钟）；解析不出返回 -1 */
    private fun toMinutes(hhmm: String): Int {
        val i = hhmm.indexOf(':')
        if (i <= 0) return -1
        val h = hhmm.substring(0, i).toIntOrNull() ?: return -1
        val mm = hhmm.substring(i + 1).toIntOrNull() ?: return -1
        return h * 60 + mm
    }

    /** 该门课本周是否要上。与 Dart 端 CourseEntry.isActiveInWeek 严格一致 */
    private fun activeInWeek(c: JSONObject, week: Int): Boolean {
        // 周次未知时一律显示，宁可多显示也不要漏（与两端既有约定一致）
        if (week <= 0) return true
        val sw = c.optInt("startWeek", 1)
        val ew = c.optInt("endWeek", 18)
        if (week < sw || week > ew) return false
        val parity = c.optInt("parity", 0)
        if (parity == 1 && week % 2 == 0) return false
        if (parity == 2 && week % 2 == 1) return false
        return true
    }

    private fun renderWeek(views: RemoteViews, raw: String, maxRows: Int) {
        val json = JSONObject(raw)
        val startMonday = json.optString("startMonday", "")
        val maxWeeks = json.optInt("maxWeeks", 30)
        val week = weekNumber(startMonday, maxWeeks)
        val dow = todayDow()

        val sections = json.optJSONArray("sections") ?: JSONArray()
        // 下课时刻。缺了它就只能按「开始时间已过」猜「已上完」，
        // 于是**正在上的那节课也会被标成已上完** —— 那是错的。
        // 旧载荷没有这个字段，此时退回「按开始时间」判断（见下面的 done 计算）。
        val sectionEnds = json.optJSONArray("sectionEnds") ?: JSONArray()
        val days = json.optJSONArray("days") ?: JSONArray()

        val rows = ArrayList<Row>()
        val now = Calendar.getInstance()
        val nowMin = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)

        val dayArr = if (dow < days.length()) days.optJSONArray(dow) else null
        if (dayArr != null) {
            for (i in 0 until dayArr.length()) {
                val c = dayArr.optJSONObject(i) ?: continue
                if (!activeInWeek(c, week)) continue
                val row = c.optInt("row", 0)
                val time =
                    if (row >= 0 && row < sections.length()) sections.optString(row, "") else ""
                val end =
                    if (row >= 0 && row < sectionEnds.length()) sectionEnds.optString(row, "") else ""
                val startMin = toMinutes(time)
                val endMin = toMinutes(end)
                // 有下课时刻就按它判断；没有则退回「开始时间已过」（旧载荷的语义）
                val done = if (endMin >= 0) {
                    endMin <= nowMin
                } else {
                    startMin >= 0 && startMin < nowMin
                }
                rows.add(Row(time, c.optString("name", ""), c.optString("room", ""), end, done))
            }
        }

        // 按上课时刻排序；解析不出时间的排到最后
        rows.sortBy { r ->
            val m = toMinutes(r.time)
            if (m < 0) Int.MAX_VALUE else m
        }

        val cal = Calendar.getInstance()
        val weekdayCn = "一二三四五六日"
        val dateText = String.format(
            "%02d/%02d",
            cal.get(Calendar.MONTH) + 1,
            cal.get(Calendar.DAY_OF_MONTH)
        )
        val title =
            (if (week > 0) "第${week}周 · " else "") + "周${weekdayCn[dow]} $dateText"
        views.setTextViewText(R.id.widget_title, title)
        views.setTextViewText(R.id.widget_count, "${rows.size} 节")

        if (rows.isEmpty()) {
            views.setTextViewText(R.id.widget_empty, "今天没有课")
            views.setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
            views.setViewVisibility(R.id.widget_next, android.view.View.GONE)
            clearRows(views)
            return
        }

        views.setViewVisibility(R.id.widget_empty, android.view.View.GONE)
        fillRows(views, rows, maxRows)

        val hidden = rows.size - maxRows
        views.setTextViewText(
            R.id.widget_count,
            if (hidden > 0) "${rows.size} 节 · 另有 $hidden 节未显示" else "${rows.size} 节"
        )

        // 「下一节」：第一门**还没开始**的课（不是「还没上完」的课 ——
        // 正在上的那节不该被叫作「下一节」）
        var next = ""
        for (r in rows) {
            val m = toMinutes(r.time)
            if (m >= 0 && m > nowMin) {
                next = "${r.time} ${r.name}" +
                    (if (r.room.isNotEmpty()) " @${r.room}" else "")
                break
            }
        }
        if (next.isNotEmpty()) {
            views.setTextViewText(R.id.widget_next, "下一节 $next")
            views.setViewVisibility(R.id.widget_next, android.view.View.VISIBLE)
        } else {
            // 全部已开始：如果还有没上完的，就提示「正在上」；
            // 否则今天的课就都结束了
            val ongoing = rows.firstOrNull { r ->
                val s = toMinutes(r.time)
                val e = toMinutes(r.end)
                s >= 0 && s <= nowMin && e >= 0 && e > nowMin
            }
            if (ongoing != null) {
                views.setTextViewText(R.id.widget_next, "正在上 ${ongoing.name}")
                views.setViewVisibility(R.id.widget_next, android.view.View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_next, android.view.View.GONE)
            }
        }
    }

    /**
     * 旧的「今日快照」渲染路径。
     *
     * 仅在读不到周级数据时使用 —— 例如刚升级、主应用还没写过新格式，
     * 桌面上那张旧卡片仍应有内容，而不是突然变空白。
     */
    private fun renderLegacyToday(views: RemoteViews, raw: String, maxRows: Int) {
        if (raw.isEmpty()) {
            showEmpty(views, "打开应用后自动显示今日课程")
            return
        }
        val json = JSONObject(raw)
        val week = json.optInt("week", 0)
        val weekday = json.optString("weekday", "")
        val date = json.optString("date", "")
        val title = (if (week > 0) "第${week}周 · " else "") + "周$weekday $date"
        views.setTextViewText(R.id.widget_title, title)

        val courses = json.optJSONArray("courses") ?: JSONArray()
        views.setTextViewText(R.id.widget_count, "${courses.length()} 节")

        if (courses.length() == 0) {
            views.setTextViewText(R.id.widget_empty, "今天没有课")
            views.setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
            views.setViewVisibility(R.id.widget_next, android.view.View.GONE)
            clearRows(views)
            return
        }

        views.setViewVisibility(R.id.widget_empty, android.view.View.GONE)
        val rows = ArrayList<Row>()
        for (i in 0 until courses.length()) {
            val c = courses.optJSONObject(i) ?: continue
            // 旧格式里 `done` 是写入那一刻算好的，直接沿用；
            // 下课时刻与结束状态在旧载荷里没有，给空串/false ——
            // 这条路径只在读不到周级数据时兜底，不影响新逻辑。
            rows.add(
                Row(
                    c.optString("time", ""),
                    c.optString("name", ""),
                    c.optString("room", ""),
                    "",
                    c.optBoolean("done", false)
                )
            )
        }
        fillRows(views, rows, maxRows)

        val next = json.optString("nextText", "")
        if (next.isNotEmpty()) {
            views.setTextViewText(R.id.widget_next, "下一节 $next")
            views.setViewVisibility(R.id.widget_next, android.view.View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_next, android.view.View.GONE)
        }
    }

    // 每行的「容器 + 三个文本」id 都是唯一的：
    // RemoteViews 靠 id 定位控件，重复 id 会定位到错的行。
    private val rowContainers = intArrayOf(
        R.id.widget_row1, R.id.widget_row2, R.id.widget_row3,
        R.id.widget_row4, R.id.widget_row5, R.id.widget_row6
    )

    private val rowTimes = intArrayOf(
        R.id.row_time_1, R.id.row_time_2, R.id.row_time_3,
        R.id.row_time_4, R.id.row_time_5, R.id.row_time_6
    )

    private val rowNames = intArrayOf(
        R.id.row_name_1, R.id.row_name_2, R.id.row_name_3,
        R.id.row_name_4, R.id.row_name_5, R.id.row_name_6
    )

    private val rowRooms = intArrayOf(
        R.id.row_room_1, R.id.row_room_2, R.id.row_room_3,
        R.id.row_room_4, R.id.row_room_5, R.id.row_room_6
    )

    /// 隐藏所有课程行（用于空态/解析失败时清干净上次的内容）
    private fun clearRows(views: RemoteViews) {
        for (i in rowContainers.indices) {
            views.setViewVisibility(rowContainers[i], android.view.View.GONE)
        }
    }

    /** 未上完 / 已上完的文字色。已上完的用更浅的灰，一眼能区分。 */
    private val COLOR_PENDING = 0xFF14161B.toInt()
    private val COLOR_DONE = 0xFF9AA0A6.toInt()

    private fun fillRows(views: RemoteViews, rows: List<Row>, maxRows: Int) {
        for (i in rowContainers.indices) {
            if (i >= maxRows || i >= rows.size) {
                views.setViewVisibility(rowContainers[i], android.view.View.GONE)
                continue
            }
            val r = rows[i]
            views.setTextViewText(rowTimes[i], r.time)
            views.setTextViewText(rowNames[i], r.name)
            views.setTextViewText(rowRooms[i], r.room)
            views.setViewVisibility(
                rowRooms[i],
                if (r.room.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE
            )

            // ===== 「已上完」要看得出来，而不是让它消失 =====
            // 早先 `done` 只算不用，界面上完全没有表现 —— 用户无法区分
            // 「这节课上完了」与「这节课被漏掉了」，看起来就像课程凭空少了。
            // 现在用「浅灰 + 删除线」明确表达「上过了」这个状态：
            // 行还在（数量对得上），但一眼知道它已经过去。
            //
            // RemoteViews 不能直接设 paintFlags，得用 setInt 反射式调用
            // （这是官方支持的路径，不是 hack）。
            views.setTextColor(rowNames[i], if (r.done) COLOR_DONE else COLOR_PENDING)
            views.setInt(
                rowNames[i],
                "setPaintFlags",
                if (r.done) {
                    android.graphics.Paint.ANTI_ALIAS_FLAG or
                        android.graphics.Paint.STRIKE_THRU_TEXT_FLAG
                } else {
                    android.graphics.Paint.ANTI_ALIAS_FLAG
                }
            )
            views.setViewVisibility(rowContainers[i], android.view.View.VISIBLE)
        }
    }

    companion object {
        /** 自刷新广播。用包名限定，避免与其它应用的同名 action 冲突 */
        private const val ACTION_SELF_REFRESH =
            "com.sdufe.hisdufe_jw.action.WIDGET_SELF_REFRESH"
    }
}
