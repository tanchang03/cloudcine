import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/adapters/cloud_drive_adapter.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/entities/scan_policy.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:cloudcine/domain/services/scan_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「边扫边出」回归。
///
/// 原来的行为：作品行只在**遍历全部结束之后**由阶段二创建。大库要遍历
/// 几千个目录、跑几十分钟，这期间 `media_works` 恒为 0，媒体库页面读的
/// 正是这张表 —— 于是用户看到的是「媒体库还是空的，点『扫描』…」，
/// 与「明明已经在扫了」完全相反。2026-09-30 真机实测确认了这个现象。
///
/// 现在改为：每落一批媒体项，就把这一批涉及到的分组建成作品行。
void main() {
  /// 根目录 3 个子目录，其中一个目录里放两集（用来验证同组归并）。
  Map<String, List<DriveEntry>> buildTree() => {
        '0': const [
          DriveEntry(id: 'd1', name: '剧甲', isDirectory: true),
          DriveEntry(id: 'd2', name: '剧乙', isDirectory: true),
          DriveEntry(id: 'd3', name: '电影丙', isDirectory: true),
        ],
        'd1': const [
          DriveEntry(
            id: 'f1',
            name: '剧甲.S01E01.1080p.mkv',
            isDirectory: false,
            sizeBytes: 1000,
          ),
          DriveEntry(
            id: 'f2',
            name: '剧甲.S01E02.1080p.mkv',
            isDirectory: false,
            sizeBytes: 2000,
          ),
        ],
        'd2': const [
          DriveEntry(
            id: 'f3',
            name: '剧乙.S01E01.1080p.mkv',
            isDirectory: false,
            sizeBytes: 3000,
          ),
        ],
        'd3': const [
          DriveEntry(
            id: 'f4',
            name: '电影丙.2024.2160p.mp4',
            isDirectory: false,
            sizeBytes: 4000,
          ),
        ],
      };

  ScanService buildService(
    MediaRepository library, {
    void Function(String dirId)? onList,
    Map<String, List<DriveEntry>>? tree,
  }) =>
      ScanService(
        registry: AdapterRegistry([
          _FakeDrive(tree ?? buildTree(), onList: onList),
        ]),
        library: library,
        policy: const ScanPolicy(
          // ⚠️ 必须显式关掉：`ScanPolicy.audioOnly` 默认 `true`（继承自音频
          // 项目），开着的话视频一条都不会入库，而且**不报任何错**。
          audioOnly: false,
          // 测试里不需要对网盘限速。
          minRequestInterval: Duration.zero,
        ),
      );

  test('遍历还没结束，媒体库里就已经有作品了', () async {
    final repo = InMemoryMediaRepository();
    final service = buildService(repo);

    /// 每次进度回调时「队列里还剩多少个目录」+「此刻已有多少作品」。
    final midWalk = <({int pending, int works})>[];

    await service.scan(
      DriveProvider.quark,
      resume: false,
      pruneStale: false,
      scrape: false,
      onProgress: (p) {
        midWalk.add((pending: p.cursor.pendingDirs.length, works: repo.works.length));
      },
    );

    // 关键断言：存在「还有目录没扫完、但作品已经建出来了」的时刻。
    final createdMidWalk = midWalk.where((s) => s.pending > 0 && s.works > 0);
    expect(
      createdMidWalk,
      isNotEmpty,
      reason: '作品必须在遍历结束前就出现，否则媒体库在扫描期间一直是空的',
    );

    expect(repo.works, isNotEmpty);
    expect(repo.items.length, 4, reason: '四个视频都该入库');
  });

  test('每个目录边界都刷一次作品，不是攒到最后', () async {
    final repo = _RecordingRepo();
    final service = buildService(repo);

    await service.scan(
      DriveProvider.quark,
      resume: false,
      pruneStale: false,
      scrape: false,
    );

    // 三个有视频的目录 → 至少三次作品落库。
    expect(
      repo.events.where((e) => e == 'works').length,
      greaterThanOrEqualTo(3),
    );

    // 事件序列里必须出现「先落作品、后面还在继续落媒体项」，
    // 也就是作品落库发生在遍历中途，而不是最后一次性补上。
    expect(
      repo.events.indexOf('works'),
      lessThan(repo.events.lastIndexOf('items')),
      reason: '作品落库必须早于遍历结束',
    );
  });

  test('同一目录下的两集归到同一个作品，计数是累加后的值', () async {
    final repo = InMemoryMediaRepository();
    final service = buildService(repo);

    await service.scan(
      DriveProvider.quark,
      resume: false,
      pruneStale: false,
      scrape: false,
    );

    final works = repo.works.values.toList();
    expect(works.length, 3, reason: '剧甲 / 剧乙 / 电影丙 三组');
    expect(
      works.map((w) => w.itemCount).reduce((a, b) => a + b),
      4,
      reason: '每组的文件数要加起来等于 4',
    );
    expect(
      works.where((w) => w.itemCount == 2),
      isNotEmpty,
      reason: '剧甲那一组应当有 2 集',
    );
  });

  test('作品不是空壳：有标题、有体积、有类型', () async {
    final repo = InMemoryMediaRepository();
    final service = buildService(repo);

    await service.scan(
      DriveProvider.quark,
      resume: false,
      pruneStale: false,
      scrape: false,
    );

    for (final w in repo.works.values) {
      expect(w.title, isNotEmpty, reason: '标题空的话海报墙上是一格空白');
      expect(w.key, isNotEmpty);
      expect(w.totalBytes, greaterThan(0));
      expect(w.itemCount, greaterThan(0));
    }
  });

  test('中途取消：已经发现的作品仍然留在库里', () async {
    final repo = InMemoryMediaRepository();
    final cancel = ScanCancellation();

    // 列到第二个子目录时取消，模拟用户扫到一半点了「停止」。
    final service = buildService(
      repo,
      onList: (dirId) {
        if (dirId == 'd1') cancel.cancel();
      },
    );

    final outcome = await service.scan(
      DriveProvider.quark,
      resume: false,
      pruneStale: false,
      scrape: false,
      cancel: cancel,
    );

    expect(outcome.wasCancelled, isTrue);
    expect(
      repo.works,
      isNotEmpty,
      reason: '取消不该把已经发现的作品丢掉 —— 那正是「边扫边看」的价值',
    );
  });

  /// 封面锚点（夸克人脸框 → 竖版裁切用）从条目一路带到作品上。
  ///
  /// 这一段是**遍历期的取种逻辑**，`FaceAnchor` 的单测覆盖不到它：
  /// 单测只能证明「给定一个框能算出锚点」，证明不了「这个锚点会跟着
  /// 正确的那张缩略图存进作品行」。
  group('封面人物锚点：地址与锚点必须成对', () {
    const thumbA = 'https://drive-pc.quark.cn/a.webp';
    const thumbB = 'https://drive-pc.quark.cn/b.webp';

    /// 一个目录、若干集，方便按顺序验证「第一条有图的说了算」。
    Map<String, List<DriveEntry>> seriesTree(List<DriveEntry> episodes) => {
          '0': const [
            DriveEntry(id: 'd1', name: '剧甲', isDirectory: true),
          ],
          'd1': episodes,
        };

    DriveEntry episode(
      String id,
      String name, {
      String? thumb,
      double? faceX,
    }) =>
        DriveEntry(
          id: id,
          name: name,
          isDirectory: false,
          sizeBytes: 1000,
          thumbnailUrl: thumb,
          faceAnchorX: faceX,
        );

    Future<MediaWork> scanOne(
      List<DriveEntry> episodes,
    ) async {
      final repo = InMemoryMediaRepository();
      await buildService(repo, tree: seriesTree(episodes)).scan(
        DriveProvider.quark,
        resume: false,
        pruneStale: false,
        scrape: false,
      );
      return repo.works.values.single;
    }

    test('条目带人脸框 → 作品同时拿到缩略图地址和锚点', () async {
      final work = await scanOne([
        episode('f1', '剧甲.S01E01.1080p.mkv', thumb: thumbA, faceX: 0.42),
      ]);

      expect(work.posterUrl, thumbA);
      expect(
        work.posterFaceX,
        0.42,
        reason: '没有这一条，封面就永远退回「画面正中」裁切 —— '
            '双人对谈镜头会正好裁在两个人中间的空隙上。',
      );
    });

    test('条目没人脸框 → 锚点是 null，地址照常', () async {
      // 夸克的人脸框覆盖率实测 93%，所以这是常态而不是异常。
      final work = await scanOne([
        episode('f1', '剧甲.S01E01.1080p.mkv', thumb: thumbA),
      ]);

      expect(work.posterUrl, thumbA);
      expect(work.posterFaceX, isNull);
    });

    test('第一条有图没人脸、第二条有人脸 → 不许把两集的拼在一起', () async {
      // 这是「地址和锚点必须一次写完」那个坑的回归测试。
      // 写成两次 `??=`（先补地址、再补锚点）的话，这里会得到
      // 「第一集的图 + 第二集的人脸位置」—— 一张图和它的人脸位置
      // 来自不同的剧集，封面会裁到一个莫名其妙的角落，而且不报任何错。
      final work = await scanOne([
        episode('f1', '剧甲.S01E01.1080p.mkv', thumb: thumbA),
        episode('f2', '剧甲.S01E02.1080p.mkv', thumb: thumbB, faceX: 0.72),
      ]);

      expect(work.posterUrl, thumbA, reason: '第一条有图的说了算');
      expect(
        work.posterFaceX,
        isNull,
        reason: '第一集没人脸框，就该退回画面正中；'
            '绝不能借用第二集的人脸位置来裁第一集的图。',
      );
    });

    test('第一条什么都没有 → 用第二条的地址和锚点（仍然是成对的）', () async {
      final work = await scanOne([
        episode('f1', '剧甲.S01E01.1080p.mkv', faceX: 0.9),
        episode('f2', '剧甲.S01E02.1080p.mkv', thumb: thumbB, faceX: 0.2),
      ]);

      expect(work.posterUrl, thumbB);
      expect(work.posterFaceX, 0.2);
    });

    test('媒体项自己也带着锚点（后续单集列表要用）', () async {
      final repo = InMemoryMediaRepository();
      await buildService(
        repo,
        tree: seriesTree([
          episode('f1', '剧甲.S01E01.1080p.mkv', thumb: thumbA, faceX: 0.42),
        ]),
      ).scan(
        DriveProvider.quark,
        resume: false,
        pruneStale: false,
        scrape: false,
      );

      final item = repo.items.values.single;
      expect(item.faceAnchorX, 0.42);
      expect(
        item.thumbUrl,
        thumbA,
        reason: '锚点说的是 thumbUrl 那张图 —— 谁提供缩略图，谁就提供锚点。',
      );
    });
  });
}

/// 记录「媒体项落库」与「作品落库」的先后顺序，用来证明作品是边扫边建的。
///
/// 继承内存库而不是手写一整套假实现：只需要覆写两个方法，
/// 其余查询能力直接复用，断言也就能用 [InMemoryMediaRepository.works]。
class _RecordingRepo extends InMemoryMediaRepository {
  final List<String> events = [];

  @override
  Future<void> upsertItems(List<MediaItem> items, {DateTime? now}) async {
    events.add('items');
    return super.upsertItems(items, now: now);
  }

  @override
  Future<void> upsertWorks(
    List<MediaWork> works, {
    DateTime? now,
    bool overrideManual = false,
  }) async {
    events.add('works');
    return super.upsertWorks(works, now: now, overrideManual: overrideManual);
  }
}

/// 内存里的假网盘：`目录 id → 条目`，一页列完，不做分页。
class _FakeDrive extends CloudDriveAdapter {
  _FakeDrive(this.tree, {this.onList});

  final Map<String, List<DriveEntry>> tree;

  /// 每次列目录时回调，测试用它来制造「扫到一半」的时刻。
  final void Function(String dirId)? onList;

  @override
  DriveProvider get provider => DriveProvider.quark;

  @override
  Capabilities get capabilities =>
      const Capabilities(provider: DriveProvider.quark);

  @override
  String get rootId => '0';

  @override
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  }) async {
    onList?.call(dirId);
    return DrivePage(entries: tree[dirId] ?? const <DriveEntry>[]);
  }

  @override
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) async =>
      const <DriveEntry>[];

  @override
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId}) =>
      throw UnimplementedError('扫描不取流');

  @override
  Future<CloudAccount?> restoreSession() async => null;

  @override
  Future<CloudAccount> authorize(AuthCredential credential) =>
      throw UnimplementedError('扫描不授权');

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> dispose() async {}
}
