import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:flutter_test/flutter_test.dart';

/// 来源筛选的**性能**回归测试。
///
/// ## 为什么单独成文件 + 带计时
///
/// 2026-10-26 真机日志暴露出一个 O(作品数 × 文件数) 的全扫描：勾选来源时
/// `listWorks` 主查询从 ~10ms 涨到 **49 秒**，`countWorksByProvider` 一次 13s+。
/// 根因是来源 / 搜索两类过滤依赖的相关子查询在 `media_items.group_key` 与
/// `media_works.merged_into` 上没有索引。
///
/// 修法是在 `AppDatabase.beforeOpen` 里幂等建索引（`idx_items_group_key_provider`
/// 落在 `media_items(group_key, provider)` 上）。本文件做三件事：
///
///   1. **索引存在性断言**：直接查 `sqlite_master`，索引没了立刻失败 ——
///      这是防止回归的最锋利一刀（有人删索引，测试马上红）。
///   2. **计时断言**：拟真规模（~2.5 万文件）下带索引的查询应当亚秒级；无索引
///      会几十秒，远超阈值。阈值留足安全边际（几秒），但足以把「全扫描档」
///      挡在门外 —— 那一档动辄超阈值几百倍。
///   3. **正确性断言**：同一部剧的文件同时来自夸克 + 百度（跨源）时，这部剧在
///      两个来源角标里**各算一次**（双算）；被折叠走的别名行不计入，但其文件
///      通过 `merged_into` 穿透归到目标名下 —— 这正是来源筛选必须穿透折叠的情形。
///
/// 不测 InMemory 实现：它本来就是线性遍历，没有索引概念，测它毫无意义。
void main() {
  late AppDatabase db;
  late DriftMediaRepository repo;
  final ts = DateTime(2026, 10, 1);

  setUp(() {
    db = AppDatabase.memory();
    repo = DriftMediaRepository(db);
  });
  tearDown(() => db.close());

  // 拟真规模：基础作品各 80 部、每部 150 个文件（一部剧的量级），
  // 再加 30 部「跨源」作品（同一 group_key 同时有夸克 + 百度文件），
  // 加 1 对「折叠」作品（别名被折进目标，文件挂在别名键下、 provider=百度）。
  // 合计约 2.5 万文件、~190 部可见作品。
  const baseCount = 80;
  const baseFiles = 150;
  const crossCount = 30;
  const crossFiles = 60; // 其中 30 夸克 + 30 百度
  const foldFiles = 40;

  Future<void> seed() async {
    final works = <MediaWork>[];
    final items = <MediaItem>[];

    for (var i = 0; i < baseCount; i++) {
      final provider = i.isEven ? DriveProvider.quark : DriveProvider.baidu;
      final key = 'base-$i';
      works.add(MediaWork(
        key: key,
        provider: provider,
        kind: MediaKind.episode,
        title: '基础作品$i',
        category: MediaCategory.series,
        year: 2020 + (i % 6),
        source: ScrapeSource.local,
        updatedAt: ts,
      ));
      for (var f = 0; f < baseFiles; f++) {
        items.add(MediaItem(
          provider: provider,
          fileId: '$key-f$f',
          name: '$key E$f.mkv',
          dirId: 'd',
          dirPath: '/',
          groupKey: key,
          kind: MediaKind.episode,
          firstSeenAt: ts,
          updatedAt: ts,
        ));
      }
    }

    // 跨源作品：1 行 work，但文件同时来自夸克 + 百度，全部挂在同一个
    // group_key 下。这是「同一部剧在两家网盘各一份、合成一行」的典型形状，
    // 正是来源筛选最该正确处理、也最容易算错的情形。
    for (var i = 0; i < crossCount; i++) {
      final key = 'cross-$i';
      works.add(MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '跨源作品$i',
        category: MediaCategory.series,
        year: 2021,
        source: ScrapeSource.local,
        updatedAt: ts,
      ));
      for (var f = 0; f < crossFiles; f++) {
        final p = f < crossFiles ~/ 2 ? DriveProvider.quark : DriveProvider.baidu;
        items.add(MediaItem(
          provider: p,
          fileId: '$key-f$f',
          name: '$key E$f.mkv',
          dirId: 'd',
          dirPath: '/',
          groupKey: key,
          kind: MediaKind.episode,
          firstSeenAt: ts,
          updatedAt: ts,
        ));
      }
    }

    // 折叠对：目标 `fold-target`（夸克文件），别名 `fold-alias`（百度文件、
    // mergedInto 指向目标）。归一不搬 media_items.group_key，所以别名的百度
    // 文件仍挂在 fold-alias 键下；来源筛选必须靠 merged_into 穿透把它们算进
    // fold-target 的百度计数里。
    works.add(MediaWork(
      key: 'fold-target',
      provider: DriveProvider.quark,
      kind: MediaKind.episode,
      title: '折叠目标',
      category: MediaCategory.series,
      year: 2022,
      source: ScrapeSource.local,
      updatedAt: ts,
    ));
    works.add(MediaWork(
      key: 'fold-alias',
      provider: DriveProvider.baidu,
      kind: MediaKind.episode,
      title: '折叠别名',
      category: MediaCategory.series,
      year: 2022,
      source: ScrapeSource.local,
      updatedAt: ts,
    ));
    for (var f = 0; f < foldFiles; f++) {
      items.add(MediaItem(
        provider: DriveProvider.quark,
        fileId: 'fold-target-f$f',
        name: 'fold-target E$f.mkv',
        dirId: 'd',
        dirPath: '/',
        groupKey: 'fold-target',
        kind: MediaKind.episode,
        firstSeenAt: ts,
        updatedAt: ts,
      ));
      items.add(MediaItem(
        provider: DriveProvider.baidu,
        fileId: 'fold-alias-f$f',
        name: 'fold-alias E$f.mkv',
        dirId: 'd',
        dirPath: '/',
        groupKey: 'fold-alias',
        kind: MediaKind.episode,
        firstSeenAt: ts,
        updatedAt: ts,
      ));
    }

    await repo.upsertWorks(works, now: ts);
    await repo.upsertItems(items);

    // 折叠关系：upsert 之后再改 merged_into，绕开 mergeWorkForUpsert 在
    // 「已存在行」时优先保留旧 mergedInto 的语义。测的是筛选逻辑，不在乎
    // 走哪条写入路径。
    await db.customStatement(
      "UPDATE media_works SET merged_into = 'fold-target' "
      "WHERE key = 'fold-alias'",
    );
  }

  test('来源筛选查询在拟真规模下是亚秒级（索引生效，非全扫描）', () async {
    await seed();

    // 1) 索引存在性：这是防回归最锋利的一刀。
    //    只断言 `idx_items_group_key_provider` —— `merged_into` 不建索引（小表
    //    不是瓶颈，且建了会锁死该列、挡住将来可能的 DROP 迁移）。
    final idxRows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND name = 'idx_items_group_key_provider'",
    ).get();
    final idxNames = idxRows.map((r) => r.read<String>('name')).toSet();
    expect(idxNames, contains('idx_items_group_key_provider'),
        reason: '缺失性能索引 idx_items_group_key_provider（来源筛选靠它）');

    Future<int> timeList(Set<DriveProvider>? providers) async {
      final sw = Stopwatch()..start();
      final works = await repo.listWorks(providers: providers, limit: 1000);
      // 触发实际读取，避免惰性求值把计时泡汤。
      expect(works, isList);
      return sw.elapsedMilliseconds;
    }

    final msQuark = await timeList({DriveProvider.quark});
    final msBaidu = await timeList({DriveProvider.baidu});
    final msBoth = await timeList({DriveProvider.quark, DriveProvider.baidu});

    final swCount = Stopwatch()..start();
    final counts = await repo.countWorksByProvider();
    final msCount = swCount.elapsedMilliseconds;

    // 拟真规模下，带索引应当是亚秒级；无索引会是几十秒。阈值留安全边际。
    const ceiling = 4000;
    expect(msQuark, lessThan(ceiling),
        reason: 'listWorks(夸克) 应远小于全扫描的几十秒，实测 $msQuark ms');
    expect(msBaidu, lessThan(ceiling),
        reason: 'listWorks(百度) 应远小于全扫描，实测 $msBaidu ms');
    expect(msBoth, lessThan(ceiling),
        reason: 'listWorks(两者) 应远小于全扫描，实测 $msBoth ms');
    expect(msCount, lessThan(ceiling),
        reason: 'countWorksByProvider 应远小于全扫描，实测 $msCount ms');

    // 2) 正确性：
    // 夸克 = 基础夸克(40) + 跨源(30) + 折叠目标(1, 自身夸克文件) = 71
    // 百度 = 基础百度(40) + 跨源(30) + 折叠目标(1, 穿透别名的百度文件) = 71
    // 折叠别名行本身（mergedInto 非空）不计入。
    expect(counts[DriveProvider.quark], 71,
        reason: '夸克：基础夸克40 + 跨源30 + 折叠目标1');
    expect(counts[DriveProvider.baidu], 71,
        reason: '百度：基础百度40 + 跨源30 + 折叠目标1(穿透别名)');
    expect(counts.containsKey(DriveProvider.aliyun), isFalse,
        reason: '阿里无文件，不应进角标表');

    // 列表口径与计数一致：单来源 71 部，两者都勾时（所有可见作品都有文件）191 部。
    final listQuark = await repo.listWorks(
        providers: {DriveProvider.quark}, limit: 1000);
    final listBaidu = await repo.listWorks(
        providers: {DriveProvider.baidu}, limit: 1000);
    final listBoth = await repo.listWorks(
        providers: {DriveProvider.quark, DriveProvider.baidu}, limit: 1000);
    expect(listQuark.length, 71, reason: 'listWorks(夸克) 应与角标一致');
    expect(listBaidu.length, 71, reason: 'listWorks(百度) 应与角标一致');
    expect(listBoth.length, 111,
        reason: 'listWorks(两者) = 可见作品总数（基础夸克40 + 基础百度40 + 跨源30 + 折叠目标1）');
  });
}
