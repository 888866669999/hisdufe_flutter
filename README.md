# hi山财 · Android 客户端（Flutter）

> 仅供个人账号的正当学习用途。只读访问教务系统，低频请求。
> 应用不保存密码（除非你主动勾选「记住账号密码」，且存入系统密钥库）。
> 本项目完全是vibecode，无任何人工审查，请不要妄图人工审查代码折磨自己，未来也大概率不会做功能性更新。

---

## 功能

| 模块 | 状态 | 说明 |
|---|---|---|
| 登录（图形验证码） | 完成 | 三步式；本机 ONNX 推理识别验证码（实测 92%）；可记住账号密码（系统密钥库） |
| 课表 | 完成 | 整周固定一屏（7 天 × 5 节同时可见）；按账号本地缓存，**支持本地增删改**；单双周/周次过滤 |
| 成绩 | 完成 | 学期筛选 + 搜索 + 客户端汇总（总学分/加权绩点） |
| 培养方案 | 完成 | 课程设置总表（可折叠）+ **PDF 附件下载**（走系统「另存为」） |
| 通选课修读情况 | 完成 | **大类 → 具体课程**（可折叠，默认收起）；类别进度 |
| 空教室查询 | 完成 | 全自动查询；客户端做周次过滤 |
| 个人信息 | 完成 | 学籍卡片分组展示 |
| 桌面卡片 | 完成 | Android App Widget，课表改动**自动同步** |
| 上课提醒 | 完成 | 本地通知，系统托管，应用关闭仍触发 |
| 校历与作息表 | 完成 | 校历由教务**教学周历**实时生成（**随学年自动更新**，自绘月历，不内置图片）；作息表抓学校官网 |
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

## 开源致谢

这个客户端能成立，靠的是下面这些开源项目。

### UI 与视觉

| 项目 | 许可 | 作用 |
|---|---|---|
| [**liquid_glass_widgets**](https://github.com/sdegenaar/liquid_glass_widgets) | MIT | 液态玻璃效果的全部实现（只用其 `AdaptiveGlass` 自适应封装：核心部分的 `LiquidGlass` 依赖 Impeller，在 Skia 上不渲染）。 |
| [**cupertino_icons**](https://github.com/flutter/packages/tree/main/packages/cupertino_icons) | MIT | 图标字形。 |

### 数据、存储与系统能力

| 项目 | 许可 | 作用 |
|---|---|---|
| [**shared_preferences**](https://pub.dev/packages/shared_preferences) | BSD-3-Clause | 偏好设置持久化。 |
| [**flutter_secure_storage**](https://github.com/juliansteenbakker/flutter_secure_storage) | BSD-3-Clause | 账号密码与会话 cookie 的加密存储（Android Keystore）。 |
| [**path_provider**](https://pub.dev/packages/path_provider) | BSD-3-Clause | 定位应用私有目录（课表缓存、PDF 落盘）。 |
| [**home_widget**](https://github.com/ABausG/home_widget) | BSD-3-Clause | 桌面「今日课程」卡片的 Dart↔原生桥。 |
| [**image_picker**](https://pub.dev/packages/image_picker) | Apache-2.0 | 头像选图（裁切是应用内自绘的）。 |

### 通知与提醒

| 项目 | 许可 | 作用 |
|---|---|---|
| [**flutter_local_notifications**](https://github.com/MaikuB/flutter_local_notifications) | BSD-3-Clause | 上课提醒的唯一通道（`zonedSchedule` 由系统 AlarmManager 托管）。 |
| [**timezone**](https://pub.dev/packages/timezone) | BSD-2-Clause | `zonedSchedule` 所需的时区计算。 |

### 验证码识别

| 项目 | 许可 | 作用 |
|---|---|---|
| [**ddddocr**](https://github.com/sml2h3/ddddocr) | MIT | 验证码识别模型（`assets/captcha.onnx`，原版量化模型 13 MB）。 |
| [**onnxruntime**](https://github.com/gtbluesky/onnxruntime_flutter) | MIT | 在设备上跑 ONNX 模型。 |
| [**image**](https://github.com/brendan-duncan/image) | MIT | 验证码预处理（解码、缩放、灰度归一化）。 |

### 网络与工具

| 项目 | 许可 | 作用 |
|---|---|---|
| [**http**](https://github.com/dart-lang/http) | BSD-3-Clause | HTTP 客户端。 |
| [**flutter_lints**](https://github.com/flutter/packages/tree/main/packages/flutter_lints) | BSD-3-Clause | 静态检查规则（开发期依赖）。 |

### 框架

[**Flutter**](https://github.com/flutter/flutter) / [**Dart**](https://github.com/dart-lang/sdk) —— BSD-3-Clause。

---

### 非代码来源

- **作息表与校历原图**：获取自[山东财经大学官网](https://www.sdufe.edu.cn/xyfw/zxxl.htm)
  的公开页面。校历的**主数据**来自教务系统的「教学周历」（结构化、随学年自动更新），
  官网校历图仅作佐证 —— 它一年一换且无法参与计算，因此不再随包内置。
- **应用图标与校徽**：由原始笔触图反解白底得到（`tools/make_app_icon.py`），
  非本项目原创。

### 本项目自身

以 MIT 许可开源，见 [LICENSE](LICENSE)。

由同作者的鸿蒙版（ArkTS）移植而来；鸿蒙版未开源。

**免责声明**：本项目为个人学习用途的第三方客户端，与山东财经大学无隶属关系，
仅供查询本人教务数据。请遵守学校相关规定，不要用于批量抓取或任何非本人用途。
