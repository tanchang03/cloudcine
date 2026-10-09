import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/drive_error.dart';
import '../../data/db/settings_store.dart';
import '../../domain/entities/scan_policy.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/services/scan_service.dart';
import '../../domain/services/work_merge_service.dart';
import 'app_providers.dart';
import 'auth_providers.dart';
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
  // 自动归一由设置决定**传不传**服务，而不是传一个开关进去 ——
  // 与 `scraper` 同一种做法，领域层因此完全不知道「设置」这回事。
  //
  // ⚠️ 读设置失败时**不**降级成「默认开」：宁可这次不归一（下次扫描
  // 还会再跑一遍），也不要在一个读不出设置的环境里动用户的库。
  final settings = ref.read(settingsProvider).valueOrNull;
  final autoMerge = settings?.autoMergeByOnlineId ?? false;

  return ScanService(
    registry: ref.read(adapterRegistryProvider),
    library: ref.read(mediaRepositoryProvider),
    scraper: ref.read(scraperPipelineProvider),
    merger: autoMerge
        ? WorkMergeService(library: ref.read(mediaRepositoryProvider))
        : null,
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

  /// 上一次「实时刷新列表」时看到的命中媒体数。判据是**它变了没有** ——
  /// 一路扫下来没有新媒体项时（都是图片 / 其它文件），库没有任何变化，
  /// 重取列表纯属白跑。
  int _liveTracks = 0;

  /// 上一次实时刷新的时刻。给高频的 `onProgress` 加一道时间闸门。
  DateTime? _liveRefreshedAt;

  /// 两次实时刷新之间的最小间隔。
  ///
  /// 小目录多的时候目录边界会一个接一个推进度，不节流就是几千次全表查询。
  /// 400ms 在「看着卡片一批批长出来」与「别把库查爆」之间取一个折中。
  static const Duration _liveRefreshInterval = Duration(milliseconds: 400);

  @override
  ScanState build() {
    // 重建时 `onDispose` 会先把上一轮的实例标记为已销毁，
    // 所以这里必须**复位** —— 否则热重载/失效一次之后，
    // 所有进度回调都会被 `_emit` 静默丢掉，进度条永远不动。
    _disposed = false;
    _liveTracks = 0;
    _liveRefreshedAt = null;
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
  /// 这次扫描扫**哪一家网盘**。
  ///
  /// ## ⛔ 为什么它必须是一个参数，而不是「当前网盘」
  ///
  /// 多家网盘同时在线，扫描器一次只能扫一家（`ScanService.scan` 收
  /// `DriveProvider`）。用「当前网盘」会让「登录了百度，扫出来的却是夸克的
  /// 目录」成为可能 —— 而那份会话可能早就失效了，表现是「扫描一直失败」。
  ///
  /// 由页面把选择传进来（见 `scanDriveProvider`），控制器不替用户决定。
  Future<void> start({
    bool resume = true,
    bool pruneStale = true,
    required DriveProvider provider,
  }) async {
    if (state.running) return;

    // 新一轮扫描：实时刷新的两道闸门各自复位 —— 上一次扫描的命中数若恰好
    // 等于这一轮的第一个值，不复位就会把「第一批作品」这次刷新吞掉。
    _liveTracks = 0;
    _liveRefreshedAt = null;

    final settings = ref.read(settingsProvider).valueOrNull;
    final autoScrape = settings?.canAutoScrape ?? false;

    final token = ScanCancellation();
    _cancel = token;
    _emit(const ScanState(running: true));

    try {
      final service = await buildScanService(ref);
      final outcome = await service.scan(
        provider,
        resume: resume,
        pruneStale: pruneStale,
        scrape: autoScrape,
        cancel: token,
        onProgress: (p) {
          _emit(ScanState(running: true, progress: p));
          // 边扫边刷：媒体库列表跟着一批批长出来，而不是等整次扫描结束。
          _liveRefresh(p);
        },
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
        ref.invalidate(yearCountsProvider);
        ref.invalidate(genreCountsProvider);
      }
    }
  }

  /// 扫描进行中，把「库里又长出了新作品」推给媒体库列表。
  ///
  /// ## 为什么需要它
  ///
  /// `ScanService` 每到一个目录边界就把这一批新分组写成作品行（「边扫边看」），
  /// 但媒体库列表原先只在**整次扫描结束**时才重取 —— 扫一个几千目录的大库要
  /// 几十分钟，期间媒体库页面一直显示扫描前的样子，看起来像卡死了。
  /// 现在扫到一批就刷一次，卡片一批批长出来。
  ///
  /// ## 两道闸门，缺一不可
  ///
  ///   - **命中媒体数变了**（见 [_liveTracks]）：没扫到新媒体项时库没变；
  ///   - **距上次刷新 ≥ [_liveRefreshInterval]**：给目录边界的密集推进度节流。
  ///
  /// 只推 [libraryListSignalProvider]，**不碰三组角标**：那三组各自是一次全表
  /// `GROUP BY`，每 400ms 跑一遍会把扫描拖慢。角标仍由 `finally` 那一段在
  /// 扫描结束后统一作废（那里也补了 `libraryWriteSignalProvider`，
  /// 目录视图的「已入库」标记同样要跟着更新）。
  void _liveRefresh(ScanProgress p) {
    if (_disposed) return;
    // `foundMedia` = 游标里的 `foundTracks`（累计命中的媒体项数）。
    if (p.foundMedia == _liveTracks) return;

    final now = DateTime.now();
    final last = _liveRefreshedAt;
    if (last != null && now.difference(last) < _liveRefreshInterval) return;

    _liveTracks = p.foundMedia;
    _liveRefreshedAt = now;
    ref.read(libraryListSignalProvider.notifier).bump();
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

/// 扫描页**正在扫哪一家网盘**。
///
/// ## 为什么它与「浏览」是两个独立的选择
///
/// 两者都是「一次只服务一家」的操作（扫描器一次扫一家、目录树一次显示
/// 一棵），但它们是**两件不同的事**：用户在扫描页选百度，不该把文件夹
/// 视图也带过去 —— 那边可能正看着夸克的某棵子树找东西。
///
/// 与 `browseDriveChoiceProvider` 同口径：内存态、默认跟随第一家有账号的。
class ScanDriveController extends Notifier<DriveProvider?> {
  @override
  DriveProvider? build() => null;

  void select(DriveProvider provider) => state = provider;
}

final scanDriveChoiceProvider =
    NotifierProvider<ScanDriveController, DriveProvider?>(
  ScanDriveController.new,
);

/// 扫描页真正会扫的那一家。
final scanDriveProvider = Provider<DriveProvider>((ref) {
  final chosen = ref.watch(scanDriveChoiceProvider);
  final connected = ref.watch(connectedDrivesProvider);
  if (chosen != null && connected.contains(chosen)) return chosen;
  return connected.isEmpty ? DriveProvider.quark : connected.first;
});
