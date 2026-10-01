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

    test('既无标识也无地址线索时**不产档位**（原画不由这里发明）', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'play_url': 'https://cdn.example.com/raw.mkv',
      });

      // 这条断言以前是相反的（那时它返回一条 id='origin' 的「原画」）。
      // 改掉它是因为那个兜底会造成**静默错播**：任何没有分辨率信息的地址
      // 都会被提升成原画，而原画永远排最前 → 默认播它。
      // 原画现在只有一个来源：/file/audioplay 取回的原文件。
      expect(qs, isEmpty);
    });

    test('显式标了 is_original 的仍然当原画（服务端确实给了标记）', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'is_original': true,
        'play_url': 'https://cdn.example.com/raw.mkv',
      });

      expect(qs.single.id, 'origin');
      expect(qs.single.isOriginal, isTrue);
      expect(qs.single.label, '原画');
    });
  });

  group('真实载荷回归 · 音轨不能被当成原画', () {
    /// 2026-10-01 实测的**真实响应**（指环王：力量之戒 S01E01，3.8 GB MKV）。
    ///
    /// 这份载荷是「原画没有画面」那个事故的现场。它必须留在这里：
    /// 事故的成因是**静默**的（解析不抛异常、日志干净），只有把真实形状钉住
    /// 才能防止有人把 `audioOnlyKeys` 那层过滤当成多余代码删掉。
    Map<String, Object?> realPayload() => {
          '8e6c6e9e94294364a7bdf9a3d01d0500': {
            'default_resolution': 'super',
            'origin_default_resolution': 'super',
            'video_list': [
              {
                'resolution': 'super',
                'video_info': {
                  'duration': 3947,
                  'size': 749283193,
                  'format': 'mp4',
                  'width': 1440,
                  'height': 600,
                  'bitrate': 1518.0,
                  'codec': 'h264',
                  'fps': 24.0,
                  'audio': {'codec': 'aac', 'channels': 2, 'bitrate': 128.0},
                  'url': 'https://video-play-c-zb.drive.quark.cn/super.mp4',
                  'resolution': 'super',
                  'hls_type': 'none',
                },
                'right': 'svip',
                'trans_status': 'success',
                'accessable': true,
              },
              {
                'resolution': 'high',
                'video_info': {
                  'width': 960,
                  'height': 400,
                  'bitrate': 855.0,
                  'codec': 'h264',
                  'url': 'https://video-play-c-zb-cf.pds.quark.cn/high.mp4',
                  'resolution': 'high',
                },
                'accessable': true,
              },
              {
                'resolution': 'low',
                'video_info': {
                  'width': 480,
                  'height': 200,
                  'codec': 'h264',
                  'url': 'https://video-play-c-zb-cf.pds.quark.cn/low.mp4',
                  'resolution': 'low',
                },
                'accessable': true,
              },
            ],
            // ⚠️ 这一条是**纯音频流**（Dolby E-AC-3）。它没有分辨率字段，
            // URL 里也没有 `1080p` 这类线索 —— 老解析器据此把它判成「原画」，
            // 而原画永远排最前，于是默认播的就是它：有声无画、时间轴照走。
            'audio_list': [
              {
                'type': 'dolby_eac3',
                'right': 'svip',
                'accessable': true,
                'audio_info': {
                  'url': 'https://video-play-c-zb-cf.pds.quark.cn/dolby.mp4',
                },
              },
            ],
            'file_name': 'The.Lord.of.the.Rings.The.Rings.of.Power.S01E01.mkv',
            'size': 3828008839,
            'meta': {
              'duration': 3947,
              'size': 3828008839,
              'format': 'matroska,webm',
              'width': 1920,
              'height': 800,
              'bitrate': 7758.0,
              'codec': 'h264',
              'fps': 24.0,
              'pix_fmt': 'yuv420p',
            },
          },
        };

    test('只解析出视频档位，绝不产出 origin（音轨不是原画）', () {
      final qs = QuarkPlayInfoParser.parseQualities(realPayload());

      expect(qs.map((q) => q.id).toList(), ['super', 'high', 'low']);
      expect(
        qs.any((q) => q.isOriginal),
        isFalse,
        reason: '原画只能来自 /file/audioplay 的原文件；'
            'play/info 的 video_list 里根本没有原画档。'
            '一旦这里又冒出 origin，默认播的就是那条没有视频轨的杜比音轨 —— '
            '有声音、进度条在走、没有画面，而且不报任何错。',
      );
      // 杜比音轨的地址绝不能出现在任何一档里
      expect(
        qs.any((q) => q.url.toString().contains('dolby')),
        isFalse,
        reason: 'audio_list 的地址是纯音频流，播它等于「没有画面」',
      );
    });

    test('码率按 kbps 读，副标题不是「0.0 Mbps」', () {
      final qs = QuarkPlayInfoParser.parseQualities(realPayload());
      final top = qs.firstWhere((q) => q.id == 'super');

      // 服务端给的是 1518.0，单位是 kbps（749 MB ÷ 3947 s = 1518 kbps）。
      // 不换算的话 displayDetail 会算出 0.0 Mbps —— 静默错，不报异常。
      expect(top.bitrate, 1518000);
      expect(top.displayDetail, '1440×600 · 1.5 Mbps');
    });

    test('没有分辨率标识的地址**不是**一档清晰度（原画只能来自 audioplay）', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'video_info': {
          'width': 960,
          'height': 400,
          'codec': 'h264',
          'url': 'https://cdn/no-resolution-marker.mp4',
        },
      });

      expect(
        qs,
        isEmpty,
        reason: '「没有标识就当原画」那个兜底正是原画播出来没画面的成因：'
            '杜比音轨的地址没有任何分辨率信息，被提升成原画后排到最前，'
            '成了默认要播的那一条。没有分辨率信息的地址一律不算档位。',
      );
    });

    test('服务端真给原画档（带标识）时仍然认得出来', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'video_list': [
          {
            'resolution': 'origin',
            'video_info': {'url': 'https://cdn/source.mkv'},
          },
        ],
      });

      expect(qs.single.id, 'origin');
      expect(qs.single.isOriginal, isTrue);
    });

    test('parseOriginalUrl 退化为最高转码档，而不是音轨', () {
      final url = QuarkPlayInfoParser.parseOriginalUrl(realPayload());
      expect(url.toString(), 'https://video-play-c-zb.drive.quark.cn/super.mp4');
    });

    test('源文件元信息来自 meta（原画那档的副标题）', () {
      final meta = QuarkPlayInfoParser.parseSourceMeta(realPayload());
      expect(meta, isNotNull);
      expect(meta!.width, 1920);
      expect(meta.height, 800);
      expect(meta.codec, 'h264');
      expect(meta.format, 'matroska,webm');
      expect(meta.sizeBytes, 3828008839);
      expect(QuarkPlayInfoParser.describeSourceMeta(meta), '1920×800 · 7.8 Mbps · MKV');
    });

    test('没有 meta 时返回 null，不猜', () {
      expect(QuarkPlayInfoParser.parseSourceMeta({'video_list': []}), isNull);
      expect(QuarkPlayInfoParser.parseSourceMeta(null), isNull);
    });

    test('meta 里的容器名认不出来时，副标题只省略容器那一段', () {
      final meta = QuarkPlayInfoParser.parseSourceMeta({
        'meta': {'width': 1280, 'height': 720, 'format': 'weird_container'},
      });
      expect(QuarkPlayInfoParser.describeSourceMeta(meta!), '1280×720');
    });

    test('无間道II 4K 的载荷（audio_list 为空）不受影响', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'video_list': [
          {'resolution': '4k', 'video_info': {'url': 'https://cdn/4k.mp4'}},
          {'resolution': 'super', 'video_info': {'url': 'https://cdn/super.mp4'}},
        ],
        'audio_list': <Object?>[],
        'meta': {'format': 'matroska,webm', 'width': 3840, 'height': 2160},
      });

      expect(qs.map((q) => q.id).toList(), ['4k', 'super']);
    });

    test('整棵音轨子树都被跳过（audio_info / audio_stream_list 同样）', () {
      final qs = QuarkPlayInfoParser.parseQualities({
        'audio_list': [
          {
            'audio_info': {'url': 'https://cdn/audio-only.mp4'},
            'audio_stream_list': [
              {'url': 'https://cdn/audio-stream.mp4'},
            ],
          },
        ],
      });

      expect(qs, isEmpty, reason: '只有音轨时应当返回空表，让调用方换路由');
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
    test('四条路由的 id 唯一、路径都在网盘前缀下', () {
      final ids = QuarkPlayRoute.values.map((r) => r.id).toSet();
      expect(ids, hasLength(QuarkPlayRoute.values.length));

      for (final r in QuarkPlayRoute.values) {
        expect(r.path.startsWith('/1/clouddrive/'), isTrue);
        expect(r.method, anyOf('GET', 'POST'));
        expect(r.isPost, r.method == 'POST');
        // GET 走 query，不可能是 body 形态
        if (!r.isPost) {
          expect(r.bodyStyle, QuarkPlayBodyStyle.query);
        }
      }
    });

    test('v2/play 必须是 POST + {"fid":…}，GET 实测 405', () {
      const route = QuarkPlayRoute.v2Play;
      expect(
        route.method,
        'POST',
        reason: '2026-10-01 实测 GET /file/v2/play 返回 '
            "405 Request method 'GET' not supported —— 这条路以前从来没通过",
      );
      expect(
        route.bodyStyle,
        QuarkPlayBodyStyle.fid,
        reason: '实测 POST {"fids":[fid]} 返回 400 code=14001 '
            '"Bad Parameter: [fid is empty!]" —— 它要的是单数 fid',
      );
    });

    test('批量形态的路由才用 fids', () {
      expect(QuarkPlayRoute.playInfo.bodyStyle, QuarkPlayBodyStyle.fids);
      expect(QuarkPlayRoute.download.bodyStyle, QuarkPlayBodyStyle.fids);
      expect(QuarkPlayRoute.audioPlay.bodyStyle, QuarkPlayBodyStyle.query);
    });

    test('请求体带上了分辨率梯度声明（少了它响应会变瘦）', () {
      expect(kQuarkPlayInfoBody['resolutions'], kQuarkResolutionTiers);
      expect(kQuarkPlayInfoBody['fetch_play_video_resolution_setting'], 1);
    });

    test('音轨子树名单钉死（原画事故的解药，别删）', () {
      expect(
        QuarkPlayInfoParser.audioOnlyKeys,
        containsAll(<String>['audio_list', 'audio_info']),
      );
    });
  });
}
