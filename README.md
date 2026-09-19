# hi山财 · Android 客户端（Flutter）




> 仅供个人账号的正当学习用途。只读访问教务系统，低频请求。
> 应用不保存密码（除非你主动勾选「记住账号密码」，且存入系统密钥库）。

---

## 功能

| 模块 | 状态 | 说明 |
|---|---|---|
| 课表 | 完成 | 按账号本地缓存，**支持本地增删改**；单双周/周次过滤 |
| 成绩 | 完成 | 学期筛选 + 搜索 + 客户端汇总（总学分/加权绩点） |
| 培养方案 | 完成 | 课程设置总表+ **PDF 附件下载**
| 通选课修读情况 | 完成 | **大类 → 具体课程**（可折叠，默认收起）；类别进度 |
| 空教室查询 | 完成 | 全自动查询；客户端做周次过滤 |
| 个人信息 | 完成 | 学籍卡片分组展示 |
| 桌面卡片 | 完成 | Android App Widget，课表改动**自动同步** |
| 上课提醒 | 完成 | 本地通知，系统托管 |
| 校历与作息表 | 完成 | **从学校官网获取**官方校历图 + 作息时刻表；离线用缓存/内置数据 |

---


## 工程结构

```
lib/
├── main.dart                     入口；生命周期钩子
├── common/                       constants / result(AppError) / week_calc
├── crypto/qz_encoder.dart        登录加密
├── network/                      cookie_jar / http_client / qz_api
├── parser/                       html_lite + 8 个页面解析器
├── model/                        models / classroom_models / reminder_plan / captcha_charset
│                                 card_layout
├── data/                         pref_store / credential_store / timetable_store
│                                 app_state / week_service / section_time_store
│                                 reminder_service / card_snapshot_store
│                                 captcha_model / re_auth_service
│                                 academic_calendar
│                                 campus_calendar_service
│                                 pdf_store
├── theme/theme.dart              
├── theme/glass_kit.dart          玻璃外观集中定义
├── widgets/                      state_views / course_editor / reauth_dialog
│                                 credentials_box / pdf_preview / calendar_sheet
└── pages/                        shell + login/schedule/score/plan/elective/
                                  classroom/profile/settings
android/app/src/main/
├── AndroidManifest.xml                       
├── kotlin/.../TodayCourseWidgetProvider.kt    
└── res/layout/today_course_widget.xml         
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

---



### 框架

[**Flutter**](https://github.com/flutter/flutter) / [**Dart**](https://github.com/dart-lang/sdk) 

---

### 非代码来源

- **校历与作息数据**：获取自[山东财经大学官网](https://www.sdufe.edu.cn/xyfw/zxxl.htm)
  的公开页面
### 本项目自身

以 MIT 许可开源，见 [LICENSE](LICENSE)。

**免责声明**：本项目为个人学习用途的第三方客户端，与山东财经大学无隶属关系，
仅供查询本人教务数据。请遵守学校相关规定，不要用于批量抓取或任何非本人用途。
