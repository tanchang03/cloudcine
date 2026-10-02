import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/missing_media.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「网盘上这个文件没了」的判定与移除范围。
///
/// 这些规则全部**不可从报错里看出对错**：判错了不抛异常，只会表现为
/// 「断网一下就被问要不要删片」（误报）或者「删掉整部剧」（代价最大的
/// 那种错）。所以每一条断言旁边都写着它防的是哪一种后果。
void main() {
  final ts = DateTime(2026, 10, 2);

  MediaItem item({
    String fileId = 'f1',
    String name = '剧集.S01E07.mkv',
    String groupKey = 'show',
    MediaKind kind = MediaKind.episode,
    String? title = '剧集',
    int? episode,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: name,
        dirId: 'd1',
        dirPath: '/剧集/剧集/',
        groupKey: groupKey,
        kind: kind,
        title: title,
        episode: episode,
        firstSeenAt: ts,
        updatedAt: ts,
      );

  MediaWork work({
    String key = 'show',
    MediaKind kind = MediaKind.episode,
    String title = '剧集',
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: kind,
        title: title,
        category: switch (kind) {
          MediaKind.movie => MediaCategory.movie,
          MediaKind.episode => MediaCategory.series,
          MediaKind.unknown => MediaCategory.other,
        },
        updatedAt: ts,
      );

  group('isMissingFileError', () {
    test('只有 notFound 算「文件没了」', () {
      expect(
        isMissingFileError(
          const DriveException(
            type: DriveErrorType.notFound,
            message: 'file not exist',
          ),
        ),
        isTrue,
        reason: '服务端明确说没有这个 fid —— 这是唯一能支撑「它可能已被删除」'
            '这个推断的信号',
      );
    });

    test('登录失效 / 限流 / 断网都不算', () {
      for (final type in [
        DriveErrorType.unauthorized,
        DriveErrorType.rateLimited,
        DriveErrorType.network,
        DriveErrorType.urlExpired,
        DriveErrorType.fileTooLarge,
        DriveErrorType.permissionDenied,
      ]) {
        expect(
          isMissingFileError(DriveException(type: type, message: 'x')),
          isFalse,
          reason: '$type 属于「这次没取到，文件本身还在」。拿它去问用户要不要'
              '从媒体库移除是最糟的一类误报：他一点确认，一部好好的片子就没了',
        );
      }
    });

    test('非 DriveException 一律不算', () {
      expect(isMissingFileError(StateError('boom')), isFalse);
      expect(isMissingFileError(null), isFalse);
    });
  });

  group('MissingMediaPlan 的移除范围', () {
    test('只有一部作品的最后一个文件时不给「只删这一个」', () {
      final plan = MissingMediaPlan.of(
        item: item(kind: MediaKind.movie, title: '电影'),
        work: work(kind: MediaKind.movie, title: '电影'),
        fileCount: 1,
      );

      expect(plan.canRemoveSingle, isFalse,
          reason: '那时「只删这个文件」和「删整部」是同一件事 —— 给两个按钮'
              '等于逼用户猜它们的区别');
      expect(plan.wholeLabel, '移除《电影》');
    });

    test('一部电影有多个版本时给「只删这一个」', () {
      final plan = MissingMediaPlan.of(
        item: item(kind: MediaKind.movie, title: '电影'),
        work: work(kind: MediaKind.movie, title: '电影'),
        fileCount: 2,
      );

      expect(plan.canRemoveSingle, isTrue,
          reason: '1080p 版没了、4K 版还在是很常见的情形，'
              '逼用户连 4K 版一起删是白白丢东西');
      expect(plan.singleLabel, '只移除这个文件');
      expect(plan.wholeLabel, contains('这部电影'));
    });

    test('剧集给出「只移除这一集」，整部那个按钮要写明文件数', () {
      final plan = MissingMediaPlan.of(
        item: item(episode: 7),
        work: work(),
        fileCount: 24,
      );

      expect(plan.singleLabel, '只移除这一集');
      expect(plan.wholeLabel, '移除整部剧《剧集》（24 个文件）',
          reason: '删掉一整部是不可撤销的（要回来得重扫一次网盘），'
              '按钮上必须写清代价');
    });

    test('作品行缺失时退回文件自己解析出的片名', () {
      final plan = MissingMediaPlan.of(
        item: item(title: '解析出的片名'),
        work: null,
        fileCount: 3,
      );
      expect(plan.workTitle, '解析出的片名');
      expect(plan.kind, MediaKind.episode,
          reason: '作品行没了，kind 只能退回文件自己的 —— 它决定按钮写'
              '「这一集」还是「这个文件」');
    });

    test('文件数为 0 时兜成 1，而不是显示「共 0 个文件」', () {
      final plan = MissingMediaPlan.of(
        item: item(),
        work: work(),
        fileCount: 0,
      );
      expect(plan.fileCount, 1,
          reason: 'itemsForWork 理论上一定包含这一条自己，拿到 0 只可能是'
              '数据异常。按 0 走会给出「移除《X》（0 个文件）」并藏掉'
              '「只删这一个」—— 一个自相矛盾的面板');
    });

    test('结果提示区分两种范围', () {
      final plan = MissingMediaPlan.of(
        item: item(episode: 7),
        work: work(),
        fileCount: 24,
      );
      // 没标季号时 `displayTitle` 就是「片名 E07」（见 MediaItem 的规则）。
      expect(plan.removedMessage(MediaRemovalScope.singleItem),
          contains('剧集 E07'),
          reason: '只删一集时提示要说清删的是**哪一集** —— 用户据此确认'
              '自己删对了，而不是以为整部剧没了');
      expect(plan.removedMessage(MediaRemovalScope.wholeWork),
          contains('《剧集》'));
    });
  });
}
