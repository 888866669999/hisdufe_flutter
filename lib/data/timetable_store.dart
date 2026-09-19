/// 课表本地缓存（按「账号 + 学期」分文件）
///
/// 从鸿蒙版 `data/TimetableStore.ets` 移植。
///
/// ===== 为什么课表要缓存，而别的都不缓存 =====
/// 用户可以在本地编辑课表（改名、换教室、加课）。
/// 如果每次进页面都从服务器重取，本地修改就会被覆盖掉。
/// 因此课表**优先读本地**，只有用户主动「恢复为服务器数据」才重取。
///
/// 成绩 / 个人信息 / 培养方案 / 通选课 / 周历则相反：一律实时取，
/// 保证「刚出的成绩」能立刻看到，而这些页面访问频率很低，重取的代价可接受。
///
/// 分片键用「账号」而不是学号：登录后可能还没拿到学号就要显示课表。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../model/models.dart';

class TimetableStore {
  static const int _version = 1;
  static const String _dirName = 'timetable';

  /// 文件名安全化：只保留 [0-9a-zA-Z._-]
  static String _safe(String s) {
    final String out = s.replaceAll(RegExp(r'[^0-9a-zA-Z._-]'), '_');
    return out.isEmpty ? 'default' : out;
  }

  static Future<Directory> _dir() async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory d = Directory('${base.path}/$_dirName');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  static Future<File> _file(String account, String semester) async {
    final Directory d = await _dir();
    return File('${d.path}/${_safe(account)}_${_safe(semester)}.json');
  }

  /// 已缓存的账号列表
  static Future<List<String>> cachedAccounts() async {
    final Directory d = await _dir();
    final Set<String> out = <String>{};
    await for (final FileSystemEntity e in d.list()) {
      final String name = e.uri.pathSegments.last;
      final int i = name.lastIndexOf('_');
      if (i > 0) {
        out.add(name.substring(0, i));
      }
    }
    return out.toList();
  }

  /// 已缓存的学期列表（去掉账号前缀与扩展名）
  static Future<List<String>> cachedSemesters() async {
    final Directory d = await _dir();
    final Set<String> out = <String>{};
    await for (final FileSystemEntity e in d.list()) {
      final String name = e.uri.pathSegments.last;
      if (!name.endsWith('.json')) {
        continue;
      }
      final int i = name.lastIndexOf('_');
      if (i > 0) {
        out.add(name.substring(i + 1, name.length - 5));
      }
    }
    return out.toList();
  }

  /// 为某个学期找账号。
  ///
  /// **只在缓存里恰好只有一个账号时才返回它**：多账号共存时猜测等于
  /// 把 A 的课表当成 B 的返回，而且是静默的。宁可回退到网络请求。
  static Future<String> findAccountForSemester(String semester) async {
    if (semester.isEmpty) {
      return '';
    }
    final List<String> accounts = await cachedAccounts();
    if (accounts.length != 1) {
      return '';
    }
    final File f = await _file(accounts.first, semester);
    return await f.exists() ? accounts.first : '';
  }

  static Future<bool> has(String account, String semester) async {
    if (account.isEmpty || semester.isEmpty) {
      return false;
    }
    final File f = await _file(account, semester);
    return f.exists();
  }

  static Future<Timetable?> load(String account, String semester) async {
    if (account.isEmpty || semester.isEmpty) {
      return null;
    }
    final File f = await _file(account, semester);
    if (!await f.exists()) {
      return null;
    }
    try {
      final String raw = await f.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return _fromJson(decoded);
    } catch (_) {
      // 缓存损坏时当作没有，让调用方去网络取，而不是把坏数据渲染出来
      return null;
    }
  }

  static Future<bool> save(String account, String semester, Timetable tt) async {
    if (account.isEmpty || semester.isEmpty) {
      return false;
    }
    try {
      final File f = await _file(account, semester);
      final Map<String, dynamic> j = <String, dynamic>{
        'version': _version,
        'account': account,
        'semester': semester,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'remark': tt.remark,
        'semesters': tt.semesters,
        'weeks': tt.weeks,
        // 服务器课程的 id 基线：删除检测靠它（见 Timetable.serverIds）。
        // 必须落盘 —— 否则重进应用后基线丢失，删除又会被判成「未修改」。
        'serverIds': tt.serverIds,
        'courses': tt.cells
            .expand((CellData c) => c.entries.map((CourseEntry e) {
                  final Map<String, dynamic> m = e.toJson();
                  m['row'] = c.row;
                  m['col'] = c.col;
                  return m;
                }))
            .toList(),
      };
      await f.writeAsString(jsonEncode(j));
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> remove(String account, String semester) async {
    final File f = await _file(account, semester);
    if (await f.exists()) {
      await f.delete();
    }
  }

  static Timetable _fromJson(Map<String, dynamic> j) {
    // 读取时做基本校验，避免损坏的缓存被当成正常课表渲染
    final Object? ver = j['version'];
    if (ver is! int || ver > _version) {
      throw const FormatException('unsupported cache version');
    }
    final Timetable tt = Timetable(
      semester: (j['semester'] ?? '') as String,
      remark: (j['remark'] ?? '') as String,
    );
    final Object? sems = j['semesters'];
    if (sems is List) {
      tt.semesters = sems.map((Object? e) => '$e').toList();
    }
    final Object? wks = j['weeks'];
    if (wks is List) {
      tt.weeks = wks.map((Object? e) => '$e').toList();
    }
    // 基线：旧缓存里没有这个字段（字段是后加的），先留空，
    // 由下面 captureServerBaseline() 用当前非本地的条目补一份 ——
    // 否则删除检测在新版本第一次加载时是失效的。
    final Object? sids = j['serverIds'];
    if (sids is List) {
      tt.serverIds = sids.map((Object? e) => '$e').toList();
    }
    final Object? courses = j['courses'];
    if (courses is List) {
      for (final Object? c in courses) {
        if (c is! Map<String, dynamic>) {
          continue;
        }
        final int row = (c['row'] ?? -1) as int;
        final int col = (c['col'] ?? -1) as int;
        if (row < 0 || row >= 5 || col < 0 || col >= 7) {
          continue;
        }
        final CourseEntry e = CourseEntry.fromJson(c);
        if (e.courseName.isEmpty) {
          continue;
        }
        e.weekText = e.weekSummary();
        tt.ensureCell(row, col).entries.add(e);
      }
    }
    // 旧缓存没有基线字段：用「当前的非本地条目」补一份。
    //
    // 这是一次**有损**的兜底（若用户在这个版本之前就删过课，那次删除
    // 无法追溯），但比完全空着好：至少从这次加载起，后续的删除能被检测到。
    if (tt.serverIds.isEmpty) {
      tt.captureServerBaseline();
    }
    tt.edited = tt.hasLocalEdits();
    return tt;
  }
}
