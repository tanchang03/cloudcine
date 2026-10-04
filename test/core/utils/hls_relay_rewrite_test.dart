import 'package:cloudcine/core/utils/hls_relay_rewrite.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这份改写是「转码档也能走本地中继」的**唯一支点**：改错一个字符，
/// 播放器就会去 `127.0.0.1` 上找根本不存在的分片（或更糟 —— 直连 CDN
/// 被本机 `http_proxy` 打成一个 ffmpeg 未放行的协议）。所以每条断言都写清
/// 「错了会怎样」。
void main() {
  group('rewriteHlsForRelay', () {
    const playlistUrl =
        'https://video-play-h-zb.drive.quark.cn/qv/ABC123_999/media.m3u8';

    test('分片行改写成中继入口，且相对路径按列表自己的地址解析', () {
      final result = rewriteHlsForRelay(
        '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:5
#EXTINF:2.000,
media-abc-0.ts?auth_key=1-2-3&token=x
#EXTINF:2.000,
media-abc-1.ts?auth_key=1-2-4&token=x
''',
        playlistUrl: Uri.parse(playlistUrl),
      );

      expect(result.entryCount, 2);
      final lines = result.body
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      expect(lines.length, 2);

      // 每一条都要能解回**上游的绝对地址** —— 这是中继唯一知道去哪儿取分片的途径。
      for (var i = 0; i < lines.length; i++) {
        expect(lines[i], startsWith('$relayEntryPath?$relayTargetQueryKey='));
        final encoded = lines[i].split('$relayTargetQueryKey=').last;
        final decoded = decodeRelayTarget(encoded);
        expect(decoded, isNotNull);
        final uri = Uri.parse(decoded!);
        expect(uri.host, 'video-play-h-zb.drive.quark.cn');
        expect(uri.path, endsWith('media-abc-$i.ts'));
        // 分片的签名查询串必须**原样**保留，丢了就是 404。
        expect(uri.queryParameters['auth_key'], '1-2-${3 + i}');
      }
    });

    test('改写的行相对「中继入口」解析后仍落在 127.0.0.1，不会漏回 CDN', () {
      // 这条是整个修复的要点：播放器只会看到 127.0.0.1。
      final result = rewriteHlsForRelay(
        '#EXTM3U\n#EXTINF:2.0,\nseg0.ts\n',
        playlistUrl: Uri.parse(playlistUrl),
      );
      final line = result.body
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'));

      final relayEntry = Uri.parse('http://127.0.0.1:60568/h1/$relayEntryPath');
      final resolved = relayEntry.resolve(line);
      expect(resolved.host, '127.0.0.1');
      expect(resolved.port, 60568);
      expect(resolved.path, '/h1/$relayEntryPath');
    });

    test('注释行与空行原样保留 —— 丢一条 #EXT-X-KEY 就会用错解码参数', () {
      const text = '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="k.bin"\n'
          '\n'
          '#EXT-X-MAP:URI="init.mp4"\n'
          '#EXTINF:6.0,\n'
          'seg0.ts\n'
          '#EXT-X-ENDLIST\n';

      final result = rewriteHlsForRelay(
        text,
        playlistUrl: Uri.parse(playlistUrl),
      );

      expect(result.body, contains('#EXT-X-KEY:METHOD=AES-128,URI="k.bin"'));
      expect(result.body, contains('#EXT-X-MAP:URI="init.mp4"'));
      expect(result.body, contains('#EXT-X-ENDLIST'));
      expect(result.entryCount, 1);
    });

    test('master 列表的子列表地址同样被改写（不需要先分辨列表类型）', () {
      final result = rewriteHlsForRelay(
        '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080\n'
        '1080/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720\n'
        '720/index.m3u8\n',
        playlistUrl: Uri.parse(playlistUrl),
      );

      expect(result.entryCount, 2);
      final encoded = result.body
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .map((l) => decodeRelayTarget(l.split('$relayTargetQueryKey=').last))
          .toList();
      // 子列表是相对 `/qv/ABC123_999/` 的，解析后必须带上那一层目录。
      expect(encoded[0], playlistUrl.replaceAll('media.m3u8', '1080/index.m3u8'));
      expect(encoded[1], playlistUrl.replaceAll('media.m3u8', '720/index.m3u8'));
    });

    test('空列表不抛异常，entryCount 为 0', () {
      final result = rewriteHlsForRelay(
        '',
        playlistUrl: Uri.parse(playlistUrl),
      );
      expect(result.entryCount, 0);
    });
  });

  group('encodeRelayTarget / decodeRelayTarget', () {
    test('带 {} %3D & 的夸克分片地址能原样往返', () {
      // 夸克的分片地址里真的有这些字符：
      // `x-oss-process=if_status_eq_404{hls/ts,from_…}`、`ct=…%3D`、`&mt=3`。
      // 逐字符百分号转义极易漏掉一个，base64url 才是稳的。
      const raw = 'https://cdn.example.com/a/media-x-0.ts?'
          'auth_key=1-2-3&x-oss-process=if_status_eq_404{hls/ts,from_QQ%3D}&mt=3';
      final encoded = encodeRelayTarget(raw);
      expect(encoded, isNot(contains('=')));
      expect(encoded, isNot(contains('{')));
      expect(encoded, isNot(contains('&')));
      expect(decodeRelayTarget(encoded), raw);
    });

    test('解不开的输入返回 null，不抛异常（调用方回 400）', () {
      expect(decodeRelayTarget('!!!not-base64!!!'), isNull);
    });
  });
}
