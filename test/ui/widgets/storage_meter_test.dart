import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/storage_meter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 容量条的**档位判定**。
///
/// 这里只测纯函数，不测画出来的颜色：颜色是皮肤（改一次主题就要改一遍测试），
/// 档位是语义（「用到 95% 要变红」这件事不该随主题变）。所以断言钉在
/// `levelFor` 上，颜色只验「三档互不相同」—— 若哪天两档被接到同一个颜色，
/// 用户就再也看不出「快满了」。
void main() {
  group('StorageLevel 档位', () {
    test('宽裕区：85% 以下都是 normal', () {
      expect(DriveStorageMeter.levelFor(0.0), StorageLevel.normal);
      expect(DriveStorageMeter.levelFor(0.5), StorageLevel.normal);
      expect(DriveStorageMeter.levelFor(0.8499), StorageLevel.normal);
    });

    test('警示区从 85% 起，且**刚好 85% 就算**', () {
      expect(DriveStorageMeter.levelFor(DriveStorageMeter.warnRatio),
          StorageLevel.warn,
          reason: '边界取 >= 而不是 >：恰好 85% 时用户已经在该考虑清理了，'
              '把它归回「宽裕」会让提示永远晚一步出现。');
      expect(DriveStorageMeter.levelFor(0.9), StorageLevel.warn);
      expect(DriveStorageMeter.levelFor(0.9499), StorageLevel.warn);
    });

    test('危险区从 95% 起（这时候「传不上去」近在眼前）', () {
      expect(DriveStorageMeter.levelFor(DriveStorageMeter.dangerRatio),
          StorageLevel.danger);
      expect(DriveStorageMeter.levelFor(1.0), StorageLevel.danger);
    });

    test('超过 100% 仍是 danger —— 不因为算出 1.2 就崩或掉回 normal', () {
      // 配额降档 / 会员到期时服务端可能给出 used > total。
      expect(DriveStorageMeter.levelFor(1.2), StorageLevel.danger);
    });

    test('三档颜色互不相同', () {
      final colors = {
        for (final level in StorageLevel.values)
          DriveStorageMeter.colorFor(level),
      };
      expect(colors.length, StorageLevel.values.length,
          reason: '两档同色 = 那一档的提示等于没做，而画面上完全看不出错。');
    });

    test('normal 用主色（它是背景信息，不该一进页面就在喊）', () {
      expect(DriveStorageMeter.colorFor(StorageLevel.normal), AppTheme.accent);
      expect(DriveStorageMeter.colorFor(StorageLevel.danger), AppTheme.danger);
    });
  });
}
