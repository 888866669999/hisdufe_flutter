/// 校历弹窗：官方校历图 + 官方作息表 + 校历备注
///
/// 从鸿蒙版 `SchedulePage.calendarSheet` 移植，并补齐了鸿蒙版没有的能力：
/// **从学校官网抓最新校历与作息表**（见 `CampusCalendarService`）。
///
/// 数据来源与两层兜底：
///   1. 联网抓 `https://www.sdufe.edu.cn/xyfw/zxxl.htm`（实测可直接抓，
///      正文含 HTML 作息表，两张校历图挂在 /virtual_attach_file.vsb 上）；
///   2. 抓不到就用上次成功缓存的图片与作息（落盘在应用私有目录）；
///   3. 从未联网成功过，就用内置的官方数据与随包图片
///      （`academic_calendar.dart` + `assets/calendar_2026_{1,2}.jpg`）。
/// 这样离线、改版、服务器故障都不会让这一页变成空白。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../data/academic_calendar.dart';
import '../data/campus_calendar_service.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';

/// 打开校历弹窗。
///
/// [semesterCode] 是当前学期代码（如 2026-2027-1），用来决定默认显示哪一学期。
Future<void> showAcademicCalendarSheet(
  BuildContext context, {
  String semesterCode = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => _CalendarSheet(
      initialTerm: AcademicCalendar.termIndexOf(semesterCode),
      semesterCode: semesterCode,
    ),
  );
}

class _CalendarSheet extends StatefulWidget {
  const _CalendarSheet({required this.initialTerm, required this.semesterCode});

  final int initialTerm;
  final String semesterCode;

  @override
  State<_CalendarSheet> createState() => _CalendarSheetState();
}

class _CalendarSheetState extends State<_CalendarSheet> {
  late int _term = widget.initialTerm;

  /// 内置图片（联网失败时的兜底；顺序与学期对应）
  static const List<String> _builtinImages = <String>[
    'assets/calendar_2026_1.jpg',
    'assets/calendar_2026_2.jpg',
  ];

  CampusCalendar? _data;
  bool _loading = true;
  bool _refreshing = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// 先展示已有数据（缓存/内置），再在后台尝试联网更新 —— 打开就有内容，
  /// 不会让用户盯着转圈等一次网络请求。
  Future<void> _init() async {
    final CampusCalendar local = await CampusCalendarService.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _data = local;
      _loading = false;
    });
    _refresh(silent: true);
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_refreshing) {
      return;
    }
    setState(() {
      _refreshing = true;
      if (!silent) {
        _error = '';
      }
    });
    final CampusCalendar? got = await CampusCalendarService.refresh();
    if (!mounted) {
      return;
    }
    setState(() {
      _refreshing = false;
      if (got != null) {
        _data = got;
        _error = '';
      } else if (!silent) {
        // 只有用户**主动**点刷新时才提示失败；静默刷新失败不打扰
        _error = CampusCalendarService.lastError.isEmpty
            ? '未能获取最新校历，已显示上次的数据'
            : '未能获取最新校历：${CampusCalendarService.lastError}';
      }
    });
  }

  /// 本学期要显示的官方图片：优先用联网缓存，缺哪张补内置的
  List<Widget> _images(BuildContext context, bool wide) {
    final List<String> cached = _data?.images ?? <String>[];
    Widget one(int term) {
      final bool online = term < cached.length;
      final String src = online ? cached[term] : _builtinImages[term];
      final ImageProvider<Object> provider = online
          ? FileImage(File(src)) as ImageProvider<Object>
          : AssetImage(src) as ImageProvider<Object>;
      return ClipRRect(
        borderRadius: BorderRadius.circular(Gaps.radiusSm),
        child: Image(
          image: provider,
          fit: BoxFit.contain,
          errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
              _imageFallback(context, term, online),
        ),
      );
    }

    if (wide) {
      return <Widget>[
        Expanded(child: one(0)),
        const SizedBox(width: Gaps.m),
        Expanded(child: one(1)),
      ];
    }
    return <Widget>[one(_term)];
  }

  /// 联网缓存损坏时退回内置图
  Widget _imageFallback(BuildContext context, int term, bool wasOnline) {
    if (wasOnline) {
      return Image.asset(
        _builtinImages[term],
        fit: BoxFit.contain,
        errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
            _missing(context),
      );
    }
    return _missing(context);
  }

  Widget _missing(BuildContext context) => Container(
        height: 120,
        alignment: Alignment.center,
        color: context.surfaceVariant,
        child: Text('校历图片缺失，请重新安装应用',
            style: TextStyle(fontSize: 12, color: context.textTertiary)),
      );

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;
    final bool wide = size.width >= 720;
    if (_loading) {
      return GlassKit.surface(
        context,
        radius: 18,
        child: SizedBox(
          height: size.height * 0.4,
          child: Center(
            child: Text('正在读取校历…',
                style: TextStyle(fontSize: 13, color: context.textTertiary)),
          ),
        ),
      );
    }

    final CampusCalendar? d = _data;
    final List<String> lines = d?.sections ?? AcademicCalendar.sectionLines();

    // 校历弹窗整块用**玻璃面板**（原先是不透明白底）。
    // 它是典型的「浮在内容之上」的浮层，玻璃在这里语义正确，
    // 也让弹窗与已玻璃化的导航栏/选择器观感一致。
    return GlassKit.surface(
      context,
      radius: 22,
      child: SizedBox(
        width: size.width,
        height: size.height * 0.88,
        child: Column(
        children: <Widget>[
          _handle(),
          _title(context),
          _termSwitch(context),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gaps.l, 0, Gaps.l, Gaps.s),
              child: Text(_error,
                  style: TextStyle(fontSize: 11, color: context.warningColor)),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(Gaps.l, 0, Gaps.l, Gaps.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 校历图：宽屏左右并排，窄屏只显示当前学期，避免被压得过小
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _images(context, true),
                    )
                  else
                    ..._images(context, false),
                  const SizedBox(height: Gaps.l),
                  _sectionTable(context, lines),
                  const SizedBox(height: Gaps.m),
                  // 这里**刻意不显示「备注」**（报到/假期等文字）。
                  //
                  // 原因：那些内容是从校历**图片**上人工转录、硬编码在
                  // `AcademicCalendar.SEMESTER_CALENDARS` 里的，官网正文
                  // 并不提供（实测页面文本中完全没有这些字）。
                  // 硬编码的假期日期一旦与官方调整不符，就成了
                  // 「看起来权威的错误信息」—— 比不显示更糟。
                  // 校历图与作息表本身都抓自官网，且上方有「刷新」可重新抓取，
                  // 用户想核对一手信息看图片即可。
                ],
              ),
            ),
          ),
          _closeBar(context),
          ],
        ),
      ),
    );
  }

  Widget _handle() => Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        decoration: BoxDecoration(
          color: context.dividerColor,
          borderRadius: BorderRadius.circular(2),
        ),
      );

  Widget _title(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gaps.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('校历',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                )),
            const SizedBox(height: 2),
            Text('来源：山东财经大学「校园服务 · 最新校历」',
                style: TextStyle(fontSize: 11, color: context.textTertiary)),
          ],
        ),
      );

  Widget _termSwitch(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gaps.l, Gaps.m, Gaps.l, Gaps.m),
        child: Row(
          children: <Widget>[
            for (int t = 0; t < 2; t++) ...<Widget>[
              if (t > 0) const SizedBox(width: Gaps.s),
              GestureDetector(
                onTap: () => setState(() => _term = t),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: _term == t
                        ? context.brandColor
                        : context.surfaceVariant,
                    borderRadius: BorderRadius.circular(Gaps.radiusSm),
                  ),
                  child: Text(t == 0 ? '第一学期' : '第二学期',
                      style: TextStyle(
                        fontSize: 13,
                        color: _term == t
                            ? AppColors.onBrand
                            : context.textPrimary,
                      )),
                ),
              ),
            ],
          ],
        ),
      );

  Widget _sectionTable(BuildContext context, List<String> lines) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gaps.m),
        decoration: BoxDecoration(
          color: context.surfaceVariant,
          borderRadius: BorderRadius.circular(Gaps.radiusSm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('日常教学时刻表',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    )),
                const Spacer(),
                if (_refreshing)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: context.textTertiary,
                    ),
                  )
                else
                  GestureDetector(
                    onTap: () => _refresh(),
                    child: Text('刷新',
                        style: TextStyle(
                            fontSize: 12, color: context.brandColor)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            for (final String line in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 13,
                    // 课间休息弱化显示：它是说明，不是可上课的节次
                    color: line.contains('课间')
                        ? context.textTertiary
                        : context.textSecondary,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Text('此处为学校官方的作息时刻；「设置 → 节次作息」可本地微调，上课提醒按该值计算。',
                style: TextStyle(fontSize: 11, color: context.textTertiary)),
          ],
        ),
      );

  Widget _closeBar(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gaps.l, Gaps.s, Gaps.l, Gaps.m),
          child: SizedBox(
            width: double.infinity,
            height: 46,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                // 半透明而非实色：玻璃面板上再放实色块会显得突兀
                backgroundColor: context.surfaceColor.withValues(alpha: 0.35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Gaps.radiusSm),
                ),
              ),
              child: Text('关闭',
                  style: TextStyle(
                    fontSize: 15,
                    color: context.textPrimary,
                  )),
            ),
          ),
        ),
      );
}
