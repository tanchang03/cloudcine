import 'package:cloudcine/domain/services/playback_resume.dart';
import 'package:flutter_test/flutter_test.dart';

/// 续播点的取舍规则。
///
/// 这几条都对应**用户看得见**的症状，而且都不抛异常、只在特定时刻显形：
///   - 规则太松 → 「看了三秒回来还卡在片头」；
///   - 规则太紧 → 「看完再点开，直接跳到大结局」；
///   - 时长未知时误判成「看完了」 → 用户的进度被**清掉**，不可恢复。
void main() {
  const shortClip = Duration(minutes: 45);
  const longMovie = Duration(hours: 3);

  group('finishedThreshold（「看完」的判定线）', () {
    test('短片用「两分钟」这条线', () {
      // 45 分钟的 2% 只有 54 秒，比两分钟还小 —— 取大的那个。
      expect(
        PlaybackResume.finishedThreshold(shortClip),
        shortClip - PlaybackResume.finishedTail,
      );
    });

    test('长片用「2%」这条线 —— 两分钟对三小时的电影太窄', () {
      // 三小时的片子里，最后两分钟很可能只是片尾曲；用 2%（3.6 分钟）
      // 才真的能判出「看完了」。
      expect(
        PlaybackResume.finishedThreshold(longMovie),
        longMovie - longMovie * PlaybackResume.finishedRatio,
      );
      // 三小时的 2% 是 3.6 分钟，比两分钟长 —— 尾巴越长，判定线越靠前，
      // 「看完了」才判得出来。所以这条阈值**小于** `总长 - 两分钟`。
      expect(
        PlaybackResume.finishedThreshold(longMovie)!,
        lessThan(longMovie - PlaybackResume.finishedTail),
      );
    });

    test('时长未知 → 判不了，返回 null（不是 0）', () {
      // 返回 0 的话「任何位置 >= 0」都成立，等于把整库都标成「看完了」。
      expect(PlaybackResume.finishedThreshold(Duration.zero), isNull);
      expect(PlaybackResume.finishedThreshold(const Duration(seconds: -5)),
          isNull);
    });

    test('片子比尾巴还短 → 判不了，而不是「一开就算看完」', () {
      // 3 秒的自检视频：2 分钟的尾巴比它还长，算出来的阈值是负数。
      expect(PlaybackResume.finishedThreshold(const Duration(seconds: 3)), isNull);
      expect(PlaybackResume.finishedThreshold(const Duration(minutes: 1)), isNull);
    });
  });

  group('isFinished', () {
    test('零位置不算看完 —— 那是「还没开始」', () {
      expect(PlaybackResume.isFinished(Duration.zero, shortClip), isFalse);
    });

    test('刚好到阈值就算看完（含边界）', () {
      final threshold = PlaybackResume.finishedThreshold(shortClip)!;
      expect(PlaybackResume.isFinished(threshold, shortClip), isTrue);
    });

    test('阈值之前不算', () {
      final threshold = PlaybackResume.finishedThreshold(shortClip)!;
      expect(
        PlaybackResume.isFinished(threshold - const Duration(seconds: 1), shortClip),
        isFalse,
      );
    });

    test('时长未知时一律不算看完', () {
      // 宁可多续一次（用户只是觉得「怎么没从头」），也别把进度清掉
      // （用户得自己拖回去，而且没有任何提示）。
      expect(
        PlaybackResume.isFinished(const Duration(minutes: 40), Duration.zero),
        isFalse,
      );
      expect(
        PlaybackResume.isFinished(const Duration(minutes: 40), const Duration(seconds: 3)),
        isFalse,
      );
    });
  });

  group('startFrom（真正从哪开始）', () {
    test('没存过 → 从头', () {
      expect(
        PlaybackResume.startFrom(stored: Duration.zero, total: shortClip),
        Duration.zero,
      );
    });

    test('只看了几秒 → 从头 —— 否则用户看到的是「卡在片头不动」', () {
      expect(
        PlaybackResume.startFrom(stored: const Duration(seconds: 3), total: shortClip),
        Duration.zero,
      );
    });

    test('刚好卡在「值得续」的门槛上 → 从头（含边界）', () {
      expect(
        PlaybackResume.startFrom(stored: PlaybackResume.minResume, total: shortClip),
        Duration.zero,
      );
    });

    test('看了一半 → 续上', () {
      expect(
        PlaybackResume.startFrom(stored: const Duration(minutes: 20), total: shortClip),
        const Duration(minutes: 20),
      );
    });

    test('看完了 → 从头重看', () {
      expect(
        PlaybackResume.startFrom(stored: const Duration(minutes: 44), total: shortClip),
        Duration.zero,
      );
    });

    test('时长未知但确实看过一段 → 照续', () {
      // 网盘没给时长、或还没解析出来时会走到这。此时「续」是对的默认：
      // 唯一能确定的信息就是「用户看到这儿了」。
      expect(
        PlaybackResume.startFrom(stored: const Duration(minutes: 20), total: null),
        const Duration(minutes: 20),
      );
      expect(
        PlaybackResume.startFrom(
          stored: const Duration(minutes: 20),
          total: Duration.zero,
        ),
        const Duration(minutes: 20),
      );
    });
  });
}
