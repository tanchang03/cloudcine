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

  group('nextVideoProbeAction：视频管线探针什么时候发读数', () {
    // 这条链回答的是用户报的「4K 全程不流畅」。判据是**实际生效的解码器**
    // 与**上屏相关的丢帧数**，而它们只能从 mpv 属性读出来 —— 真机上唯一能
    // 看到的地方是应用内「诊断日志」页，所以这段判断错了不会报错，只会让人
    // 照着假结论去改一堆没用的参数。

    test('解码器还没起来（hwdec-current 是空串）时**不发**第一拍', () {
      // ⛔ 这条是整段逻辑里最容易写错、代价最大的一处：`loadfile` 之后的一小段
      // 时间里 `hwdec-current` 就是空串。把它当成「软解」会得出
      // 「硬解没生效」的结论，而它下一秒就起来了。
      expect(
        nextVideoProbeAction(ticks: 1, samples: 0, decoderReady: false),
        VideoProbeAction.skip,
      );
      expect(
        nextVideoProbeAction(ticks: 5, samples: 0, decoderReady: false),
        VideoProbeAction.skip,
      );
    });

    test('解码器一起来就发第一拍（不必等满固定秒数）', () {
      expect(
        nextVideoProbeAction(ticks: 1, samples: 0, decoderReady: true),
        VideoProbeAction.sample,
      );
    });

    test('第一拍之后按固定间隔继续发 —— 采样要**跨越整段播放**', () {
      // ⛔ 旧策略只发两拍（约第 6s / 第 27s），而那两拍恰好都贴着
      // 「起播 + 片头跳过 seek」，读数全是 0 —— 用户报的却是**全程**不流畅。
      // 只测起播那 30 秒就会得出「没有掉帧」的假结论（10-04 就是这么栽的）。
      expect(
        nextVideoProbeAction(ticks: 2, samples: 1, decoderReady: true),
        VideoProbeAction.skip,
      );
      expect(
        nextVideoProbeAction(ticks: 7, samples: 1, decoderReady: true),
        VideoProbeAction.sample,
        reason: '第 7 拍（约第 21s）要再发一条',
      );
      expect(
        nextVideoProbeAction(ticks: 98, samples: 5, decoderReady: true),
        VideoProbeAction.sample,
        reason: '第 98 拍（约第 294s）还得在发 —— 长片要能一直看到读数',
      );
    });

    test('采样点不挨着 —— 相邻两条之间至少隔一拍', () {
      // 挨着发的两个数都是 0，看不出「每 10 秒丢 30 帧」这种速率。
      var samples = 0;
      final sampleTicks = <int>[];
      for (var ticks = 1; ticks <= 40; ticks++) {
        final a = nextVideoProbeAction(
          ticks: ticks,
          samples: samples,
          decoderReady: true,
        );
        if (a == VideoProbeAction.sample) {
          samples++;
          sampleTicks.add(ticks);
        }
      }
      expect(
        sampleTicks.length,
        greaterThan(2),
        reason: '一轮探针至少要发三条，才谈得上「跨越整段播放」',
      );
      for (var i = 1; i < sampleTicks.length; i++) {
        expect(
          sampleTicks[i] - sampleTicks[i - 1],
          greaterThan(1),
        );
      }
    });

    test('发满上限就收工 —— 别把 800 行的环形缓冲刷满', () {
      expect(
        nextVideoProbeAction(ticks: 200, samples: 16, decoderReady: true),
        VideoProbeAction.stop,
      );
      expect(
        nextVideoProbeAction(ticks: 121, samples: 3, decoderReady: true),
        VideoProbeAction.stop,
      );
    });

    test('解码器一直不起来时到点就停 —— 不能永远挂着定时器', () {
      expect(
        nextVideoProbeAction(ticks: 9, samples: 0, decoderReady: false),
        VideoProbeAction.skip,
      );
      expect(
        nextVideoProbeAction(ticks: 10, samples: 0, decoderReady: false),
        VideoProbeAction.stop,
      );
    });
  });

  group('shouldKickHwdec：起播后要不要重建解码器', () {
    // 这条判据是「Surface 等超时」那条兜底路上的闸门。它决定要不要在播放
    // 中途改 `hwdec` —— 改会重建解码器，有一瞬间顿挫；不改则 4K 继续丢帧。
    // 三个条件各自都能单独写错，所以逐条钉住。

    test('还在拷贝档 + 片头 → 动手', () {
      expect(
        MediaKitPlaybackEngine.shouldKickHwdec(
          hwdecCurrent: 'mediacodec-copy',
          position: Duration.zero,
        ),
        isTrue,
      );
    });

    test('已经是零拷贝 → 绝不动手（一个字节都不改播放）', () {
      // 直通生效时这条检查必须是纯读。误判成「要重建」会在片头平白顿一下，
      // 而且用户刚报过「卡顿」，这一下会被当成没修好。
      expect(
        MediaKitPlaybackEngine.shouldKickHwdec(
          hwdecCurrent: 'mediacodec',
          position: Duration.zero,
        ),
        isFalse,
      );
    });

    test('解码器还没起来（空串）→ 不动手', () {
      // ⛔ 空串不是「退回拷贝」，只是还没有读数。这一条写错就会在起播那一
      // 瞬间触发一次没必要的重建。
      expect(
        MediaKitPlaybackEngine.shouldKickHwdec(
          hwdecCurrent: '',
          position: Duration.zero,
        ),
        isFalse,
      );
    });

    test('已过重建窗口 → 不动手，哪怕确实在拷贝档', () {
      // 重建的顿挫放在正片中间就成了**新的卡顿**。窗口边界是闭区间：
      // 正好卡在窗口末尾那一次仍允许（那时的顿挫还贴着片头）。
      const window = MediaKitPlaybackEngine.hwdecKickWindow;
      expect(
        MediaKitPlaybackEngine.shouldKickHwdec(
          hwdecCurrent: 'mediacodec-copy',
          position: window + const Duration(seconds: 1),
        ),
        isFalse,
      );
      expect(
        MediaKitPlaybackEngine.shouldKickHwdec(
          hwdecCurrent: 'mediacodec-copy',
          position: window,
        ),
        isTrue,
      );
    });
  });
}
