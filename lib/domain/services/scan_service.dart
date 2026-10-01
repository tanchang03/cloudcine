import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../core/utils/filename_parser.dart';
import '../../core/utils/image_formats.dart';
import '../../core/utils/media_category.dart';
import '../../core/utils/subtitle_formats.dart';
import '../../core/utils/video_formats.dart';
import '../adapters/cloud_drive_adapter.dart';
import '../adapters/media_repository.dart';
import '../entities/drive_entry.dart';
import '../entities/drive_provider.dart';
import '../entities/media_item.dart';
import '../entities/media_work.dart';
import '../entities/scan_cursor.dart';
import '../entities/scan_policy.dart';
import 'scraper.dart';
import 'subtitle_service.dart';

/// 扫描取消信号。
///
/// 不用 `Future.cancel`：扫描是「多页循环 + 每页落库」的长流程，
/// 需要一个能在页边界被检查的协作式开关。
class ScanCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 扫描进度快照（推给 UI）。
class ScanProgress {
  const ScanProgress({
    required this.cursor,
    required this.isRunning,
    this.currentDirPath,
    this.message,
    this.phase = ScanPhase.walking,
    this.scrapedWorks = 0,
    this.totalWorksToScrape = 0,
  });

  final ScanCursor cursor;
  final bool isRunning;
  final String? currentDirPath;
  final String? message;

  /// 当前阶段。刮削是在遍历之后单独跑的，UI 要能区分「在走目录」和
  /// 「在刮元数据」—— 后者慢得多，不区分会让用户以为卡住了。
  final ScanPhase phase;

  final int scrapedWorks;
  final int totalWorksToScrape;

  int get scannedDirs => cursor.scannedDirs;
  int get scannedFiles => cursor.scannedFiles;
  int get foundMedia => cursor.foundTracks;
  int get totalBytes => cursor.totalBytes;
  int get pendingDirs => cursor.pendingDirs.length;
  int get failedDirs => cursor.failedDirs;

  @override
  String toString() => 'ScanProgress(${phase.name}, 目录 ${cursor.scannedDirs}, '
      '文件 ${cursor.scannedFiles}, 媒体 ${cursor.foundTracks}, '
      '待扫 ${cursor.pendingDirs.length})';
}

/// 扫描阶段。
enum ScanPhase {
  /// 遍历网盘目录
  walking,

  /// 在线刮削元数据
  scraping,

  /// 收尾
  finishing;

  String get label => switch (this) {
        ScanPhase.walking => '遍历目录',
        ScanPhase.scraping => '刮削元数据',
        ScanPhase.finishing => '收尾',
      };
}

/// 一次扫描的结果。
class ScanOutcome {
  const ScanOutcome({
    required this.cursor,
    required this.itemsIndexed,
    required this.removedItems,
    required this.subtitlesIndexed,
    required this.worksScraped,
    required this.wasCancelled,
    this.error,
  });

  final ScanCursor cursor;
  final int itemsIndexed;
  final int removedItems;
  final int subtitlesIndexed;
  final int worksScraped;
  final bool wasCancelled;
  final String? error;

  bool get isComplete => cursor.isComplete && !wasCancelled && error == null;

  @override
  String toString() => 'ScanOutcome(入库 $itemsIndexed, 清理 $removedItems, '
      '字幕 $subtitlesIndexed, 刮削 $worksScraped, '
      '${wasCancelled ? "已取消" : (error == null ? "完成" : "出错：$error")})';
}

/// 视频媒体库扫描调度服务。
///
/// 负责「遍历网盘 → 识别视频 → 索引字幕 → 归组 → 刮削」这条完整链路：
///   - BFS 逐目录、逐页拉取（分页信号见 `QuarkAdapter.listDirectory` 的注释）
///   - 视频识别与容器/分辨率推断
///   - **每页落库**，任何时刻被杀都能原地续扫
///   - 单目录失败不终止整次扫描（记录并继续）
///   - 授权失效必须立刻上抛（继续扫只会拿到一堆 31001）
///   - 全量扫完后清理网盘侧已删除的陈旧记录
///   - 字幕**只建引用不读正文**（见 [SubtitleIndexer]）
///   - 刮削在遍历之后单独跑，且**只刮还没刮过的作品**
///
/// 只依赖 [CloudDriveAdapter] 与 [MediaRepository] 两个抽象，
/// 因此可以在单元测试里用假适配器 + 内存库完整覆盖。
class ScanService {
  ScanService({
    required DriveAdapterRegistry registry,
    required MediaRepository library,
    this.policy = const ScanPolicy(),
    this.parser = const MediaFilenameParser(),
    this.subtitleIndexer = const SubtitleIndexer(),
    ScraperPipeline? scraper,
    DateTime Function()? clock,
  })  : _registry = registry,
        _library = library,
        _scraper = scraper,
        _clock = clock ?? DateTime.now;

  final DriveAdapterRegistry _registry;
  final MediaRepository _library;
  final ScanPolicy policy;

  /// 文件名解析器。无状态纯函数，测试可替换。
  final MediaFilenameParser parser;

  final SubtitleIndexer subtitleIndexer;

  /// 刮削流水线。`null` 表示本次扫描只做本地解析、不刮削。
  final ScraperPipeline? _scraper;

  final DateTime Function() _clock;

  ScanCancellation? _active;
  ScanProgress? _lastProgress;

  ScanProgress? get lastProgress => _lastProgress;
  bool get isRunning => _active != null;

  /// 请求停止当前扫描（协作式，在页边界生效）
  void requestCancel() => _active?.cancel();

  /// 执行一次扫描。
  ///
  /// [resume] 为真时从上次的续扫游标继续；上次已扫完则自动重新开始。
  /// [pruneStale] 为真时在**完整扫完**后清理网盘侧已删除的记录
  /// （中途取消/失败不清理，否则会误删还没扫到的部分）。
  /// [scrape] 为真时在遍历结束后跑在线刮削。
  ///
  /// **默认 `false`**：刮削的默认入口是详情页的「刮削」按钮。全盘自动刮削
  /// 对额度小的源（豆瓣匿名约 10 个搜索词）是灾难性的 —— 中途耗尽会让整批
  /// 作品一条都刮不到，且这个 IP 短时间内不可用。要自动刮就在设置里显式打开
  /// （`autoScrapeOnScan`）。
  Future<ScanOutcome> scan(
    DriveProvider provider, {
    bool resume = true,
    bool pruneStale = true,
    bool scrape = false,
    ScanCancellation? cancel,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    if (_active != null) {
      throw StateError('已有扫描在进行中');
    }
    final token = cancel ?? ScanCancellation();
    _active = token;

    try {
      return await _run(
        provider,
        resume: resume,
        pruneStale: pruneStale,
        scrape: scrape,
        cancel: token,
        onProgress: onProgress,
      );
    } finally {
      _active = null;
    }
  }

  Future<ScanOutcome> _run(
    DriveProvider provider, {
    required bool resume,
    required bool pruneStale,
    required bool scrape,
    required ScanCancellation cancel,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    final adapter = _registry.requireAdapter(provider);
    final capabilities = adapter.capabilities;

    if (!capabilities.canListDirectory) {
      throw DriveException(
        type: DriveErrorType.unsupported,
        message: '${provider.displayName} 不支持列目录，无法遍历媒体库',
      );
    }

    // 只有在「有游标 且 尚未扫完」时才续扫；其余情况（从未扫过、上次已扫完）
    // 一律从头开始，避免拿着 completed 的游标空转一轮。
    final restored = resume ? await _library.loadScanCursor(provider) : null;
    final resumable =
        (restored != null && !restored.isComplete) ? restored : null;

    diag.section('扫描 ${resumable == null ? "开始" : "续扫"}（${provider.displayName}）');
    diag.info(
      '扫描',
      '根目录=${adapter.rootId} 续扫=${resumable != null} '
      '刮削=${scrape && _scraper != null} 策略: $policy',
    );

    var cursor = resumable ??
        ScanCursor.fresh(
          provider: provider,
          rootId: adapter.rootId,
          now: _clock(),
        );

    /// 本次是否从零开始。**陈旧清理只在「从零扫完」时才做**：
    /// 续扫时本次运行只看到了部分目录，拿本次看到的 id 当白名单会把上次
    /// 扫到、这次还没扫到的记录误删。
    final startedFresh = resumable == null;

    final buffer = <MediaItem>[];

    /// 本次运行**实际扫到**的媒体项 id —— 陈旧清理的白名单来源。
    final seenIds = <String>{};

    /// 本次运行**确实建立了字幕引用**的媒体项 id —— 字幕清理的白名单来源。
    final seenSubtitleItems = <String>{};

    /// 归组键 → 刮削查询。遍历结束后统一跑。
    ///
    /// 用 Map 而不是 Set：同一部剧的每一集都会产出同一个 key，
    /// 保留第一集的查询即可（片名/年份/季号一致），顺带天然去重。
    final scrapeQueries = <String, ScrapeQuery>{};

    /// 归组键 → 该组的代表信息（类型/标题/年份/文件数/体积）。
    final workSeeds = <String, _WorkSeed>{};

    /// 已发现、但还没写成作品行的归组键。
    ///
    /// 存在的理由是「边扫边看」：作品行原先只在遍历**全部结束之后**才建，
    /// 于是大库（几千个目录）在扫描的几十分钟里 `media_works` 一直是 0，
    /// 媒体库页面显示的还是「媒体库还是空的，点『扫描』…」——与事实相反。
    /// 现在每落一批媒体项，就把这一批涉及到的分组建成作品行。
    final dirtyWorkKeys = <String>{};

    /// 把 [dirtyWorkKeys] 里的分组写成作品行（元数据留空，刮削阶段再补）。
    ///
    /// 与阶段二走的是**同一个仓储入口**，所以 `mergeWorkForUpsert` 的
    /// 「保护已有元数据」规则照样生效：先建空元数据的行，不会把后来
    /// 刮削到的海报/简介顶掉（那条规则有单测覆盖）。
    Future<void> flushWorks() async {
      if (dirtyWorkKeys.isEmpty) return;
      final works = <MediaWork>[];
      for (final key in dirtyWorkKeys) {
        final seed = workSeeds[key];
        if (seed == null) continue;
        works.add(
          _buildWork(key: key, provider: provider, seed: seed, meta: null),
        );
      }
      dirtyWorkKeys.clear();
      await _library.upsertWorks(works, now: _clock());
    }

    var indexed = 0;
    var removed = 0;
    var subtitlesIndexed = 0;
    var worksScraped = 0;
    var cancelled = false;
    String? error;

    // 节流计数：游标批量落盘 / 进度批量推送，避免几千次 SQLite 写与 UI 重建。
    var pagesSinceCursorFlush = 0;
    var pagesSinceEmit = 0;

    /// 上一次列目录请求的**发起时刻**，供 [throttleList] 计算剩余等待。
    DateTime? lastListAt;

    /// 节流：保证相邻两次列目录请求之间至少间隔 [ScanPolicy.minRequestInterval]。
    ///
    /// ⚠️ 必须在**每次请求之前**调用，并按「上次发起时刻」算剩余等待时间。
    /// 早先参考项目的实现是在页尾固定 sleep 一次，但内层循环在
    /// `pageToken == null` 时先 `break` 了 —— 于是「换目录」的那一次请求
    /// 完全没被节流。对「每个目录都只有一页」的媒体库（很常见）等于
    /// **全程不节流**：几千个目录会以网络往返速度一路打过去，3 QPS
    /// 安全线形同虚设。
    ///
    /// 按请求**起点**而不是终点计时，才是「最小间隔」的正确语义。
    Future<void> throttleList() async {
      final interval = policy.minRequestInterval;
      if (interval <= Duration.zero) return;
      final last = lastListAt;
      if (last != null) {
        final wait = interval - _clock().difference(last);
        if (wait > Duration.zero) await Future.delayed(wait);
      }
      lastListAt = _clock();
    }

    void emit({
      bool running = true,
      String? message,
      ScanPhase phase = ScanPhase.walking,
      int totalToScrape = 0,
    }) {
      final progress = ScanProgress(
        cursor: cursor,
        isRunning: running,
        currentDirPath: cursor.currentDir?.path,
        message: message,
        phase: phase,
        scrapedWorks: worksScraped,
        totalWorksToScrape: totalToScrape,
      );
      _lastProgress = progress;
      onProgress?.call(progress);
    }

    emit();

    // -----------------------------------------------------------------
    // 阶段一：BFS 遍历
    // -----------------------------------------------------------------
    try {
      while (cursor.hasPendingWork) {
        if (cancel.isCancelled) {
          cancelled = true;
          break;
        }

        if (cursor.currentDir == null) {
          cursor = cursor.dequeue(_clock());
          if (cursor.currentDir == null) break;
        }
        final dir = cursor.currentDir!;

        /// 本目录扫到的媒体项 —— 字幕匹配要用**整个目录收齐后**的列表。
        final dirItems = <MediaItem>[];

        /// 本目录的字幕条目。**不是媒体项**，单独收着。
        ///
        /// 直接丢掉就等于没有外挂字幕功能；当成媒体项入库则会让
        /// 「字幕」变成一部只有 40KB 的「视频」。所以第三条路：收着，
        /// 目录收齐后拿去和视频配对。
        final dirSubtitles = <DriveEntry>[];

        var pageToken = cursor.currentPageToken;
        var dirFailed = false;

        while (true) {
          // 节流放在请求**之前**：同目录翻页、换目录、续扫首请求
          // 走的都是同一条限速逻辑，不会再有漏网的请求。
          await throttleList();

          DrivePage page;
          try {
            page = await adapter.listDirectory(
              dirId: dir.id,
              pageToken: pageToken,
              pageSize: policy.pageSize,
            );
          } on DriveException catch (e) {
            if (e.needsReauth) rethrow; // 授权问题必须让用户处理
            // 单个目录失败（无权限/超时）不该毁掉整次扫描
            cursor = cursor.addCounts(failures: 1, now: _clock());
            cursor = cursor.copyWith(lastError: e.message, updatedAt: _clock());
            dirFailed = true;
            break;
          }

          var newFiles = 0;
          var newItems = 0;
          var newBytes = 0;

          for (final entry in page.entries) {
            if (entry.isDirectory) {
              final childDepth = dir.depth + 1;
              if (!policy.shouldEnterDir(entry.name, childDepth)) continue;
              if (policy.reachedDirLimit(
                cursor.scannedDirs,
                queuedDirs: cursor.pendingDirs.length,
              )) {
                continue;
              }
              cursor = cursor.enqueueIfAbsent(
                PendingDir(
                  id: entry.id,
                  path: _joinPath(dir.path, entry.name),
                  depth: childDepth,
                ),
                _clock(),
              );
              continue;
            }

            newFiles++;

            // 字幕：先收着，目录收齐后再配对。
            if (SubtitleFormats.isSubtitleFile(entry.name)) {
              dirSubtitles.add(entry);
              continue;
            }
            // 图片与其它非视频文件直接跳过。
            // ⚠️ 图片**不当媒体项**入库：一张 `cover.jpg` 变成「一个视频」
            // 会让媒体库出现一堆点开就报错的条目。
            if (isImageFile(entry.name, mimeType: entry.mimeType)) continue;
            if (!VideoFormats.isVideoFile(entry.name, mimeType: entry.mimeType)) {
              continue;
            }
            // 蓝光镜像不索引：mpv 播不了 BD 导航结构，索引了只会得到
            // 一堆点了播不了的行。
            if (VideoFormats.isDiscImage(entry.name)) {
              diag.debug('扫描', '跳过镜像文件：${entry.name}');
              continue;
            }

            final parsed = parser.parse(
              entry.name,
              dirName: MediaFilenameParser.dirNameOf(dir.path),
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
            seenIds.add(item.id);
            newItems++;
            newBytes += entry.sizeBytes ?? 0;

            // 刮削查询：同一组只留一条。
            //
            // 查询的构造走 `ScrapeQuery.fromParsed`，与详情页的「刮削」按钮
            // 共用同一份逻辑 —— 两处各拼一遍的话，同一个作品在「扫描期」
            // 与「点按钮」时会查出不同结果，而且**不会报错**。
            final scrapeQuery = ScrapeQuery.fromParsed(parsed);
            if (scrapeQuery != null) {
              scrapeQueries.putIfAbsent(parsed.groupKey, () => scrapeQuery);
              final seed = workSeeds.putIfAbsent(
                parsed.groupKey,
                () => _WorkSeed(
                  kind: parsed.kind,
                  title: parsed.title!,
                  year: parsed.year,
                  // 分类判定用「文件名 + 目录路径 + 片名」三处证据：
                  // 网盘上「动漫」这类信息几乎总是写在目录名里
                  // （`/动漫/进击的巨人/…`），只看片名会大面积漏判。
                  category: MediaCategoryGuesser.guess(
                    kind: parsed.kind,
                    title: parsed.title,
                    fileName: entry.name,
                    dirPath: dir.path,
                  ),
                ),
              );
              // 第一条没缩略图时用后面的补上（夸克对约 30% 的视频
              // 还没生成预览图，而同一部剧里通常总有一集是有的）。
              //
              // ⚠️ 地址和锚点**必须在同一次赋值里一起写**：它们描述的是同一张图。
              // 拆成两次写（先 `posterUrl ??=`、再 `posterFaceX ??=`）会在
              // 「第一集有图但没人脸、第二集有人脸但没图」时拼出一对不匹配的
              // 组合 —— 拿甲图的人脸位置去裁乙图。写成 `if` 而不是 `??=`，
              // 就是为了让这两行在结构上无法分开。
              if (seed.posterUrl == null && item.thumbUrl != null) {
                seed.posterUrl = item.thumbUrl;
                seed.posterFaceX = item.faceAnchorX;
              }
              seed.itemCount++;
              seed.totalBytes += entry.sizeBytes ?? 0;
              dirtyWorkKeys.add(parsed.groupKey);
            }
          }

          cursor = cursor.addCounts(
            files: newFiles,
            tracks: newItems,
            bytes: newBytes,
            now: _clock(),
          );

          pageToken = page.nextPageToken;
          cursor = cursor.copyWith(
            currentPageToken: pageToken,
            clearPageToken: pageToken == null,
            updatedAt: _clock(),
          );

          pagesSinceCursorFlush++;
          pagesSinceEmit++;

          // 批量落库续扫游标：目录边界 / 取消 / 每 N 页 都落一次，
          // 避免几千次 SQLite 写（每次都要把 pendingDirs 全量序列化进 JSON）。
          if (pageToken == null ||
              cancel.isCancelled ||
              pagesSinceCursorFlush >= policy.cursorFlushEveryPages) {
            await _library.saveScanCursor(cursor);
            pagesSinceCursorFlush = 0;
          }

          if (pageToken == null ||
              cancel.isCancelled ||
              pagesSinceEmit >= policy.progressEmitEveryPages) {
            emit();
            pagesSinceEmit = 0;
          }

          // 及时入库，避免长时间占用内存
          if (buffer.length >= 200) {
            await _library.upsertItems(buffer, now: _clock());
            indexed += buffer.length;
            buffer.clear();
          }

          if (pageToken == null) break;
          if (cancel.isCancelled) {
            cancelled = true;
            break;
          }
        }

        // 当前目录处理完毕
        cursor = cursor.copyWith(
          clearCurrentDir: true,
          clearPageToken: true,
          scannedDirs: dirFailed ? cursor.scannedDirs : cursor.scannedDirs + 1,
          updatedAt: _clock(),
        );

        if (buffer.isNotEmpty) {
          await _library.upsertItems(buffer, now: _clock());
          indexed += buffer.length;
          buffer.clear();
        }

        // 目录边界：顺手把本目录新出现的分组建成作品行，
        // 这样媒体库在扫描过程中就能一条条长出来。
        await flushWorks();

        // 字幕匹配：**必须在本目录视频收齐之后**。
        //
        // 已知边界：若上次扫描是在本目录中途被杀的，续扫进来时前几页的
        // 视频不在 dirItems 里，字幕可能对不上（结果是「这个目录这次没有
        // 字幕」）。不会产生错误结果，下一次完整扫描会补上。
        if (dirSubtitles.isNotEmpty && dirItems.isNotEmpty) {
          final result = subtitleIndexer.indexDirectory(
            items: dirItems,
            subtitleFiles: dirSubtitles,
          );
          if (result.matchCount > 0) {
            await _library.upsertSubtitles(result.refs, now: _clock());
            for (final e in result.entries) {
              seenSubtitleItems.add(e.itemId);
            }
            subtitlesIndexed += result.matchCount;
            diag.info(
              '字幕',
              '${dir.path}：${dirSubtitles.length} 个字幕文件对上 '
              '${result.entries.length} 个视频（${result.matchCount} 条）',
            );
          }
        }

        // 目录边界强制落盘 + 推进度
        await _library.saveScanCursor(cursor);
        emit();
        pagesSinceCursorFlush = 0;
        pagesSinceEmit = 0;

        if (cursor.scannedDirs % 50 == 0) {
          diag.info(
            '扫描',
            '已扫 ${cursor.scannedDirs} 目录 / '
            '${cursor.scannedFiles} 文件 / ${cursor.foundTracks} 媒体…',
          );
        }

        if (cancelled) break;
      }

      if (buffer.isNotEmpty) {
        await _library.upsertItems(buffer, now: _clock());
        indexed += buffer.length;
        buffer.clear();
      }

      // 遍历收尾：把最后一批分组也建成作品行。
      await flushWorks();

      if (cancelled) {
        cursor = cursor.pause(_clock());
      } else if (cursor.hasPendingWork) {
        cursor = cursor.pause(_clock());
      } else {
        cursor = cursor.markCompleted(_clock());
      }
    } on DriveException catch (e) {
      error = e.message;
      cursor = cursor.fail(e.message, _clock());
      await _library.saveScanCursor(cursor);
      emit(running: false, message: e.message);
      diag.error('扫描', '中断（需授权 ${e.needsReauth}）：${e.message}');
      rethrow;
    } catch (e) {
      error = e.toString();
      cursor = cursor.fail(error, _clock());
      await _library.saveScanCursor(cursor);
      emit(running: false, message: error);
      diag.error('扫描', '意外中断：$error');
    }

    // -----------------------------------------------------------------
    // 阶段二：归组 + 刮削
    // -----------------------------------------------------------------
    //
    // 刮削**只在遍历正常结束（未取消、无错）时做**：中途取消时列表还不完整，
    // 为半份数据去消耗 TMDB 的配额没有意义，用户下次续扫还会再来一遍。
    if (scrape && _scraper != null && !cancelled && error == null) {
      emit(
        running: true,
        phase: ScanPhase.scraping,
        totalToScrape: scrapeQueries.length,
        message: '正在刮削元数据…',
      );
      for (final entry in scrapeQueries.entries) {
        if (cancel.isCancelled) {
          cancelled = true;
          break;
        }
        final seed = workSeeds[entry.key];
        if (seed == null) continue;

        try {
          final meta = await _scraper.scrape(entry.value);
          final work = _buildWork(
            key: entry.key,
            provider: provider,
            seed: seed,
            meta: meta,
          );
          await _library.upsertWorks([work], now: _clock());
          if (meta != null && meta.source == ScrapeSource.online) worksScraped++;
        } catch (e) {
          diag.warn('刮削', '${entry.key} 失败，跳过', error: e);
        }

        emit(
          running: true,
          phase: ScanPhase.scraping,
          totalToScrape: scrapeQueries.length,
          message: '正在刮削元数据…',
        );
      }
    } else if (!cancelled && error == null) {
      // 没开刮削时也要建作品行，否则媒体库是空的（只有文件没有作品）。
      for (final entry in scrapeQueries.entries) {
        final seed = workSeeds[entry.key];
        if (seed == null) continue;
        final work = _buildWork(
          key: entry.key,
          provider: provider,
          seed: seed,
          meta: null,
        );
        await _library.upsertWorks([work], now: _clock());
      }
    }

    // -----------------------------------------------------------------
    // 阶段三：陈旧清理
    // -----------------------------------------------------------------
    //
    // 白名单必须是「本次运行实际扫到的 id」。用「库里现有的全部」当白名单
    // 等于永远删不掉任何东西 —— 陈旧记录会一直留在索引里。
    //
    // 三个前置条件缺一不可：
    //   - startedFresh：续扫时本次只看到部分目录，白名单不完整；
    //   - isComplete：中途取消 / 失败时索引不完整；
    //   - seenIds 非空：适配器异常返回空页时，不至于把整个媒体库清空。
    if (pruneStale && startedFresh && cursor.isComplete && error == null) {
      if (seenIds.isNotEmpty) {
        removed = await _library.deleteItemsNotIn(provider, seenIds);

        // 字幕多一道闸：**有目录列失败时不清理**。
        //
        // 失败目录里的视频这次没被扫到，它们的字幕引用自然也不在
        // [seenSubtitleItems] 里 —— 按白名单删会把那些**明明还在**的字幕
        // 全删掉，而失败往往只是超时，下一次扫描可能就好了。
        // 白名单式的清理在「白名单本身不完整」时是有害的，宁可这次不清理。
        if (cursor.failedDirs == 0) {
          await _library.deleteSubtitlesNotIn(provider, seenSubtitleItems);
        }
      }
    }

    await _library.saveScanCursor(cursor);
    emit(
      running: false,
      phase: ScanPhase.finishing,
      message: cursor.isComplete ? '已完成' : null,
    );

    if (cancelled) {
      diag.warn('扫描', '已取消：游标阶段=paused，可续扫'
          '（目录 ${cursor.scannedDirs} / 媒体 ${cursor.foundTracks}）');
    } else if (error != null) {
      diag.error('扫描', '结束但有问题：$error');
    } else {
      diag.info(
        '扫描',
        '完成：目录 ${cursor.scannedDirs} / 文件 ${cursor.scannedFiles} / '
        '媒体 ${cursor.foundTracks} / 清理 $removed'
        '${subtitlesIndexed == 0 ? "" : " / 字幕 $subtitlesIndexed 条"}'
        '${worksScraped == 0 ? "" : " / 在线刮削 $worksScraped 部"}',
      );
    }
    diag.section('扫描结束');

    return ScanOutcome(
      cursor: cursor,
      itemsIndexed: indexed,
      removedItems: removed,
      subtitlesIndexed: subtitlesIndexed,
      worksScraped: worksScraped,
      wasCancelled: cancelled,
      error: error,
    );
  }

  /// 构造作品行。
  ///
  /// 刮削结果优先；没有就退到本地解析的标题与年份 —— 这样即使一个刮削器
  /// 都没配，媒体库里也有正常的标题，而不是一串文件名。
  ///
  /// ## 海报的两级来源
  ///
  /// `TMDB 海报` → `网盘缩略图`。第二级是本项目「无刮削也要有画面」的关键：
  /// 夸克给每个视频生成了服务端预览图（实测 640×360 WebP），
  /// 直接拿它当作品封面，媒体库就不再是一墙灰块。
  ///
  /// 顺序不能反：TMDB 的海报是**竖版作品海报**（2:3），网盘缩略图是
  /// **视频画面**（16:9）。有正规海报时用视频截图会显得很不专业。
  ///
  /// ⚠️ 两种来源的**比例不同**，所以换来源时必须同时换掉 `posterFaceX`
  /// 锚点（见下）：锚点是「视频帧里人物在哪」，拿去裁 2:3 的作品海报是错的。
  MediaWork _buildWork({
    required String key,
    required DriveProvider provider,
    required _WorkSeed seed,
    required ScrapedMetadata? meta,
  }) {
    // 取一次，避免下面两处各算一遍导致「地址用刮削的、锚点用网盘的」这种
    // 只有视觉上才看得出来的错配。
    final scrapedPoster = _nonEmpty(meta?.posterUrl);

    return MediaWork(
      key: key,
      provider: provider,
      kind: seed.kind,
      category: seed.category,
      title: meta?.title ?? seed.title,
      originalTitle: meta?.originalTitle,
      year: meta?.year ?? seed.year,
      overview: meta?.overview,
      posterUrl: scrapedPoster ?? seed.posterUrl,
      // 锚点跟着**实际用的那张图**走：
      //   - 用了刮削海报 → 它是 2:3 的竖版作品海报，铺满格子、不裁切，
      //     不需要锚点（拿视频帧的人脸位置去裁它只会裁错地方）；
      //   - 用了网盘缩略图 → 16:9 要裁成竖版，此时锚点才是「凸显人物」的依据。
      posterFaceX: scrapedPoster == null ? seed.posterFaceX : null,
      backdropUrl: meta?.backdropUrl,
      rating: meta?.rating,
      genres: meta?.genres ?? const [],
      onlineId: meta?.onlineId,
      source: meta?.source ?? ScrapeSource.local,
      scrapedAt: meta?.source == ScrapeSource.online ? _clock() : null,
      itemCount: seed.itemCount,
      totalBytes: seed.totalBytes,
      updatedAt: _clock(),
    );
  }

  static String? _nonEmpty(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  /// 拼接目录展示路径，保证以 `/` 开头、以 `/` 结尾。
  static String _joinPath(String base, String name) {
    if (base.isEmpty) return '/$name/';
    if (base.endsWith('/')) return '$base$name/';
    return '$base/$name/';
  }
}

/// 作品种子：遍历期累积的、与刮削无关的那部分信息。
class _WorkSeed {
  _WorkSeed({
    required this.kind,
    required this.title,
    required this.category,
    this.year,
  });

  final MediaKind kind;
  final String title;
  final int? year;

  /// 一级分类（电影 / 剧集 / 动漫 / 综艺 / 纪录片 / 其他）。
  ///
  /// 在**第一条**命中这个分组的文件上判定一次，之后不再改 —— 同一部剧的
  /// 每一集文件名可能差异很大（`S01E01` 有季集号、`SP` 特别篇没有），
  /// 逐集重判会让分类在「剧集」和「其他」之间跳。以第一条为准更稳定，
  /// 而第一条通常是最规整的那一集。
  final MediaCategory category;

  /// 网盘服务端缩略图地址（**未刮削时的封面兜底**）。
  ///
  /// 只取分组里的**第一条**有缩略图的 —— 一部剧几十集，每集都存一份地址
  /// 没有意义：作品海报只需要一张，而且用户认的是「这部剧」而不是「第 7 集
  /// 的那一帧」。
  ///
  /// 它只在**没有在线刮削海报**时才被用上（见 [_buildWork]）。
  ///
  /// ⚠️ 它和 [posterFaceX] 是**一对**，只在 `_walkDirectory` 里那一处 `if`
  /// 里一起赋值。构造函数故意不收这两个参数 —— 那样就会出现「构造时给了地址、
  /// 循环里再补锚点」这种半截状态，而它们描述的是同一张图。
  String? posterUrl;

  /// [posterUrl] 那张图里**人物所在的水平位置**（0~1），来自夸克人脸框。
  ///
  /// ⚠️ 与 [posterUrl] 是**一对**，必须同进同退：它们描述的是同一张图。
  /// 只换地址不换锚点 = 拿上一张图的人脸位置去裁这一张。
  double? posterFaceX;

  int itemCount = 0;
  int totalBytes = 0;
}
