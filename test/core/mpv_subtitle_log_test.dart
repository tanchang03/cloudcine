import 'package:cloudcine/core/utils/mpv_subtitle_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 这一组用例守的是「字幕出不来时**能不能看到原因**」。
  //
  // 背景（实测，2026-10-03，The Glory S01E01 内封 PGS）：轨道列得出来、也打得勾，
  // 画面却没字，而诊断日志里**一条线索都没有** —— 因为 mpv 那句
  // `Could not find subtitle decoder for format 'hdmv_pgs_subtitle'.`
  // 既不含 `failed`/`error`（被 `_onPlayerError` 丢），
  // 又不是 HTTP 4xx（被 `isHttp4xxLog` 丢）。
  //
  // 断言写的是**真实日志原文**，不是自己编的近似句 —— 编的句子换个 prefix
  // 就不成立了，等于没测。
  group('isSubtitleDiagnosticLog —— 放行字幕解码的报错', () {
    test('认得出「找不到解码器」（libmpv 缺 pgssub 时 mpv 的原话）', () {
      expect(
        isSubtitleDiagnosticLog(
          "Could not find subtitle decoder for format 'hdmv_pgs_subtitle'.",
        ),
        isTrue,
        reason: '这句是「本机解不开 PGS」的**唯一直接证据**，漏了它整条线索就断了',
      );
    });

    test('认得出 libavcodec 字幕解码器/转换器打不开', () {
      expect(isSubtitleDiagnosticLog('Could not open libavcodec subtitle decoder'),
          isTrue);
      expect(
          isSubtitleDiagnosticLog('Could not open libavcodec subtitle converter'),
          isTrue);
    });

    test('VobSub / DVB 也一起放行 —— 它们是同一类位图字幕', () {
      expect(
        isSubtitleDiagnosticLog(
          "Could not find subtitle decoder for format 'dvd_subtitle'.",
        ),
        isTrue,
      );
      expect(
        isSubtitleDiagnosticLog(
          "Could not find subtitle decoder for format 'dvb_subtitle'.",
        ),
        isTrue,
      );
    });

    test('大小写不敏感 —— mpv 的 prefix 大小写并不稳定', () {
      expect(isSubtitleDiagnosticLog('COULD NOT FIND SUBTITLE DECODER'), isTrue);
    });
  });

  group('isSubtitleDiagnosticLog —— 不要误伤', () {
    test('HTTP 403 不算字幕问题', () {
      expect(
        isSubtitleDiagnosticLog('http: HTTP error 403 Forbidden'),
        isFalse,
        reason: '它归 isHttp4xxLog 管，两边混在一起会去刷新一条没问题的链',
      );
    });

    test('`Failed to open` 不算字幕问题', () {
      expect(
        isSubtitleDiagnosticLog('Failed to open https://example.com/a.mkv .'),
        isFalse,
      );
    });

    test('只写 `sub` 缩写不算 —— 必须整词，否则普通日志会被大量误伤', () {
      expect(isSubtitleDiagnosticLog('sub: something happened'), isFalse);
    });
  });
}
