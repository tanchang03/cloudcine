import 'package:cloudcine/core/utils/video_formats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VideoFormats.isVideoFile', () {
    test('认得主流容器扩展名（含大小写）', () {
      expect(VideoFormats.isVideoFile('movie.mkv'), isTrue);
      expect(VideoFormats.isVideoFile('movie.MP4'), isTrue);
      expect(VideoFormats.isVideoFile('movie.rmvb'), isTrue);
      expect(VideoFormats.isVideoFile('movie.m2ts'), isTrue);
      expect(VideoFormats.isVideoFile('movie.ogv'), isTrue);
    });

    test('非视频扩展名判否', () {
      expect(VideoFormats.isVideoFile('readme.txt'), isFalse);
      expect(VideoFormats.isVideoFile('song.flac'), isFalse);
      expect(VideoFormats.isVideoFile('subtitle.srt'), isFalse);
    });

    test('扩展名认不出时用 MIME 兜底', () {
      expect(
        VideoFormats.isVideoFile('no-extension', mimeType: 'video/x-matroska'),
        isTrue,
      );
      expect(
        VideoFormats.isVideoFile('no-extension', mimeType: 'text/plain'),
        isFalse,
      );
    });

    test('没有扩展名也不报错', () {
      expect(VideoFormats.isVideoFile('noext'), isFalse);
      expect(VideoFormats.isVideoFile('.hidden'), isFalse);
    });
  });

  group('VideoFormats.containerOf', () {
    test('取最后一个点之后的扩展名', () {
      // `2023.mkv` 不能被当成扩展名
      expect(
        VideoFormats.containerOf('The.Wandering.Earth.II.2023.mkv'),
        VideoContainer.matroska,
      );
    });

    test('MIME 补充识别', () {
      expect(
        VideoFormats.containerOf('weird', mimeType: 'video/x-matroska'),
        VideoContainer.matroska,
      );
      expect(
        VideoFormats.containerOf('weird', mimeType: 'video/x-msvideo'),
        VideoContainer.avi,
      );
    });

    test('认不出来归到 other，但仍然会被索引', () {
      expect(VideoFormats.containerOf('weird.mxf'), VideoContainer.other);
    });
  });

  group('VideoFormats.resolutionFromName', () {
    test('扫描式写法', () {
      expect(
        VideoFormats.resolutionFromName('a.1080p.mkv'),
        VideoResolution.fhd1080,
      );
      expect(
        VideoFormats.resolutionFromName('a.720P.mkv'),
        VideoResolution.hd720,
      );
      expect(
        VideoFormats.resolutionFromName('a.2160p.mkv'),
        VideoResolution.uhd2160,
      );
      // 隔行扫描也认
      expect(
        VideoFormats.resolutionFromName('a.1080i.mkv'),
        VideoResolution.fhd1080,
      );
    });

    test('习惯叫法 4K / 8K / 2K', () {
      expect(
        VideoFormats.resolutionFromName('a.4K.mkv'),
        VideoResolution.uhd2160,
      );
      expect(
        VideoFormats.resolutionFromName('a.8K.mkv'),
        VideoResolution.uhd4320,
      );
      expect(
        VideoFormats.resolutionFromName('a.2K.mkv'),
        VideoResolution.qhd1440,
      );
    });

    test('宽x高写法', () {
      expect(
        VideoFormats.resolutionFromName('a.1920x1080.mkv'),
        VideoResolution.fhd1080,
      );
      expect(
        VideoFormats.resolutionFromName('a.3840×2160.mkv'),
        VideoResolution.uhd2160,
      );
    });

    test('宽银幕裁切不冒充高分辨率', () {
      // 1920x800 的「高」只有 800，标成 1080P 是误导
      expect(
        VideoFormats.resolutionFromName('a.1920x800.mkv'),
        VideoResolution.hd720,
      );
    });

    test('认不出来返回 null，不猜', () {
      expect(VideoFormats.resolutionFromName('a.mkv'), isNull);
      expect(VideoFormats.resolutionFromName('a.480p.mkv'), VideoResolution.sd480);
      // 低于 360 的「高」不成档
      expect(VideoFormats.resolutionFromName('a.320x240.mkv'), isNull);
    });

    test('竖屏写法也按短边认档', () {
      // `1080x1920` 的第二个数是长边。早先直接取第二个数当「高」去比
      // 480/720/1080 那排档位，竖屏片会被说成 1440P。
      expect(
        VideoFormats.resolutionFromName('a.1080x1920.mkv'),
        VideoResolution.fhd1080,
      );
      expect(
        VideoFormats.resolutionFromName('a.720x1280.mkv'),
        VideoResolution.hd720,
      );
    });

    test('marketingLabel 把 2160P 说成 4K', () {
      expect(VideoResolution.uhd2160.marketingLabel, '4K');
      expect(VideoResolution.uhd4320.marketingLabel, '8K');
      expect(VideoResolution.fhd1080.marketingLabel, '1080P');
    });
  });

  group('VideoFormats.resolutionFromDimensions', () {
    test('标准 16:9 尺寸各归其档', () {
      expect(
        VideoFormats.resolutionFromDimensions(7680, 4320),
        VideoResolution.uhd4320,
      );
      expect(
        VideoFormats.resolutionFromDimensions(3840, 2160),
        VideoResolution.uhd2160,
      );
      expect(
        VideoFormats.resolutionFromDimensions(2560, 1440),
        VideoResolution.qhd1440,
      );
      expect(
        VideoFormats.resolutionFromDimensions(1920, 1080),
        VideoResolution.fhd1080,
      );
      expect(
        VideoFormats.resolutionFromDimensions(1280, 720),
        VideoResolution.hd720,
      );
      expect(
        VideoFormats.resolutionFromDimensions(854, 480),
        VideoResolution.sd480,
      );
    });

    test('宽银幕裁切按长边归挡，不被高度拉低一档', () {
      // 2026-10-01 实测（44 个目录 / 427 个视频）里这类占 40%。
      // 只按高度会全部低估一档，后果不只是标签难看：「同片多版本」排序会把
      // 4K 版排到 1080P 版后面，用户挑清晰度时选错文件。
      expect(
        VideoFormats.resolutionFromDimensions(3840, 1632),
        VideoResolution.uhd2160,
      );
      expect(
        VideoFormats.resolutionFromDimensions(3840, 1608),
        VideoResolution.uhd2160,
      );
      expect(
        VideoFormats.resolutionFromDimensions(4096, 1742),
        VideoResolution.uhd2160,
      );
      expect(
        VideoFormats.resolutionFromDimensions(1920, 804),
        VideoResolution.fhd1080,
      );
      expect(
        VideoFormats.resolutionFromDimensions(1280, 536),
        VideoResolution.hd720,
      );
    });

    test('4:3 老内容靠短边兜住，不会连角标都没有', () {
      // 720x576 的长边 720 低于最低档 sd480 的长边 854，只按长边会返回 null
      // —— 一部 DVD 时代的老剧连分辨率都不显示。
      expect(
        VideoFormats.resolutionFromDimensions(720, 576),
        VideoResolution.sd480,
      );
      expect(
        VideoFormats.resolutionFromDimensions(720, 480),
        VideoResolution.sd480,
      );
      expect(
        VideoFormats.resolutionFromDimensions(640, 480),
        VideoResolution.sd480,
      );
      // 960x720 是实打实的 720 线，不该因为长边只有 960 就掉到 480P
      expect(
        VideoFormats.resolutionFromDimensions(960, 720),
        VideoResolution.hd720,
      );
      // 1440x1080 是 4:3 的 1080，长边 1440 只够 720P
      expect(
        VideoFormats.resolutionFromDimensions(1440, 1080),
        VideoResolution.fhd1080,
      );
    });

    test('竖屏与横屏同档：第二根轴用短边，不能用「高」', () {
      // 竖屏的「高」就是长边。若第二根轴取「高」，1080x1920 会被读成 1440P、
      // 720x1280 被读成 1080P —— 手机拍的竖屏内容会全部虚高一到两档。
      expect(
        VideoFormats.resolutionFromDimensions(1080, 1920),
        VideoResolution.fhd1080,
      );
      expect(
        VideoFormats.resolutionFromDimensions(720, 1280),
        VideoResolution.hd720,
      );
      expect(
        VideoFormats.resolutionFromDimensions(2160, 3840),
        VideoResolution.uhd2160,
      );
      expect(
        VideoFormats.resolutionFromDimensions(1440, 2560),
        VideoResolution.qhd1440,
      );
    });

    test('只给一边时把它当档位数字读（兜底路径）', () {
      // 实战里夸克宽高都给（实测 427/427 全有），这条只是防御性兜底。
      expect(
        VideoFormats.resolutionFromDimensions(1080, null),
        VideoResolution.fhd1080,
      );
      expect(
        VideoFormats.resolutionFromDimensions(null, 1080),
        VideoResolution.fhd1080,
      );
      expect(
        VideoFormats.resolutionFromDimensions(720, null),
        VideoResolution.hd720,
      );
      expect(
        VideoFormats.resolutionFromDimensions(3840, null),
        VideoResolution.uhd2160,
      );
    });

    test('缺值 / 非法值返回 null，UI 上不显示角标', () {
      expect(VideoFormats.resolutionFromDimensions(null, null), isNull);
      expect(VideoFormats.resolutionFromDimensions(0, 0), isNull);
      expect(VideoFormats.resolutionFromDimensions(-1920, -1080), isNull);
      // 长边不足 854、短边又不足 360 的，两轴都不成档
      expect(VideoFormats.resolutionFromDimensions(320, 240), isNull);
    });

    test('实测与文件名冲突时实测说了算', () {
      // 文件名是发布组自己写的标签，会错会缺；尺寸是服务端读文件头得到的。
      // `MediaItem.fromEntry` 的取值顺序：实测尺寸 → 文件名宽高 → 文件名档位。
      const name = 'Movie.2023.1080p.WEB-DL.mkv';
      expect(VideoFormats.resolutionFromName(name), VideoResolution.fhd1080);
      // 同一个文件名，实测是 4K 宽银幕 —— 应采信实测
      expect(
        VideoFormats.resolutionFromDimensions(3840, 1632),
        VideoResolution.uhd2160,
      );
    });
  });

  group('VideoFormats.isSampleOrExtra', () {
    test('命中花絮标记', () {
      expect(VideoFormats.isSampleOrExtra('Movie.2023.sample.mkv'), isTrue);
      expect(VideoFormats.isSampleOrExtra('Movie.2023.trailer.mkv'), isTrue);
      expect(VideoFormats.isSampleOrExtra('Movie.2023.花絮.mkv'), isTrue);
      expect(VideoFormats.isSampleOrExtra('Movie.2023.预告.mkv'), isTrue);
    });

    test('正片不会被误判', () {
      expect(VideoFormats.isSampleOrExtra('Movie.2023.1080p.mkv'), isFalse);
      expect(VideoFormats.isSampleOrExtra('The.Sampler.2023.mkv'), isFalse);
    });
  });

  group('VideoFormats.isDiscImage', () {
    test('iso / img 是镜像', () {
      expect(VideoFormats.isDiscImage('movie.iso'), isTrue);
      expect(VideoFormats.isDiscImage('movie.img'), isTrue);
      expect(VideoFormats.isDiscImage('movie.mkv'), isFalse);
    });
  });
}
