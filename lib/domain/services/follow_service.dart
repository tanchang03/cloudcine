import '../../core/diagnostics/diag_log.dart';
import '../../data/db/settings_store.dart';
import '../adapters/media_repository.dart';
import '../entities/drive_provider.dart';
import 'follow_auto_check.dart';
import 'follow_plan.dart';
import 'media_discovery.dart';
import 'scan_service.dart';

/// 「发现一个目录」这件事的**最小接口** —— 追更检查只用到这一个能力。
///
/// ## 为什么不直接依赖 `MediaDiscoveryService`
///
/// 那个类需要一个 `DriveAdapterRegistry`（会去建 HTTP 适配器、读扫描策略），
/// 单测里造一个等于把半个应用启动起来。而追更检查真正要的只有一句话：
/// 「把这个目录（含子目录）过一遍，告诉我有没有失败」。
///
/// 抽成函数类型之后，单测可以直接塞一个 lambda 返回构造好的
/// [DiscoveryOutcome]，于是 [FollowPlan] 之外的判据（失败目录不推进水位线、
/// 按目录回写到多部作品）也能被钉住 —— 这几条恰恰是最容易写错、且错了
/// **不报错**的。
///
/// 组合根负责把它接到真实现上（`recursive: true`，见红线 3）。
typedef DiscoverDirectoryFn = Future<DiscoveryOutcome> Function({
  required String dirId,
  required String dirPath,
});

/// 检查进度快照（给页头按钮的转圈文案用）。
class FollowProgress {
  const FollowProgress({
    required this.done,
    required this.total,
    this.currentDir,
  });

  final int done;
  final int total;
  final String? currentDir;

  @override
  String toString() => 'FollowProgress($done/$total, ${currentDir ?? "-"})';
}

/// 一次追更检查的结果。
class FollowOutcome {
  const FollowOutcome({
    this.skipped = false,
    this.followedWorks = 0,
    this.dirsChecked = 0,
    this.dirsFailed = 0,
    this.worksChecked = 0,
    this.updatedWorks = 0,
    this.newItems = 0,
    this.cancelled = false,
    this.error,
  });

  /// 被节流窗口挡掉了（一次网盘请求都没发）。
  final bool skipped;

  /// 在追的作品数。
  final int followedWorks;

  /// 成功列完的目录数。
  final int dirsChecked;

  /// 列失败的目录数。**不为 0 时结果是不完整的**（那批作品的角标这次不更新）。
  final int dirsFailed;

  /// 本次**水位线被推进**的作品数（= 目录全部成功的那些）。
  final int worksChecked;

  /// 其中**真的查出有新集**的作品数（角标数字变了的那几部）。
  final int updatedWorks;

  /// 本次新发现的总条数（所有作品的增量之和）。
  final int newItems;

  final bool cancelled;

  /// 面向用户的失败原因（`null` = 正常跑完）。
  final String? error;

  /// 有东西要告诉用户吗（决定要不要弹提示 / 刷新）。
  ///
  /// ⛔ 「没查出更新」**不是**「有东西要说」—— 手动点一次检查、
  ///    什么都没变时弹一个「没有更新」是最典型的噪音。
  bool get hasNews => newItems > 0;

  /// 给状态行 / SnackBar 用的一句话。
  String get message {
    if (skipped) return '刚刚检查过，稍后再试';
    if (error != null) return '检查更新失败：$error';
    if (cancelled) return '检查已取消';
    if (newItems > 0) {
      return '有 $updatedWorks 部剧更新了（共 $newItems 集）';
    }
    if (dirsFailed > 0) {
      return '检查完成，但有 $dirsFailed 个目录没读到，下次会重试';
    }
    return '没有更新';
  }

  @override
  String toString() => 'FollowOutcome($message, 在追 $followedWorks, '
      '目录 $dirsChecked${dirsFailed == 0 ? "" : "/失败 $dirsFailed"}, '
      '推进 $worksChecked, 新增 $newItems)';
}

/// **追更检查**：把已追剧作品名下的目录各过一遍，算出「新入库了几条」。
///
/// ## 它解决什么问题
///
/// 网盘上用户追的剧更新了第 13 集。全盘扫描能发现，但代价是遍历几千个目录、
/// 几分钟、一次被限流的风险 —— 而这个动作在用户心里是「点一下看看有没有」。
///
/// 追更检查只列**已追剧作品名下的那几个目录**（去重后通常 1~5 个），
/// 秒级完成，而且**只增不减**：不写续扫游标、不做陈旧清理
/// （见 [DiscoverDirectoryFn] 的接线要求）。
///
/// ## 三条判据（全部基于已有的 `media_items.first_seen_at`）
///
/// ```
/// ① 「本次新扫到的条」   = first_seen_at > follow_checked_at   → 累加进角标
/// ② 「追剧以来新增的条」 = first_seen_at > follow_started_at   → 剧集行 NEW 标签
/// ③ 「这一集还没看过」   = max_position_ms IS NULL
/// ```
///
/// ② ∧ ③ 由 `MediaWork.isNewSinceFollow` 在**渲染时**现算，这里不写任何东西。
///
/// ⛔ **刻意不用 `media_items.modified_at`**：那是网盘给的文件修改时间，
///    **替换文件（换一版更高码率）也会变** —— 用它当判据会把「换了个版本」
///    误报成「更新了最新一集」。
class FollowService {
  FollowService({
    required MediaRepository library,
    required SettingsStore settings,
    required DiscoverDirectoryFn discoverDirectory,
    DateTime Function()? clock,
  })  : _library = library,
        _settings = settings,
        _discover = discoverDirectory,
        _clock = clock ?? DateTime.now;

  final MediaRepository _library;
  final SettingsStore _settings;
  final DiscoverDirectoryFn _discover;
  final DateTime Function() _clock;

  /// 是否有检查正在跑（防「连点两次检查更新」）。
  ///
  /// ⚠️ 与 `MediaDiscoveryService._active` 同一个道理，但它**跨调用真的有效**：
  /// 组合根持有的是同一个 [FollowService] 实例（不像 discovery 那样每次新建），
  /// 所以这个字段能拦住并发。真正的并发后果是「两次检查各自读到同一个水位线、
  /// 各自把增量写一遍」——角标会**翻倍**，而且不报错。
  bool _running = false;

  bool get isRunning => _running;

  /// 跑一次检查。
  ///
  /// @param force `true` = 手动入口：无视节流窗口、也无视 `follow_auto_check`
  ///   是不是 `off`（用户明确要求了）。
  /// @param cancel 协作式取消。取消**不回滚已经推进的水位线** ——
  ///   那部分是真实检查过的，留着是对的。
  Future<FollowOutcome> check({
    bool force = false,
    ScanCancellation? cancel,
    void Function(FollowProgress progress)? onProgress,
  }) async {
    if (_running) {
      diag.warn('追剧', '已有检查在进行中，跳过这次');
      return const FollowOutcome(skipped: true);
    }
    _running = true;
    try {
      return await _run(force: force, cancel: cancel, onProgress: onProgress);
    } finally {
      _running = false;
    }
  }

  Future<FollowOutcome> _run({
    required bool force,
    ScanCancellation? cancel,
    void Function(FollowProgress progress)? onProgress,
  }) async {
    final startedAt = _clock();

    // ---- 1. 节流闸 ----
    final policy = FollowAutoCheck.parse(
      await _settings.read(SettingKeys.followAutoCheck),
    );
    // ⛔⛔ `off` 必须**在这里**显式挡掉，不能只靠下面那个「窗口为 null 就跳过
    //      节流判断」。
    //
    // 两者的含义完全相反：
    //   * `off`      = 「不要自动跑」（用户明确关掉了）；
    //   * 窗口 null  = 「不节流」（想跑就跑）。
    // 把 `off` 也表达成 `throttleWindow == null`，于是设成「关闭」之后
    // **一次节流判断都不做** ⇒ 每次启动、每次进媒体库都真的去列网盘目录。
    // 症状是「我明明关了自动检查，它还在发请求」—— 而日志上一切正常。
    //
    // ⛔ 只挡自动路径：手动入口（`force`）本来就该无视这个开关，
    //    那是用户明确要求了（见类文档最后一条）。
    if (!force && policy == FollowAutoCheck.off) {
      diag.debug('追剧', '自动检查已关闭，跳过');
      return const FollowOutcome(skipped: true);
    }
    final window = policy.throttleWindow;
    if (!force && window != null) {
      final lastSec = await _settings.readInt(SettingKeys.followLastCheckAt);
      if (lastSec != null) {
        final elapsed = startedAt.difference(
          DateTime.fromMillisecondsSinceEpoch(lastSec * 1000),
        );
        if (elapsed < window) {
          diag.debug('追剧', '距上次检查 ${elapsed.inMinutes} 分钟，未到窗口，跳过');
          return const FollowOutcome(skipped: true);
        }
      }
    }

    // ---- 2. 追剧清单 ----
    //
    // ⛔ 空清单要**提前返回**：一部都没在追时，后面每一步都是零成本的空转，
    //    但第 4 步会真的去发网盘请求 —— 提前返回就是「一次请求都不发」。
    final keys = await _library.followedWorkKeys();
    if (keys.isEmpty) {
      await _markChecked(startedAt);
      diag.debug('追剧', '没有在追的作品，跳过');
      return const FollowOutcome(skipped: false);
    }

    // ---- 3. 目录集合（并集口径，含被折叠的源作品名下的文件）----
    final dirs = await _library.dirsForWorks(keys);
    final plan = FollowPlan.of(dirs);
    diag.info(
      '追剧',
      '开始检查：在追 ${keys.length} 部 · 目录 ${plan.requestCount} 个',
    );

    if (plan.requestCount == 0) {
      // 一部在追的作品一个目录都没有（文件行的 dir_id 全是空串）。
      // ⛔ **不能**推进它们的水位线：我们什么都没检查。
      await _markChecked(startedAt);
      return FollowOutcome(followedWorks: keys.length);
    }

    // ---- 4. 逐个目录跑局部发现 ----
    final failed = <String>{};
    var done = 0;
    var cancelled = false;
    for (final dir in plan.dirs) {
      if (cancel?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      done++;
      onProgress?.call(
        FollowProgress(done: done, total: plan.requestCount, currentDir: dir.dirPath),
      );
      try {
        final outcome = await _discover(
          dirId: dir.dirId,
          dirPath: dir.dirPath,
        );
        // ⛔ 判据是「这一次列目录完整吗」，不是「有没有新东西」。
        //    `failedDirs > 0` 时结果是不完整的（子目录超时/限流），
        //    那批新集可能正好在没读到的子目录里 —— 推进水位线等于把它们
        //    永久划进「已读」，用户再也不会被提醒，而且没有任何报错。
        if (!outcome.isComplete || outcome.failedDirs > 0) {
          failed.add(dir.dirId);
          diag.warn(
            '追剧',
            '目录未读完整，本次不推进水位线：${dir.dirPath}'
            '（跳过 ${outcome.failedDirs} 个子目录，取消=${outcome.wasCancelled}）',
          );
        }
      } catch (e) {
        // 单个目录失败不该毁掉整次检查 —— 其它目录的结果照样有效。
        failed.add(dir.dirId);
        diag.warn('追剧', '列目录失败：${dir.dirPath}（$e）');
      }
    }

    // ⛔⛔ 水位线取的是**发现跑完之后**的时刻，不是检查开始那一刻。
    //
    // 发现的产物是 `media_items.first_seen_at`（那一刻写进去的），而水位线
    // 是「我们已经看到这里了」的承诺。用**开始**时刻当水位线的话，这次检查
    // 自己刚插进去的那些行（`first_seen_at` 晚于开始时刻）在下一次检查里
    // 会**被再数一遍** —— 角标翻倍，而且不报错。
    //
    // 反过来用**结束**时刻也不会漏：这次数过的行 `first_seen_at <= 结束时刻`，
    // 下次的判据 `first_seen_at > 结束时刻` 对它们为假。
    //
    // ⚠️ 已知的 1 秒竞态：全库时间列都是**秒**，所以「恰好在结束那一秒里、
    //    且没被这次列目录看到」的新文件会被划进「已读」。要触发它需要一次
    //    并发的扫描/发现正好落在那一秒 —— 概率极低，且修它只能靠毫秒时间列
    //    （跨端契约，代价远大于收益）。
    final checkedAt = _clock();

    // ---- 5. 回写（一次事务）----
    //
    // ⛔ **按目录**回写，不是按「发起检查的那一部」：`/电影/` 是平铺的，
    //    一个目录含几十部作品。只回写发起者的话，同一个目录里同时更新的
    //    另外几部就永远收不到提醒。
    final checked = plan.checkedWorks(failed);
    var updatedWorks = 0;
    var newItems = 0;
    if (checked.isNotEmpty) {
      // ⚠️ 这里读的是**旧**水位线（还没写回去），所以「本次新增」的判据
      //    `first_seen_at > 旧水位线` 正好把这次发现插进来的行算进去。
      final counts = await _library.pendingNewItemCounts(checked.toList());
      final increments = <String, int>{};
      counts.forEach((key, n) {
        if (n > 0) increments[key] = n;
      });
      // ⛔ 即使 `increments` 是空的**也要写**：`checkedKeys` 的语义是
      //    「这些作品这次被完整检查过了」，水位线要跟着推进 —— 不推进的话
      //    下一次会把同一批老条目重新数一遍（而它们其实已经被数进角标了）。
      await _library.applyFollowCheck(
        increments: increments,
        checkedKeys: checked,
        checkedAt: checkedAt,
      );
      updatedWorks = increments.length;
      newItems = increments.values.fold<int>(0, (a, b) => a + b);
    }

    // ---- 6. 节流零点 ----
    await _markChecked(checkedAt);

    final outcome = FollowOutcome(
      followedWorks: keys.length,
      dirsChecked: plan.requestCount - failed.length,
      dirsFailed: failed.length,
      worksChecked: checked.length,
      updatedWorks: updatedWorks,
      newItems: newItems,
      cancelled: cancelled,
    );
    diag.info('追剧', '检查结束：$outcome');
    return outcome;
  }

  /// 推进全局节流零点。
  ///
  /// ⛔ 放在 `settings` 表（`follow_last_check_at`），**不是** `media_works`
  ///    的任何一列 —— 同步判据 `libraryModifiedAt` 不含 `settings` 表，
  ///    写它不会让本机「看起来更新」。写进 `media_works` 的话，每次自动检查
  ///    都会改同步判据，本机永远赢下 LWW 比较、把另一台设备的进度盖掉。
  Future<void> _markChecked(DateTime now) => _settings.write(
        SettingKeys.followLastCheckAt,
        (now.millisecondsSinceEpoch ~/ 1000).toString(),
      );
}

/// 组合根接线用的小工具：把 `MediaDiscoveryService` 适配成
/// [DiscoverDirectoryFn]，并**强制** `recursive = true`。
///
/// ⛔ `recursive` **必须**为真：剧集常在 `S01/` 子目录里，只看一层会永远
///    发现不了新集（红线 3）。把它写死在这里，是为了让调用点没有机会传错 ——
///    传成 `false` 的后果是「有的剧就是不提醒」，而检查日志一切正常。
///
/// ## `buildService` 为什么是异步的
///
/// `MediaDiscoveryService` 要一个已经解析好的 `ScanPolicy`（并发数 / 限速），
/// 而那个策略是**读设置**得来的（`buildScanPolicy` 是 `Future`）。
/// `DiscoveryController` 那边同样是「每次任务现读一次策略再建服务」——
/// 缓存一份的话，用户在设置页改了并发数要重启 App 才生效。
DiscoverDirectoryFn followDiscoveryAdapter({
  required Future<MediaDiscoveryService> Function() buildService,
  required DriveProvider provider,
}) {
  return ({required String dirId, required String dirPath}) async {
    final service = await buildService();
    return service.discoverDirectory(
      provider,
      dirId: dirId,
      dirPath: dirPath,
      recursive: true,
    );
  };
}
