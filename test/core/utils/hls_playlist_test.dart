import 'package:cloudcine/core/utils/hls_playlist.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这份解析只服务于诊断，但它的结论**决定排查方向**：
/// 「合计时长只有几秒」= 服务端给的就是个短列表；
/// 「合计时长几十分钟」= 列表是完整的，是播放器没跟上。
/// 读错这一条，后面所有功夫都白费。
void main() {
  group('summarizeHlsPlaylist', () {
    test('数得出分片与合计时长 —— 这是「列表本身就短」的直接证据', () {
      final summary = summarizeHlsPlaylist('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.006,
seg0.ts
#EXTINF:6.006,
seg1.ts
#EXTINF:3.500,
seg2.ts
#EXT-X-ENDLIST
''');

      expect(summary.isMaster, isFalse);
      expect(summary.segmentCount, 3);
      // 6.006 + 6.006 + 3.5 = 15.512 → 15 秒
      expect(summary.totalDuration.inSeconds, 15);
      expect(summary.hasEndList, isTrue);
      expect(summary.describe(), contains('分片 3 个'));
    });

    test('master 播放列表认出来 —— 否则「0 个分片」会被误读成空列表', () {
      // 夸克的 `media.m3u8` 是 master 的话，真正的分片列表在子列表里，
      // 而子列表**没被下载下来**。分不清这一点就会得出「服务端给了个空表」
      // 这种错误结论，然后去查错方向。
      final summary = summarizeHlsPlaylist('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
720/index.m3u8
''');

      expect(summary.isMaster, isTrue);
      expect(summary.segmentCount, 0);
      expect(summary.describe(), contains('master'));
    });

    test('没有 ENDLIST 要明确标出来 —— 那是直播流，不会按分片读完就 EOF', () {
      // 这一条是排除法用的：如果列表没有 ENDLIST，那「播几秒就 EOF」
      // 就不可能由「列表读完了」解释，得去别处找原因。
      final summary = summarizeHlsPlaylist('''
#EXTM3U
#EXTINF:6.0,
seg0.ts
''');

      expect(summary.hasEndList, isFalse);
      expect(summary.describe(), contains('没有 ENDLIST'));
    });

    test('畸形 / 空输入不抛异常，退化成空摘要', () {
      // 诊断本身失败是最糟的失败方式：在最需要证据的那一刻把证据也弄丢。
      expect(summarizeHlsPlaylist('').segmentCount, 0);
      expect(summarizeHlsPlaylist('这不是 m3u8').segmentCount, 0);
      // 缺秒数的 #EXTINF 只计数、不加时长，不该整条解析崩掉。
      final broken = summarizeHlsPlaylist('#EXTINF:,\nseg.ts');
      expect(broken.segmentCount, 1);
      expect(broken.totalDuration, Duration.zero);
    });

    test('带中文标题的 EXTINF 也要能读出秒数', () {
      // 夸克的分片行常带标题；逗号后面的东西绝不能影响数字解析。
      final summary = summarizeHlsPlaylist('#EXTINF:9.009,第 1 集 开场\nseg.ts');
      expect(summary.totalDuration.inSeconds, 9);
    });
  });

  group('firstSegmentUri', () {
    test('跳过全部注释行，取第一条分片地址', () {
      // 分片地址是「分片自检」的输入。取错行（比如取到 #EXTINF 那一行）
      // 会让自检去请求一个不存在的地址，然后得出「分片取不到」的错误结论
      // —— 而真正的分片其实是好的。
      final uri = firstSegmentUri('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:5
#EXTINF:2.000,
media-abc-0.ts?auth_key=1-2-3&token=x
#EXTINF:2.000,
media-abc-1.ts?auth_key=1-2-4&token=x
''');

      expect(uri, 'media-abc-0.ts?auth_key=1-2-3&token=x');
    });

    test('空列表 / 全是注释 → null（调用方要能区分「没有分片行」）', () {
      expect(firstSegmentUri(''), isNull);
      expect(firstSegmentUri('#EXTM3U\n#EXT-X-ENDLIST\n'), isNull);
    });

    test('相对路径原样返回，交给调用方 resolve', () {
      // 这里**故意不**自己拼基准：分片是相对 m3u8 自己的地址算的，
      // 拼错基准正是「转码档走中继就播不了」那个事故的成因。
      expect(firstSegmentUri('sub/dir/seg0.ts'), 'sub/dir/seg0.ts');
      expect(
        firstSegmentUri('https://cdn.example.com/a/b.ts'),
        'https://cdn.example.com/a/b.ts',
      );
    });
  });
}
