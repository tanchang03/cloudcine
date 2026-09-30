import 'package:cloudcine/data/remote/quark/quark_play_routes.dart';
import 'package:flutter_test/flutter_test.dart';

/// `play/info` 的真实响应形状**没有落盘证据**（参考项目只打过端点、
/// 没留下响应样本），所以解析器刻意不按固定字段名读，而是递归遍历、
/// 收集「像播放地址的字段」。
///
/// 正因如此，这些合成载荷测试是这条路由**唯一能离线验证的部分**：
/// 它们钉住的是「换字段名/换嵌套层级仍然认得出来」，而不是某个具体
/// 服务端契约。形状无关性本身就是被测试的性质。
void main() {
  group('parseQualities · 形状无关', () {
    test('典型嵌套载荷：梯度 + 原画，且已按清晰度降序排好', () {
      final data = {
        'data': {
          'video_list': [
            {
              'resolution': '4k',
              'url': 'https://cdn.example.com/v/4k/index.m3u8',
              'width': 3840,
              'height': 2160,
              'bitrate': 8000000,
              'size': 1234567,
            },
            {
              'resolution': '1080p',
              'url': 'https://cdn.example.com/v/1080p/index.m3u8',
              'width': 1920,
              'height': 1080,
              'bitrate': 3000000,
            },
            {
              'resolution': '720p',
              'url': 'https://cdn.example.com/v/720p/index.m3u8',
              'height': 720,
            },
          ],
          'origin': {
            'is_original': true,
            'play_url': 'https://cdn.example.com/origin.mkv',
          },
        },
      };

      final qs = QuarkPlayInfoParser.parseQualities(data);

      // 原画必须排最前 —— 这是「选了 4K 却拿到 1080P」那类事故的反面
      expect(qs.map((q) => q.id).toList(), ['origin', '4k', '1080p', '720p']);

      final origin = qs.first;
      expect(origin.isOriginal, isTrue);
      expect(origin.label, '原画');
      expect(origin.url.toString(), 'https://cdn.example.com/origin.mkv');

      final uhd = qs[1];
      expect(uhd.isOriginal, isFalse);
      expect(uhd.label, '4K');
      expect(uhd.height, 2160);
      expect(uhd.width, 3840);
      expect(uhd.bitrate, 8000000);
      expect(uhd.estimatedBytes, 1234567);
      expect(uhd.displayDetail, '3840×2160 · 8.0 Mbps');
    });

    test('数字是字符串也照样读出来（服务端类型不稳定）', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'url': 'https://cdn.example.com/a.mp4',
        'resolution': 'super',
        'height': '1080',
        'width': '1920',
        'bitrate': '2500000',
      });

      expect(qs, hasLength(1));
      expect(qs.single.label, '超清 1080P');
      expect(qs.single.height, 1080);
      expect(qs.single.width, 1920);
      expect(qs.single.displayDetail, '1920×1080 · 2.5 Mbps');
    });

    test('字段名大小写不敏感', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'Play_Url': 'https://cdn.example.com/a.mp4',
        'Resolution': '1080p',
        'Height': 1080,
      });

      expect(qs, hasLength(1));
      expect(qs.single.id, '1080p');
      expect(qs.single.height, 1080);
    });

    test('顶层就是列表也能解析', () {
      final qs = QuarkPlayInfoParser.parseQualities([
        {'resolution': '1080p', 'url': 'https://cdn.example.com/1.mp4'},
        {'resolution': '720p', 'url': 'https://cdn.example.com/2.mp4'},
      ]);

      expect(qs.map((q) => q.id).toList(), ['1080p', '720p']);
    });

    test('没有分辨率字段时，从 URL 里嗅探档位', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'play_url': 'https://cdn.example.com/v/1080p/index.m3u8',
      });

      expect(qs.single.id, '1080p');
      expect(qs.single.height, 1080);
      // 档位是从 URL 推出来的，不是服务端标为原画
      expect(qs.single.isOriginal, isFalse);
    });

    test('既无标识也无地址线索时，当原画处理', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'play_url': 'https://cdn.example.com/raw.mkv',
      });

      expect(qs.single.id, 'origin');
      expect(qs.single.isOriginal, isTrue);
      expect(qs.single.label, '原画');
    });
  });

  group('parseQualities · 过滤与去重', () {
    test('没有地址的档位被丢掉（选了没反应比不显示更糟）', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'resolutions': [
          {'resolution': '4k'},
          {'resolution': '1080p', 'url': 'https://cdn.example.com/1080.mp4'},
        ],
      });

      expect(qs, hasLength(1));
      expect(qs.single.id, '1080p');
    });

    test('同一档位出现多次时保留第一个（主地址优先于备份地址）', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'list': [
          {'resolution': '1080p', 'url': 'https://cdn.example.com/main.mp4'},
          {'resolution': '1080p', 'url': 'https://cdn.example.com/backup.mp4'},
        ],
      });

      expect(qs, hasLength(1));
      expect(qs.single.url.toString(), 'https://cdn.example.com/main.mp4');
    });

    test('不是 http(s) 的字符串不会被当成地址', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'url': 'not-a-url',
        'resolution': '1080p',
      });

      expect(qs, isEmpty);
    });
  });

  group('parseQualities · 垃圾输入不抛异常', () {
    test('null / 空 / 字符串 / 空列表都返回空表', () {
      expect(QuarkPlayInfoParser.parseQualities(null), isEmpty);
      expect(QuarkPlayInfoParser.parseQualities(<String, Object?>{}), isEmpty);
      expect(QuarkPlayInfoParser.parseQualities('oops'), isEmpty);
      expect(QuarkPlayInfoParser.parseQualities(<Object?>[]), isEmpty);
      expect(QuarkPlayInfoParser.parseQualities(42), isEmpty);
    });
  });

  group('parseOriginalUrl', () {
    test('优先取被标为原画的那一档', () {
      final url = QuarkPlayInfoParser.parseOriginalUrl({
        'video_list': [
          {'resolution': '1080p', 'url': 'https://cdn.example.com/1080.mp4'},
        ],
        'origin': {'is_original': true, 'url': 'https://cdn.example.com/raw.mkv'},
      });

      expect(url.toString(), 'https://cdn.example.com/raw.mkv');
    });

    test('没有原画标记时取排序后的第一条', () {
      final url = QuarkPlayInfoParser.parseOriginalUrl({
        'list': [
          {'resolution': '720p', 'url': 'https://cdn.example.com/720.mp4'},
          {'resolution': '1080p', 'url': 'https://cdn.example.com/1080.mp4'},
        ],
      });

      expect(url.toString(), 'https://cdn.example.com/1080.mp4');
    });

    test('一条档位都没有时返回 null（调用方应换下一条路由）', () {
      expect(QuarkPlayInfoParser.parseOriginalUrl(null), isNull);
      expect(QuarkPlayInfoParser.parseOriginalUrl({'code': 0}), isNull);
    });
  });

  group('诊断描述', () {
    test('空档位有专门的文案（排查「清晰度列表是空的」）', () {
      expect(describeQualities(const []), '无档位（只有原画流）');
    });

    test('describeQualities 只含档位与高度', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'video_list': [
          {'resolution': '4k', 'url': 'https://cdn.example.com/4k.mp4'},
        ],
        'origin': {'is_original': true, 'url': 'https://cdn.example.com/raw.mkv'},
      });

      final text = describeQualities(qs);
      expect(text, 'origin, 4k(2160p)');
      // 地址里有 auth_key 签名，绝不能进日志
      expect(text.contains('http'), isFalse);
      expect(text.contains('auth_key'), isFalse);
    });

    test('describeUrl 抹掉签名参数', () {
      final text = describeUrl(
        Uri.parse('https://cdn.example.com/a.mkv?auth_key=SECRET123&x=1'),
      );

      expect(text.contains('SECRET123'), isFalse);
    });
  });

  group('路由常量', () {
    test('四条路由的 id 唯一、方法与参数形态自洽', () {
      final ids = QuarkPlayRoute.values.map((r) => r.id).toSet();
      expect(ids, hasLength(QuarkPlayRoute.values.length));

      for (final r in QuarkPlayRoute.values) {
        expect(r.path.startsWith('/1/clouddrive/'), isTrue);
        expect(r.method, anyOf('GET', 'POST'));
        expect(r.isPost, r.method == 'POST');
        // POST 走 body、GET 走 query，不能反
        expect(
          r.bodyStyle,
          r.isPost ? QuarkPlayBodyStyle.fids : QuarkPlayBodyStyle.query,
        );
      }
    });

    test('请求体带上了分辨率梯度声明（少了它响应会变瘦）', () {
      expect(kQuarkPlayInfoBody['resolutions'], kQuarkResolutionTiers);
      expect(kQuarkPlayInfoBody['fetch_play_video_resolution_setting'], 1);
    });
  });
}
