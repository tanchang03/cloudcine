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

    test('marketingLabel 把 2160P 说成 4K', () {
      expect(VideoResolution.uhd2160.marketingLabel, '4K');
      expect(VideoResolution.uhd4320.marketingLabel, '8K');
      expect(VideoResolution.fhd1080.marketingLabel, '1080P');
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
