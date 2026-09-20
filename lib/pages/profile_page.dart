/// 个人信息页
///
/// 从鸿蒙版 `pages/ProfilePage.ets` 移植。
///
/// ===== 头像 =====
/// 圆形。默认显示**应用图标**（`assets/logo.png`，与桌面图标同一份源图）；
/// 用户可以从相册选图、在应用内裁切后替换（见 [AvatarStore] 与
/// [AvatarCropDialog]）。裁切与存储都在本地完成，不上传任何图片。
///
/// ===== 页面结构：头部恒在，只有数据区降级 =====
/// 本页是**窄屏下进入设置的唯一入口**（齿轮按钮在头部卡片右端）。
/// 早期版本把整个页面写成「加载态 / 错误态 / 成功态」三选一，
/// 于是离线时头部连齿轮一起消失 —— 用户既看不到自己的信息，
/// **也再没有路径打开设置页**（设置本身不联网，本可以正常使用）。
/// 现在改为：头部（头像 + 姓名 + 齿轮）永远渲染，
/// 只有它下面的资料区在「加载中 / 出错 / 有数据」之间切换。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../common/constants.dart';
import '../data/app_state.dart';
import '../data/avatar_store.dart';
import '../data/page_cache.dart';
import '../data/re_auth_service.dart';
import '../model/models.dart';
import '../parser/profile_parser.dart';
import '../theme/glass_kit.dart';
import '../theme/theme.dart';
import '../widgets/app_refresh.dart';
import '../widgets/avatar_crop_dialog.dart';
import '../widgets/state_views.dart';
import '../widgets/top_fade_blur.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({this.onOpenSettings, super.key});

  /// 打开设置页。由外壳传入（页面自己不知道导航结构）。
  ///
  /// 入口放在**顶部个人卡片的正右侧**：个人卡片是该页最显眼的元素，
  /// 设置与「我的」在语义上也最贴近，比塞进顶栏更符合直觉。
  final VoidCallback? onOpenSettings;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _loading = true;
  String _error = '';
  /// 操作类提示（如换头像失败）。与 _error 分开：那个是「整页加载失败」，
  /// 会替掉整个页面；这里只是「刚做的某件事没成功」，不该动已有内容。
  String _actionHint = '';
  StudentProfile? _profile;

  /// 当前头像文件。为 null 表示用的是默认头像（应用图标）。
  File? _avatar;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
    // 先用内存缓存填满首帧，再交给 _load 决定要不要联网。
    // 这样切页回来（缓存还在内存里）不会闪一下加载态。
    _profile = _loader().peek();
    _load();
  }

  Future<void> _loadAvatar() async {
    final File? f = await AvatarStore.current();
    if (!mounted) {
      return;
    }
    setState(() => _avatar = f);
  }

  /// 从相册选图 → 应用内裁切 → 保存。
  ///
  /// 失败路径都给出明确原因：选图被取消是正常操作（静默返回），
  /// 而「读不出那张图」（比如选了个改了扩展名的文件）要告诉用户换一张，
  /// 否则点了确认没反应会让人以为应用卡了。
  Future<void> _pickAvatar() async {
    try {
      final XFile? picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // 不让插件做压缩与裁切：它自带的裁切是系统 UI，与本应用的玻璃风格
        // 割裂，而且我们要自己控制输出尺寸。这里只要原始字节。
        maxWidth: 2400,
        maxHeight: 2400,
      );
      if (picked == null || !mounted) {
        return; // 用户取消了
      }
      final Uint8List bytes = await picked.readAsBytes();
      if (!mounted) {
        return;
      }

      final Uint8List? cropped = await showDialog<Uint8List>(
        context: context,
        builder: (BuildContext ctx) => AvatarCropDialog(imageBytes: bytes),
      );
      if (cropped == null || !mounted) {
        return; // 用户取消了裁切
      }

      final File saved = await AvatarStore.save(cropped);
      if (!mounted) {
        return;
      }
      setState(() => _avatar = saved);
    } catch (e) {
      if (!mounted) {
        return;
      }
      // 走页面内提示，**不用 SnackBar**：本应用的壳是 GlassScaffold
      // （内部 CupertinoPageScaffold），树里没有 Material 的 Scaffold，
      // ScaffoldMessenger 的 showSnackBar 会因缺少 Scaffold 而不显示
      // （assert `_scaffolds.isNotEmpty`）。这个坑在 PDF 下载那里踩过。
      setState(() => _actionHint = '无法读取这张图片，请换一张试试');
    }
  }

  /// 移除自定义头像，回到默认（应用图标）
  Future<void> _clearAvatar() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('恢复默认头像'),
        content: const Text('将移除你设置的头像，恢复为应用默认图标。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    await AvatarStore.clear();
    if (!mounted) {
      return;
    }
    setState(() => _avatar = null);
  }

  /// 点头像：已自定义过就弹出「换一张 / 恢复默认」，
  /// 否则直接进选图流程（少一次点击）。
  Future<void> _tapAvatar() async {
    if (_avatar == null) {
      await _pickAvatar();
      return;
    }
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GlassKit.surface(
            ctx,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  leading: Icon(Icons.photo_library_outlined,
                      color: ctx.brandColor),
                  title: const Text('换一张'),
                  onTap: () => Navigator.pop(ctx, 'pick'),
                ),
                ListTile(
                  leading: Icon(Icons.restart_alt, color: ctx.textSecondary),
                  title: const Text('恢复默认头像'),
                  onTap: () => Navigator.pop(ctx, 'clear'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || choice == null) {
      return;
    }
    if (choice == 'pick') {
      await _pickAvatar();
    } else if (choice == 'clear') {
      await _clearAvatar();
    }
  }

  Future<void> _load({bool interactive = false, bool force = false}) async {
    // 用户点导航进来的首次加载同样算「主动操作」：
    // 否则会话失效时只会给一句内联提示，逼迫用户再点一次「重试」。
    // 标记是一次性的（取走即清零），冷启动不受影响。
    interactive = interactive || ReAuthService.consumeUserIntent();
    // 已有内容时不显示整屏加载态：切页回来应该立刻看到旧资料，
    // 新数据到了再替换（否则每次切页都闪一下「正在获取个人信息…」）。
    setState(() {
      _error = '';
      if (_profile == null) {
        _loading = true;
      }
    });
    try {
      final PageLoadResult<StudentProfile> r = await _loader().load(force: force);
      if (!mounted) {
        return;
      }
      _applyProfile(r.data);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) {
        return;
      }
      // 会话失效时**先尝试静默续期**（用已保存的账号密码 + OCR 自动登录），
      // 成功就直接重载，用户完全无感；只有续期也失败才置弹窗标记。
      final bool renewed = await ReAuthService.handlePageError(e, (String msg) {
        setState(() {
          _loading = false;
          // 已有缓存内容时不清空 _profile：让用户继续看到旧资料，
          // 只在顶部提示这次刷新失败了
          _error = msg;
        });
      }, interactive: interactive);
      if (renewed && mounted) {
        await _load(force: force);
      }
    }
  }

  /// 缓存 key 随账号变化，所以每次现取 —— 不能缓存在字段里：
  /// 登出再登录（换账号）时页面可能不重建，字段会留下上一个账号的 key，
  /// 后果是 B 读到 A 的缓存。
  PageDataLoader<StudentProfile> _loader() => PageDataLoader<StudentProfile>(
        key: PageCache.keyOf(AppState.instance.account, kCacheProfile),
        fetch: AppState.instance.api.getProfileHtml,
        parse: ProfileParser.parse,
        ttl: kTtlProfile,
      );

  /// 把解析结果落进页面状态，并顺手同步姓名/学号到全局（顶部会显示）
  void _applyProfile(StudentProfile p) {
    if (p.name.isNotEmpty) {
      AppState.instance.studentName = p.name;
    }
    if (p.studentId.isNotEmpty) {
      AppState.instance.studentId = p.studentId;
    }
    _profile = p;
  }

  @override
  Widget build(BuildContext context) {
    // ===== 头部恒在 =====
    // 齿轮是窄屏下唯一的设置入口，任何「整页替换」的加载/错误态都会把它
    // 一起替换掉，于是离线时设置页变得不可达（而设置页本身不联网）。
    // 结构固定为：头部 + 「资料区的三态」，头部不参与状态切换。
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: AppRefresh(
            onRefresh: () => _load(force: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(Gaps.page, appBarInset(context) + Gaps.page,
                  Gaps.page, Gaps.page + Gaps.scrollTail),
              children: <Widget>[
                if (_actionHint.isNotEmpty) ...<Widget>[
                  _actionHintBanner(),
                  const SizedBox(height: Gaps.m),
                ],
                // 刷新失败但还有旧数据时的提示（比整屏报错温和得多）
                if (_error.isNotEmpty && _profile != null) ...<Widget>[
                  _staleBanner(),
                  const SizedBox(height: Gaps.m),
                ],
                _header(),
                const SizedBox(height: Gaps.m),
                ..._body(),
              ],
            ),
          ),
        ),
        const TopFadeBlur(),
      ],
    );
  }

  /// 资料区的四种情况：首屏加载 / 无数据且出错 / 无数据 / 有数据
  List<Widget> _body() {
    final StudentProfile? p = _profile;
    if (p != null && p.sections.isNotEmpty) {
      return <Widget>[
        for (final ProfileSection s in p.sections) ...<Widget>[
          GroupTitle(s.title),
          GroupBox(
            children: <Widget>[
              for (final ProfileField f in s.fields) _fieldRow(f, s.fields.last == f),
            ],
          ),
          const SizedBox(height: Gaps.m),
        ],
      ];
    }
    if (_loading) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: LoadingView(message: '正在获取个人信息…'),
        ),
      ];
    }
    // 没有数据（从未取到，或缓存被清）：给可重试的错误块。
    // 注意这**只是列表里的一项**，头部与齿轮仍在上面 —— 这正是本次修复的要点。
    return <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: <Widget>[
            Text(
              _error.isEmpty ? '暂无个人信息' : _error,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: context.textSecondary),
            ),
            const SizedBox(height: Gaps.m),
            FilledButton(
              onPressed: () => _load(interactive: true, force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    ];
  }

  /// 操作类提示条（可点掉，不遮挡已有内容）
  Widget _actionHintBanner() {
    return GestureDetector(
      onTap: () => setState(() => _actionHint = ''),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.dangerColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Gaps.radiusSm),
        ),
        child: Text(_actionHint,
            style: TextStyle(fontSize: 12, color: context.dangerColor)),
      ),
    );
  }

  /// 「刷新失败，以下是缓存内容」提示条
  Widget _staleBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.warningColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Gaps.radiusSm),
      ),
      child: Text(
        _error,
        style: TextStyle(fontSize: 12, color: context.textSecondary),
      ),
    );
  }

  /// 圆形头像：默认是应用图标，用户设置过则显示自己的图。
  ///
  /// 整个圆都是可点区域（换头像/恢复默认都在点击后的流程里）。
  /// 相机角标**只在用默认头像时**显示：那是「还没设过头像」的提示，
  /// 用户一旦设过就永久消失，不再打扰。
  Widget _avatarView() {
    const double side = 56;
    final File? f = _avatar;
    final bool isDefault = f == null;

    final Widget image = isDefault
        // 默认头像：应用图标本体（与桌面图标同一份源图）
        ? Padding(
            padding: const EdgeInsets.all(9),
            child: Image.asset('assets/logo.png', fit: BoxFit.contain),
          )
        : ClipOval(
            child: Image.file(
              f,
              width: side,
              height: side,
              fit: BoxFit.cover,
              // ===== 换完头像能立刻刷新，需要「key + 淘汰缓存」两件事 =====
              // 缺任何一个都会退化成「必须杀进程重进才变」：
              //
              //   1. **key 变了才会重新解析**。`Image.didUpdateWidget` 只在
              //      `widget.image != oldWidget.image` 时才调 `_resolveImage()`，
              //      而 `FileImage` 的相等性只看**文件路径** ——
              //      我们的头像永远是同一个 avatar.png，路径不变即为相等，
              //      于是根本不会去重新读文件。
              //      把「大小 + 修改时间」拼进 key，内容一变 key 就变，
              //      Flutter 会重建 element 并重新解析。
              //   2. **还要淘汰 ImageCache 里的旧条目**。全局图片缓存按
              //      路径做键，不淘汰的话重新解析时仍会命中旧图。
              //      那一步在 AvatarStore.save/clear 里做（见该文件说明）。
              key: ValueKey<String>(
                '${f.path}|${f.lengthSync()}|${f.lastModifiedSync().microsecondsSinceEpoch}',
              ),
              // 文件被外部删掉时不要抛异常，退回一个占位
              errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                  Icon(Icons.person, size: 26, color: context.brandColor),
            ),
          );

    return GestureDetector(
      onTap: _tapAvatar,
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: context.brandSoftColor,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: image,
              ),
            ),
            // 相机角标：仅默认头像时出现，提示「这里可以设头像」
            if (isDefault)
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                    // 描边用卡片底色，把角标从头像上「切」出来
                    border:
                        Border.all(color: context.surfaceVariant, width: 1.5),
                  ),
                  child: Icon(
                    Icons.photo_camera,
                    size: 11,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 头部卡片：头像 + 姓名 + 设置入口。
  ///
  /// **不依赖 [_profile]**：姓名/学号在没取到资料时退回全局状态里的值
  /// （登录时写入，见 AppState.studentName），仍然取不到就显示占位文案。
  /// 这样离线、首次安装等拿不到资料的情况下，头部与齿轮依旧可用。
  Widget _header() {
    final StudentProfile? p = _profile;
    final String name =
        (p?.name.isNotEmpty ?? false) ? p!.name : AppState.instance.studentName;
    final String sid =
        (p?.studentId.isNotEmpty ?? false) ? p!.studentId : AppState.instance.studentId;
    return SectionCard(
      child: Row(
        children: <Widget>[
          _avatarView(),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name.isNotEmpty ? name : '未获取到姓名',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
                if (sid.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text('学号 $sid',
                      style: TextStyle(
                          fontSize: 12, color: context.textTertiary)),
                ],
              ],
            ),
          ),
          // 设置入口：个人卡片右端。用与卡片同一套玻璃的药丸按钮，
          // 而不是裸图标 —— 卡片本身就是玻璃，裸图标会显得是「贴上去的」。
          if (widget.onOpenSettings != null) ...<Widget>[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: widget.onOpenSettings,
              child: GlassKit.fieldBackdrop(
                context,
                child: Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  child: Icon(Icons.settings_outlined,
                      size: 20, color: context.brandColor),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _fieldRow(ProfileField f, bool last) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gaps.m, vertical: 12),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(
                bottom: BorderSide(color: context.dividerColor, width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(f.label,
                style: TextStyle(fontSize: 13, color: context.textSecondary)),
          ),
          Expanded(
            child: Text(
              f.value,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 14, color: context.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
