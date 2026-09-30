import 'package:cloudcine/domain/entities/quality_option.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QualityLabels.labelFor', () {
    test('常见档位标识有中文名', () {
      expect(QualityLabels.labelFor('origin'), '原画');
      expect(QualityLabels.labelFor('4k'), '4K');
      expect(QualityLabels.labelFor('super'), '超清 1080P');
      expect(QualityLabels.labelFor('high'), '高清 720P');
      expect(QualityLabels.labelFor('normal'), '标清 480P');
      expect(QualityLabels.labelFor('low'), '流畅 360P');
    });

    test('大小写与空格不影响', () {
      expect(QualityLabels.labelFor('  ORIGIN '), '原画');
      expect(QualityLabels.labelFor('1080P'), '1080P');
    });

    test('认不出来时**原样返回标识**，不猜一个中文名', () {
      // 猜错的代价（用户选了「高清 720P」拿到 480P）比看到陌生标识更糟
      expect(QualityLabels.labelFor('h265_1080'), 'h265_1080');
      expect(QualityLabels.labelFor(''), '未知');
    });
  });

  group('QualityLabels.isOriginal', () {
    test('原画的多种标识', () {
      for (final id in ['origin', 'original', 'source', 'raw', 'bluray']) {
        expect(QualityLabels.isOriginal(id), isTrue, reason: id);
      }
    });

    test('转码档位不是原画', () {
      expect(QualityLabels.isOriginal('super'), isFalse);
      expect(QualityLabels.isOriginal('1080p'), isFalse);
    });
  });

  group('QualityLabels.sortWeight', () {
    test('原画排最前', () {
      final original = QualityLabels.sortWeight(
        const QualityOption(id: 'origin', label: '原画', isOriginal: true),
      );
      final uhd = QualityLabels.sortWeight(
        const QualityOption(id: '4k', label: '4K', height: 2160),
      );
      expect(original, lessThan(uhd));
    });

    test('有高度信息时按高度降序', () {
      final uhd = QualityLabels.sortWeight(
        const QualityOption(id: '4k', label: '4K', height: 2160),
      );
      final fhd = QualityLabels.sortWeight(
        const QualityOption(id: '1080p', label: '1080P', height: 1080),
      );
      expect(uhd, lessThan(fhd));
    });

    test('没有高度信息时从标识里抠数字', () {
      final fhd = QualityLabels.sortWeight(
        const QualityOption(id: '1080p', label: '1080P'),
      );
      final hd = QualityLabels.sortWeight(
        const QualityOption(id: '720p', label: '720P'),
      );
      expect(fhd, lessThan(hd));
    });
  });

  group('QualityOption', () {
    test('没有地址的档位不可选', () {
      const q = QualityOption(id: '4k', label: '4K');
      expect(q.isAvailable, isFalse);
    });

    test('displayDetail 优先用服务端给的说明', () {
      const withDetail = QualityOption(
        id: '4k',
        label: '4K',
        detail: '服务端原话',
        width: 3840,
        height: 2160,
      );
      expect(withDetail.displayDetail, '服务端原话');
    });

    test('没有说明时用宽高与码率拼', () {
      const q = QualityOption(
        id: '4k',
        label: '4K',
        width: 3840,
        height: 2160,
        bitrate: 12000000,
      );
      expect(q.displayDetail, '3840×2160 · 12.0 Mbps');
    });

    test('什么都没有时是空串而不是 null', () {
      const q = QualityOption(id: '4k', label: '4K');
      expect(q.displayDetail, '');
    });
  });
}
