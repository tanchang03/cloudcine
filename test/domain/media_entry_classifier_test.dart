import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/services/media_entry_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「哪些网盘条目该进媒体库」这条判据现在被**两条**入口共用
/// （全盘扫描、文件夹里的发现）。这些用例守的是判定顺序 ——
/// 顺序变了，同一个文件在两条路上会落到不同角色，而那是静默的。
void main() {
  DriveEntry entry(String name, {String? mime, bool dir = false}) => DriveEntry(
        id: 'x',
        name: name,
        isDirectory: dir,
        mimeType: mime,
      );

  test('目录优先于一切', () {
    expect(classifyEntry(entry('电影', dir: true)), EntryRole.directory);
    // 名字像视频的目录仍然是目录
    expect(classifyEntry(entry('Movie.mkv', dir: true)), EntryRole.directory);
  });

  test('视频是唯一会被索引的角色', () {
    expect(classifyEntry(entry('Movie.2024.1080p.mkv')), EntryRole.video);
    expect(classifyEntry(entry('Show.S01E01.mp4')), EntryRole.video);
    expect(EntryRole.video.isIndexable, isTrue);
    for (final role in EntryRole.values) {
      if (role == EntryRole.video) continue;
      expect(role.isIndexable, isFalse, reason: '${role.name} 不该入库');
    }
  });

  test('字幕排在视频之前 —— 字幕文件不是媒体项', () {
    // `.srt` 不会被 `isVideoFile` 认成视频，但顺序仍然重要：
    // 万一哪天有同名的 .sub/.mkv 之类混淆，字幕必须优先被摘出去。
    expect(classifyEntry(entry('Movie.2024.1080p.chs.srt')), EntryRole.subtitle);
    expect(classifyEntry(entry('Movie.ass')), EntryRole.subtitle);
  });

  test('图片不进媒体库：一张 cover.jpg 不该变成「一个视频」', () {
    expect(classifyEntry(entry('cover.jpg')), EntryRole.image);
    expect(classifyEntry(entry('poster.png')), EntryRole.image);
  });

  test('扩展名认不出时看 MIME', () {
    expect(
      classifyEntry(entry('noext', mime: 'image/jpeg')),
      EntryRole.image,
      reason: '网盘偶尔给出没有扩展名（或扩展名被改坏）的文件，'
          'MIME 是唯一能救回它的信号',
    );
    expect(
      classifyEntry(entry('noext', mime: 'video/mp4')),
      EntryRole.video,
    );
  });

  test('蓝光镜像单独一类：mpv 播不了 BD 导航，索引了只会得到点了播不了的行', () {
    expect(classifyEntry(entry('Movie.2024.iso')), EntryRole.discImage);
    expect(classifyEntry(entry('Movie.2024.img')), EntryRole.discImage);
  });

  test('其余一律 other', () {
    expect(classifyEntry(entry('readme.txt')), EntryRole.other);
    expect(classifyEntry(entry('Movie.2024.1080p.mkv.nfo')), EntryRole.other);
  });
}
