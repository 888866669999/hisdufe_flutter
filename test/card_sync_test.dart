/// 桌面卡片「周级快照」与「用户意图标记」的单元测试
///
/// 这两块都是在真机上暴露出来的体验缺陷，靠肉眼回归很容易漏，
/// 因此把契约钉在测试里：
///
///   1. **卡片同步不及时**的根因是主应用只写了一份「算好的今天」，
///      卡片重画旧数据 —— 跨天/时段变化都不会更新。现在改为写整周课表，
///      由卡片自己按当前时间筛课。这里锁住那份载荷的结构与筛选语义。
///   2. **还要手动点重试**的根因是用户点导航触发的首次加载被当成
///      「自动加载」，续期被间隔限制挡掉。这里锁住一次性标记的取用语义。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisdufe_jw/common/constants.dart';
import 'package:hisdufe_jw/data/card_snapshot_store.dart';
import 'package:hisdufe_jw/data/pref_store.dart';
import 'package:hisdufe_jw/data/re_auth_service.dart';
import 'package:hisdufe_jw/data/section_time_store.dart';
import 'package:hisdufe_jw/model/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 造一张可控的课表：只在指定 (row, col) 放一门课
Timetable _tt(List<CellData> cells) => Timetable(semester: '2026-2027-1', cells: cells);

CourseEntry _course({
  String name = '大学物理',
  int startWeek = 1,
  int endWeek = 18,
  int parity = 0,
  String room = '7-120',
  String campus = '章丘',
}) =>
    CourseEntry(
      id: name,
      courseName: name,
      teacher: '李静',
      room: room,
      campus: campus,
      startWeek: startWeek,
      endWeek: endWeek,
      parity: parity,
    );

Map<String, dynamic> _weekOf(Timetable t, {String startMonday = '2026-08-24'}) =>
    jsonDecode(jsonEncode(CardSnapshotStore.buildWeek(t, startMonday)))
        as Map<String, dynamic>;

void main() {
  setUp(() async {
    // 每个用例都从干净的存储开始（resetCacheForTest 的原因见
    // section_time_store_test.dart 里同一处说明）。
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PrefStore.resetCacheForTest();
    await PrefStore.init();
    await SectionTimeStore.resetCacheForTest();
    // 节次作息要就位，否则 sections 会是空串（卡片拿不到上课时刻）
    await SectionTimeStore.load();
  });

  group('周级快照载荷', () {
    test('包含卡片自算「今天」所需的全部字段', () {
      final Map<String, dynamic> w = _weekOf(_tt(<CellData>[
        CellData(row: 0, col: 0, entries: <CourseEntry>[_course()]),
      ]));
      expect(w.containsKey('startMonday'), isTrue);
      expect(w['startMonday'], '2026-08-24');
      expect(w.containsKey('maxWeeks'), isTrue);
      expect(w.containsKey('sections'), isTrue);
      expect(w.containsKey('sectionEnds'), isTrue,
          reason: '卡片要靠下课时刻判断「已上完」，缺了它只能按开始时间猜');
      expect(w.containsKey('days'), isTrue);
      // 7 天，索引 0=周一
      expect((w['days'] as List<dynamic>).length, 7);
      // 每行的上课时刻与官方作息一致
      expect((w['sections'] as List<dynamic>).first, '08:30');
      // 下课时刻也要给到，且与官方作息一致
      expect((w['sectionEnds'] as List<dynamic>).first, '10:00');
    });

    test('sectionEnds 与 sections 一一对应、长度相同', () {
      final Map<String, dynamic> w = _weekOf(_tt(<CellData>[]));
      final List<dynamic> s = w['sections'] as List<dynamic>;
      final List<dynamic> e = w['sectionEnds'] as List<dynamic>;
      expect(e.length, s.length);
      // 每一段的结束都要晚于开始（否则卡片的「已上完」判断会立刻为真）
      for (int i = 0; i < s.length; i++) {
        final int a = SectionTimeStore.toMinutes(s[i] as String);
        final int b = SectionTimeStore.toMinutes(e[i] as String);
        expect(b, greaterThan(a), reason: '第 ${i + 1} 段: $a -> $b');
      }
    });

    test('total 等于所有天的课程数之和（用于「不写空表」的判断）', () {
      final Timetable t = _tt(<CellData>[
        CellData(row: 0, col: 0, entries: <CourseEntry>[_course(), _course(name: '英语')]),
        CellData(row: 2, col: 3, entries: <CourseEntry>[_course(name: '离散数学')]),
      ]);
      final Map<String, dynamic> w = _weekOf(t);
      expect(w['total'], 3);
    });

    test('空课表的 total 是 0', () {
      expect(_weekOf(_tt(<CellData>[]))['total'], 0);
    });

    test('课程落到正确的星期列，并带上周次区间与单双周', () {
      // 周三（col=2）第 3 行
      final Map<String, dynamic> w = _weekOf(_tt(<CellData>[
        CellData(
          row: 2,
          col: 2,
          entries: <CourseEntry>[
            _course(name: '离散数学', startWeek: 3, endWeek: 9, parity: 2),
          ],
        ),
      ]));
      final List<dynamic> days = w['days'] as List<dynamic>;
      expect(days[0], isEmpty, reason: '周一没课');
      expect((days[2] as List<dynamic>).length, 1, reason: '周三有一门');
      final Map<String, dynamic> c =
          (days[2] as List<dynamic>).first as Map<String, dynamic>;
      expect(c['name'], '离散数学');
      expect(c['row'], 2);
      expect(c['startWeek'], 3);
      expect(c['endWeek'], 9);
      expect(c['parity'], 2);
    });

    test('教室带上校区，与页面展示一致', () {
      final Map<String, dynamic> w = _weekOf(_tt(<CellData>[
        CellData(row: 0, col: 0, entries: <CourseEntry>[_course()]),
      ]));
      final Map<String, dynamic> c = ((w['days'] as List<dynamic>).first
          as List<dynamic>).first as Map<String, dynamic>;
      expect(c['room'], '7-120(章丘)');
    });

    test('无校区时只给教室号（不出现空括号）', () {
      final Map<String, dynamic> w = _weekOf(_tt(<CellData>[
        CellData(
          row: 0,
          col: 0,
          entries: <CourseEntry>[_course(room: 'B203', campus: '')],
        ),
      ]));
      final Map<String, dynamic> c = ((w['days'] as List<dynamic>).first
          as List<dynamic>).first as Map<String, dynamic>;
      expect(c['room'], 'B203');
    });

    test('空课表也能生成合法载荷（days 是 7 个空数组，不是 null）', () {
      final Map<String, dynamic> w = _weekOf(_tt(<CellData>[]));
      final List<dynamic> days = w['days'] as List<dynamic>;
      expect(days.length, 7);
      expect(days.every((dynamic d) => (d as List<dynamic>).isEmpty), isTrue);
    });

    test('载荷可被 JSON 往返（卡片侧读的就是序列化后的文本）', () {
      final Timetable t = _tt(<CellData>[
        CellData(row: 4, col: 6, entries: <CourseEntry>[_course()]),
      ]);
      final String raw = jsonEncode(CardSnapshotStore.buildWeek(t, '2026-08-24'));
      final Map<String, dynamic> back =
          jsonDecode(raw) as Map<String, dynamic>;
      expect((back['days'] as List<dynamic>)[6], isNotEmpty);
      expect(back['sections'], isNotEmpty);
    });
  });

  group('不拿空表覆盖已有数据（「卡片课程消失」的防线）', () {
    test('hasCourses：有课为真、无课为假', () {
      expect(
        CardSnapshotStore.hasCourses(_tt(<CellData>[
          CellData(row: 0, col: 0, entries: <CourseEntry>[_course()]),
        ])),
        isTrue,
      );
      expect(CardSnapshotStore.hasCourses(_tt(<CellData>[])), isFalse);
      // 有格子但没有课 → 视为「没课」
      expect(
        CardSnapshotStore.hasCourses(_tt(<CellData>[CellData(row: 0, col: 0)])),
        isFalse,
      );
    });

    test('null 课表不算「有课」', () {
      expect(CardSnapshotStore.hasCourses(null), isFalse);
    });

    test('上一次写的是有课的载荷时，空表被拦下', () async {
      // 先写入一份「有课」的载荷
      await CardSnapshotStore.refresh(
        _tt(<CellData>[
          CellData(row: 0, col: 0, entries: <CourseEntry>[_course()]),
        ]),
        '2026-08-24',
      );
      // 断言要看**周级载荷**：真正决定卡片显示的是它
      // （今日快照只看「今天」那一天，而测试里的课不一定落在今天）。
      expect(PrefStore.getText(kKeyCardWeek).contains('大学物理'), isTrue);

      // 再推一张空表：应当被跳过（桌面数据保持原样）
      await CardSnapshotStore.refresh(_tt(<CellData>[]), '2026-08-24');

      expect(PrefStore.getText(kKeyCardWeek).contains('大学物理'), isTrue,
          reason: '空表不该把已有课程抹掉');
    });

    test('上一次本来就是空的，空表照常写入（不误拦）', () async {
      await CardSnapshotStore.refresh(_tt(<CellData>[]), '2026-08-24');
      final String raw = PrefStore.getText(kKeyCardWeek);
      expect(raw.isNotEmpty, isTrue, reason: '首次写入空表是合法状态');
      expect(raw.contains('"total":0'), isTrue);
    });

    test('有课的新表正常覆盖（不能因为防呆而卡住更新）', () async {
      await CardSnapshotStore.refresh(
        _tt(<CellData>[
          CellData(row: 0, col: 0, entries: <CourseEntry>[_course(name: '旧课')]),
        ]),
        '2026-08-24',
      );
      await CardSnapshotStore.refresh(
        _tt(<CellData>[
          CellData(row: 1, col: 1, entries: <CourseEntry>[_course(name: '新课')]),
        ]),
        '2026-08-24',
      );
      final String raw = PrefStore.getText(kKeyCardWeek);
      expect(raw.contains('新课'), isTrue);
      expect(raw.contains('旧课'), isFalse);
    });
  });

  group('快照构建的容错（损坏数据不得抛异常）', () {
    test('课表字段异常时 refresh 不抛，且照常产出可渲染的载荷', () async {
      // 损坏数据的来源很现实：旧版本写下的缓存、被清理工具截断的 JSON、
      // 手工改过的 preferences。这类数据进到 `as String` 这种硬转换里
      // 会直接抛 TypeError，而调用链会把任何异常当成「会话失效」
      // 去触发重新登录 —— 表现成「课表打不开还让我重登」，极难定位。
      //
      // CourseEntry 的字段是 non-nullable，没法在测试里造出 null；
      // 这里改从**载荷**一侧验证契约：无论字段长什么样，
      // buildWeek/build 都必须返回结构完整的对象，不抛异常。
      final Timetable t = _tt(<CellData>[
        CellData(
          row: 0,
          col: 0,
          entries: <CourseEntry>[
            // 空字符串、越界的周次、未知的 parity —— 都是真实会遇到的脏值
            _course(name: '', room: '', campus: ''),
            _course(name: '越界周', startWeek: 99, endWeek: 1),
            _course(name: '怪 parity', parity: 7),
          ],
        ),
      ]);

      // 不抛异常。
      // 注意日期要选**周一**（课放在 col 0）—— build() 只产出「当天」的课，
      // 挑别的日子会得到 0 条，测不出容错。
      final CardSnapshot snap =
          CardSnapshotStore.build(t, '2026-08-24', DateTime(2026, 9, 14, 9));
      // 3 门里「越界周」（startWeek 99 > endWeek 1）会被周次过滤正确剔除，
      // 剩下 2 门 —— 这正是期望行为，不是 bug。
      expect(snap.courses.length, 2);
      expect(snap.courses.first.room, '', reason: '空教室不该变成空括号');

      final Map<String, dynamic> w = jsonDecode(jsonEncode(
        CardSnapshotStore.buildWeek(t, '2026-08-24'),
      )) as Map<String, dynamic>;
      expect(w['total'], 3);

      // refresh 全链路也不抛（它内部已兜住所有异常）
      await expectLater(
        CardSnapshotStore.refresh(t, '2026-08-24'),
        completes,
      );
    });

    test('refresh 在课表为 null 时返回 null，不抛', () async {
      final CardSnapshot? r = await CardSnapshotStore.refresh(null, '2026-08-24');
      expect(r, isNull);
    });

    test('startMonday 为空（未设开学日期）时仍能构建，week=0', () {
      final CardSnapshot s =
          CardSnapshotStore.build(_tt(<CellData>[]), '', DateTime(2026, 9, 18));
      expect(s.week, 0);
      // week=0 表示「周次未知」，此时不过滤课程（宁可多显示也不漏）
      expect(s.hasCourse, isFalse);
    });
  });

  group('周次筛选语义（与卡片侧 Kotlin 实现必须一致）', () {
    /// 这里直接复用 CourseEntry.isActiveInWeek —— 卡片侧 Kotlin
    /// 的 activeInWeek 是它的逐字翻版。任一侧改了过滤规则，
    /// 这个测试与卡片都会同时暴露出来。
    test('区间外不显示', () {
      final CourseEntry c = _course(startWeek: 3, endWeek: 9);
      expect(c.isActiveInWeek(2), isFalse);
      expect(c.isActiveInWeek(3), isTrue);
      expect(c.isActiveInWeek(9), isTrue);
      expect(c.isActiveInWeek(10), isFalse);
    });

    test('单周只看奇数周', () {
      final CourseEntry c = _course(parity: 1);
      expect(c.isActiveInWeek(1), isTrue);
      expect(c.isActiveInWeek(2), isFalse);
    });

    test('双周只看偶数周', () {
      final CourseEntry c = _course(parity: 2);
      expect(c.isActiveInWeek(2), isTrue);
      expect(c.isActiveInWeek(3), isFalse);
    });

    test('周次未知（0）时一律显示，宁可多显示也不要漏', () {
      final CourseEntry c = _course(startWeek: 10, endWeek: 12);
      expect(c.isActiveInWeek(0), isTrue);
    });
  });

  group('用户意图标记（决定「要不要用户手动点重试」）', () {
    test('默认没有标记 —— 冷启动必须保持安静', () {
      // 先清干净，避免受其它用例影响
      ReAuthService.consumeUserIntent();
      expect(ReAuthService.consumeUserIntent(), isFalse,
          reason: '没有导航时不该出现「用户主动」标记');
    });

    test('标记后可被取到', () {
      ReAuthService.consumeUserIntent();
      ReAuthService.noteUserIntent();
      expect(ReAuthService.consumeUserIntent(), isTrue);
    });

    test('取走即清零 —— 一次导航只让一次加载成为「主动」', () {
      ReAuthService.consumeUserIntent();
      ReAuthService.noteUserIntent();
      expect(ReAuthService.consumeUserIntent(), isTrue);
      expect(ReAuthService.consumeUserIntent(), isFalse,
          reason: '第二次加载不该继续算主动，否则自动重载会反复触发续期');
    });

    test('重复标记不叠加（多次导航只算一次）', () {
      ReAuthService.consumeUserIntent();
      ReAuthService.noteUserIntent();
      ReAuthService.noteUserIntent();
      expect(ReAuthService.consumeUserIntent(), isTrue);
      expect(ReAuthService.consumeUserIntent(), isFalse);
    });
  });

  group('重试预算（决定「会不会让用户看到登录框」）', () {
    test('交互路径允许 3 次提交，把失败率压到约 0.05%', () {
      // 单次实测约 92%：三次 = 1 - 0.08^3 ≈ 99.95%
      // 这正是「用户无需感知」所需的量级，且仍是有限的请求次数。
      expect(kMaxLoginAttempts, 3);
    });

    test('越界的尝试次数被夹回上限（防止把账号打到临时锁定）', () {
      // 这条规则由 clampLoginAttempts 直接实现，下面调用的是它本身
      expect(clampLoginAttempts(99), kMaxLoginAttempts);
      expect(clampLoginAttempts(10000), kMaxLoginAttempts);
      expect(clampLoginAttempts(0), 1);
      expect(clampLoginAttempts(-5), 1);
      // 区间内的值原样保留
      expect(clampLoginAttempts(1), 1);
      expect(clampLoginAttempts(2), 2);
      expect(clampLoginAttempts(3), 3);
    });
  });
}
