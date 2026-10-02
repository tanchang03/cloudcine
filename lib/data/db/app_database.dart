import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/diagnostics/diag_log.dart';
import 'tables.dart';

part 'app_database.g.dart';

/// 本地索引库。
///
/// 全部数据都在本机：媒体项、作品元数据、字幕引用、续扫游标、设置。
/// **网盘侧只读** —— 本应用不上传、不移动、不删除、不分享用户的文件。
@DriftDatabase(
  tables: [MediaItems, MediaWorks, SubtitleRefs, ScanCursors, Settings],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// 打开磁盘上的库文件。
  ///
  /// `createInBackground` 让建库/迁移跑在后台 isolate：媒体库首次扫描时
  /// 可能有几千次写入，放在主 isolate 会直接卡住 UI 线程。
  AppDatabase.openFile(File file)
      : super(NativeDatabase.createInBackground(file));

  /// 内存库（测试用）。
  AppDatabase.memory() : super(NativeDatabase.memory());

  /// 当前 schema 版本。
  ///
  /// v1：首个版本（媒体项 / 作品 / 字幕引用 / 续扫游标 / 设置）。
  /// v2：`media_items.resumePositionMs` —— 续播位置。
  /// v3：`media_items.thumbUrl`（网盘缩略图）+ `media_works.category`（分类）。
  /// v4：`media_items.videoWidth` / `videoHeight`（网盘给的**实测**像素尺寸）。
  /// v5：`media_works.posterFaceX`（封面裁切用的人物锚点）。
  /// v6：`media_works.lastModifiedAt`（作品下所有文件的网盘修改时间最大值，
  ///     「最近修改」排序用）。
  /// v7：`media_works.firstSeenAt`（作品首次入库时间，「最近添加」排序用）。
  ///     之前这列隐式地由 `updatedAt` 兼任，但重扫时会刷新，导致「最近添加」
  ///     变成「最近被扫到」。
  /// v8：`media_works.categoryManual` / `genresManual` —— 用户手动指定
  ///     分类 / 类型标签的标记位。置位后重扫与重刮削都不再覆盖对应的列。
  /// v9：`media_items.part` / `partLabel` —— 「部」（`第X部` / `Part.N` /
  ///     `特别篇`）。与「季」构成两级细分，详情页据此画层级选择器。
  /// v10：`media_works.seasonCount` —— 作品下已标季号的季数，列表页卡片
  ///     显示「N 季」用（冗余列，避免每个作品一次 COUNT DISTINCT 子查询）。
  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          diag.info('数据库', '索引库已创建（schema v$schemaVersion）');
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // 加列时旧行的值是 NULL，而这一列的 NULL 语义正好是
            // 「没有可续的点」—— 所以**不需要回填**，也不需要默认值。
            await m.addColumn(mediaItems, mediaItems.resumePositionMs);
            diag.info('数据库', '索引库已升级到 v2（新增续播位置）');
          }
          if (from < 3) {
            // `thumbUrl` 的 NULL 语义是「这个文件没有预览图」，不需要回填；
            // 旧库会在下次扫描时自然补上。
            await m.addColumn(mediaItems, mediaItems.thumbUrl);
            // `category` 有 `DEFAULT ''`，SQLite 的 `ADD COLUMN` 会把旧行
            // 一并填成空串 —— 而空串正好表示「还没判定过」，由
            // `backfillWorkCategories()` 补算。**不做「默认成 other」**：
            // 那会让老库在用户下一次扫描之前整库落进「其他」栏，
            // 看起来像分类功能坏了。
            await m.addColumn(mediaWorks, mediaWorks.category);
            diag.info('数据库', '索引库已升级到 v3（缩略图地址 + 媒体分类）');
          }
          if (from < 4) {
            // NULL 语义是「网盘还没给出实测尺寸」，不需要回填 ——
            // 而且**没法**回填：旧库里根本没有这个信息，只能等下次扫描。
            //
            // 代价要说清楚：升级后旧库里那些**文件名里没写分辨率**的条目
            // 仍然没有分辨率角标，直到用户重扫一次。这比「编一个值塞进去」
            // 诚实 —— 编出来的值会让人以为分辨率是从文件里读的。
            await m.addColumn(mediaItems, mediaItems.videoWidth);
            await m.addColumn(mediaItems, mediaItems.videoHeight);
            diag.info('数据库', '索引库已升级到 v4（实测视频尺寸）');
          }
          if (from < 5) {
            // NULL 语义是「这张封面不需要锚点（不是视频帧）或没有可用人脸框」，
            // 两种情况渲染时都退回画面正中，所以不需要回填。
            //
            // 同样**没法**回填：旧库里根本没存过人脸框，只能等下次扫描。
            // 代价是升级后封面暂时按画面正中裁 —— 竖版裁切只会保留约 37.5%
            // 的画面宽度，所以双人对谈镜头会裁到两人之间的空隙。重扫一次即好。
            await m.addColumn(mediaWorks, mediaWorks.posterFaceX);
            diag.info('数据库', '索引库已升级到 v5（封面人物锚点）');
          }
          if (from < 6) {
            await m.addColumn(mediaWorks, mediaWorks.lastModifiedAt);
            // ⚠️ 这一列**必须回填**，不能像前几版那样「等下次扫描」。
            //
            // 原因：它是**默认排序**（`WorkSort.recentModified`）的唯一依据。
            // 留成 NULL 的话，整个媒体库在这一列上没有可排序的值，
            // 用户升级后打开就是一屏按 tie-breaker 排的乱序 —— 看起来
            // 像「更新把这个功能做坏了」。而前面几列（`posterFaceX`、
            // `videoWidth`…）只是显示上的细节，缺了不影响列表能不能用。
            //
            // 好在**能回填**：`media_items.modifiedAt` 里就存着每集的网盘
            // 修改时间，取每个 group 的 MAX 即可，不需要碰网络。
            // 口径与 `WorkSeed.add()` 一致：sample/extra 也计入。
            await customStatement('''
              UPDATE media_works
              SET last_modified_at = (
                SELECT MAX(mi.modified_at)
                FROM media_items mi
                WHERE mi.group_key = media_works.key
              )
            ''');
            diag.info('数据库', '索引库已升级到 v6（最近修改时间，已从媒体项回填）');
          }
          if (from < 7) {
            await m.addColumn(mediaWorks, mediaWorks.firstSeenAt);
            // 这一列也**必须回填**：它决定「最近添加」排序。
            //
            // 留成 NULL 的话，选了「最近添加」排序的作品会全部垫底，
            // 而用户看不出是「新列还没值」还是「排序坏了」。
            //
            // 回填口径：取作品下所有文件的 `first_seen_at` 最小值
            // （最早入库的那一集）。一部剧可能分多次入库（先存了第一季、
            // 一个月后存第二季），取最小值能反映「这部作品最早什么时候
            // 出现在库里」。
            await customStatement('''
              UPDATE media_works
              SET first_seen_at = (
                SELECT MIN(mi.first_seen_at)
                FROM media_items mi
                WHERE mi.group_key = media_works.key
              )
            ''');
            diag.info('数据库', '索引库已升级到 v7（入库时间，已从媒体项回填）');
          }
          if (from < 8) {
            // 两个标记位都是 `DEFAULT false`，SQLite 的 `ADD COLUMN` 会把
            // 旧行一并填成 false —— 语义正好是「这两列都还没被用户手动改过」，
            // 不需要回填，也不需要额外的数据迁移。
            //
            // 老库里的分类 / 类型仍然是自动判定的结果，行为和升级前完全一致；
            // 用户手动改一次之后才会置位。
            await m.addColumn(mediaWorks, mediaWorks.categoryManual);
            await m.addColumn(mediaWorks, mediaWorks.genresManual);
            diag.info('数据库', '索引库已升级到 v8（手动分类 / 类型标记位）');
          }
          if (from < 9) {
            // 两列的 NULL 语义都是「这个文件没标部」，详情页据此**不画**
            // 「部」那一层 —— 所以不需要回填，旧库升级后的表现与升级前
            // 完全一致（平铺列表，只多了一次「没有部」的判定）。
            //
            // 也**没法**回填：部号是从文件名解析出来的，旧库里根本没存过，
            // 只能等下次扫描。代价是老作品暂时看不到「部」分层，重扫一次
            // 即好。这比「编一个部号塞进去」诚实 —— 编出来的值会让用户
            // 以为它是从文件名读出来的。
            await m.addColumn(mediaItems, mediaItems.part);
            await m.addColumn(mediaItems, mediaItems.partLabel);
            diag.info('数据库', '索引库已升级到 v9（分部：第X部 / 特别篇）');
          }
          if (from < 10) {
            await m.addColumn(mediaWorks, mediaWorks.seasonCount);
            // ⚠️ 这一列**必须回填**，和 `lastModifiedAt`（v6）同一条理由：
            // 它直接显示在卡片副标题上（「剧集 · 2023 · 3 季 · 24 集」）。
            // 留成 0 的话，升级后**所有**多季剧的「N 季」都会消失 ——
            // 用户看不出是「新列还没值」还是「这个功能没了」。
            //
            // 好在能回填：`media_items.season` 里就存着每集的季号，
            // 数一下去重个数即可，不需要碰网络。
            //
            // 口径与 `WorkSeed.seasonCount` 一致：只数 `> 0` 的季号
            // （`NULL` 和 `0` 都是「未标季」，不算一季）。
            await customStatement('''
              UPDATE media_works
              SET season_count = (
                SELECT COUNT(DISTINCT mi.season)
                FROM media_items mi
                WHERE mi.group_key = media_works.key
                  AND mi.season IS NOT NULL
                  AND mi.season > 0
              )
            ''');
            diag.info('数据库', '索引库已升级到 v10（季数，已从媒体项回填）');
          }
          if (to > schemaVersion) {
            // 留一个显式的分支而不是空实现：将来加列时这里就是唯一的落点，
            // 而空的 onUpgrade 会让「忘了写迁移」变成一个静默的数据损坏。
            diag.warn('数据库', '未预期的 schema 升级：$from → $to');
          }
        },
        beforeOpen: (details) async {
          // 外键在 SQLite 里默认是关的，必须每个连接显式打开。
          await customStatement('PRAGMA foreign_keys = ON');
          diag.debug('数据库', '索引库已打开（v${details.versionNow}）');
        },
      );

  /// 清空全部索引数据（「重建媒体库」用）。
  ///
  /// ⚠️ 只清本地索引，**不动网盘**。
  Future<void> wipeIndex() async {
    await transaction(() async {
      await delete(subtitleRefs).go();
      await delete(mediaItems).go();
      await delete(mediaWorks).go();
      await delete(scanCursors).go();
    });
    diag.warn('数据库', '已清空本地索引（网盘侧未做任何改动）');
  }
}

/// 打开（必要时创建）应用数据库文件。
///
/// 路径放在 `getApplicationSupportDirectory()` 下：那是 macOS/Windows/Linux
/// 上「应用自己的数据」的标准位置，且**不会被系统清理**（临时目录会）。
Future<AppDatabase> openAppDatabase() async {
  final dir = await getApplicationSupportDirectory();
  if (!await dir.exists()) await dir.create(recursive: true);
  final file = File(p.join(dir.path, 'cloudcine.sqlite'));
  diag.info('数据库', '索引库路径：${file.path}');
  return AppDatabase.openFile(file);
}
