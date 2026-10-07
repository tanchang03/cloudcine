import 'dart:io';
import 'dart:typed_data';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/progress_store.dart';
import 'package:cloudcine/data/db/progress_sync.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/playback_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// 静默同步的**合并方向**与**上传判据**。
///
/// 这个功能最不能出的错是「拿本机知道的那部分进度，把网盘上另一台设备的
/// 进度整个覆盖掉」—— 而它不报错、两边都显示同步成功。所以下面把
/// 「什么时候必须不传」单独测一遍。
void main() {
  late Directory dir;
  late String path;
  late InMemoryMediaRepository repo;
  late ProgressStore store;

  final now = DateTime(2026, 10, 7, 12);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('cloudcine_progress_sync');
    path = '${dir.path}${Platform.pathSeparator}${ProgressStore.fileName}';
    repo = InMemoryMediaRepository();
    store = ProgressStore(filePath: path, flushDelay: const Duration(hours: 1));
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  MediaItem item(String id) => MediaItem(
        provider: DriveProvider.quark,
        fileId: id,
        name: '$id.mkv',
        dirId: 'd1',
        dirPath: '/剧/Show/',
        groupKey: 'show',
        kind: MediaKind.episode,
        title: 'Show',
        season: 1,
        episode: 1,
        firstSeenAt: now,
        updatedAt: now,
      );

  /// 造一个带可控「网盘」的同步服务。
  ///
  /// [remote] 就是网盘上那个文件的字节；闭包里改它，模拟「传上去了」。
  ProgressSyncService makeService(
    Uint8List? Function() remote, {
    void Function(Uint8List bytes)? onUpload,
    Object? downloadError,
  }) =>
      ProgressSyncService(
        store: store,
        repository: repo,
        downloadRemote: () async {
          if (downloadError != null) throw downloadError;
          return remote();
        },
        uploadRemote: (bytes) async => onUpload?.call(bytes),
      );

  test('网盘上还没有进度文件 + 本地库已有进度 → 播种并上传', () async {
    await repo.upsertItems([item('e1')]);
    await repo.saveResumePosition('quark:e1', const Duration(minutes: 3));
    await repo.markPlayed('quark:e1', now);

    Uint8List? uploaded;
    final outcome = await makeService(
      () => null,
      onUpload: (b) => uploaded = b,
    ).syncSilently();

    expect(outcome.ok, isTrue);
    expect(outcome.seeded, greaterThan(0), reason: '老用户升级上来那批要靠播种');
    expect(outcome.uploaded, isTrue);
    expect(uploaded, isNotNull);
    final onDrive = ProgressBook.fromBytes(uploaded!);
    expect(onDrive['quark:e1']!.resumeMs, 3 * 60 * 1000);
  });

  test('网盘上另一台机器的进度被合进来，并回填进媒体项行', () async {
    await repo.upsertItems([item('e1'), item('e2')]);
    await repo.saveResumePosition('quark:e1', const Duration(minutes: 3));

    final remoteBook = ProgressBook({
      'quark:e2': ProgressEntry(
        resumeMs: 900_000,
        maxMs: 1_200_000,
        playedAtSec: 4000000000,
        updatedAtSec: 4000000000,
      ),
    });

    final outcome = await makeService(() => remoteBook.toBytes()).syncSilently();

    expect(outcome.ok, isTrue);
    expect(outcome.downloaded, isTrue);
    // e2 的进度被铺进了媒体项行 —— 二十多处 SQL 查询读的就是这三列。
    final resume = await repo.resumePositions(['quark:e2']);
    expect(resume['quark:e2'], const Duration(milliseconds: 900_000));
    final max = await repo.maxPositions(['quark:e2']);
    expect(max['quark:e2'], const Duration(milliseconds: 1_200_000));
    // e1 本地那份没有被抹掉。
    expect((await repo.resumePositions(['quark:e1']))['quark:e1'],
        const Duration(minutes: 3));
  });

  test('⛔ 下载失败时**绝不上传**（否则会覆盖掉另一台设备的进度）', () async {
    await repo.upsertItems([item('e1')]);
    await repo.saveResumePosition('quark:e1', const Duration(minutes: 3));

    var uploaded = false;
    final outcome = await makeService(
      () => null,
      onUpload: (_) => uploaded = true,
      downloadError: const SocketException('网络不通'),
    ).syncSilently();

    expect(uploaded, isFalse, reason: '读不到远程就传，等于用本地覆盖远程');
    expect(outcome.ok, isFalse);
    expect(outcome.message, contains('未上传'));
    // 但本地该做的两件事照做：进度已落盘、界面看到的仍然是最全的一份。
    expect(File(path).existsSync(), isTrue);
    expect((await repo.resumePositions(['quark:e1']))['quark:e1'],
        const Duration(minutes: 3));
  });

  test('两边内容一致 → **不传**（空同步不该在网盘上走一遍「先删后传」）', () async {
    await repo.upsertItems([item('e1')]);
    await repo.saveResumePosition('quark:e1', const Duration(minutes: 3));
    await repo.markPlayed('quark:e1', now);
    await store.load();
    await store.mergeFrom(await repo.progressSnapshot());
    await store.flush();

    final identical = store.book.toBytes();
    var uploaded = false;
    final outcome = await makeService(
      () => identical,
      onUpload: (_) => uploaded = true,
    ).syncSilently();

    expect(uploaded, isFalse);
    expect(outcome.ok, isTrue);
    expect(outcome.mergedIn, 0);
  });

  test('本地新看了一集、远程一无所知 → 必须上传（mergedIn 为 0 也要传）', () async {
    await repo.upsertItems([item('e1')]);
    await repo.saveResumePosition('quark:e1', const Duration(minutes: 5));
    await repo.markPlayed('quark:e1', now);

    // 远程是一份**空书**（有文件、但里面没有条目）。
    Uint8List? uploaded;
    final outcome = await makeService(
      () => ProgressBook().toBytes(),
      onUpload: (b) => uploaded = b,
    ).syncSilently();

    expect(outcome.mergedIn, 0, reason: '远程什么都没给');
    expect(outcome.uploaded, isTrue, reason: '「远程有没有给我」不等于「我要不要给远程」');
    expect(ProgressBook.fromBytes(uploaded!)['quark:e1'], isNotNull);
  });

  test('上传失败 → 本地不丢，返回失败（下一轮重试）', () async {
    await repo.upsertItems([item('e1')]);
    await repo.saveResumePosition('quark:e1', const Duration(minutes: 7));
    await repo.markPlayed('quark:e1', now);

    final outcome = await ProgressSyncService(
      store: store,
      repository: repo,
      downloadRemote: () async => null,
      uploadRemote: (_) async => throw const SocketException('上传挂了'),
    ).syncSilently();

    expect(outcome.ok, isFalse);
    expect(outcome.message, contains('上传失败'));
    expect((await repo.resumePositions(['quark:e1']))['quark:e1'],
        const Duration(minutes: 7));
  });

  test('进度同步**不动**库的「最后变更时间」（不触发整份 .ccbak 上传）', () async {
    await repo.upsertItems([item('e1')]);
    final before = await repo.latestLibraryChangeAt();

    await repo.saveResumePosition('quark:e1', const Duration(minutes: 9));
    await repo.markPlayed('quark:e1', DateTime(2026, 10, 7, 23));

    expect(
      await repo.latestLibraryChangeAt(),
      before,
      reason: '播放进度走独立通道；它还参与整库 LWW 的话，看一集就会推动整份备份',
    );
  });
}
