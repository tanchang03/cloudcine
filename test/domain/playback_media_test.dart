import 'package:cloudcine/domain/services/playback_media.dart';
import 'package:flutter_test/flutter_test.dart';

/// 起播位置只有一条可靠路径：mpv 的 `start` 属性（由 `Media(start:)` 落地）。
///
/// 这些用例盯的不是「值传对了没有」，而是**两个会让功能静默失效的坑**：
///
///   1. `start == null` 不是「从头开始」，而是「什么都不设」—— 上一次设过的值
///      还留在 mpv 里（实测：`start=20` 播完 A，再放 B 时 B 也从 20s 起播）。
///   2. 「open 之后再 seek」完全无效（实测：`loadfile` 后立刻 `seek 20`，
///      3 秒后位置仍是 3.0s）。所以只要有人把起播位置改回 seek 路线，
///      「续播」就会再次变成「每次都从头开始」，而单元测试是唯一能在
///      没有网络、没有 mpv 的情况下发现这件事的地方。
///
/// 完整实测记录见 `playback_media.dart` 的类文档。
void main() {
  group('PlaybackMedia.build', () {
    test('不给起播位置时 start 是 0，**不是** null', () {
      final media = PlaybackMedia.build('https://example.com/a.mkv');

      // 传 null 会让 media_kit **跳过**设置 mpv 的 start 属性，于是上一次播放
      // 残留的值继续生效。症状：播过一部续播的片子之后，别的片子也从中途开始
      // —— 只在特定顺序下复现，极难查。
      expect(media.start, isNotNull);
      expect(media.start, Duration.zero);
    });

    test('给了起播位置就原样带过去（续播点精确到毫秒）', () {
      final media = PlaybackMedia.build(
        'https://example.com/b.mkv',
        startAt: const Duration(minutes: 2, seconds: 10, milliseconds: 500),
      );

      expect(media.start, const Duration(minutes: 2, seconds: 10, milliseconds: 500));
    });

    test('请求头原样带上 —— 夸克直链缺 Cookie 一律 412', () {
      final media = PlaybackMedia.build(
        'https://example.com/c.mkv',
        headers: const <String, String>{'Cookie': 'a=b', 'Referer': 'x'},
      );

      expect(media.httpHeaders, <String, String>{'Cookie': 'a=b', 'Referer': 'x'});
    });

    test('地址原样保留（含签名查询串）', () {
      const url = 'https://video-play-c-zb.pds.quark.cn/x/y?sign=abc&t=1';
      final media = PlaybackMedia.build(url);

      expect(media.uri, url);
    });
  });
}
