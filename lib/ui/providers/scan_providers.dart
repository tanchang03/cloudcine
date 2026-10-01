import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/drive_error.dart';
import '../../data/db/settings_store.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/entities/scan_policy.dart';
import '../../domain/services/scan_service.dart';
import 'app_providers.dart';
import 'library_providers.dart';
import 'library_refresh_providers.dart';
import 'scrape_providers.dart';
import 'settings_providers.dart';

/// 按用户设置构造扫描策略。
///
/// **全盘扫描与文件夹里的「发现媒体」共用这一份** —— 两处各读一遍设置的话，
/// 用户把「请求间隔」从 350ms 调到 1000ms 只会对其中一条路径生效，
/// 另一条会继续按旧值打网盘，而用户完全无从发现。
Future<ScanPolicy> buildScanPolicy(Ref<Object?> ref) async {
  final settings = ref.read(settingsStoreProvider);

  // 一次批量读，避免几个串行的 SQLite 往返。
  final values = await settings.readAll(const [
    SettingKeys.scanIntervalMs,
    SettingKeys.scanMaxDepth,
  ]);

  final intervalMs = int.tryParse(values[SettingKeys.scanIntervalMs] ?? '') ?? 350;
  final maxDepth = int.tryParse(values[SettingKeys.scanMaxDepth] ?? '') ?? 12;

  return ScanPolicy(
    maxDepth: maxDepth,
    minRequestInterval: Duration(milliseconds: intervalMs),
    // ⚠️ **必须显式关掉**。`ScanPolicy` 的默认值是 `audioOnly: true`
    // （那份配置继承自音频项目），开着会只索引音频文件，
    // 视频库扫完会一条都不剩 —— 而且**不报错**。
    audioOnly: false,
  );
}

/// 构造一次扫描用的 [ScanService]。
///
/// ## 为什么不做成常驻 Provider
///
/// 它的构造依赖**异步读出来的设置**（节流间隔、最大深度），而 Riverpod 的
/// 同步 `Provider` 拿不到这些值。硬塞一个「启动时读一次的缓存快照」会让
/// 「改了设置但没生效」变成一个**静默** bug。
///
/// 每次扫描重建的开销可以忽略（就是几个对象），而 `isRunning` /
/// `lastProgress` 这类状态由 [ScanController] 自己持有，不依赖服务实例。
///
/// ## 刮削器来自 [scraperPipelineProvider]（长期存活的那个）
///
/// 不在这里现 new 一套：`TmdbScraper` 的熔断与 `DoubanScraper` 的 `103`
/// 熔断都挂在实例上，每次扫描重建会把它们清零。而「扫描期自动刮削」
/// 默认是关的，所以扫描多半根本不碰它们 —— 详情页那个按钮用的才是同一套
/// 实例，熔断状态要在那里延续。
Future<ScanService> buildScanService(Ref<Object?> ref) async {
  return ScanService(
    registry: ref.read(adapterRegistryProvider),
    library: ref.read(mediaRepositoryProvider),
    scraper: ref.read(scraperPipelineProvider),
    policy: await buildScanPolicy(ref),
  );
}

/// 扫描状态快照。
class ScanState {
  const ScanState({
    this.running = false,
    this.progress,
    this.outcome,
    this.error,
  });

  final bool running;

  /// 扫描中的实时进度。仅在 [running] 为真时有值。
  final ScanProgress? progress;

  /// 上一次扫描的结果。
  final ScanOutcome? outcome;

  /// 上一次扫描的失败原因（面向用户）。
  final String? error;

  /// 当前阶段。**没在扫描时是 `null`**，而不是硬塞一个 `idle` ——
  /// `ScanPhase` 只描述「扫描中的哪一步」，给它加个 `idle` 会让
  /// 「正在收尾」和「还没开始」在类型上无法区分。
  ScanPhase? get phase => progress?.phase;

  /// 是否已经跑过至少一次（决定空态显示「开始扫描」还是「上次结果」）。
  bool get hasRun => outcome != null || error != null;

  @override
  String toString() => 'ScanState(running=$running, phase=${phase?.name ?? "-"}, '
      'error=${error ?? "-"})';
}

/// 扫描控制器。
///
/// 只做三件事：**发起、转播进度、取消**。真正的扫描逻辑在
/// [ScanService]（无 UI 依赖，可单测），进度落库在仓储层。
class ScanController extends Notifier<ScanState> {
  ScanCancellation? _cancel;
  bool _disposed = false;

  @override
  ScanState build() {
    // 重建时 `onDispose` 会先把上一轮的实例标记为已销毁，
    // 所以这里必须**复位** —— 否则热重载/失效一次之后，
    // 所有进度回调都会被 `_emit` 静默丢掉，进度条永远不动。
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const ScanState();
  }

  /// 请求停止。协作式：在目录/页边界生效，不会立刻中断。
  void cancel() => _cancel?.cancel();

  /// 开始一次扫描。
  ///
  /// [resume] 为真时从上次的续扫游标继续（上次已扫完会自动重新开始）。
  /// [pruneStale] 为真时在**完整扫完**后清理网盘侧已删除的记录。
  ///
  /// ## 为什么没有 `scrape` 参数了
  ///
  /// 「扫描完要不要刮削」从「本次扫描的选项」变成了**全局设置**
  /// （`autoScrapeOnScan`，默认关）。理由：豆瓣的匿名额度只有约 10 个搜索词，
  /// 全盘自动刮必然中途耗尽并让这个 IP 短期不可用。刮削的默认入口因此改到
  /// 详情页的「刮削」按钮，扫描只负责建索引。
  ///
  /// 由这里读设置而不是让页面传参，是为了让「重试」那条路径也自动遵循同一个
  /// 决定 —— 页面传参时漏传一处就会静默地不刮（或反过来）。
  Future<void> start({
    bool resume = true,
    bool pruneStale = true,
  }) async {
    if (state.running) return;

    final settings = ref.read(settingsProvider).valueOrNull;
    final autoScrape = settings?.canAutoScrape ?? false;

    final token = ScanCancellation();
    _cancel = token;
    _emit(const ScanState(running: true));

    try {
      final service = await buildScanService(ref);
      final outcome = await service.scan(
        DriveProvider.quark,
        resume: resume,
        pruneStale: pruneStale,
        scrape: autoScrape,
        cancel: token,
        onProgress: (p) => _emit(ScanState(running: true, progress: p)),
      );
      _emit(ScanState(outcome: outcome));
      if (!_disposed) {
        await ref
            .read(settingsStoreProvider)
            .writeDateTime(SettingKeys.lastScanAt, DateTime.now());
      }
    } on DriveException catch (e) {
      _emit(ScanState(error: _explain(e)));
    } catch (e) {
      _emit(ScanState(error: '扫描失败：$e'));
    } finally {
      _cancel = null;
      // 扫描改变了索引库，媒体库列表与统计必须重取。
      // 放在 `finally` 里：**取消和失败也改过库**（每页都落盘了），
      // 只刷新成功路径会让取消后列表停在旧数据上。
      if (!_disposed) {
        // 推一下「库刚被写过」的信号：目录视图的「已入库」标记读的是同一张表，
        // 不推的话用户扫完回到目录视图，看到的还是扫描前的标记。
        ref.read(libraryWriteSignalProvider.notifier).bump();
        ref.invalidate(workListProvider);
        ref.invalidate(libraryStatsProvider);
        // 「最近播放」的角标也要跟着重取：清理陈旧条目会删掉一些播过的
        // 作品行（网盘侧已删除的文件）。
        ref.invalidate(playedCountProvider);
        // 三个筛选角标同样会变：新扫进来的作品带着新的分类 / 年份 / 类型。
        // 少一个的话，用户扫完 100 部电影，筛选面板上「电影」还是旧数字，
        // 看起来像「筛选没生效」。
        ref.invalidate(categoryCountsProvider);
        ref.invalidate(decadeCountsProvider);
        ref.invalidate(genreCountsProvider);
      }
    }
  }

  void _emit(ScanState next) {
    if (_disposed) return;
    state = next;
  }

  static String _explain(DriveException e) => switch (e.type) {
        DriveErrorType.unauthorized => '登录已失效，请重新扫码登录夸克账号',
        DriveErrorType.rateLimited => '请求过于频繁，被夸克限流了，请稍后再试',
        DriveErrorType.network => '网络不可用，请检查网络连接',
        _ => e.message,
      };
}

final scanControllerProvider =
    NotifierProvider<ScanController, ScanState>(ScanController.new);
