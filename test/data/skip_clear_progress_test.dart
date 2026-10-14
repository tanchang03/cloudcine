import 'dart:io';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/db/progress_store.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/playback_progress.dart';
import 'package:cloudcine/domain/services/skip_learning.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// **「清除片头 / 片尾」这条路上，库列与进度文件必须一起清。**
///
/// ## 它防的是什么
///
/// 片头 / 片尾的**真源是进度文件**，`media_works` 那几列只是物化投影
/// （见 `WorkSkipEntry` 的类文档）。所以「清除」如果只写库、不动进度文件，
/// 后果**不是「清得不彻底」，而是「清掉了又自己回来」**：
///
/// ```
/// ① 用户在界面上点「清除学习结论」 → media_works 三列置 NULL ✅
/// ② 进度库内存里仍留着上一轮播种进来的学习组（hasLearned == true）
/// ③ 下一次同步（每 30 分钟一次 / 启动时）：
///       applySkipMarkerSnapshot 只写「有内容」的那一组
///    ⇒ 把学习结论**原样写回 media_works** ❌
/// ```
///
/// 而界面上刚才明明写着「已清除」—— 用户只会认为「这个功能清除不掉」。
///
/// ⛔ 两端必须同口径：Android 的 `LibraryDb.clearLearnedSkip` **一直**会调
///    `progress.recordLearnedSkip(…全空…)`，PC 这边曾经漏了整整一句
///    （2026-10-11 收尾自查时发现）。
void main() {
  late Directory dir;
  late AppDatabase db;
  late ProgressStore store;
  late DriftMediaRepository repo;

  const key = 'quark:g1';
  final learnedAt = DateTime(2026, 10, 11, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloudcine_skip_clear');
    db = AppDatabase(NativeDatabase.memory());
    store = ProgressStore(
      filePath: '${dir.path}${Platform.pathSeparator}${ProgressStore.fileName}',
      // 单测里不要防抖落盘 —— 每一步都自己 `await flush()`，时序才确定。
      flushDelay: const Duration(hours: 1),
    );
    repo = DriftMediaRepository(db, progress: store);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  MediaWork work({int? introStartMs, int? introEndMs}) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '测试剧',
        introStartMs: introStartMs,
        introEndMs: introEndMs,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

  /// 学出一组结论（片头 88 秒 / 片尾距末尾 70 秒）。
  Future<void> learn() => repo.saveLearnedSkip(
        key,
        SkipLearningOutcome(
          intro: LearnedIntro(
            end: const Duration(seconds: 88),
            samples: 4,
            spread: const Duration(seconds: 2),
          ),
          outro: LearnedOutro(
            offset: const Duration(seconds: 70),
            samples: 4,
            spread: const Duration(seconds: 3),
          ),
        ),
        now: learnedAt,
      );

  /// 模拟「上一轮同步播过种」：把库里的投影合进进度库。
  Future<void> seed() async {
    await store.load();
    await store.mergeFrom(await repo.skipMarkerSnapshot());
    await store.flush();
  }

  test('清除学习结论时，进度文件里那一组也要清（否则下一次同步会写回来）', () async {
    // ⛔ 这部作品同时有**手标**片头 —— 不是为了别的，而是让条目在手标组上
    //    有内容、从而不会因为「两组都空」被 `putSkip` 整条删掉（见第三个用例）。
    await repo.upsertWorks([work(introStartMs: 0, introEndMs: 95_000)]);
    await learn();
    await seed();

    final seeded = store.skipFor(key);
    expect(seeded, isNotNull, reason: '播种之后进度库里应当有这一条');
    expect(seeded!.hasLearned, isTrue);

    await repo.clearLearnedSkip(key);

    // ① 库列清了。
    final row = await repo.workByKey(key);
    expect(row!.learnedIntroEndMs, isNull);
    expect(row.learnedOutroOffsetMs, isNull);
    expect(row.learnedIntroStartMs, isNull);

    // ② 进度文件里那一组也清了，且 `lu` 前进了 —— 这才是「不会自己回来」
    //    的判据（LWW 靠时间戳，不靠内容）。
    final after = store.skipFor(key);
    expect(after, isNotNull, reason: '手标组还在，条目本身不该消失');
    expect(
      after!.hasLearned,
      isFalse,
      reason: '少了 `recordLearnedSkip(…全空…)` 这一句的话，'
          '`applySkipMarkerSnapshot` 会认为「这一组有内容」并把旧结论写回库里 —— '
          '用户点了「清除」，半小时后又回来了。',
    );
    expect(
      after.learnedUpdatedAtSec,
      greaterThan(seeded.learnedUpdatedAtSec),
      reason: '`lu` 必须前进，否则云上那份旧结论在 LWW 里会赢回来',
    );
    // 手标组不受影响 —— 两组各判各的。
    expect(after.hasManual, isTrue);
    expect(after.introEndMs, 95_000);
  });

  test('清除手标时同样要写进度文件（`mu` 前进）', () async {
    await repo.upsertWorks([work(introStartMs: 0, introEndMs: 95_000)]);
    await learn();
    await seed();

    final seeded = store.skipFor(key)!;
    await repo.clearWorkIntroRange(key);

    final after = store.skipFor(key);
    expect(after, isNotNull, reason: '学习组还在，条目本身不该消失');
    expect(after!.hasManual, isFalse);
    expect(
      after.manualUpdatedAtSec,
      greaterThan(seeded.manualUpdatedAtSec),
      reason: '「清除」在 LWW 里赢过旧值靠的就是这个前进的时间戳',
    );
    expect(after.hasLearned, isTrue, reason: '清除手标不该动学习那一组');
  });

  test('⚠️ 已知缺口：作品**只有**学习结论时，清除会被下一次同步带回来', () async {
    // 这不是期望行为，是**已记录的限制**：`putSkip` 在两组都空时把整条删掉，
    // 于是「我清除了」这件事在进度文件里没有留下任何痕迹（没有墓碑），
    // 下一轮 `mergeFrom(网盘那份)` 自然又把旧结论合了回来。
    //
    // 修法（未做）：让 `WorkSkipEntry.isEmpty` 也看时间戳
    // （`mu`/`lu` 前进过的空组 = 墓碑，不算空），并让 `applySkipMarkerSnapshot`
    // 用「时间戳 > 0」而不是「有没有内容」来判「这一组我知道吗」。
    // 那是跨端契约改动，两端要一起动，所以单独排期。
    await repo.upsertWorks([work()]); // ⛔ 没有手标
    await learn();
    await seed();

    // 网盘上那份（上一轮传上去的）还带着学习结论。
    final remote = store.book.toBytes();

    await repo.clearLearnedSkip(key);
    expect(
      store.skipFor(key),
      isNull,
      reason: '两组都空 ⇒ `putSkip` 把整条删掉 —— 这正是缺口的成因',
    );

    // 下一轮同步：先合网盘那份，再回填库。
    await store.mergeFrom(ProgressBook.fromBytes(remote));
    await repo.applySkipMarkerSnapshot(store.book);

    expect(
      (await repo.workByKey(key))!.learnedOutroOffsetMs,
      isNotNull,
      reason: '⚠️ 这是**已知缺口**，不是期望行为。'
          '修好之后这里应当改成 `isNull`（并同步更新 HOWTO）。',
    );
  });
}
