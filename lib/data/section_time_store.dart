/// 节次作息（官方默认值 + 用户可自定义）
///
/// 从鸿蒙版 `data/SectionTimeStore.ets` 移植。
///
/// 默认值取自学校官方的「日常教学时刻表」（见 [kSections]）。
/// 官网会更新这些时刻，因此 [CampusCalendarService] 在刷新校历时会
/// 「顺手」把官网作息同步进来 —— 但**只在用户没有自定义过**的前提下。
/// 「谁写的」由 [isDefault] 的来源标记判断，不靠值比较（原因见该方法的说明）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../common/constants.dart';
import 'pref_store.dart';

class SectionTime {
  SectionTime(this.index, this.label, this.start, this.end);

  final int index;
  final String label;
  final String start;
  final String end;

  int startMinutes() => SectionTimeStore.toMinutes(start);

  /// 下课时刻的分钟数（0:00 起算），解析失败返回 -1。
  ///
  /// 判断「这节课上完没有」必须用它，**不能用 startMinutes** ——
  /// 按开始时刻算会把正在上的课标成已上完（14:23 时 14:00 那节仍在进行中）。
  /// 鸿蒙端与 Kotlin 侧都按结束时刻判断，这里保持一致。
  int endMinutes() => SectionTimeStore.toMinutes(end);
}

class SectionTimeStore {
  static List<SectionTime>? _times;

  static List<SectionTime> _official() => kSections
      .map((SectionDef s) => SectionTime(s.index, s.label, s.start, s.end))
      .toList();

  static Future<void> load() async {
    if (_times != null) {
      return;
    }
    final String raw = PrefStore.loadSectionTimes();
    if (raw.isEmpty) {
      _times = _official();
      return;
    }
    final List<String> segs = raw.split(';');
    if (segs.length != kSections.length) {
      _times = _official();
      return;
    }
    final List<SectionTime> parsed = <SectionTime>[];
    for (int i = 0; i < segs.length; i++) {
      final List<String> parts = segs[i].split('-');
      if (parts.length != 2) {
        _times = _official();
        return;
      }
      final String start = parts[0].trim();
      final String end = parts[1].trim();
      // 逐项校验格式，而不是只看「有没有减号」。
      //
      // 为什么必须校验：这段串是**外部数据**（preferences 文件，可能被
      // 旧版本写坏、被备份还原搞乱、或被手工改过）。若放过 `abc-def`
      // 这类值，它会一路流到提醒计算里 —— 而 `toMinutes` 对非法值返回
      // -1，最终表现为「某节课的提醒时间莫名奇妙」，很难反查到源头。
      // 宁可整份回退到官方值：作息是可恢复的配置，不是用户数据。
      if (toMinutes(start) < 0 || toMinutes(end) < 0 || start.length > 5 || end.length > 5) {
        _times = _official();
        return;
      }
      parsed.add(SectionTime(i, kSections[i].label, start, end));
    }
    _times = parsed;
  }

  static List<SectionTime> all() => _times ?? _official();

  /// 清空进程内缓存，让下一次 [load] 重新从存储读。
  ///
  /// 只给测试用：这个类的静态缓存是「一次进程一份」的语义，
  /// 测试里要模拟「重启 App」必须能把它清掉，否则用例之间会互相串味。
  @visibleForTesting
  static Future<void> resetCacheForTest() async {
    _times = null;
  }

  static SectionTime? at(int index) {
    final List<SectionTime> list = all();
    if (index < 0 || index >= list.length) {
      return null;
    }
    return list[index];
  }

  /// 是否是**官方**作息（即用户没手动改过）。
  ///
  /// ===== 为什么不能拿存储值和 [kSections] 逐项比 =====
  /// 早先的判据正是那样，它有个致命后果：官网改了作息 → 我们自动同步一次
  /// → 存储值不再等于包内常量 → 下次刷新被判成「用户自定义」而跳过，
  /// **此后官网任何改动都进不来**，而用户从没改过任何东西；
  /// 设置页也会错误地显示「已自定义」。而且包内常量随包固化，
  /// 装机后本就代表不了「官网当前值」。
  ///
  /// 现在读一个**来源标记**：只有用户在设置里保存时才置位。
  /// 自动同步只写值、不置位，因此可以一直跟随官网。
  static bool isDefault() => !PrefStore.loadSectionTimesCustom();

  static Future<void> save() async {
    final List<SectionTime> list = _times ?? _official();
    final String v = list.map((SectionTime s) => '${s.start}-${s.end}').join(';');
    await PrefStore.saveSectionTimes(v);
  }

  /// 保存**用户手动编辑**的作息。
  ///
  /// 会置位「已自定义」标记 —— 这是用户意图，从此不再被官网同步覆盖。
  static Future<void> saveAll(List<SectionTime> list) async {
    _times = list;
    await save();
    await PrefStore.saveSectionTimesCustom(true);
  }

  /// 保存**从官网同步来**的作息。
  ///
  /// 与 [saveAll] 的唯一区别是**不置位**自定义标记 ——
  /// 这是官网的值，以后官网再改还要能同步进来。
  static Future<void> saveOfficial(List<SectionTime> list) async {
    _times = list;
    await save();
  }

  /// 恢复官方默认作息：这是用户主动选择的行为，
  /// 因此要**清掉**自定义标记，让后续官网同步重新生效。
  static Future<void> resetToDefault() async {
    _times = _official();
    await save();
    await PrefStore.saveSectionTimesCustom(false);
  }

  /// `HH:mm` → 分钟数；非法返回 -1
  static int toMinutes(String hhmm) {
    final List<String> p = hhmm.split(':');
    if (p.length != 2) {
      return -1;
    }
    final int? h = int.tryParse(p[0]);
    final int? m = int.tryParse(p[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return -1;
    }
    return h * 60 + m;
  }

  /// 把 `H:mm` / `HH:m` 这类写法补零成 `HH:mm`。
  ///
  /// 只做补零、不做解析：合法性由 [toMinutes] 把关，走到这里时输入已可解析。
  static String normalize(String v) {
    final List<String> p = v.split(':');
    if (p.length != 2) {
      return v;
    }
    return '${p[0].padLeft(2, '0')}:${p[1].padLeft(2, '0')}';
  }

  /// 校验并规范化一批「用户输入的作息」，返回可直接保存的列表。
  ///
  /// 抽成纯函数放在 store 里，而不是留在设置页的 `_editSectionTimes` 内联 ——
  /// 那段逻辑曾经**写错过**（校验新值、却保存了旧的 `draft`），
  /// 表现为「改了时间点保存没反应」。内联在页面方法里时，它极难被测到；
  /// 抽出来之后就能直接对着这个契约写用例。
  ///
  /// [labels] 只用于报错文案（「第三、四节：结束时间应晚于开始时间」），
  /// 长度需与 [starts]/[ends] 一致。
  ///
  /// 返回 null 表示校验失败，[error] 里是对用户的一句话说明。
  static List<SectionTime>? validateAndBuild({
    required List<String> starts,
    required List<String> ends,
    required List<String> labels,
    required void Function(String message) error,
  }) {
    if (starts.length != ends.length || starts.length != labels.length) {
      error('数据不完整，请重新打开此页面');
      return null;
    }
    final List<SectionTime> out = <SectionTime>[];
    for (int i = 0; i < starts.length; i++) {
      final String sv = starts[i].trim();
      final String ev = ends[i].trim();
      final int s = toMinutes(sv);
      final int e = toMinutes(ev);
      if (s < 0 || e < 0) {
        error('${labels[i]}：时间格式应为 HH:mm，例如 08:30');
        return null;
      }
      if (e <= s) {
        error('${labels[i]}：结束时间应晚于开始时间');
        return null;
      }
      // 统一补零，否则存进去的「8:5」在提醒与卡片里显示会不齐
      out.add(SectionTime(i, labels[i], normalize(sv), normalize(ev)));
    }
    return out;
  }

  /// 供界面展示：`第1大节 08:30 起，共 5 段`
  static String hint() {
    final List<SectionTime> list = all();
    if (list.isEmpty) {
      return '未设置';
    }
    return '第1大节 ${list.first.start} 起，共 ${list.length} 段';
  }
}
