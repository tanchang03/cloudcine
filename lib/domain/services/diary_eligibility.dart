/// 「这部作品够不够格、自动记入观影日记」的纯判定。
///
/// ## 为什么是纯函数
///
/// 与 `PlaybackCompletion` / `PlaybackResume` 同一条理由：这类规则最容易被
/// 「顺手加一个 IO / 读一次钟」毁掉可测性，而它恰恰是用户最会质疑的地方
/// （「为什么这部没记入」「为什么那部记进去了」）。它不读时钟、不碰存储、
/// 不发请求，所以可以直接单元测试。
///
/// ## 两个口径（见设计文档 §3）
///
/// | 形态 | 判定 | 分母 |
/// |---|---|---|
/// | 电影 / 单文件作品 | `maxPositionMs / durationMs ≥ movieThreshold` | 该文件自己的时长 |
/// | 剧集 / 多文件作品（≥2 个文件） | `看完的集数 / 库里已有的集数 ≥ seriesThreshold` | 库里已有的**非花絮**文件数 |
///
/// 单集「看完」复用 `PlaybackResume.isFinished`（95.6% 那套），不是 80% ——
/// 否则会出现「详情页某集没打勾，整部剧却记入了」这种让用户以为判错的场面
/// （详见设计文档 §3.2）。
library;

import '../entities/media_item.dart';
import '../entities/media_work.dart';
import '../../core/utils/filename_parser.dart';
import 'playback_progress.dart';
import 'playback_resume.dart';

/// 记入那一刻要**冻结**进日记的全部快照数据。
///
/// 由 [DiaryEligibility.evaluate] 在记入瞬间算出，之后不再回查媒体库 ——
/// 用户清理索引库 / 删掉文件，都不该改写「历史上某天这部剧被看完了」这个事实。
class DiarySnapshot {
  const DiarySnapshot({
    required this.provider,
    required this.workKey,
    required this.title,
    required this.kind,
    required this.episodeTotal,
    required this.episodeWatched,
    required this.completionRatio,
    required this.durationMs,
    required this.maxPositionMs,
    required this.lastWatchedSec,
    required this.sourceItemIds,
    this.originalTitle,
    this.year,
    this.category,
    this.genres = const <String>[],
    this.posterUrl,
    this.posterFile,
    this.posterFaceX,
    /// 完成度是否可靠。库里过半文件拿不到时长时标 `false`（见 §3.5），
    /// 仍可记入，但 UI 要打一个问号。
    this.reliable = true,
  });

  final String provider;
  final String workKey;
  final String title;
  final String? originalTitle;
  final int? year;

  /// `MediaKind.name`（`movie` / `episode` / `unknown`）。
  final String kind;

  final String? category;
  final List<String> genres;
  final String? posterUrl;
  final String? posterFile;
  final double? posterFaceX;

  /// 记入时**冻结**的集数（剧集口径的分母分子来源）。
  final int episodeTotal;
  final int episodeWatched;

  /// `episodeWatched / episodeTotal`，冗余存一份便于排序展示。
  final double completionRatio;

  /// 电影口径的两个数；剧集也存（按集汇总），便于将来换口径重算。
  final int durationMs;
  final int maxPositionMs;

  /// 最后一次播放（Unix 秒），取所有文件里最大的 `playedAtSec`。
  final int lastWatchedSec;

  /// 记入时这部作品下**非花絮**的文件 id 列表，仅用于「资源还在就跳过去重看」。
  final List<String> sourceItemIds;

  final bool reliable;
}

/// 「够不够格记入」的判定器。
abstract final class DiaryEligibility {
  const DiaryEligibility._();

  /// 剧集：集数完成率阈值。
  static const double seriesThreshold = 0.80;

  /// 电影：单片完播率阈值。
  static const double movieThreshold = 0.80;

  /// 时长未知文件占比超过这个就标「完成度不可靠」（见 §3.5）。
  static const double unreliableUnknownRatio = 0.20;

  /// 单集「看完」复用播放器的既有定义（95.6% 规则）。
  ///
  /// 时长未知 → 判不了，按「没看完」处理（与 `PlaybackResume.isFinished` 一致）。
  static bool isItemFinished(MediaItem item, ProgressEntry? progress) {
    final durationMs = item.durationMs;
    if (durationMs == null || durationMs <= 0) return false;
    final posMs = progress?.maxMs ?? 0;
    return PlaybackResume.isFinished(
      Duration(milliseconds: posMs),
      Duration(milliseconds: durationMs),
    );
  }

  /// 这部作品够不够格记入。
  ///
  /// 返回 `null` = 不达标（或根本没有可判内容）；非 `null` = 达标，携带冻结快照。
  ///
  /// [progressByFileId] 是「`MediaItem.id` → 播放进度」的查表（[MediaItem.id]
  /// 是带 provider 前缀的稳定主键）。进度存在独立进度通道里，不挂在 `MediaItem`
  /// 上；这里取的是 [MediaRepository.progressSnapshot] 的 `.items`，它的 key 就是
  /// `item.id`（`'provider:fid'`），所以内部一律用 `item.id` 查，不能用
  /// `item.fileId`（那是裸 fid，和 `progressSnapshot` 的 key 对不上 —— 2026-10-26
  /// 上线后「捕种 0」的事故就是这里错配导致的）。没有就传空表，等价于「全都没看过」。
  static DiarySnapshot? evaluate({
    required MediaWork work,
    required List<MediaItem> items,
    required Map<String, ProgressEntry> progressByFileId,
  }) {
    // 只算「正片」文件，花絮/预告不进分母（与 `media_items.isSampleOrExtra` 一致）。
    final files = items.where((i) => !i.isSampleOrExtra).toList();
    if (files.isEmpty) return null;

    final isSeries = work.kind == MediaKind.episode && files.length >= 2;

    if (isSeries) {
      return _evaluateSeries(work: work, files: files, progress: progressByFileId);
    }
    return _evaluateMovie(work: work, files: files, progress: progressByFileId);
  }

  /// 剧集口径：看完的集数 / 库里已有的集数。
  static DiarySnapshot? _evaluateSeries({
    required MediaWork work,
    required List<MediaItem> files,
    required Map<String, ProgressEntry> progress,
  }) {
    var total = 0;
    var watched = 0;
    var unknownDuration = 0;
    var aggDuration = 0; // 所有正片时长之和（电影口径对照用）
    var aggWatched = 0; // 所有正片「实际看过的位置」之和
    var lastWatched = 0;
    final ids = <String>[];

    for (final item in files) {
      total++;
      ids.add(item.fileId);
      final dur = item.durationMs;
      final prog = progress[item.id];
      final pos = prog?.maxMs ?? 0;
      final played = prog?.playedAtSec ?? 0;
      if (played > lastWatched) lastWatched = played;
      if (dur == null || dur <= 0) {
        // 时长未知：计入分母，但不计入分子（拿不到证据说它看完）。
        unknownDuration++;
        continue;
      }
      aggDuration += dur;
      aggWatched += pos > dur ? dur : pos;
      if (isItemFinished(item, prog)) watched++;
    }

    if (total == 0) return null;
    final ratio = watched / total;
    // 完成度是否可靠：时长未知占比超阈值就标不可靠，但仍记入。
    final reliable = unknownDuration / total <= unreliableUnknownRatio;
    if (ratio < seriesThreshold) return null;

    return DiarySnapshot(
      provider: work.provider.name,
      workKey: work.key,
      title: work.title,
      kind: work.kind.name,
      originalTitle: work.originalTitle,
      year: work.year,
      category: work.category.name,
      genres: List<String>.from(work.genres),
      posterUrl: work.posterUrl,
      posterFile: work.posterFile,
      posterFaceX: work.posterFaceX,
      episodeTotal: total,
      episodeWatched: watched,
      completionRatio: ratio,
      durationMs: aggDuration,
      maxPositionMs: aggWatched,
      lastWatchedSec: lastWatched,
      sourceItemIds: ids,
      reliable: reliable,
    );
  }

  /// 电影 / 单文件口径：可观看版本里最远那次播放 / 时长 ≥ movieThreshold。
  static DiarySnapshot? _evaluateMovie({
    required MediaWork work,
    required List<MediaItem> files,
    required Map<String, ProgressEntry> progress,
  }) {
    var bestRatio = 0.0;
    var bestPos = 0;
    var bestDur = 0;
    var lastWatched = 0;
    final ids = <String>[];

    for (final item in files) {
      ids.add(item.fileId);
      final dur = item.durationMs ?? 0;
      final prog = progress[item.id];
      final pos = prog?.maxMs ?? 0;
      final played = prog?.playedAtSec ?? 0;
      if (played > lastWatched) lastWatched = played;
      if (dur <= 0) continue; // 拿不到分母，这一版无法判定
      final r = pos / dur;
      if (r > bestRatio) {
        bestRatio = r;
        bestPos = pos;
        bestDur = dur;
      }
    }

    if (bestDur <= 0) return null; // 所有版本都拿不到时长，判不了
    if (bestRatio < movieThreshold) return null;

    return DiarySnapshot(
      provider: work.provider.name,
      workKey: work.key,
      title: work.title,
      kind: work.kind.name,
      originalTitle: work.originalTitle,
      year: work.year,
      category: work.category.name,
      genres: List<String>.from(work.genres),
      posterUrl: work.posterUrl,
      posterFile: work.posterFile,
      posterFaceX: work.posterFaceX,
      // 单文件作品「集数」视角下就是 1/1，便于 UI 统一展示。
      episodeTotal: 1,
      episodeWatched: 1,
      completionRatio: 1.0,
      durationMs: bestDur,
      maxPositionMs: bestPos,
      lastWatchedSec: lastWatched,
      sourceItemIds: ids,
      reliable: true,
    );
  }
}
