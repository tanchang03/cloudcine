/// 人脸框 → 竖版封面的**裁切锚点**。
///
/// ## 为什么需要它
///
/// 库里绝大多数封面来自夸克服务端生成的**视频帧（16:9）**，而海报格子是竖版。
/// 把 16:9 裁成竖版只能保留约 37.5% 的画面宽度，**裁哪一块**就成了关键：
///
///   - 按画面正中裁：双人对谈镜头的中点是**两个人之间的空隙**，
///     裁出来既没有主体也认不出是哪部片子；
///   - 按人脸裁：把「最显眼的那张脸」放在裁切窗中心，才叫「凸显人物」。
///
/// 夸克正好下发了人脸框，所以这件事可以做得准，而不是靠猜一个偏移量。
///
/// ## `cover_face_boundary` 的实测格式（2026-10-01 探针）
///
/// 递归遍历目录取到 60 个视频条目，**56 条带这个字段（93%）**，每条 1~3 张脸。
/// 原始值形如：
///
/// ```
/// [["46.09","37.22","50.16","47.50"], ["51.56","23.06","55.00","31.11"]]
/// ```
///
/// 判定它是 `[x1,y1,x2,y2]` 百分比（而不是 `[x,y,w,h]`）的依据：
///
///   - 每个框恰好 **4 个字符串**；
///   - 抽样的 13 个框**全部**满足 `x1<x2` 且 `y1<y2` —— 这是「两个角点」的
///     特征；`[x,y,w,h]` 不会天然满足这个序关系；
///   - 424 个数值全部落在 **0~100**，所以是百分比而不是像素；
///   - `x` 是**宽度**的百分比、`y` 是**高度**的百分比，原点在左上角。
///     用 `["46.09","37.22","50.16","47.50"]` 验证：框宽 `4.07%×1920 = 78px`、
///     框高 `10.28%×1080 = 111px`，宽高比 **0.70** —— 正是人脸的形状。
///
///     ⚠️ 直接把两个百分比相除会得到 `0.4`，看着完全不像脸，很容易因此
///     误判成「这不是人脸框」。**必须先按各自轴换算成像素再比。**
library;

abstract final class FaceAnchor {
  /// 竖版格子从 16:9 视频帧里能保留的宽度比例。
  ///
  /// 夸克三档缩略图都是 16:9（实测 178×100 / 533×300 / 640×360），
  /// 而海报格子的画面区是 2:3 —— 按高度铺满后，宽度只剩
  /// `(2/3) / (16/9) = 0.375`，也就是只能看到 37.5% 的画面宽度。
  ///
  /// ⚠️ 这是「格子正好 2:3」这个**理想值**，只在没有真实尺寸时兜底用。
  /// 真实卡片里海报区还要扣掉标题两行，比例约 **0.8**，保留宽度其实是 0.45。
  /// 画的时候一律走 [keptWidthForBox] 现算 —— 用这个常数会让对齐偏掉
  /// 2~3% 的画面宽度，而且卡片比例一改就偏得更多。
  static const double keptWidthFor169 = (2 / 3) / (16 / 9);

  /// 夸克缩略图的固有比例。三档实测都是 16:9，与源视频自身的比例无关
  /// （服务端统一生成成这个尺寸）。
  static const double sourceAspect = 16 / 9;

  /// 目标格子的宽高比下，`BoxFit.cover` 能保留源图宽度的比例。
  ///
  /// 源图恒为 [sourceAspect]；格子比源图**宽**时不会被裁（返回 1）。
  /// 尺寸非法（布局阶段还没算出来）时也返回 1 —— 宁可居中也不要
  /// 用一个瞎猜的比例去放大锚点偏移。
  static double keptWidthForBox(double boxWidth, double boxHeight) {
    if (boxWidth <= 0 || boxHeight <= 0) return 1;
    final boxAspect = boxWidth / boxHeight;
    return (boxAspect / sourceAspect).clamp(0.0, 1.0);
  }

  /// 解析 `cover_face_boundary`，返回归一化的**水平锚点**（0~1）。
  ///
  /// 取**面积最大**的那张脸：裁切窗只能保住一个人的宽度，多人同框时
  /// 保住「最显眼的那个人」比保住「所有人的中点」更贴近「凸显人物」。
  ///
  /// 没有任何可用框时返回 `null`（调用方退回画面正中）。
  ///
  /// 只用到 `x`：16:9 裁成竖版是**按高度铺满、只裁宽度**（见 [keptWidthFor169]），
  /// 纵向一块都不裁，所以 `y` 仅参与「这是不是一个合法矩形」的校验。
  static double? parseX(Object? raw) {
    if (raw is! List) return null;

    double? bestX;
    var bestArea = 0.0;

    for (final box in raw) {
      if (box is! List || box.length < 4) continue;

      final x1 = _num(box[0]);
      final y1 = _num(box[1]);
      final x2 = _num(box[2]);
      final y2 = _num(box[3]);
      if (x1 == null || y1 == null || x2 == null || y2 == null) continue;

      // 不是合法矩形 —— 也顺手排除掉 `[x,y,w,h]` 这种排布（w/h 会是正数，
      // 但 x2=x+w 不可能小于 x1=x）。
      if (x2 <= x1 || y2 <= y1) continue;

      // 不在 0~100 里就说明不是百分比，宁可不要也不要算出一个荒唐的锚点。
      if (x1 < 0 || y1 < 0 || x2 > 100 || y2 > 100) continue;

      final area = (x2 - x1) * (y2 - y1);
      if (area <= bestArea) continue;

      bestArea = area;
      bestX = ((x1 + x2) / 2) / 100;
    }

    return bestX;
  }

  /// 把水平锚点换算成 `Image.alignment` 的 x 分量（-1 ~ 1）。
  ///
  /// `BoxFit.cover` 的 `alignment.x` 线性地选择「露出源图的哪一段」：
  /// `-1` = 最左、`0` = 正中、`1` = 最右。要让**裁切窗中心**落在 `anchorX`
  /// 上，需要
  ///
  /// ```
  /// t = 2·(anchorX − 0.5) / (1 − keptWidth)
  /// ```
  ///
  /// 分母 `1 − keptWidth` 是关键：裁切窗只占源宽的 37.5%，所以锚点移动
  /// 1% 需要 `alignment` 移动约 3.2% —— 少了这个放大，人脸会明显偏离中心。
  ///
  /// [keptWidth] ≥ 1 表示源图不比格子宽，压根不会裁切，锚点无意义 → 返回 0。
  static double alignmentX(
    double anchorX, {
    double keptWidth = keptWidthFor169,
  }) {
    if (keptWidth >= 1) return 0;
    final t = 2 * (anchorX - 0.5) / (1 - keptWidth);
    return t.clamp(-1.0, 1.0);
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}
