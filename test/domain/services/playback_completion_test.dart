import 'package:cloudcine/domain/services/playback_completion.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「播完了」的护栏。
///
/// 它是纯函数，所以能直接测 —— 而它**值得**测：判错的两个方向代价都很实在，
/// 而且都表现为「播放窗口自己在换片/不换片」，用户看不出原因。
void main() {
  const sawVideo = true;
  const noVideo = false;

  group('位置足够长就一律放行', () {
    test('正常片尾：位置 3600s → 播完', () {
      // 主路径。绝大多数自动连播走这里，护栏不该碰它。
      expect(
        PlaybackCompletion.isRealEnd(
          position: const Duration(seconds: 3600),
          sawVideo: sawVideo,
        ),
        isTrue,
      );
    });

    test('长片但全程没画面 → 仍然算播完（纯音频文件）', () {
      // ⚠️ 这条护住一个容易写反的地方：本应用也索引纯音频文件
      // （`ScanPolicy.audioOnly`），那种文件**永远**不会 `sawVideo`。
      // 只看「有没有画面」的话，每一首音频播完都会被判成故障。
      expect(
        PlaybackCompletion.isRealEnd(
          position: const Duration(seconds: 3600),
          sawVideo: noVideo,
        ),
        isTrue,
      );
    });

    test('边界：恰好 3 秒就算够', () {
      expect(
        PlaybackCompletion.isRealEnd(
          position: PlaybackCompletion.minPlayed,
          sawVideo: noVideo,
        ),
        isTrue,
      );
    });
  });

  group('位置很短时要看有没有出过画面', () {
    test('⚠️ 故障现场：1 秒 + 全程没画面 → 不算播完', () {
      // 这条就是 2026-10-04 那次：夸克转码档 HLS 只给了约 1 秒的流、
      // 有声音没画面，然后 mpv 报 EOF。当时没有护栏，于是 60 秒内
      // 级联跳了 5 部片，真正的报错一次都没露出来。
      expect(
        PlaybackCompletion.isRealEnd(
          position: const Duration(seconds: 1),
          sawVideo: noVideo,
        ),
        isFalse,
      );
    });

    test('2 秒 + 没画面 → 不算播完（DV 片那次是 10s→12s 也是这一类）', () {
      expect(
        PlaybackCompletion.isRealEnd(
          position: const Duration(seconds: 2),
          sawVideo: noVideo,
        ),
        isFalse,
      );
    });

    test('1 秒但确实出过画面 → 放行（真的是个短视频）', () {
      // 反向对照：证明这条护栏**不是**无脑按位置拦。
      expect(
        PlaybackCompletion.isRealEnd(
          position: const Duration(seconds: 1),
          sawVideo: sawVideo,
        ),
        isTrue,
      );
    });

    test('位置还是 0 时，就算出过画面也不算播完', () {
      // 一秒都没放就报 EOF 是最典型的开流失败。
      expect(
        PlaybackCompletion.isRealEnd(
          position: Duration.zero,
          sawVideo: sawVideo,
        ),
        isFalse,
      );
      expect(
        PlaybackCompletion.isRealEnd(
          position: Duration.zero,
          sawVideo: noVideo,
        ),
        isFalse,
      );
    });

    test('2.9 秒 + 有画面 → 放行（还没到 3 秒的门槛，靠画面救回来）', () {
      expect(
        PlaybackCompletion.isRealEnd(
          position: const Duration(milliseconds: 2900),
          sawVideo: sawVideo,
        ),
        isTrue,
      );
    });
  });

  group('describe：被拦下时要能一眼看出原因', () {
    test('三个量都在文案里', () {
      // 下次报「怎么不自动连播了」，第一件要确认的就是「当时位置多少、
      // 有没有画面、时长多少」—— 少任何一个都没法判断是护栏误伤还是流坏了。
      final text = PlaybackCompletion.describe(
        position: const Duration(seconds: 1),
        duration: const Duration(seconds: 2740),
        sawVideo: false,
      );
      expect(text, contains('1s'));
      expect(text, contains('2740s'));
      expect(text, contains('没有画面'));
    });

    test('出过画面时文案要如实说', () {
      final text = PlaybackCompletion.describe(
        position: const Duration(seconds: 1),
        duration: const Duration(seconds: 5),
        sawVideo: true,
      );
      expect(text, contains('出过画面'));
    });
  });

  group('转码档的「可疑阈值」必须高于护栏阈值', () {
    // 这两个数字一旦贴到一起（或反过来），2026-10-04 那个坑就会原样复现：
    //
    // 实测的故障现场是「位置 3~7 秒 + mpv 报过视频尺寸」。护栏按它的规则
    // **放行**（确实像一段真播完的短片）—— 于是挂在护栏里的诊断一次都不跑，
    // `media.m3u8` 里到底写了什么从头到尾没人看过。
    //
    // 所以这里断言的是**两个阈值的关系**，不是某一个具体数值。
    test('suspiciousHlsPosition 大于 minPlayed，故障现场才落得进诊断', () {
      expect(
        PlaybackCompletion.suspiciousHlsPosition >
            PlaybackCompletion.minPlayed,
        isTrue,
      );
    });

    test('实测的 7 秒故障现场确实落在可疑区间内', () {
      const worstCase = Duration(seconds: 7);
      expect(worstCase < PlaybackCompletion.suspiciousHlsPosition, isTrue);
    });
  });
}
