import 'package:cloudcine/data/playback/media_kit_playback_engine.dart';
import 'package:cloudcine/domain/services/intro_marker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;

/// media_kit 引擎里**能脱离 Player 实例测**的那部分。
///
/// `mk.Player()` 在 `flutter test` 里构造不出来（要 native 库），所以真正
/// 会出错的那些映射逻辑被刻意抽成了静态纯函数 —— 它们是引擎里唯一
/// 有判断（而不是转发）的地方：
///   - 合成轨过滤 + 轨道号解析（判错 = 菜单里多两条点了没反应的选项）；
///   - 章节终点补全（判错 = 负时长 / 章节区间错位）。
void main() {
  group('parseTrackId：mpv 的轨道号 → 契约的整数 id', () {
    test('数字串解析成整数', () {
      expect(MediaKitPlaybackEngine.parseTrackId('3'), 3);
    });

    test('合成轨 auto / no 解析成 null', () {
      // ⚠️ 这两条是 media_kit 硬塞进来的**合成轨**，它们的 id 不是轨道号。
      // 当成真实轨道会踩两个坑：菜单里多出两条点了没反应的选项，
      // 以及自动选字幕取「第一条」时每次都会选中它们。
      expect(MediaKitPlaybackEngine.parseTrackId('auto'), isNull);
      expect(MediaKitPlaybackEngine.parseTrackId('no'), isNull);
    });

    test('null 进 null 出', () {
      expect(MediaKitPlaybackEngine.parseTrackId(null), isNull);
    });

    test('空串解析成 null，而不是抛异常', () {
      // mpv 在读不到属性时给的就是空串（`getProperty` 丢掉返回码）。
      expect(MediaKitPlaybackEngine.parseTrackId(''), isNull);
    });
  });

  group('mapTracks：mk.Tracks → EngineTracks', () {
    test('默认构造的 Tracks 只有合成轨，映射出来是空的', () {
      // `mk.Tracks()` 的默认值就是 [auto, no] —— 一个没有任何内嵌轨的文件
      // 解出来正是这个样子。映射后必须一条不剩。
      final tracks = MediaKitPlaybackEngine.mapTracks(const mk.Tracks());
      expect(tracks.isEmpty, isTrue);
      expect(tracks.audio, isEmpty);
      expect(tracks.subtitle, isEmpty);
      expect(tracks.video, isEmpty);
    });

    test('真实轨道被映射，轨道号解析成整数', () {
      final tracks = MediaKitPlaybackEngine.mapTracks(
        const mk.Tracks(
          audio: [
            mk.AudioTrack('auto', null, null),
            mk.AudioTrack('no', null, null),
            mk.AudioTrack('1', '国语', 'chi'),
            mk.AudioTrack('2', '粤语', 'yue'),
          ],
        ),
      );
      expect(tracks.audio.map((t) => t.id), [1, 2]);
      expect(tracks.audio.first.title, '国语');
      expect(tracks.audio.first.language, 'chi');
    });

    test('合成轨与真实轨混在一起时只留真实轨', () {
      final tracks = MediaKitPlaybackEngine.mapTracks(
        const mk.Tracks(
          subtitle: [
            mk.SubtitleTrack('auto', null, null),
            mk.SubtitleTrack('no', null, null),
            mk.SubtitleTrack('3', '简体', 'chi'),
          ],
        ),
      );
      expect(tracks.subtitle.length, 1);
      expect(tracks.subtitle.single.id, 3);
    });

    test('三类轨分开映射，不串味', () {
      final tracks = MediaKitPlaybackEngine.mapTracks(
        const mk.Tracks(
          video: [mk.VideoTrack('1', '主视频', null)],
          audio: [mk.AudioTrack('2', '音轨', null)],
          subtitle: [mk.SubtitleTrack('3', '字幕', null)],
        ),
      );
      expect(tracks.video.single.id, 1);
      expect(tracks.audio.single.id, 2);
      expect(tracks.subtitle.single.id, 3);
    });

    test('isDefault 为 null 时落成 false（契约里它是非空 bool）', () {
      final tracks = MediaKitPlaybackEngine.mapTracks(
        const mk.Tracks(audio: [mk.AudioTrack('1', null, null)]),
      );
      expect(tracks.audio.single.isDefault, isFalse);
    });

    test('isDefault 为 true 时保留', () {
      // 内嵌字幕「发布者标记为默认」那一条要靠它 —— 丢了会让自动选字幕
      // 退化成「按语言猜」。
      final tracks = MediaKitPlaybackEngine.mapTracks(
        const mk.Tracks(
          audio: [mk.AudioTrack('1', null, null, isDefault: true)],
        ),
      );
      expect(tracks.audio.single.isDefault, isTrue);
    });

    test('指纹在条数相同但轨道号变化时**必须**变', () {
      // 这是 `EngineTracks.signature` 存在的一半理由：换集时音轨常常还是
      // 两条，只有 id 变了。只比条数的话「还原音轨」「自动选字幕」都不会
      // 重跑，症状是「第二集沿用第一集的音轨选择」。
      final before = MediaKitPlaybackEngine.mapTracks(
        const mk.Tracks(audio: [mk.AudioTrack('1', null, null)]),
      );
      final after = MediaKitPlaybackEngine.mapTracks(
        const mk.Tracks(audio: [mk.AudioTrack('4', null, null)]),
      );
      expect(before.signature, isNot(after.signature));
    });

    test('指纹在内容完全相同时保持不变', () {
      // 反过来：内容一样就不能变，否则每一拍都上报一次轨道清单，
      // 订阅方（播放页）跟着每拍重跑自动选字幕。
      const source = mk.Tracks(audio: [mk.AudioTrack('1', '国语', 'chi')]);
      expect(
        MediaKitPlaybackEngine.mapTracks(source).signature,
        MediaKitPlaybackEngine.mapTracks(source).signature,
      );
    });
  });

  group('chaptersFrom：mpv 的章节清单补出终点', () {
    const opening = IntroChapter(title: 'Opening', start: Duration.zero);
    const partA = IntroChapter(title: 'Part A', start: Duration(seconds: 10));
    const ending = IntroChapter(title: 'Ending', start: Duration(seconds: 40));

    test('空清单映射成空列表', () {
      expect(
        MediaKitPlaybackEngine.chaptersFrom(const [], const Duration(minutes: 1)),
        isEmpty,
      );
    });

    test('一章延伸到下一章的起点', () {
      final chapters = MediaKitPlaybackEngine.chaptersFrom(
        const [opening, partA, ending],
        const Duration(seconds: 60),
      );
      expect(chapters[0].start, Duration.zero);
      expect(chapters[0].end, Duration(seconds: 10));
      expect(chapters[1].start, Duration(seconds: 10));
      expect(chapters[1].end, Duration(seconds: 40));
    });

    test('最后一章延伸到片尾', () {
      final chapters = MediaKitPlaybackEngine.chaptersFrom(
        const [opening, partA, ending],
        const Duration(seconds: 60),
      );
      expect(chapters.last.end, const Duration(seconds: 60));
      expect(chapters.last.duration, const Duration(seconds: 20));
    });

    test('章节标题原样保留', () {
      final chapters = MediaKitPlaybackEngine.chaptersFrom(
        const [opening],
        const Duration(seconds: 60),
      );
      expect(chapters.single.title, 'Opening');
    });

    test('片长还没解出来时最后一章退化成零长度，而不是编一个终点', () {
      // 章节清单的用途只有「认片头」，而认片头只看 start。编一个假终点
      // 反而会污染 `EngineChapter.duration`，所以宁可退化。
      final chapters = MediaKitPlaybackEngine.chaptersFrom(
        const [ending],
        Duration.zero,
      );
      expect(chapters.single.start, const Duration(seconds: 40));
      expect(chapters.single.end, const Duration(seconds: 40));
      expect(chapters.single.duration, Duration.zero);
    });

    test('片长比最后一章起点还小（读到的时长不对）也不出负时长', () {
      final chapters = MediaKitPlaybackEngine.chaptersFrom(
        const [ending],
        const Duration(seconds: 5),
      );
      expect(chapters.single.duration, Duration.zero);
    });

    test('乱序的章节清单不出负时长', () {
      // mpv 理论上按序给，但真出现乱序时 `end < start` 会让 duration 变负数，
      // 流到界面上是「负数时长」—— 比退化到 0 难查得多。
      final chapters = MediaKitPlaybackEngine.chaptersFrom(
        const [ending, opening],
        const Duration(seconds: 60),
      );
      for (final c in chapters) {
        // ⚠️ 用 `isNegative` 而不是 `isNonNegative`：后者是给 `num` 的，
        // 对 `Duration` 会抛类型错误（`Duration` 不实现 `Comparable<num>`）。
        expect(c.duration.isNegative, isFalse);
      }
    });

    test('一章都没有时不会凭空造出一个区间', () {
      expect(
        MediaKitPlaybackEngine.chaptersFrom(const [], const Duration(seconds: 60)),
        isEmpty,
      );
    });
  });
}
