/// 通选课各大类的「总学分要求」本地配置
///
/// 从鸿蒙版 `data/ElectiveRequirementStore.ets` 移植，存储形态与语义保持一致。
///
/// ===== 为什么需要它 =====
/// 学校页面「要求学分（大于等于）」一列实测是**空的**（学校没有录入），
/// 于是 App 只能显示「学校未设置要求」，学生无从知道还差多少学分，
/// 进度条也画不出来（没有分母）。
/// 而每个专业的通选学分要求都明明白白写在培养方案里、对学生是确定的，
/// 所以让用户自己录一次：录完即可长期使用，界面立刻能算「还差 X 学分」。
///
/// ===== 为什么按账号分片 =====
/// 要求学分挂在**专业**上，同机换账号（不同专业/年级）时要求不同，
/// 串用会让 B 看到 A 的要求 —— 与课表缓存按账号分文件是同一个理由。
///
/// 存储形态：一个 JSON 数组
///   [{"a":"账号","c":"大类名","v":12},{"a":"账号","c":"其他类","v":8}]
/// 用数组而不是「账号|大类 → 值」的复合键对象：后者依赖分隔符不出现在
/// 大类名里，属于隐式约定；数组显式分字段，不会因为学校改个大类名就串行。
library;

import 'dart:convert';

import '../common/constants.dart';
import 'pref_store.dart';

/// 要求学分的合理上限：通选课总学分不可能到这个量级，用于挡住误输入
const double kMaxRequiredCredit = 200;

class ElectiveRequirementStore {
  /// 读取某账号的全部自定义要求。
  ///
  /// 返回以**大类名**为键的 Map（调用方只关心「这个大类要求多少」，
  /// 不需要再知道账号 —— 账号已在读的时候筛过了）。
  /// 任何异常都返回空表：这只是锦上添花的配置，读不到不该影响主流程。
  static Map<String, double> load(String account) {
    final Map<String, double> out = <String, double>{};
    if (account.isEmpty) {
      return out;
    }
    final String raw = PrefStore.getText(kKeyElectiveRequired);
    if (raw.isEmpty) {
      return out;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) {
        return out;
      }
      for (final Object? item in decoded) {
        if (item is! Map) {
          continue;
        }
        final Object? a = item['a'];
        final Object? c = item['c'];
        final Object? v = item['v'];
        if (a is! String || c is! String || v is! num) {
          continue;
        }
        if (a == account && c.isNotEmpty && isValid(v.toDouble())) {
          out[c] = v.toDouble();
        }
      }
    } catch (_) {
      // 内容损坏时当作空表：宁可让用户重录，也不能让整页加载失败
      return out;
    }
    return out;
  }

  /// 写入（或清除）某账号某个大类的要求学分。
  ///
  /// [value] < 0 表示**清除**该大类的自定义要求，让它回落到服务器的值
  /// （学校绝大多数是空，于是界面回到「学校未设置要求」）。
  /// 这样「清除」与「设为某个数」共用一条写入路径，不必各写一遍。
  ///
  /// 返回是否写入成功。
  static Future<bool> save(
    String account,
    String category,
    double value,
  ) async {
    if (account.isEmpty || category.isEmpty) {
      return false;
    }
    if (value >= 0 && !isValid(value)) {
      return false;
    }
    final List<Map<String, Object>> all = _loadAll();
    final List<Map<String, Object>> next = <Map<String, Object>>[];
    for (final Map<String, Object> it in all) {
      final bool sameAccount = it['a'] == account;
      final bool sameCategory = it['c'] == category;
      if (sameAccount && sameCategory) {
        continue; // 由下面按 value 决定是否重新写入
      }
      next.add(it);
    }
    if (value >= 0) {
      next.add(<String, Object>{'a': account, 'c': category, 'v': value});
    }
    await PrefStore.putText(kKeyElectiveRequired, jsonEncode(next));
    return true;
  }

  /// 清除某账号的全部自定义要求（退出登录时调用，避免跨账号串用）
  static Future<void> clearAccount(String account) async {
    if (account.isEmpty) {
      return;
    }
    final List<Map<String, Object>> all = _loadAll();
    final List<Map<String, Object>> next = <Map<String, Object>>[];
    for (final Map<String, Object> it in all) {
      if (it['a'] != account) {
        next.add(it);
      }
    }
    await PrefStore.putText(kKeyElectiveRequired, jsonEncode(next));
  }

  /// 解析全部记录（所有账号）。
  ///
  /// 单独抽出来是因为 save / clear 都要「读全量 → 改 → 写回」，
  /// 若各自解析一遍，两处的容错行为容易走偏。
  static List<Map<String, Object>> _loadAll() {
    final String raw = PrefStore.getText(kKeyElectiveRequired);
    final List<Map<String, Object>> out = <Map<String, Object>>[];
    if (raw.isEmpty) {
      return out;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) {
        return out;
      }
      for (final Object? item in decoded) {
        if (item is! Map) {
          continue;
        }
        final Object? a = item['a'];
        final Object? c = item['c'];
        final Object? v = item['v'];
        if (a is String && a.isNotEmpty &&
            c is String && c.isNotEmpty &&
            v is num && isValid(v.toDouble())) {
          out.add(<String, Object>{'a': a, 'c': c, 'v': v.toDouble()});
        }
      }
    } catch (_) {
      return out;
    }
    return out;
  }

  /// 合法范围：0 以上且不超上限（0 表示「不需要修」也是一种合法要求）
  static bool isValid(double v) => !v.isNaN && v >= 0 && v <= kMaxRequiredCredit;

  /// 把用户输入解析成数值；非法返回 -1。
  ///
  /// 只接受「数字 + 最多一个小数点」，避免 `double.tryParse` 把 "12abc" 读成 12。
  static double parseInput(String text) {
    final String t = text.trim();
    if (t.isEmpty) {
      return -1;
    }
    if (!RegExp(r'^\d+(\.\d)?$').hasMatch(t)) {
      return -1;
    }
    final double v = double.tryParse(t) ?? -1;
    return isValid(v) ? v : -1;
  }
}
