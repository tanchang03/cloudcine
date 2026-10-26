import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/diary_eligibility.dart';
import 'package:cloudcine/domain/services/playback_progress.dart';
import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem item({
  required String fileId,
  MediaKind kind = MediaKind.episode,
  int? durationMs,
  int? maxMs,
  int? playedAtSec,
  bool sample = false,
}) =>
    MediaItem(
      provider: DriveProvider.quark,
      fileId: fileId,
      name: '$fileId.mkv',
      dirId: 'd',
      dirPath: '/',
      groupKey: 'g',
      kind: kind,
      durationMs: durationMs,
      isSampleOrExtra: sample,
      firstSeenAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

ProgressEntry prog({int? maxMs, int? playedAtSec}) => ProgressEntry(
      maxMs: maxMs,
      playedAtSec: playedAtSec,
      updatedAtSec: 1,
    );

MediaWork work({required MediaKind kind, String title = '漫长的季节'}) => MediaWork(
      key: 'quark|${kind.name}|$title',
      provider: DriveProvider.quark,
      kind: kind,
      title: title,
      updatedAt: DateTime(2026),
    );

/// 进度表的 key 是 `MediaItem.id`（带 provider 前缀），不是裸 `fileId`。
/// 见 `DiaryEligibility.evaluate` 的 `progressByFileId` 约定。
String pid(String fileId) => '${DriveProvider.quark.id}:$fileId';

void main() {
  group('电影 / 单文件口径', () {
    test('没看够 80% → 不记入', () {
      final w = work(kind: MediaKind.movie);
      final items = [item(fileId: 'f1', durationMs: 7_200_000, maxMs: 5_700_000)];
      final snap = DiaryEligibility.evaluate(
        work: w,
        items: items,
        progressByFileId: {'f1': prog(maxMs: 5_700_000)},
      );
      expect(snap, isNull);
    });

    test('恰好 80% → 记入（冻结为 1/1）', () {
      final w = work(kind: MediaKind.movie);
      final items = [item(fileId: 'f1', durationMs: 7_200_000, maxMs: 5_760_000)];
      final snap = DiaryEligibility.evaluate(
        work: w,
        items: items,
        progressByFileId: {'f1': prog(maxMs: 5_760_000, playedAtSec: 100)},
      );
      expect(snap, isNotNull);
      expect(snap!.episodeTotal, 1);
      expect(snap.episodeWatched, 1);
      expect(snap.completionRatio, 1.0);
      expect(snap.kind, 'movie');
      expect(snap.lastWatchedSec, 100);
      expect(snap.reliable, isTrue);
    });

    test('多版本电影取「看得最远」那一版算占比', () {
      final w = work(kind: MediaKind.movie, title: '流浪地球2');
      final items = [
        item(fileId: '1080p', durationMs: 7_200_000, maxMs: 3_000_000),
        item(fileId: '2160p', durationMs: 7_200_000, maxMs: 6_000_000),
      ];
      final snap = DiaryEligibility.evaluate(
        work: w,
        items: items,
        progressByFileId: {
          pid('1080p'): prog(maxMs: 3_000_000),
          '2160p': prog(maxMs: 6_000_000),
        },
      );
      expect(snap, isNotNull);
      expect(snap!.maxPositionMs, 6_000_000);
    });

    test('所有版本都拿不到时长 → 判不了，不记入', () {
      final w = work(kind: MediaKind.movie);
      final items = [item(fileId: 'f1', durationMs: null)];
      final snap = DiaryEligibility.evaluate(
        work: w, items: items, progressByFileId: const {});
      expect(snap, isNull);
    });
  });

  group('剧集 / 多文件口径（集数 ≥ 80%）', () {
    test('8/10 看完 → 记入', () {
      final w = work(kind: MediaKind.episode);
      final items = List.generate(
        10,
        (i) => item(
          fileId: 'e$i',
          durationMs: 2_700_000, // 45 分钟
          maxMs: i < 8 ? 2_580_000 : 1_000_000, // 前 8 集看完（≥43min），后 2 集只看了 1min
        ),
      );
      final progMap = {
        for (var i = 0; i < 10; i++)
          'e$i': prog(maxMs: i < 8 ? 2_580_000 : 1_000_000)
      };
      final snap =
          DiaryEligibility.evaluate(work: w, items: items, progressByFileId: progMap);
      expect(snap, isNotNull);
      expect(snap!.episodeTotal, 10);
      expect(snap.episodeWatched, 8);
      expect(snap.completionRatio, closeTo(0.8, 1e-9));
      expect(snap.kind, 'episode');
    });

    test('7/10 看完 → 不记入', () {
      final w = work(kind: MediaKind.episode);
      final items = List.generate(
        10,
        (i) => item(
          fileId: 'e$i',
          durationMs: 2_700_000,
          maxMs: i < 7 ? 2_580_000 : 1_000_000,
        ),
      );
      final progMap = {
        for (var i = 0; i < 10; i++)
          'e$i': prog(maxMs: i < 7 ? 2_580_000 : 1_000_000)
      };
      final snap =
          DiaryEligibility.evaluate(work: w, items: items, progressByFileId: progMap);
      expect(snap, isNull);
    });

    test('花絮/预告不进分母', () {
      final w = work(kind: MediaKind.episode);
      // 8 集正片都看完 + 2 个花絮没看 → 应判 8/8 = 100%
      final eps = List.generate(
        8,
        (i) => item(fileId: 'e$i', durationMs: 2_700_000, maxMs: 2_580_000),
      );
      final extras = [
        item(fileId: 'sp1', durationMs: 2_700_000, maxMs: 0, sample: true),
        item(fileId: 'sp2', durationMs: 2_700_000, maxMs: 0, sample: true),
      ];
      final progMap = {
        for (var i = 0; i < 8; i++) 'e$i': prog(maxMs: 2_580_000)
      };
      final snap = DiaryEligibility.evaluate(
        work: w, items: [...eps, ...extras], progressByFileId: progMap);
      expect(snap, isNotNull);
      expect(snap!.episodeTotal, 8);
      expect(snap.episodeWatched, 8);
    });
  });

  group('单文件 tv：退化成电影口径（95.6%）', () {
    test('1 集只看了 85%（低于 95.6%）→ 整部不记入', () {
      final w = work(kind: MediaKind.episode); // 只有 1 个文件
      final items = [item(fileId: 'e0', durationMs: 2_700_000, maxMs: 2_295_000)];
      final snap = DiaryEligibility.evaluate(
        work: w,
        items: items,
        progressByFileId: {'e0': prog(maxMs: 2_295_000)},
      );
      expect(snap, isNull);
    });

    test('1 集看完了（≥95.6%）→ 记入', () {
      final w = work(kind: MediaKind.episode);
      final items = [item(fileId: 'e0', durationMs: 2_700_000, maxMs: 2_580_000)];
      final snap = DiaryEligibility.evaluate(
        work: w,
        items: items,
        progressByFileId: {'e0': prog(maxMs: 2_580_000)},
      );
      expect(snap, isNotNull);
    });
  });

  group('时长未知的处理', () {
    test('未知时长计入分母、不计入分子', () {
      final w = work(kind: MediaKind.episode);
      final items = [
        item(fileId: 'e0', durationMs: 2_700_000, maxMs: 2_580_000), // 看完
        item(fileId: 'e1', durationMs: null), // 未知时长，算 1 集但永远完不成
        item(fileId: 'e2', durationMs: null),
      ];
      final progMap = {'e0': prog(maxMs: 2_580_000)};
      final snap = DiaryEligibility.evaluate(
        work: w, items: items, progressByFileId: progMap);
      // 1/3 = 33% < 80% → 不记入
      expect(snap, isNull);
    });

    test('未知时长占多数（>20%）→ 记入但标不可靠', () {
      final w = work(kind: MediaKind.episode);
      final items = [
        for (var i = 0; i < 8; i++)
          item(fileId: 'e$i', durationMs: 2_700_000, maxMs: 2_580_000),
        item(fileId: 'x1', durationMs: null),
        item(fileId: 'x2', durationMs: null),
        item(fileId: 'x3', durationMs: null),
      ];
      final progMap = {
        for (var i = 0; i < 8; i++) 'e$i': prog(maxMs: 2_580_000)
      };
      final snap = DiaryEligibility.evaluate(
        work: w, items: items, progressByFileId: progMap);
      expect(snap, isNotNull);
      expect(snap!.episodeTotal, 11);
      expect(snap.episodeWatched, 8);
      expect(snap.reliable, isFalse);
    });
  });

  group('isItemFinished 复用 PlaybackResume', () {
    test('45 分钟剧看到 43 分钟 → 看完', () {
      expect(
        DiaryEligibility.isItemFinished(
          item(fileId: 'e', durationMs: 2_700_000),
          prog(maxMs: 2_580_000),
        ),
        isTrue,
      );
    });
    test('45 分钟剧只看到 40 分钟 → 没看完', () {
      expect(
        DiaryEligibility.isItemFinished(
          item(fileId: 'e', durationMs: 2_700_000),
          prog(maxMs: 2_400_000),
        ),
        isFalse,
      );
    });
    test('时长未知 → 永远判没看完', () {
      expect(
        DiaryEligibility.isItemFinished(
          item(fileId: 'e', durationMs: null),
          prog(maxMs: 999_999_999),
        ),
        isFalse,
      );
    });
  });

  group('空输入', () {
    test('没有任何文件 → 不记入', () {
      final snap = DiaryEligibility.evaluate(
        work: work(kind: MediaKind.episode),
        items: const [],
        progressByFileId: const {},
      );
      expect(snap, isNull);
    });
    test('只有花絮 → 不记入', () {
      final w = work(kind: MediaKind.episode);
      final items = [item(fileId: 'sp', sample: true, maxMs: 0)];
      final snap = DiaryEligibility.evaluate(
        work: w, items: items, progressByFileId: const {});
      expect(snap, isNull);
    });
  });
}
