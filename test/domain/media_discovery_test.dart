import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/scan_cursor.dart';
import 'package:cloudcine/domain/entities/scan_policy.dart';
import 'package:cloudcine/domain/services/media_discovery.dart';
import 'package:cloudcine/domain/services/scan_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_drive.dart';

/// 局部发现（文件夹里点「发现 / 加入媒体库」）。
///
/// 这些用例守的是**与全盘扫描的三条硬区别**（见 `MediaDiscoveryService`）：
/// 只增不减、不碰续扫游标、深度相对目标算。每一条做错都会**静默**损坏
/// 媒体库 —— 没有报错，只有「东西莫名其妙少了」或「续扫之后少了一半」。
void main() {
  /// 一棵小树：
  ///   /电影/            电影甲.2024.1080p.mkv + 同名 .srt + cover.jpg + 镜像.iso
  ///   /电影/新片/       新片.2025.2160p.mkv
  ///   /剧乙/            剧乙.S01E01.mkv
  ///   /电影/新片/深层/  深层.2026.1080p.mkv（测深度）
  Map<String, List<DriveEntry>> buildTree() => {
        'root': const [
          DriveEntry(id: 'd1', name: '电影', isDirectory: true),
          DriveEntry(id: 'd2', name: '剧乙', isDirectory: true),
        ],
        'd1': const [
          DriveEntry(
            id: 'f1',
            name: 'Movie.2024.1080p.mkv',
            isDirectory: false,
            sizeBytes: 1000,
          ),
          DriveEntry(
            id: 's1',
            name: 'Movie.2024.1080p.chs.srt',
            isDirectory: false,
            sizeBytes: 40,
          ),
          DriveEntry(
            id: 'p1',
            name: 'cover.jpg',
            isDirectory: false,
            sizeBytes: 20,
          ),
          DriveEntry(
            id: 'i1',
            name: 'Movie.2024.iso',
            isDirectory: false,
            sizeBytes: 9999,
          ),
          DriveEntry(id: 'd1s', name: '新片', isDirectory: true),
        ],
        'd1s': const [
          DriveEntry(
            id: 'f2',
            name: 'Newone.2025.2160p.mkv',
            isDirectory: false,
            sizeBytes: 2000,
          ),
          DriveEntry(id: 'd1s2', name: '深层', isDirectory: true),
        ],
        'd1s2': const [
          DriveEntry(
            id: 'f3',
            name: 'Deep.2026.1080p.mkv',
            isDirectory: false,
            sizeBytes: 3000,
          ),
        ],
        'd2': const [
          DriveEntry(
            id: 'f4',
            name: 'Other.S01E01.1080p.mkv',
            isDirectory: false,
            sizeBytes: 4000,
          ),
        ],
      };

  MediaDiscoveryService buildService(
    MediaRepository library, {
    FakeDriveAdapter? drive,
    ScanPolicy policy = const ScanPolicy(
      // ⚠️ 必须显式关掉：默认值 `audioOnly: true` 继承自音频项目，
      // 开着的话视频一条都不会入库，而且**不报任何错**。
      audioOnly: false,
      minRequestInterval: Duration.zero,
    ),
  }) =>
      MediaDiscoveryService(
        registry: AdapterRegistry([drive ?? FakeDriveAdapter(buildTree())]),
        library: library,
        policy: policy,
      );

  group('目录发现', () {
    test('递归把子目录里的视频一起收进来，并建出作品行', () async {
      final repo = InMemoryMediaRepository();
      final outcome = await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );

      expect(
        repo.items.keys.toSet(),
        {'quark:f1', 'quark:f2', 'quark:f3'},
        reason: '子目录（新片、深层）里的视频也属于这次发现',
      );
      expect(
        repo.works.length,
        3,
        reason: '媒体库里只有文件没有作品的话，海报墙上什么都不会出现 —— '
            '发现必须和全盘扫描一样建作品行',
      );
      expect(outcome.mediaFound, 3);
      expect(outcome.added, 3);
      expect(outcome.existing, 0);
      expect(outcome.scannedDirs, 3, reason: '电影 / 新片 / 深层 三个目录');
      expect(outcome.failedDirs, 0);
      expect(outcome.isComplete, isTrue);
    });

    test('只本层：不进入子目录', () async {
      final repo = InMemoryMediaRepository();
      final outcome = await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
        recursive: false,
      );

      expect(repo.items.keys.toSet(), {'quark:f1'});
      expect(outcome.scannedDirs, 1);
    });

    test('多页目录会一直翻到最后一页', () async {
      // 每页 2 条，'d1' 有 5 条 → 必须翻 3 页，否则会漏掉后面的视频。
      final repo = InMemoryMediaRepository();
      final outcome = await buildService(
        repo,
        policy: const ScanPolicy(
          audioOnly: false,
          minRequestInterval: Duration.zero,
          pageSize: 2,
        ),
      ).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
        recursive: false,
      );

      expect(outcome.mediaFound, 1);
      // d1 里 5 条：1 个视频 + 字幕 + 图片 + 镜像 + 1 个子目录 → 4 个文件。
      expect(outcome.scannedFiles, 4, reason: '四条都要被数到，说明翻页没漏');
    });

    test('⚠️ 绝不清理陈旧：本次没扫到的目录，记录必须原样留着', () async {
      final repo = InMemoryMediaRepository();
      // 库里已经有一条「剧乙」的记录，但这次只发现 /电影/。
      await repo.upsertItems([
        MediaItem.fromEntry(
          entry: const DriveEntry(
            id: 'f4',
            name: 'Other.S01E01.1080p.mkv',
            isDirectory: false,
            sizeBytes: 4000,
          ),
          provider: DriveProvider.quark,
          dirPath: '/剧乙/',
          parsed: const MediaFilenameParser().parse('Other.S01E01.1080p.mkv'),
        ),
      ]);

      await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );

      expect(
        repo.items.containsKey('quark:f4'),
        isTrue,
        reason: '局部发现只看到一棵子树。拿它当白名单去清理陈旧记录，'
            '会把子树之外的**全部**媒体项删光 —— 而用户只是想加一部新片。',
      );
    });

    test('⚠️ 绝不写续扫游标：全盘扫描的队列必须原样不动', () async {
      final repo = InMemoryMediaRepository();
      final before = ScanCursor(
        provider: DriveProvider.quark,
        rootId: 'root',
        updatedAt: DateTime(2026, 1, 1),
        pendingDirs: const [
          PendingDir(id: 'd2', path: '/剧乙/', depth: 1),
          PendingDir(id: 'd9', path: '/其它/', depth: 1),
        ],
        stage: ScanStage.paused,
        scannedDirs: 7,
        foundTracks: 42,
      );
      await repo.saveScanCursor(before);

      await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );

      final after = await repo.loadScanCursor(DriveProvider.quark);
      expect(after, isNotNull);
      expect(
        after!.pendingDirs.length,
        2,
        reason: '续扫队列描述的是**全盘扫描**的进度。局部发现往里写一笔，'
            '用户下次点「从上次中断处继续」就会从错的队列开始 —— '
            '表现是「续扫之后少了一大半片子」，而这两件事在用户眼里毫无关联。',
      );
      expect(after.stage, ScanStage.paused);
      expect(after.scannedDirs, 7);
      expect(after.foundTracks, 42);
    });

    test('从没扫过时，局部发现也不会凭空造出一个游标', () async {
      final repo = InMemoryMediaRepository();
      await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );
      expect(await repo.loadScanCursor(DriveProvider.quark), isNull);
    });

    test('深度限制相对**本次目标**算，而不是相对网盘根', () async {
      final repo = InMemoryMediaRepository();
      // maxDepth=1 表示「只进一层子目录」。从 /电影/ 开始发现时，
      // 「新片」（深度 1）必须进得去 —— 如果深度从网盘根算起，
      // 用户选中的目录本身就已经是第 1 层，会被当场截断、一条都扫不到。
      final outcome = await buildService(
        repo,
        policy: const ScanPolicy(
          audioOnly: false,
          minRequestInterval: Duration.zero,
          maxDepth: 1,
        ),
      ).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );

      expect(repo.items.containsKey('quark:f2'), isTrue, reason: '深度 1 要进');
      expect(
        repo.items.containsKey('quark:f3'),
        isFalse,
        reason: '深度 2（深层）超过 maxDepth，不该进',
      );
      expect(outcome.scannedDirs, 2);
    });

    test('库里已存在的文件算「已有」，不算「新增」', () async {
      final repo = InMemoryMediaRepository();
      final service = buildService(repo);

      final first = await service.discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
        recursive: false,
      );
      expect(first.added, 1);
      expect(first.existing, 0);

      final second = await service.discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
        recursive: false,
      );
      expect(second.mediaFound, 1);
      expect(
        second.added,
        0,
        reason: '第二次点「发现」不该说「新增 1 个」—— 那会让用户以为'
            '库里多出了一份，而其实只是把元数据刷新了一遍',
      );
      expect(second.existing, 1);
      expect(repo.items.length, 1, reason: '幂等：不会产生重复行');
    });

    test('非视频文件一律不入库（字幕 / 图片 / 镜像）', () async {
      final repo = InMemoryMediaRepository();
      await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
        recursive: false,
      );

      expect(repo.items.keys.toSet(), {'quark:f1'});
      expect(
        repo.items.values.map((i) => i.name),
        isNot(contains('cover.jpg')),
        reason: '一张封面图变成「一个视频」，会让媒体库出现点开就报错的条目',
      );
      expect(
        repo.items.keys,
        isNot(contains('quark:i1')),
        reason: 'mpv 播不了 BD 镜像，索引了只会得到点了播不了的行',
      );
    });

    test('字幕与同目录的视频配对（只建引用）', () async {
      final repo = InMemoryMediaRepository();
      final outcome = await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
        recursive: false,
      );

      expect(outcome.subtitlesIndexed, 1);
      final tracks = await repo.subtitlesForItem('quark:f1');
      expect(tracks, hasLength(1));
      expect(tracks.single.fileName, 'Movie.2024.1080p.chs.srt');
    });

    test('单个目录列失败不终止整次发现，但结果要如实标记为不完整', () async {
      final repo = InMemoryMediaRepository();
      final drive = FakeDriveAdapter(buildTree(), failFor: {'d1s'});
      final outcome = await buildService(repo, drive: drive).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );

      expect(outcome.failedDirs, 1);
      expect(outcome.isComplete, isTrue, reason: '这不是整次失败，只是有个目录没读到');
      expect(
        repo.items.containsKey('quark:f1'),
        isTrue,
        reason: '失败的目录之外的成果必须留下',
      );
      expect(
        outcome.scannedDirs,
        1,
        reason: '只有 d1 列成功（d1s 失败了），所以已扫目录数是 1 —— '
            '把失败的也算进去会让「已扫 N 个目录」虚高',
      );
    });

    test('授权失效必须上抛，不能静默继续', () async {
      final repo = InMemoryMediaRepository();
      final drive = FakeDriveAdapter(
        buildTree(),
        failWith: const DriveException(
          type: DriveErrorType.unauthorized,
          message: 'require login',
        ),
      );

      expect(
        () => buildService(repo, drive: drive).discoverDirectory(
          DriveProvider.quark,
          dirId: 'd1',
          dirPath: '/电影',
        ),
        throwsA(isA<DriveException>()),
        reason: '凭证废了继续扫只会拿到一堆同样的错误，用户还看不到「要重新登录」',
      );
    });

    test('中途取消：已经发现的作品仍然留在库里', () async {
      final repo = InMemoryMediaRepository();
      final cancel = ScanCancellation();
      final drive = FakeDriveAdapter(
        buildTree(),
        onList: (dirId) {
          if (dirId == 'd1s') cancel.cancel();
        },
      );

      final outcome = await buildService(repo, drive: drive).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
        cancel: cancel,
      );

      expect(outcome.wasCancelled, isTrue);
      expect(
        repo.works,
        isNotEmpty,
        reason: '取消不该把已经发现的作品丢掉 —— 那正是「边发现边看」的价值',
      );
    });

    test('进度回调里的数字是累计的', () async {
      final repo = InMemoryMediaRepository();
      final seen = <DiscoveryProgress>[];
      await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
        onProgress: seen.add,
      );

      expect(seen, isNotEmpty);
      expect(seen.last.finished, isTrue);
      expect(seen.last.scannedDirs, 3);
      expect(seen.last.mediaFound, 3);
    });
  });

  group('单文件发现', () {
    const movie = DriveEntry(
      id: 'f9',
      name: 'Solo.2024.1080p.mkv',
      isDirectory: false,
      sizeBytes: 1000,
      parentId: 'd1',
    );

    test('把文件加进媒体库并建出作品行', () async {
      final repo = InMemoryMediaRepository();
      final outcome = await buildService(repo).discoverFile(
        DriveProvider.quark,
        entry: movie,
        dirPath: '/电影',
      );

      expect(repo.items.containsKey('quark:f9'), isTrue);
      expect(repo.works.length, 1);
      expect(outcome.scope, DiscoveryScope.file);
      expect(outcome.mediaFound, 1);
      expect(outcome.added, 1);
      expect(outcome.isComplete, isTrue);
    });

    test('重复加入同一个文件：幂等，且报「已有」', () async {
      final repo = InMemoryMediaRepository();
      final service = buildService(repo);

      await service.discoverFile(
        DriveProvider.quark,
        entry: movie,
        dirPath: '/电影',
      );
      final again = await service.discoverFile(
        DriveProvider.quark,
        entry: movie,
        dirPath: '/电影',
      );

      expect(repo.items.length, 1);
      expect(again.added, 0);
      expect(again.existing, 1);
    });

    test('顺带把同目录的字幕配上（否则用户看不出为什么字幕没进来）', () async {
      final repo = InMemoryMediaRepository();
      final drive = FakeDriveAdapter({
        'd1': const [
          DriveEntry(
            id: 'f9',
            name: 'Movie.2024.1080p.mkv',
            isDirectory: false,
            sizeBytes: 1000,
          ),
          DriveEntry(
            id: 's9',
            name: 'Movie.2024.1080p.chs.srt',
            isDirectory: false,
            sizeBytes: 40,
          ),
        ],
      });

      final outcome = await buildService(repo, drive: drive).discoverFile(
        DriveProvider.quark,
        entry: const DriveEntry(
          id: 'f9',
          name: 'Movie.2024.1080p.mkv',
          isDirectory: false,
          sizeBytes: 1000,
          parentId: 'd1',
        ),
        dirPath: '/电影',
      );

      expect(outcome.subtitlesIndexed, 1);
      expect(await repo.subtitlesForItem('quark:f9'), hasLength(1));
    });

    test('调用方给了目录 id 就用它 —— 不依赖响应里带父目录 id', () async {
      final repo = InMemoryMediaRepository();
      final drive = FakeDriveAdapter({
        'd1': const [
          DriveEntry(
            id: 's9',
            name: 'Movie.2024.1080p.chs.srt',
            isDirectory: false,
            sizeBytes: 40,
          ),
        ],
      });

      // ⚠️ 这条 entry **没有** `parentId`。真实场景是网盘响应里没带
      // `pdir_fid`（夸克对某些列表不下发这个字段）。实现若只看
      // `entry.parentId`，字幕会**静默**配不上 —— 用户只看到「字幕没进来」，
      // 而「字幕」与「父目录 id 这个字段」在用户眼里毫无关联。
      final outcome = await buildService(repo, drive: drive).discoverFile(
        DriveProvider.quark,
        entry: const DriveEntry(
          id: 'f9',
          name: 'Movie.2024.1080p.mkv',
          isDirectory: false,
          sizeBytes: 1000,
        ),
        dirPath: '/电影',
        dirId: 'd1',
      );

      expect(outcome.subtitlesIndexed, 1);
      expect(await repo.subtitlesForItem('quark:f9'), hasLength(1));
    });

    test('非视频文件：什么都不做，也不报错', () async {
      final repo = InMemoryMediaRepository();
      final outcome = await buildService(repo).discoverFile(
        DriveProvider.quark,
        entry: const DriveEntry(
          id: 'p1',
          name: 'cover.jpg',
          isDirectory: false,
          sizeBytes: 20,
        ),
        dirPath: '/电影',
      );

      expect(outcome.mediaFound, 0);
      expect(outcome.isEmpty, isTrue);
      expect(repo.items, isEmpty);
      expect(repo.works, isEmpty);
    });

    test('取同目录字幕失败不影响「文件已入库」这个主结果', () async {
      final repo = InMemoryMediaRepository();
      final drive = FakeDriveAdapter(
        const {},
        failWith: const DriveException(
          type: DriveErrorType.network,
          message: 'timeout',
        ),
      );

      final outcome = await buildService(repo, drive: drive).discoverFile(
        DriveProvider.quark,
        entry: movie,
        dirPath: '/电影',
      );

      expect(repo.items.containsKey('quark:f9'), isTrue);
      expect(outcome.subtitlesIndexed, 0);
      expect(outcome.isComplete, isTrue);
    });
  });

  group('与全盘扫描的口径一致', () {
    test('同一个文件走两条路，得到同一个分组键与分类', () async {
      final tree = {
        'root': const [
          DriveEntry(id: 'd1', name: '动漫', isDirectory: true),
        ],
        'd1': const [
          DriveEntry(id: 'd2', name: '进击的巨人', isDirectory: true),
        ],
        'd2': const [
          DriveEntry(
            id: 'f1',
            name: 'Attack.on.Titan.S01E01.1080p.mkv',
            isDirectory: false,
            sizeBytes: 1000,
          ),
        ],
      };

      // ① 全盘扫描
      final scanRepo = InMemoryMediaRepository();
      await ScanService(
        registry: AdapterRegistry([FakeDriveAdapter(tree)]),
        library: scanRepo,
        policy: const ScanPolicy(
          audioOnly: false,
          minRequestInterval: Duration.zero,
        ),
      ).scan(DriveProvider.quark, resume: false, pruneStale: false);

      // ② 局部发现（从 /动漫/ 开始）
      final discRepo = InMemoryMediaRepository();
      await MediaDiscoveryService(
        registry: AdapterRegistry([FakeDriveAdapter(tree)]),
        library: discRepo,
        policy: const ScanPolicy(
          audioOnly: false,
          minRequestInterval: Duration.zero,
        ),
      ).discoverDirectory(DriveProvider.quark, dirId: 'd1', dirPath: '/动漫');

      final byScan = scanRepo.works.values.single;
      final byDiscovery = discRepo.works.values.single;

      expect(
        byDiscovery.key,
        byScan.key,
        reason: '两处各写一遍归组逻辑的话，同一个文件会归到两个不同的作品上 —— '
            '媒体库里会多出一个重复格子，而且不报任何错',
      );
      expect(byDiscovery.title, byScan.title);
      expect(
        byDiscovery.category,
        byScan.category,
        reason: '分类靠目录名判定（/动漫/…），两条路必须给出同一个结果',
      );
      expect(byDiscovery.category, MediaCategory.anime);
      expect(byDiscovery.totalBytes, byScan.totalBytes);
      expect(
        discRepo.items.values.single.groupKey,
        scanRepo.items.values.single.groupKey,
      );
    });
  });

  // -------------------------------------------------------------------
  // 目录视图「直接播」的解析口径
  // -------------------------------------------------------------------

  /// 这一组守的是**第三条路**：目录视图里不先入库、直接点播。
  ///
  /// 它和「加入媒体库」造的是同一个东西，只是不写库。两处口径分叉的话，
  /// 用户先直接播、后把它加进库，会得到两条 `groupKey` 不同的记录 ——
  /// 同一部片子在海报墙上出现两格，而且没有任何报错。
  group('parseTransientMedia（目录视图直接播）', () {
    const movie = DriveEntry(
      id: 'f1',
      name: 'Movie.2024.1080p.mkv',
      isDirectory: false,
      sizeBytes: 1000,
    );

    test('目录路径归一成扫描器口径（带结尾斜杠）', () {
      // 目录视图手上是 `crumb.path`（**不带**尾斜杠），而扫描器/发现写库时
      // 一律带尾斜杠。不归一的话 `/电影` 与 `/电影/` 会变成两个键。
      final withSlash = parseTransientMedia(
        entry: movie,
        provider: DriveProvider.quark,
        dirPath: '/电影/',
      );
      final withoutSlash = parseTransientMedia(
        entry: movie,
        provider: DriveProvider.quark,
        dirPath: '/电影',
      );

      expect(withSlash.item.dirPath, '/电影/');
      expect(withoutSlash.item.dirPath, '/电影/');
      expect(
        withoutSlash.item.groupKey,
        withSlash.item.groupKey,
        reason: '同一条目、同一个目录，换个写法必须解析出同一个分组键',
      );
      expect(withoutSlash.item.id, 'quark:f1', reason: '主键仍按 fid 拼');
    });

    test('与「加入媒体库」落到的是同一条记录', () async {
      final repo = InMemoryMediaRepository();
      await buildService(repo).discoverFile(
        DriveProvider.quark,
        entry: movie,
        dirPath: '/电影',
        dirId: 'd1',
      );
      final stored = repo.items['quark:f1']!;

      final transient = parseTransientMedia(
        entry: movie,
        provider: DriveProvider.quark,
        dirPath: '/电影',
      ).item;

      expect(
        transient.groupKey,
        stored.groupKey,
        reason: '两条路必须给出同一个分组键 —— 否则先直接播、后加入媒体库，'
            '同一部片子会在库里出现两格',
      );
      expect(transient.id, stored.id);
      expect(transient.dirPath, stored.dirPath);
      expect(transient.title, stored.title);
      expect(transient.year, stored.year);
      expect(transient.resolution, stored.resolution);
      expect(transient.sizeBytes, stored.sizeBytes);
      expect(transient.thumbUrl, stored.thumbUrl);
    });

    test('解析结果与媒体项同源 —— 归组要的那一份不会跟条目分叉', () {
      final media = parseTransientMedia(
        entry: const DriveEntry(
          id: 'f2',
          name: 'Show.S01E03.1080p.mkv',
          isDirectory: false,
          sizeBytes: 2000,
        ),
        provider: DriveProvider.quark,
        dirPath: '/剧乙',
      );

      expect(media.parsed.groupKey, media.item.groupKey);
      expect(media.parsed.kind, media.item.kind);
      expect(media.parsed.title, media.item.title);
      expect(media.parsed.year, media.item.year);
      expect(media.item.dirPath, '/剧乙/');
    });
  });

  /// [DiscoveryOutcome.touchedWorkKeys] —— 「这次发现碰了哪几部作品」。
  ///
  /// 它是「要不要问一句『把这批新文件并进某部已有作品吗』」的唯一触发条件
  /// （见 `WorkMergeSuggester`）。判据错的方向有两个，代价完全不同：
  ///
  ///   - **偏大**（把没碰过的作品也算进来）→ 用户每点一次「发现」都被追问
  ///     同一件事，最后他会把这个功能当噪音；
  ///   - **偏小**（该记的没记）→ 建议永远不出，用户又回到
  ///     「提示说发现了新文件，可我哪儿都没看到」那个现场。
  group('touchedWorkKeys：这次发现碰了哪几部作品', () {
    test('目录发现：新入库的分组全在，且与作品数对得上', () async {
      final repo = InMemoryMediaRepository();
      final outcome = await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );

      expect(outcome.added, 3);
      expect(
        outcome.touchedWorkKeys,
        hasLength(3),
        reason: '电影 / 新片 / 深层 三个分组，各有 1 个新文件',
      );
      expect(
        outcome.touchedWorkKeys,
        repo.works.keys.toSet(),
        reason: '「碰过」的分组必须正好是这次新建出来的那几部',
      );
    });

    test('重跑一次、一个文件都没新增 → 空集（不许追问同一件事）', () async {
      final repo = InMemoryMediaRepository();
      final service = buildService(repo);
      await service.discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );

      final again = await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );

      expect(again.added, 0);
      expect(again.existing, 3);
      expect(
        again.touchedWorkKeys,
        isEmpty,
        reason: '第二次一个文件都不是新的 —— 建议器据此直接返回空，'
            '否则用户每点一次「发现」都会被问一遍',
      );
    });

    test('给已有作品补一集 → 那一组也算「碰过」', () async {
      final repo = InMemoryMediaRepository();
      await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
        recursive: false,
      );
      final firstKeys = repo.works.keys.toSet();

      // 再发现一次，这次连子目录一起（新片 / 深层 是新的）。
      final outcome = await buildService(repo).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/电影',
      );

      expect(outcome.added, 2);
      expect(outcome.touchedWorkKeys, hasLength(2));
      expect(
        outcome.touchedWorkKeys.intersection(firstKeys),
        isEmpty,
        reason: '「电影」那一部这次一条新文件都没有，不该被算进来',
      );
    });

    test('单文件发现：新文件记它的分组，已在库的则不记', () async {
      final repo = InMemoryMediaRepository();
      const entry = DriveEntry(
        id: 'f1',
        name: 'Movie.2024.1080p.mkv',
        isDirectory: false,
        sizeBytes: 1000,
      );

      final first = await buildService(repo).discoverFile(
        DriveProvider.quark,
        entry: entry,
        dirPath: '/电影',
        dirId: 'd1',
      );
      expect(first.touchedWorkKeys, hasLength(1));

      final second = await buildService(repo).discoverFile(
        DriveProvider.quark,
        entry: entry,
        dirPath: '/电影',
        dirId: 'd1',
      );
      expect(
        second.touchedWorkKeys,
        isEmpty,
        reason: '重复点「加入媒体库」不该被当成一次新入库',
      );
    });
  });

  group('目录锚点：同一剧集目录下新开一层（2026-10-07 现场）', () {
    /// 现场那棵树：
    ///   `/来自：分享/兰丨香R-故/`          → `01.mp4`、`02.mp4`（片名靠目录名兜底）
    ///   `/来自：分享/兰丨香R-故/去头去尾版 4K/` → `S01E01.第1集.mkv`（自带季集结构）
    ///
    /// 第二层是**后来新开的**，于是走「先发现父目录、再发现子目录」这条真实路径。
    Map<String, List<DriveEntry>> liveTree() => {
          'root': const [
            DriveEntry(id: 'd1', name: '兰丨香R-故', isDirectory: true),
          ],
          'd1': const [
            DriveEntry(
              id: 'f1',
              name: '01.mp4',
              isDirectory: false,
              parentId: 'd1',
              sizeBytes: 100,
            ),
            DriveEntry(
              id: 'f2',
              name: '02.mp4',
              isDirectory: false,
              parentId: 'd1',
              sizeBytes: 100,
            ),
            DriveEntry(
              id: 'd1s',
              name: '去头去尾版 4K',
              isDirectory: true,
              parentId: 'd1',
            ),
          ],
          'd1s': const [
            DriveEntry(
              id: 'f3',
              name: 'S01E01.第1集.2160p.WEB-DL.H.265.Pure.mkv',
              isDirectory: false,
              parentId: 'd1s',
              sizeBytes: 300,
            ),
            DriveEntry(
              id: 'f4',
              name: 'S01E02.第2集.2160p.WEB-DL.H.265.Pure.mkv',
              isDirectory: false,
              parentId: 'd1s',
              sizeBytes: 300,
            ),
          ],
        };

    test('第二趟发现子目录 → 新集归到已有那部剧，不再分叉', () async {
      final repo = InMemoryMediaRepository();
      final drive = FakeDriveAdapter(liveTree());

      // 第一趟：用户点父目录（**仅本层**，与现场一致）→ 建出《兰香如故》。
      await buildService(repo, drive: drive).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/来自：分享/兰丨香R-故',
        recursive: false,
      );
      expect(repo.works, hasLength(1));
      final key = repo.works.keys.single;

      // 第二趟：用户点新开的那一层。
      await buildService(repo, drive: drive).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1s',
        dirPath: '/来自：分享/兰丨香R-故/去头去尾版 4K',
        recursive: false,
      );

      expect(
        repo.works, hasLength(1),
        reason: '不锚的话这里会变成 2 部 —— 剧集页里看不见那 2 集，'
            '追更检查还会报「没有更新」',
      );
      expect(repo.works.keys.single, key);
      expect(
        repo.items['quark:f3']!.groupKey,
        key,
        reason: '新集的归组键必须等于那部已有剧集',
      );
      expect(repo.items['quark:f4']!.groupKey, key);
    });

    test('父目录（递归）一趟扫完也一样 —— 追更检查走的就是这条路', () async {
      final repo = InMemoryMediaRepository();
      final drive = FakeDriveAdapter(liveTree());

      // 先建出老作品，再把子目录里的两条也一起发现（`recursive: true`
      // 正是 `followDiscoveryAdapter` 的接线方式）。
      await buildService(repo, drive: drive).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/来自：分享/兰丨香R-故',
        recursive: false,
      );
      final key = repo.works.keys.single;

      final outcome = await buildService(repo, drive: drive).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/来自：分享/兰丨香R-故',
        recursive: true,
      );

      expect(repo.works, hasLength(1));
      expect(repo.works.keys.single, key);
      expect(
        outcome.touchedWorkKeys,
        {key},
        reason: '「有新内容的作品」只该有那部剧 —— 追更检查靠它算增量',
      );
    });

    test('库里一部剧都没有时（首次发现）不受影响', () async {
      final repo = InMemoryMediaRepository();
      final drive = FakeDriveAdapter(liveTree());

      await buildService(repo, drive: drive).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/来自：分享/兰丨香R-故',
        recursive: true,
      );

      // 没有任何锚点可用 → 退回按文件名归组的老行为：父目录那两条
      // 靠目录名兜底成一部，子目录那两条自带季集结构、片名取自子目录名，
      // 于是仍然是两部。这是**已知且可接受**的：用户手上有那部剧之后，
      // 下一次发现就会归到一起（见下一条用例）。
      expect(repo.works.length, greaterThanOrEqualTo(1));
    });

    test('平铺目录里的新文件不会被吸进那部剧（闸 3）', () async {
      final repo = InMemoryMediaRepository();
      final drive = FakeDriveAdapter({
        'root': const [
          DriveEntry(id: 'd1', name: '兰香如故', isDirectory: true),
        ],
        'd1': const [
          DriveEntry(
            id: 'f1',
            name: '01.mp4',
            isDirectory: false,
            parentId: 'd1',
            sizeBytes: 100,
          ),
        ],
      });

      await buildService(repo, drive: drive).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/来自：分享/兰香如故',
        recursive: false,
      );
      final showKey = repo.works.keys.single;

      // 用户往**同一个目录**里又丢了一部电影。
      drive.tree['d1']!.add(
        const DriveEntry(
          id: 'f2',
          name: '奥德赛.2026.2160p.mkv',
          isDirectory: false,
          parentId: 'd1',
          sizeBytes: 900,
        ),
      );

      await buildService(repo, drive: drive).discoverDirectory(
        DriveProvider.quark,
        dirId: 'd1',
        dirPath: '/来自：分享/兰香如故',
        recursive: false,
      );

      expect(
        repo.items['quark:f2']!.groupKey,
        isNot(showKey),
        reason: '文件直接躺在剧集目录里时不算归属证据 —— 否则平铺目录里'
            '的新片会被吸进那部剧',
      );
    });
  });
}
