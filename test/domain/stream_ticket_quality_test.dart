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

  group('StreamTicket.withQuality', () {
    QualityOption withSize(String id, {int? bytes}) => QualityOption(
          id: id,
          label: id,
          url: Uri.parse('https://cdn/$id.mkv'),
          estimatedBytes: bytes,
        );

    test('服务端给了这一档体积时用它', () {
      final ticket = StreamTicket(
        url: Uri.parse('https://cdn/origin.mkv'),
        contentLength: 17 * 1024 * 1024 * 1024,
      );

      final next = ticket.withQuality(
        withSize('4k', bytes: 4 * 1024 * 1024 * 1024),
      );

      expect(next.contentLength, 4 * 1024 * 1024 * 1024);
      expect(next.url, Uri.parse('https://cdn/4k.mkv'));
    });

    test('服务端没给体积时留 null —— **绝不沿用上一条流的体积**', () {
      // ⚠️ 这条断言钉的是「切到 4K 就黑屏」的根因，不要改回去。
      //
      // 旧实现是 `quality.estimatedBytes ?? contentLength`：换档时上一条流是
      // 原画，于是「原画 17 GiB 的块布局」被套到 4 GiB 的转码流上 ——
      // 本地中继按错的总长切块、发越界的 Range，上游回 416，画面就没了。
      //
      // 留 null 会让 `_prepareSource` 看到「长度未知」而**跳过中继、直连播放**：
      // 少一点加速，但至少能播。
      final ticket = StreamTicket(
        url: Uri.parse('https://cdn/origin.mkv'),
        contentLength: 17 * 1024 * 1024 * 1024,
      );

      final next = ticket.withQuality(withSize('4k'));

      expect(next.contentLength, isNull);
    });

    test('没有地址的档位原样返回，不改票据', () {
      final ticket = StreamTicket(url: Uri.parse('https://cdn/origin.mkv'));

      final next = ticket.withQuality(
        const QualityOption(id: '4k', label: '4K'),
      );

      expect(next, same(ticket));
    });
  });

  /// 「这条通道最多开几条连接」。
  ///
  /// 2026-10-09 对百度两条通道实测（同一账号、同一文件）：
  /// `origin=dlna` **每条连接各自限速**（1 条 1.1 MB/s、8 条 4.1 MB/s，能叠加），
  /// 而普通通道是**账号级**限速（1 与 4 互有胜负、8 条总有被掐断的连接，
  /// 且累计 ~10 MiB 后 1/4/8 条一起归零）。
  /// 所以「开几条」不能由下载服务拍一个全局默认值 —— 它写在票据上。
  group('StreamTicket.maxConnections', () {
    test('票据没写上限时用消费方的默认值', () {
      final ticket = StreamTicket(url: Uri.parse('https://cdn/a.mkv'));

      expect(ticket.maxConnections, isNull);
      expect(ticket.connectionsFor(8), 8);
      expect(ticket.connectionsFor(3), 3,
          reason: '默认值是多少就返回多少，不该被悄悄改成 8');
    });

    test('票据钉了上限就以票据为准', () {
      final ticket = StreamTicket(
        url: Uri.parse('https://cdn/a.pdf'),
        maxConnections: 1,
      );

      expect(ticket.connectionsFor(8), 1,
          reason: '普通通道是账号级限速：加连接不加吞吐，'
              '8 条每次都会出现被掐断的连接 ——'
              '那正是「下载卡在 0% 不动」的样子');
    });

    test('上限小于 1 时收敛到 1 —— 绝不能算出 0 条连接', () {
      // 0 条连接会让「文件足够大」那条分块判据静默失效，
      // 表现是「大文件永远走单连接」—— 一个**悄悄发生**的降级，
      // 而不是一个能被发现的错误。
      final ticket = StreamTicket(
        url: Uri.parse('https://cdn/a.pdf'),
        maxConnections: 0,
      );

      expect(ticket.connectionsFor(8), 1);
    });

    test('换档不换通道：并发上限跟着票据走', () {
      // 上限是**通道**的属性，与清晰度无关。漏掉它会让换到转码档之后
      // 又按消费方默认值（8 条）去打开这条通道。
      final ticket = StreamTicket(
        url: Uri.parse('https://cdn/origin.mkv'),
        maxConnections: 1,
      );

      final next = ticket.withQuality(
        const QualityOption(
          id: '4k',
          label: '4K',
          url: null,
        ),
      );

      // 没地址的档位原样返回 —— 换个有地址的再试。
      expect(next, same(ticket));

      final switched = ticket.withQuality(
        QualityOption(id: '4k', label: '4K', url: Uri.parse('https://cdn/4k.mkv')),
      );
      expect(switched.maxConnections, 1);
    });
  });
}
