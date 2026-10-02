import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../core/utils/drive_paths.dart';
import '../../core/utils/filename_parser.dart';
import '../adapters/cloud_drive_adapter.dart';
import '../adapters/media_repository.dart';
import '../entities/drive_entry.dart';
import '../entities/drive_provider.dart';
import '../entities/media_item.dart';
import '../entities/scan_policy.dart';
import 'media_entry_classifier.dart';
import 'request_throttle.dart';
import 'scan_service.dart';
import 'subtitle_service.dart';
import 'work_builder.dart';

/// 一次发现的覆盖范围。
enum DiscoveryScope {
  /// 一个目录（可选含其子目录）
  directory,

  /// 单个文件
  file;

  String get label => switch (this) {
        DiscoveryScope.directory => '目录',
        DiscoveryScope.file => '文件',
      };
}

/// 局部发现的进度快照。
class DiscoveryProgress {
  const DiscoveryProgress({
    required this.scope,
    required this.rootPath,
    this.currentDirPath,
    this.scannedDirs = 0,
    this.scannedFiles = 0,
    this.mediaFound = 0,
    this.added = 0,
    this.finished = false,
  });

  final DiscoveryScope scope;

  /// 本次发现的目标路径（目录或文件所在的目录）。
  final String rootPath;

  final String? currentDirPath;
  final int scannedDirs;
  final int scannedFiles;
  final int mediaFound;
  final int added;
  final bool finished;

  @override
  String toString() => 'DiscoveryProgress(${scope.name}, $rootPath, '
      '目录 $scannedDirs, 文件 $scannedFiles, 媒体 $mediaFound, 新增 $added)';
}

/// 一次发现的结果。
class DiscoveryOutcome {
  const DiscoveryOutcome({
    required this.scope,
    required this.rootPath,
    this.mediaFound = 0,
    this.added = 0,
    this.existing = 0,
    this.works = 0,
    this.subtitlesIndexed = 0,
    this.scannedDirs = 0,
    this.scannedFiles = 0,
    this.failedDirs = 0,
    this.wasCancelled = false,
    this.error,
  });

  final DiscoveryScope scope;

  /// 目标路径。目录发现是那个目录；文件发现是它所在的目录。
  final String rootPath;

  /// 这次看到了多少个可索引的视频文件（含早已入库的）。
  final int mediaFound;

  /// 其中**之前不在库里**的条数。
  ///
  /// 与 [existing] 相加等于 [mediaFound]。分开报的理由：用户点「发现」时
  /// 最想知道的是「有没有新东西」——只报「发现 12 个媒体文件」而其中
  /// 12 个都是旧的，会让人以为这次操作什么都没做（其实它刷新了元数据）。
  final int added;

  /// 其中**已经在库里**的条数（这次只是把元数据刷新了一遍）。
  final int existing;

  /// 这次涉及的**分组数**（会写成作品行）。
  final int works;

  final int subtitlesIndexed;
  final int scannedDirs;
  final int scannedFiles;

  /// 因权限 / 超时被跳过的目录数。**它不为 0 时结果是不完整的**。
  final int failedDirs;

  final bool wasCancelled;

  /// 中断原因（面向用户）。为 `null` 表示正常跑完。
  final String? error;

  bool get isComplete => !wasCancelled && error == null;

  /// 什么都没发现（目录里没有视频）。UI 据此给「这里没有可入库的视频」。
  bool get isEmpty => mediaFound == 0;

  @override
  String toString() => 'DiscoveryOutcome(${scope.name}, $rootPath, '
      '媒体 $mediaFound（新增 $added / 已有 $existing）, 作品 $works, '
      '字幕 $subtitlesIndexed, 目录 $scannedDirs'
      '${failedDirs == 0 ? "" : ", 跳过 $failedDirs"}'
      '${wasCancelled ? ", 已取消" : (error == null ? "" : ", 出错：$error")})';
}

/// **局部发现**：把某个目录（含子目录）或某个文件里的媒体补进媒体库。
///
/// ## 它解决什么问题
///
/// 网盘是个持续变化的目录：用户今天往 `/电影/` 里丢了一部新片。这时
/// 让用户为了这一部片子跑一次全盘扫描，代价是遍历几千个目录、好几分钟，
/// 以及一次被限流的风险。
///
/// 局部发现只走用户指定的那一小片，几秒完成，且**只增不减**。
///
/// ## 与全盘扫描的三条硬区别
///
/// 这三条都是「局部视野」的直接后果，任何一条做错都会静默地损坏媒体库：
///
///   1. **绝不清理陈旧记录**。全盘扫描扫完会用「本次见到的 id」当白名单，
///      删掉网盘侧已删除的行；局部发现只看到一棵子树，拿它当白名单等于
///      把子树之外的**全部**媒体项删光。所以这里根本不调
///      `deleteItemsNotIn` / `deleteSubtitlesNotIn`。
///   2. **绝不写续扫游标**。`ScanCursor` 描述的是全盘扫描的 BFS 队列与
///      分页位置。局部发现往里写一笔，用户下次点「从上次中断处继续」就会
///      从一个错的队列开始 —— 表现是「续扫之后少了一大半片子」，而这两件
///      事在用户眼里毫无关联。
///   3. **深度限制相对本次目标算**，不是相对网盘根。用户选中的目录就是
///      「第 0 层」，否则从 `/电影/2024/新片/` 里发现时会被根目录算起的
///      深度早早截断。
///
/// ## 共用的部分
///
/// 条目分类（[classifyEntry]）、归组与作品行构造（[WorkSeedBook]）、
/// 字幕配对（[SubtitleIndexer]）与全盘扫描**是同一份实现**。两处各写一遍
/// 会让同一个文件走两条路得到不同的分组键或分类，而那是静默的。
class MediaDiscoveryService {
  MediaDiscoveryService({
    required DriveAdapterRegistry registry,
    required MediaRepository library,
    this.policy = const ScanPolicy(),
    this.parser = const MediaFilenameParser(),
    this.subtitleIndexer = const SubtitleIndexer(),
    DateTime Function()? clock,
  })  : _registry = registry,
        _library = library,
        _clock = clock ?? DateTime.now;

  final DriveAdapterRegistry _registry;
  final MediaRepository _library;
  final ScanPolicy policy;
  final MediaFilenameParser parser;
  final SubtitleIndexer subtitleIndexer;
  final DateTime Function() _clock;

  /// 本实例上是否有发现正在跑。
  ///
  /// ⚠️ **它不是 UI 那一侧的并发守卫**：`DiscoveryController` 每次发起都会
  /// `MediaDiscoveryService(...)` 新建一个实例（`policy` 必须现读设置，缓存
  /// 实例会让改了设置不生效），所以这个字段**跨调用永远是 `false`**。真正
  /// 拦住「连点两次」的是 `DiscoveryController.canStart`（看 `state.running`
  /// 与全盘扫描是否在跑）。
  ///
  /// 留着它的理由：直接持有同一个实例的调用方（测试、将来的批处理入口）
  /// 不会自己踩自己 —— 两次并发的列目录会把实际 QPS 翻倍，而两边各自的
  /// 节流器都以为自己守住了 3 QPS。
  bool _active = false;

  /// 是否已有发现在进行中。
  bool get isRunning => _active;

  /// 发现一个目录。`recursive` 为假时只看这一层。
  Future<DiscoveryOutcome> discoverDirectory(
    DriveProvider provider, {
    required String dirId,
    required String dirPath,
    bool recursive = true,
    ScanCancellation? cancel,
    void Function(DiscoveryProgress progress)? onProgress,
  }) async {
    if (_active) {
      throw StateError('已有发现在进行中');
    }
    _active = true;
    try {
      return await _discoverDirectory(
        provider,
        dirId: dirId,
        dirPath: dirPath,
        recursive: recursive,
        cancel: cancel,
        onProgress: onProgress,
      );
    } finally {
      _active = false;
    }
  }

  Future<DiscoveryOutcome> _discoverDirectory(
    DriveProvider provider, {
    required String dirId,
    required String dirPath,
    required bool recursive,
    ScanCancellation? cancel,
    void Function(DiscoveryProgress progress)? onProgress,
  }) async {
    final adapter = _registry.requireAdapter(provider);
    if (!adapter.capabilities.canListDirectory) {
      throw DriveException(
        type: DriveErrorType.unsupported,
        message: '${provider.displayName} 不支持列目录，无法发现媒体',
      );
    }

    final token = cancel ?? ScanCancellation();
    final rootPath = drivePathWithTrailingSlash(dirPath);

    diag.section('发现媒体（$rootPath${recursive ? "" : "，仅本层"}）');

    // 「新增 / 已有」的基线：本次目标路径下**当前已在库里**的文件 id。
    //
    // ⚠️ 这是一份**开始前**的快照。同一批里出现两条相同的 id 只会被算一次，
    // 因为遍历里同一个 fid 不会出现两次。库大于 `listItems` 的上限时基线
    // 会偏小（把已有的算成新增），这个偏差只会让文案偏乐观，不会损坏数据。
    final known = await _knownIds(rootPath);

    final book = WorkSeedBook();
    final throttle = RequestThrottle(
      minInterval: policy.minRequestInterval,
      clock: _clock,
    );

    // BFS 队列。**不落库**（见类文档第 2 条）。
    final queue = <_Target>[
      _Target(id: dirId, path: rootPath, depth: 0),
    ];
    final buffer = <MediaItem>[];

    var scannedDirs = 0;
    var scannedFiles = 0;
    var failedDirs = 0;
    var mediaFound = 0;
    var added = 0;
    var existing = 0;
    var subtitlesIndexed = 0;
    var cancelled = false;
    String? error;

    void emit({bool finished = false, String? currentDir}) {
      onProgress?.call(
        DiscoveryProgress(
          scope: DiscoveryScope.directory,
          rootPath: rootPath,
          currentDirPath: currentDir,
          scannedDirs: scannedDirs,
          scannedFiles: scannedFiles,
          mediaFound: mediaFound,
          added: added,
          finished: finished,
        ),
      );
    }

    emit();

    try {
      while (queue.isNotEmpty) {
        if (token.isCancelled) {
          cancelled = true;
          break;
        }

        final dir = queue.removeAt(0);

        /// 本目录扫到的媒体项 —— 字幕匹配要用**整个目录收齐后**的列表。
        final dirItems = <MediaItem>[];

        /// 本目录的字幕条目。**不是媒体项**，单独收着。
        final dirSubtitles = <DriveEntry>[];

        String? pageToken;
        var dirFailed = false;
        while (true) {
          await throttle.wait();

          DrivePage page;
          try {
            page = await adapter.listDirectory(
              dirId: dir.id,
              pageToken: pageToken,
              pageSize: policy.pageSize,
            );
          } on DriveException catch (e) {
            if (e.needsReauth) rethrow; // 授权问题必须让用户处理
            // 单个目录失败不该毁掉整次发现
            failedDirs++;
            dirFailed = true;
            diag.warn('发现', '列目录失败，跳过：${dir.path}（${e.message}）');
            break;
          }

          for (final entry in page.entries) {
            if (entry.isFile) scannedFiles++;

            switch (classifyEntry(entry)) {
              case EntryRole.directory:
                if (!recursive) break;
                final childDepth = dir.depth + 1;
                if (!policy.shouldEnterDir(entry.name, childDepth)) break;
                if (policy.reachedDirLimit(
                  scannedDirs,
                  queuedDirs: queue.length,
                )) {
                  break;
                }
                queue.add(
                  _Target(
                    id: entry.id,
                    path: drivePathJoin(dir.path, entry.name),
                    depth: childDepth,
                  ),
                );

              case EntryRole.subtitle:
                dirSubtitles.add(entry);

              case EntryRole.image:
              case EntryRole.other:
                // 图片与其它非视频文件直接跳过。⚠️ 图片**不当媒体项**入库：
                // 一张 `cover.jpg` 变成「一个视频」会让媒体库出现一堆
                // 点开就报错的条目。
                break;

              case EntryRole.discImage:
                diag.debug('发现', '跳过镜像文件：${entry.name}');

              case EntryRole.video:
                {
                  // 传整个目录路径（不是末级目录名）—— 目录级归组要用它，见 [DirectoryTitle]。
                  final parsed = parser.parse(
                    entry.name,
                    dirPath: dir.path,
                  );
                  final item = MediaItem.fromEntry(
                    entry: entry,
                    provider: provider,
                    dirPath: dir.path,
                    parsed: parsed,
                    now: _clock(),
                  );
                  buffer.add(item);
                  dirItems.add(item);
                  mediaFound++;
                  if (known.contains(item.id)) {
                    existing++;
                  } else {
                    added++;
                  }
                  book.add(parsed: parsed, item: item, dirPath: dir.path);
                }
            }
          }

          pageToken = page.nextPageToken;

          // 及时入库，避免长时间占用内存
          if (buffer.length >= 200) {
            await _library.upsertItems(buffer, now: _clock());
            buffer.clear();
          }

          if (pageToken == null) break;
          if (token.isCancelled) {
            cancelled = true;
            break;
          }
        }

        if (!dirFailed) scannedDirs++;

        if (buffer.isNotEmpty) {
          await _library.upsertItems(buffer, now: _clock());
          buffer.clear();
        }

        // 目录边界：把本目录新出现的分组建成作品行 ——
        // 否则媒体库里只涨文件不涨作品，海报墙上什么都不会变。
        if (book.hasDirty) {
          await _library.upsertWorks(
            book.buildDirty(provider: provider, now: _clock()),
            now: _clock(),
          );
          book.markClean();
        }

        // 字幕匹配：**必须在本目录视频收齐之后**。
        if (dirSubtitles.isNotEmpty && dirItems.isNotEmpty) {
          final result = subtitleIndexer.indexDirectory(
            items: dirItems,
            subtitleFiles: dirSubtitles,
          );
          if (result.matchCount > 0) {
            await _library.upsertSubtitles(result.refs, now: _clock());
            subtitlesIndexed += result.matchCount;
          }
        }

        emit(currentDir: dir.path);
        if (cancelled) break;
      }
    } on DriveException catch (e) {
      error = e.message;
      diag.error('发现', '中断（需授权 ${e.needsReauth}）：${e.message}');
      rethrow;
    } catch (e) {
      error = e.toString();
      diag.error('发现', '意外中断：$error');
    }

    emit(finished: true);

    final outcome = DiscoveryOutcome(
      scope: DiscoveryScope.directory,
      rootPath: rootPath,
      mediaFound: mediaFound,
      added: added,
      existing: existing,
      works: book.groupCount,
      subtitlesIndexed: subtitlesIndexed,
      scannedDirs: scannedDirs,
      scannedFiles: scannedFiles,
      failedDirs: failedDirs,
      wasCancelled: cancelled,
      error: error,
    );

    diag.info('发现', '结束：$outcome');
    diag.section('发现结束');
    return outcome;
  }

  /// 发现**单个文件**。
  ///
  /// 顺带把**同一目录下的字幕**也配对进来（多一次列目录请求）。理由：
  /// 用户点「加入媒体库」时想的是「把这一集弄进来」，而外挂字幕是这一集的
  /// 一部分 —— 漏掉它，用户要等到下次「发现整个目录」才会看到字幕，
  /// 而他完全不会把这两件事联系起来。
  ///
  /// [dirId] 是 [entry] **所在目录**的 id，用来列同目录字幕。调用方手上有
  /// 这个值（他就是从那个目录的列表里拿到 [entry] 的）时**一定要传**：
  /// 不传会退回 [DriveEntry.parentId]，而那个字段依赖网盘响应里带父目录 id，
  /// 缺了就是静默地配不上字幕。
  Future<DiscoveryOutcome> discoverFile(
    DriveProvider provider, {
    required DriveEntry entry,
    required String dirPath,
    String? dirId,
  }) async {
    if (_active) {
      throw StateError('已有发现在进行中');
    }
    _active = true;
    try {
      return await _discoverFile(
        provider,
        entry: entry,
        dirPath: dirPath,
        dirId: dirId,
      );
    } finally {
      _active = false;
    }
  }

  Future<DiscoveryOutcome> _discoverFile(
    DriveProvider provider, {
    required DriveEntry entry,
    required String dirPath,
    String? dirId,
  }) async {
    final rootPath = drivePathWithTrailingSlash(dirPath);
    final role = classifyEntry(entry);

    if (role != EntryRole.video) {
      // UI 只对视频行给入口，这里只是防御：别把一个 .jpg 变成「一个视频」。
      diag.info('发现', '跳过非视频文件：${entry.name}（${role.name}）');
      return DiscoveryOutcome(
        scope: DiscoveryScope.file,
        rootPath: rootPath,
      );
    }

    final parsed = parser.parse(
      entry.name,
      dirPath: rootPath,
    );
    final item = MediaItem.fromEntry(
      entry: entry,
      provider: provider,
      dirPath: rootPath,
      parsed: parsed,
      now: _clock(),
    );

    final known = await _knownIds(rootPath);
    final isNew = !known.contains(item.id);

    diag.section('发现文件（${entry.name}）');

    await _library.upsertItems([item], now: _clock());

    final book = WorkSeedBook();
    book.add(parsed: parsed, item: item, dirPath: rootPath);
    await _library.upsertWorks(
      book.buildDirty(provider: provider, now: _clock()),
      now: _clock(),
    );

    // 同目录字幕是**额外的**一次列目录，同样要过同一把节流尺子 ——
    // 它是这个服务里唯一一处不在 BFS 主循环里的网盘请求，漏掉它就等于
    // 在 3 QPS 的安全线上偷偷多打几次。
    final throttle = RequestThrottle(
      minInterval: policy.minRequestInterval,
      clock: _clock,
    );
    final subtitlesIndexed = await _indexSiblingSubtitles(
      provider: provider,
      parentId: dirId ?? entry.parentId,
      item: item,
      throttle: throttle,
    );

    final outcome = DiscoveryOutcome(
      scope: DiscoveryScope.file,
      rootPath: rootPath,
      mediaFound: 1,
      added: isNew ? 1 : 0,
      existing: isNew ? 0 : 1,
      works: book.groupCount,
      subtitlesIndexed: subtitlesIndexed,
      scannedDirs: 0,
      scannedFiles: 1,
    );
    diag.info('发现', '结束：$outcome');
    diag.section('发现结束');
    return outcome;
  }

  /// 取同目录的字幕并只和 [item] 配对。
  ///
  /// 列目录失败**不上抛**：字幕是增强，拿不到就算了 —— 主流程（把这个文件
  /// 弄进库）已经成功了，为了字幕报错会让用户以为整个操作失败。
  ///
  /// [parentId] 允许为空：拿不到父目录 id 时**静默返回 0**，不去猜。
  Future<int> _indexSiblingSubtitles({
    required DriveProvider provider,
    required String? parentId,
    required MediaItem item,
    required RequestThrottle throttle,
  }) async {
    if (parentId == null || parentId.isEmpty) return 0;

    try {
      final adapter = _registry.requireAdapter(provider);
      final subtitles = <DriveEntry>[];
      String? pageToken;
      do {
        await throttle.wait();
        final page = await adapter.listDirectory(
          dirId: parentId,
          pageToken: pageToken,
          pageSize: policy.pageSize,
        );
        subtitles.addAll(page.entries.where(
          (e) => classifyEntry(e) == EntryRole.subtitle,
        ));
        pageToken = page.nextPageToken;
      } while (pageToken != null);

      if (subtitles.isEmpty) return 0;

      final result = subtitleIndexer.indexDirectory(
        items: [item],
        subtitleFiles: subtitles,
      );
      if (result.matchCount == 0) return 0;
      await _library.upsertSubtitles(result.refs, now: _clock());
      return result.matchCount;
    } on DriveException catch (e) {
      if (e.needsReauth) rethrow;
      diag.warn('发现', '取同目录字幕失败，跳过：${e.message}');
      return 0;
    }
  }

  /// 本次目标路径下**当前已在库里**的文件 id 集合。
  Future<Set<String>> _knownIds(String path) async {
    final items = await _library.listItems(pathPrefix: path);
    return items.map((i) => i.id).toSet();
  }
}

/// BFS 队列里的一格。
class _Target {
  _Target({
    required this.id,
    required this.path,
    required this.depth,
  });

  final String id;

  /// 展示路径，**带结尾斜杠**（与 `MediaItem.dirPath` 同口径）。
  final String path;

  /// 相对**本次发现目标**的深度（目标是第 0 层）。
  final int depth;
}
