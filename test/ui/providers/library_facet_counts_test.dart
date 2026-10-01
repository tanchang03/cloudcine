import 'dart:convert';

import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 筛选面板角标与**分类回填**的先后顺序。
///
/// ## 为什么值得单独一个文件
///
/// 角标是按 `category` 收窄算出来的，而老库里那一列还是空串（v3 之前入库的
/// 行）。`workListProvider` 会先等回填再查列表，如果两个计数 provider 不等，
/// 就会出现「列表已经按回填后的分类筛好了，面板上的数字却还是按回填前的
/// 分类算的」—— 两者对不上，而用户完全看不出为什么。
///
/// 这条依赖很反直觉（「数年代为什么会依赖分类？」），所以写个测试钉住，
/// 免得下一轮有人觉得那个 `await` 是多余的顺手删掉。
void main() {
  final now = DateTime(2026, 10, 1);

  late AppDatabase db;
  late DriftMediaRepository repo;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    repo = DriftMediaRepository(db);
    container = ProviderContainer(
      overrides: [mediaRepositoryProvider.overrideWithValue(repo)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 写一行 **v3 之前** 的作品：`category` 是空串（还没判定过）。
  Future<void> seedLegacy({
    required String key,
    required String kind,
    required String title,
    int? year,
    List<String> genres = const [],
  }) async {
    await db.into(db.mediaWorks).insert(
          MediaWorksCompanion.insert(
            key: key,
            provider: DriveProvider.quark.id,
            kind: kind,
            title: title,
            year: Value(year),
            genres: Value(jsonEncode(genres)),
            source: 'online',
            updatedAt: now,
          ),
        );
  }

  test('老库的空分类先回填，面板角标才按回填后的分类统计', () async {
    // 空分类 + TMDB 类型是「动画」→ 回填后应该变成「动漫」。
    await seedLegacy(
      key: 'legacy',
      kind: 'episode',
      title: '某动画',
      year: 2021,
      genres: const ['动画'],
    );

    // 用户在分类栏里点了「动漫」。
    container.read(libraryFilterProvider.notifier).setCategory(MediaCategory.anime);

    final counts = await container.read(decadeCountsProvider.future);

    expect(
      counts,
      {2020: 1},
      reason: '不等回填的话，这一行还带着空串分类，而「动漫」那一档的条件是 '
          '`category = "anime"` —— 统计结果是空表。用户看到的是「动漫栏里'
          '明明有一部 2021 年的片子，筛选面板里却没有 2020 年代」。',
    );
  });

  test('角标等于「点了之后的条数」—— 这条不变量在回填场景下也成立', () async {
    await seedLegacy(
      key: 'legacy',
      kind: 'episode',
      title: '某动画',
      year: 2021,
      genres: const ['动画'],
    );
    container.read(libraryFilterProvider.notifier).setCategory(MediaCategory.anime);

    final counts = await container.read(decadeCountsProvider.future);
    final genres = await container.read(genreCountsProvider.future);

    // 这两条断言不是凑数的：下面的循环**空表时一次都不执行**，
    // 所以少了它们，provider 一旦漏掉回填（角标全空），这条不变量
    // 会以「零次比较」的方式通过 —— 正是它要防的那种失败。
    expect(counts, isNotEmpty, reason: '年代角标空了，下面的循环等于没跑');
    expect(genres, isNotEmpty, reason: '类型角标空了，下面的循环等于没跑');

    // 列表侧走的是同一个仓储，但 `workListProvider` 已经等过回填了 ——
    // 这里显式等一次，复刻真实调用顺序。
    await container.read(categoryBackfillProvider.future);

    for (final entry in counts.entries) {
      final hit = await repo.listWorks(
        category: MediaCategory.anime,
        decades: {entry.key},
      );
      expect(hit, hasLength(entry.value), reason: '${entry.key} 年代');
    }
    for (final entry in genres.entries) {
      final hit = await repo.listWorks(
        category: MediaCategory.anime,
        genres: {entry.key},
      );
      expect(hit, hasLength(entry.value), reason: entry.key);
    }
  });

  test('没选分类时（「全部」）不需要回填也数得对', () async {
    await seedLegacy(key: 'a', kind: 'movie', title: '甲', year: 1995);
    await seedLegacy(key: 'b', kind: 'movie', title: '乙', year: 2023);

    expect(await container.read(decadeCountsProvider.future), {1990: 1, 2020: 1});
  });
}
