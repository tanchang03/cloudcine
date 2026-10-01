import 'package:cloudcine/core/utils/face_anchor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 由 `alignment.x` **反推**裁切窗中心，用来验证「人脸真的落在窗中心」。
///
/// 这是把 `alignment` 的定义式反过来写：`t = -1` 露最左、`+1` 露最右，
/// 中间线性。断言它比断言 `t` 的具体数值更能说明问题 ——
/// 数值对不对不重要，「人脸有没有被裁到边上去」才重要。
double _windowCenter(double t, double keptWidth) =>
    (t + 1) / 2 * (1 - keptWidth) + keptWidth / 2;

void main() {
  group('FaceAnchor.parseX', () {
    test('单个框 → 框中心的归一化 x', () {
      // 取自 2026-10-01 探针的真实返回值。
      final x = FaceAnchor.parseX([
        ['46.09', '37.22', '50.16', '47.50'],
      ]);
      expect(x, closeTo(0.48125, 1e-9));
    });

    test('多个框取**面积最大**的那张脸，而不是第一个', () {
      // 真实的三人同框样本：面积分别是 41.8 / 27.7 / 40.1，
      // 最大的是第一个；下面那条用例专门覆盖「最大的不在第一个」。
      final x = FaceAnchor.parseX([
        ['46.09', '37.22', '50.16', '47.50'],
        ['51.56', '23.06', '55.00', '31.11'],
        ['71.72', '36.94', '76.09', '46.11'],
      ]);
      expect(x, closeTo(0.48125, 1e-9));
    });

    test('最大的脸不在第一位时仍然选它', () {
      // 面积：9.84~25.16 → 15.32×34.44 = 527.6（最大，在第一位）
      // 这里把它放到最后，确认选择逻辑不是「取第一个」。
      final x = FaceAnchor.parseX([
        ['84.06', '36.39', '89.69', '51.39'], // 5.63×15.00 = 84.5
        ['47.66', '27.22', '60.47', '56.39'], // 12.81×29.17 = 373.7
        ['9.84', '31.39', '25.16', '65.83'], // 15.32×34.44 = 527.6 ← 应选这个
      ]);
      expect(
        x,
        closeTo(0.175, 1e-9),
        reason: '竖版裁切窗只能保住约 37.5% 的画面宽度，多人同框时'
            '必须锚在最显眼的那张脸上 —— 锚在「所有人的中点」会裁到'
            '两个人中间的空隙，既没有主体也认不出是哪部片子。',
      );
    });

    test('数字类型也接受（不只是字符串）', () {
      expect(
        FaceAnchor.parseX([
          [46.09, 37.22, 50.16, 47.50],
        ]),
        closeTo(0.48125, 1e-9),
      );
    });

    test('没有字段 / 形状不对 → null', () {
      expect(FaceAnchor.parseX(null), isNull);
      expect(FaceAnchor.parseX(''), isNull);
      expect(FaceAnchor.parseX(<Object?>[]), isNull);
      expect(FaceAnchor.parseX(<Object?>[null, 'x', 42]), isNull);
      // 元素不是 list
      expect(FaceAnchor.parseX(['46.09', '37.22']), isNull);
    });

    test('框不够 4 个数 → 跳过', () {
      expect(FaceAnchor.parseX([
        ['46.09', '37.22', '50.16'],
      ]), isNull);
    });

    test('数不出来 / 不是合法矩形 → 跳过', () {
      expect(FaceAnchor.parseX([
        ['a', 'b', 'c', 'd'],
      ]), isNull);
      // x2 <= x1：这不是 `[x1,y1,x2,y2]` 的排布
      expect(FaceAnchor.parseX([
        ['50.16', '37.22', '46.09', '47.50'],
      ]), isNull);
      expect(FaceAnchor.parseX([
        ['46.09', '47.50', '50.16', '37.22'],
      ]), isNull);
    });

    test('数值超出 0~100 → 跳过（说明不是百分比）', () {
      expect(FaceAnchor.parseX([
        ['46.09', '37.22', '501.6', '47.50'],
      ]), isNull);
      expect(FaceAnchor.parseX([
        ['-1', '37.22', '50.16', '47.50'],
      ]), isNull);
    });

    test('坏框不影响好框（逐条跳过而不是整段放弃）', () {
      final x = FaceAnchor.parseX([
        ['bad'],
        ['46.09', '37.22', '50.16', '47.50'],
        ['999', '1', '999.5', '2'],
      ]);
      expect(x, closeTo(0.48125, 1e-9));
    });

    test('百分比必须按各自的轴换算 —— 别把两个百分比直接相除', () {
      // 这是那个「看着不像人脸」的陷阱的回归测试。
      // ["46.09","37.22","50.16","47.50"] 的原始百分比之比是 4.07/10.28 = 0.40，
      // 看着像一根竖条；但 x 是宽度的百分比、y 是高度的百分比，
      // 换算到 1920×1080 后是 78×111 px，宽高比 0.70 —— 正常的人脸比例。
      const x1 = 46.09, y1 = 37.22, x2 = 50.16, y2 = 47.50;
      final wPx = (x2 - x1) / 100 * 1920;
      final hPx = (y2 - y1) / 100 * 1080;
      final aspect = wPx / hPx;

      expect(aspect, greaterThan(0.6));
      expect(aspect, lessThan(0.85));
      expect(
        (x2 - x1) / (y2 - y1),
        lessThan(0.5),
        reason: '直接相除得到的 0.40 会让人误判「这不是人脸框」并删掉这段解析。'
            '实际上它只是忘了 x/y 各自的分母不同。',
      );
    });
  });

  group('FaceAnchor.alignmentX', () {
    test('锚点在正中 → alignment 0', () {
      expect(FaceAnchor.alignmentX(0.5), closeTo(0, 1e-9));
    });

    test('锚点在最左/最右边界 → alignment ∓1', () {
      // 裁切窗宽 0.375，所以窗中心能到达的极限就是 0.1875 / 0.8125。
      expect(FaceAnchor.alignmentX(0.1875), closeTo(-1, 1e-9));
      expect(FaceAnchor.alignmentX(0.8125), closeTo(1, 1e-9));
    });

    test('超出可及范围时被夹住（人脸贴边也不会裁出画面外）', () {
      expect(FaceAnchor.alignmentX(0.0), -1);
      expect(FaceAnchor.alignmentX(1.0), 1);
    });

    test('换算后的窗中心确实落在锚点上', () {
      for (final anchor in const [0.1875, 0.3, 0.5, 0.7, 0.8125]) {
        final t = FaceAnchor.alignmentX(anchor);
        expect(
          _windowCenter(t, FaceAnchor.keptWidthFor169),
          closeTo(anchor, 1e-9),
          reason: '分母 1−keptWidth 是必须的：裁切窗只占源宽 37.5%，'
              '锚点动 1% 需要 alignment 动约 3.2%。少了这个放大，'
              '人脸会明显偏离窗中心（贴到裁切边缘）。',
        );
      }
    });

    test('源图不比格子宽时不裁切 → 0', () {
      expect(FaceAnchor.alignmentX(0.2, keptWidth: 1.0), 0);
      expect(FaceAnchor.alignmentX(0.2, keptWidth: 1.5), 0);
    });

    test('16:9 源图裁成 2:3 只保留 37.5% 宽度', () {
      expect(FaceAnchor.keptWidthFor169, closeTo(0.375, 1e-9));
    });
  });

  group('FaceAnchor.keptWidthForBox', () {
    test('真实卡片格子（172×215）保留 45%，不是理想的 37.5%', () {
      // 卡片格本身是 2:3，但海报区还要扣掉下面的标题两行，
      // 实际比例约 0.8（比 2:3 更宽）—— 保留宽度因此是 0.45。
      expect(FaceAnchor.keptWidthForBox(172, 215), closeTo(0.45, 1e-9));
    });

    test('格子正好是 2:3 时与 keptWidthFor169 一致', () {
      expect(
        FaceAnchor.keptWidthForBox(200, 300),
        closeTo(FaceAnchor.keptWidthFor169, 1e-9),
      );
    });

    test('格子比源图宽（横版）→ 压根不裁，返回 1', () {
      expect(FaceAnchor.keptWidthForBox(320, 100), 1.0);
    });

    test('尺寸还没算出来 / 非法 → 1（宁可居中，也不要拿瞎猜的比例放大偏移）', () {
      expect(FaceAnchor.keptWidthForBox(0, 215), 1.0);
      expect(FaceAnchor.keptWidthForBox(172, 0), 1.0);
      expect(FaceAnchor.keptWidthForBox(-1, -1), 1.0);
      expect(FaceAnchor.keptWidthForBox(double.infinity, 215), 1.0);
    });

    test('按真实格子算，人脸才落在窗中心', () {
      const kept = 0.45;
      final t = FaceAnchor.alignmentX(0.3, keptWidth: kept);
      expect(_windowCenter(t, kept), closeTo(0.3, 1e-9));
    });

    test('回归：写死 2:3 的理想常数会让对齐偏掉', () {
      // 用默认（= 理想 2:3 格子）算出来的 alignment，放到真实格子上就偏了。
      final t = FaceAnchor.alignmentX(0.3);
      final actual = _windowCenter(t, 0.45);
      expect(
        actual,
        greaterThan(0.31),
        reason: '这个项目的卡片比例已经改过两次了。写死一个常数的话，'
            '改比例时人脸会悄悄偏离窗中心（当前约 2.4% 的画面宽度），'
            '而且不会报任何错 —— 所以绘制时必须用 LayoutBuilder 现算。',
      );
    });
  });
}
