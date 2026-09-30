import 'package:cloudcine/domain/entities/quality_option.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「该播哪一档」的判定规则。
///
/// 这组用例存在的理由：规则原本是 `PlaybackController` 的私有方法，
/// 现在独立播放窗口那条路也要用它（主窗口取到票据后据此决定把哪一档的地址
/// 发出去）。**两条路共用同一处实现**，所以这个行为契约必须被钉住 ——
/// 一旦改动，内置播放页和独立窗口会同时受影响，而不是只坏一个。
void main() {
  StreamTicket ticketWith(List<QualityOption> qualities) => StreamTicket(
        url: Uri.parse('https://cdn/default.m3u8'),
        qualities: qualities,
      );

  QualityOption q(
    String id, {
    String? url,
    bool original = false,
  }) =>
      QualityOption(
        id: id,
        label: id,
        url: url == null ? null : Uri.parse(url),
        isOriginal: original,
      );

  group('StreamTicket.pickActiveQualityId', () {
    test('没有转码梯度时返回 null —— 原画就是唯一那条流', () {
      expect(ticketWith(const []).pickActiveQualityId(), isNull);
      expect(ticketWith(const []).pickActiveQualityId('high'), isNull);
    });

    test('没指定档位时**原画优先**', () {
      final ticket = ticketWith([
        q('low', url: 'https://cdn/low.m3u8'),
        q('origin', url: 'https://cdn/o.m3u8', original: true),
        q('4k', url: 'https://cdn/4k.m3u8'),
      ]);

      expect(ticket.pickActiveQualityId(), 'origin');
    });

    test('指定档位优先于原画 —— 用户显式选过就听用户的', () {
      final ticket = ticketWith([
        q('origin', url: 'https://cdn/o.m3u8', original: true),
        q('4k', url: 'https://cdn/4k.m3u8'),
      ]);

      expect(ticket.pickActiveQualityId('4k'), '4k');
    });

    test('指定的档位不存在时回落到原画', () {
      final ticket = ticketWith([
        q('origin', url: 'https://cdn/o.m3u8', original: true),
        q('4k', url: 'https://cdn/4k.m3u8'),
      ]);

      expect(ticket.pickActiveQualityId('8k'), 'origin');
    });

    test('指定的档位存在但服务端没给地址 → 不算数，回落到原画', () {
      final ticket = ticketWith([
        q('origin', url: 'https://cdn/o.m3u8', original: true),
        q('4k'),
      ]);

      expect(ticket.pickActiveQualityId('4k'), 'origin');
    });

    test('空串档位等同于没指定', () {
      final ticket = ticketWith([
        q('origin', url: 'https://cdn/o.m3u8', original: true),
        q('4k', url: 'https://cdn/4k.m3u8'),
      ]);

      expect(ticket.pickActiveQualityId(''), 'origin');
    });

    test('原画没地址时退到第一个可用档', () {
      final ticket = ticketWith([
        q('origin', original: true),
        q('high', url: 'https://cdn/h.m3u8'),
      ]);

      expect(ticket.pickActiveQualityId(), 'high');
    });

    test('所有档位都没地址时仍返回第一档', () {
      // 与迁移前的行为保持一致：这里不做「没有可用档就抛」的判断，
      // 可用性由 UI 另外判（`QualityOption.isAvailable`）。
      final ticket = ticketWith([q('origin', original: true), q('high')]);

      expect(ticket.pickActiveQualityId(), 'origin');
    });
  });
}
