import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/face_anchor.dart';
import '../../domain/entities/media_work.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';

/// 海报。
///
/// ## 两种画法，按「知不知道人物在哪」分
///
/// 封面只有两个来源，比例差得很远：
///
///   - **夸克服务端生成的视频帧**（库里绝大多数）—— 实测 **640×360（16:9）**，
///     是「剧中某一帧」，带硬字幕；
///   - **TMDB 刮削出来的真海报** —— **2:3 竖版**。
///
/// 而卡片是竖版格子。16:9 的帧塞进竖版格子，必然要丢掉一半以上的画面宽度，
/// 所以「怎么丢」才是关键：
///
///   1. **有 `posterFaceX`（人物锚点）→ `cover` + 水平对齐到人物。**
///      夸克列目录时顺带给了人脸框 `cover_face_boundary`（实测 93% 的视频都有），
///      用它算出「该保留画面哪一段」，人物就被框在格子中间 —— 这是用户要的
///      「按竖版裁切、凸显人物」。这条路径只有一层图，没有模糊底、没有暗罩：
///      `cover` 本来就铺满，糊一层底图纯属浪费一次高斯模糊。
///
///   2. **没有锚点 → 模糊底图 + `contain` 完整画面。** 分两种情况：
///      TMDB 的 2:3 真海报（`contain` 在竖版格子里几乎铺满），
///      以及约 7% 没检出人脸的视频帧。
///      **不知道人在哪就不硬裁** —— 居中裁切有一半概率正好把人物切出画面，
///      而 `contain` 至少保证整帧可见（上下留白由模糊底图填，见
///      `docs/封面问题-实测/` 的实测截图）。
///
/// 为什么当初不直接用 `cover` 单层铺满：2026-10-01 实测过，朴素的居中 `cover`
/// 在 2:3 格子里只保留约 31% 的画面宽度，结果常是「一个人的躯干 + 被切掉一半的
/// 字幕」。现在 `cover` 能用，靠的是**锚点**而不是「居中」。
///
/// 其余仍是三级降级，每一级都有明确的视觉结果，不会出现空白：
///   1. 磁盘缓存命中 → 直接显示文件（打开媒体库秒出图的关键）；
///   2. 有远程地址 → 下载并缓存后再显示（期间显示占位）；
///   3. 都没有 → 渐变底 + 片名首字。
///
/// 不用 `Image.network`：它每次重建都可能重发请求，而海报墙一滚动
/// 就是几十次；而且断网时它会退化成一块灰，看不出是哪部片子。
class PosterImage extends ConsumerStatefulWidget {
  const PosterImage({
    super.key,
    required this.work,
    this.borderRadius = 10,
  });

  final MediaWork work;
  final double borderRadius;

  @override
  ConsumerState<PosterImage> createState() => _PosterImageState();
}

class _PosterImageState extends ConsumerState<PosterImage> {
  String? _path;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(PosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一部片子被重新刮削后 `posterUrl` / `posterFile` 会变，
    // 不重新解析就会一直显示旧图。
    if (oldWidget.work.posterUrl != widget.work.posterUrl ||
        oldWidget.work.posterFile != widget.work.posterFile) {
      _resolved = false;
      _path = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final work = widget.work;
    final url = work.posterUrl;

    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _resolved = true);
      return;
    }

    final path = await ref.read(posterCacheProvider).pathFor(
          key: work.key,
          url: url,
          knownFile: work.posterFile,
        );

    if (!mounted) return;
    setState(() {
      _path = path;
      _resolved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: path == null
          ? _Placeholder(
              title: widget.work.title,
              // 还在解析中时不要显示「无海报」的观感 —— 占位底色更安静。
              pending: !_resolved,
            )
          : _Frame(
              path: path,
              title: widget.work.title,
              // 锚点为空 = 不知道人物在哪（2:3 的刮削海报 / 没检出人脸的帧）。
              faceX: widget.work.posterFaceX,
            ),
    );
  }
}

/// 裁切型画法：`cover` 铺满 + 按人物锚点决定保留画面哪一段。
///
/// 单独一个部件是因为它和 [_Frame] 的层叠结构完全不同（这里只有一层图），
/// 而 `LayoutBuilder` 需要包住真正的绘制节点才能拿到格子尺寸。
class _FaceCrop extends StatelessWidget {
  const _FaceCrop({
    required this.path,
    required this.title,
    required this.faceX,
  });

  final String path;
  final String title;

  /// 人物水平锚点（0~1，0.5 = 正中）。
  final double faceX;

  @override
  Widget build(BuildContext context) {
    // 保留宽度比例必须**按真实格子算**，不能写死。
    //
    // 卡片格是 2:3，但海报区还要扣掉下面的标题两行，实际比例约 0.8
    // （比 2:3 更宽）；而且这两个数字都是会被改的 —— 这个项目里卡片比例
    // 已经调过两次了。写死一个常数，改比例时对齐就会悄悄偏掉。
    return LayoutBuilder(
      builder: (context, constraints) {
        final kept = FaceAnchor.keptWidthForBox(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        return Image.file(
          File(path),
          fit: BoxFit.cover,
          // 纵向不用管：源图是 16:9、格子是竖版，`cover` 以**高度**为准，
          // 整幅画面的高度一个像素都不裁，所以 y 取 0 即可。
          alignment: Alignment(FaceAnchor.alignmentX(faceX, keptWidth: kept), 0),
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, __, ___) => _Placeholder(title: title, pending: false),
        );
      },
    );
  }
}

/// 完整画面型画法：模糊底图 + 暗罩 + `contain` 前景。
///
/// 两层用**同一个文件、同一个 `FileImage` 解码结果**，Flutter 的图片缓存
/// 会让它只解码一次，所以多这一层不额外占内存。
class _Frame extends StatelessWidget {
  const _Frame({required this.path, required this.title, this.faceX});

  final String path;
  final String title;

  /// 人物锚点；非空就走裁切画法（见 [_FaceCrop]）。
  final double? faceX;

  /// 模糊半径。取值偏大是有意的：底图只负责「填色」，
  /// 半径小了会让人误以为画面本来就这么糊。
  static const double _blurSigma = 24;

  /// 底图暗罩的不透明度。压暗后前景画面的边缘更清楚，
  /// 也让右下角那个「简介」按钮在任何画面上都看得见。
  static const double _scrimOpacity = 0.42;

  @override
  Widget build(BuildContext context) {
    final faceX = this.faceX;
    if (faceX != null) {
      return _FaceCrop(path: path, title: title, faceX: faceX);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1) 底层：铺满 + 模糊。用 clamp 而不是默认的 decal，
        //    否则模糊会把边缘「吃掉」成透明，露出后面的底色。
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: _blurSigma,
            sigmaY: _blurSigma,
            tileMode: ui.TileMode.clamp,
          ),
          child: Image.file(
            File(path),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            // 底图只是背景，坏了也不该让整面墙抛异常 —— 静默退成纯色。
            errorBuilder: (_, __, ___) => const ColoredBox(color: AppTheme.panel2),
          ),
        ),

        // 2) 中层：暗罩。
        ColoredBox(color: Colors.black.withValues(alpha: _scrimOpacity)),

        // 3) 顶层：完整画面，不裁切。
        Image.file(
          File(path),
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
          // 图片文件可能被外部删掉/损坏，加载失败退回占位，
          // 而不是让整个海报墙抛异常。
          errorBuilder: (_, __, ___) => _Placeholder(
            title: title,
            pending: false,
          ),
        ),
      ],
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title, required this.pending});

  final String title;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    if (pending) {
      return const ColoredBox(color: AppTheme.panel2);
    }

    final initial = title.trim().isEmpty ? '?' : title.trim().characters.first;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.panel3, AppTheme.panel2],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w300,
            color: AppTheme.dim,
          ),
        ),
      ),
    );
  }
}
