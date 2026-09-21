# hi山财 · Android 客户端（Flutter）

> 仅供个人账号的正当学习用途。只读访问教务系统，低频请求。
> 应用不保存密码（除非你主动勾选「记住账号密码」，且存入系统密钥库）。
> 本项目完全是vibecode，无任何人工审查，请不要妄图人工审查代码折磨自己，未来也大概率不会做功能性更新。

---

## 功能

| 模块 | 状态 | 说明 |
|---|---|---|
| 课表 | 完成 | 按单双周显示本周课程|
| 成绩 | 完成 | 学期筛选 + 搜索  |
| 培养方案 | 完成 | 课程设置总表+ **PDF 附件下载** |
| 通选课修读情况 | 完成 | **大类 → 具体课程**；类别进度 |
| 空教室查询 | 完成 | 全自动查询；客户端做周次过滤 |
| 个人信息 | 完成 | 学籍卡片分组展示 |
| 桌面卡片 | 完成 |自动按时间同步高亮显示下一节课程 |
| 上课提醒 | 完成 | 本地通知，系统托管，应用关闭仍触发 |
| 作息表 | 完成 | 作息表取自学校官网 |
| 界面材质 | 完成 | 液态玻璃 / Material 3 两套，设置里可切换 |

---

## 工程结构

```
lib/
├── main.dart                     入口；生命周期钩子
├── common/                       constants / result(AppError) / week_calc / url_guard
├── crypto/qz_encoder.dart        登录加密
├── network/                      cookie_jar / http_client / qz_api
├── parser/                       html_lite + 7 个页面解析器
│                                 (timetable / score / profile / plan / elective /
│                                  classroom / week_calendar)
├── model/                        models / classroom_models / reminder_plan / captcha_charset
│                                 card_layout
├── data/                         pref_store / credential_store / session_cookie_store
│                                 timetable_store / app_state / week_service
│                                 section_time_store / reminder_service
│                                 card_snapshot_store / captcha_model / captcha_solver
│                                 re_auth_service / avatar_store / pdf_store / pdf_saver
│                                 elective_requirement_store / page_cache(三层缓存)
│                                 academic_calendar(官方作息) / campus_calendar_service
│                                 semester_calendar_service(教学周历)
├── theme/                        theme.dart / glass_kit.dart(玻璃外观集中定义)
│                                 material_style.dart(M3↔玻璃切换)
├── widgets/                      state_views / app_refresh / course_editor
│                                 reauth_dialog / credentials_box / glass_picker
│                                 glass_picker_field / calendar_sheet / semester_month_grid
│                                 section_time_dialog / requirement_editor_dialog
│                                 avatar_crop_dialog / top_fade_blur
└── pages/                        shell + login/schedule/score/plan/elective/
                                  classroom/profile/settings + top_bar_slot
shaders/top_fade_blur.frag        顶部渐变模糊着色器
test/                             304 个用例（解析器 / 缓存 / 布局 / 提醒 …）
android/app/src/main/
├── AndroidManifest.xml
├── kotlin/.../MainActivity.kt
├── kotlin/.../TodayCourseWidgetProvider.kt     桌面卡片
└── res/layout/today_course_widget.xml
docs/技术笔记.md                  实现细节、排查记录、已知限制
```

---

## 构建与运行

### 环境

- Flutter 3.44.2（Dart 3.12）
- Android SDK：compileSdk **36**、minSdk 24、targetSdk 36
- **JDK 17**

### 构建

```bash
flutter pub get
flutter build apk --debug      # 或 --release
```

产物：`build/app/outputs/flutter-apk/app-debug.apk`
（含 arm64-v8a / armeabi-v7a / x86_64 三个 ABI）

### 运行

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.sdufe.hisdufe_jw/.MainActivity
```

### 测试

```bash
flutter test
```

实现细节、构建环境的坑、排查记录与已知限制，见 [docs/技术笔记.md](docs/技术笔记.md)。

---




### 非代码来源

- **作息表与校历原图**：获取自[山东财经大学官网](https://www.sdufe.edu.cn/xyfw/zxxl.htm)
  的公开页面。
- **应用图标与校徽**：本人手绘。

### 本项目自身

以 MIT 许可开源，见 [LICENSE](LICENSE)。

由同作者的鸿蒙版（ArkTS）移植而来；鸿蒙版尚未开源。

**免责声明**：本项目为个人学习用途的第三方客户端，与山东财经大学无隶属关系，
仅供查询本人教务数据。请遵守学校相关规定，不要用于批量抓取或任何非本人用途。
