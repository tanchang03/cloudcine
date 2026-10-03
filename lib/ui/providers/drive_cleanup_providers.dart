import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/services/drive_cleanup.dart';
import 'app_providers.dart';
import 'auth_providers.dart';
import 'drive_browse_providers.dart';
import 'library_providers.dart';

/// 批量删除的进度快照。
class DriveCleanupState {
  const DriveCleanupState({
    this.running = false,
    this.done = 0,
    this.total = 0,
  });

  final bool running;

  /// 已经处理完的条目数（成功的 + 失败的）。
  final int done;

  /// 这次要处理的总条目数。
  final int total;

  bool get hasProgress => running && total > 0;

  @override
  String toString() => 'DriveCleanupState(running=$running, $done/$total)';
}

/// 一次批量删除的结果。
///
/// 三个数字都必须如实带到界面上 —— 这是本项目反复踩过的那类坑：
/// 「删了一部分」被说成「删除完成」，用户在列表里还看得见剩下的那些，
/// 只会以为界面没刷新，然后再点一次删除。
class DriveCleanupOutcome {
  const DriveCleanupOutcome({
    required this.plan,
    required this.deleted,
    required this.failed,
    required this.libraryRemoved,
    this.fatalError,
  });

  final DriveDeletePlan plan;

  /// 网盘侧确认删掉的条目数。
  final int deleted;

  /// 失败的条目数（含因致命错误**没发出去**的那些批次）。
  final int failed;

  /// 顺带从本地媒体库索引里移除的条数。
  ///
  /// 与 [deleted] 不是一回事：删掉的可能是字幕、图片、还没入库的片子，
  /// 那些在索引里本来就没有行。
  final int libraryRemoved;

  /// 撞上「再试也没用」的错误（凭证失效 / 网络断了）时的说明。
  ///
  /// 非空表示后面几批**根本没发出去** —— 界面必须说出来，否则用户会以为
  /// 那些是「网盘拒绝删」，而实际是「这次没试」。
  final String? fatalError;

  /// 结果提示文案。
  String get message {
    final base = plan.deletedMessage(deleted: deleted, failed: failed);
    return fatalError == null ? base : '$base $fatalError';
  }

  @override
  String toString() => 'DriveCleanupOutcome(deleted=$deleted, '
      'failed=$failed, libraryRemoved=$libraryRemoved)';
}

/// 网盘批量删除（目录视图的多选删除走这里）。
///
/// ## 它比「调一次 deleteFiles」多做的三件事
///
///   1. **分块**。夸克没有公开删除接口的规模上限，一次带几千个 fid 的请求
///      一旦超时，用户什么信息都拿不到。见 [DriveDeletePlan.maxIdsPerRequest]。
///   2. **顺带清理本地媒体库索引**。删掉一部片子之后，海报墙上那张卡片还
///      挂着、点下去只会报「文件打不开了」—— 那是用户完全没预期的后果
///      （他删的是网盘上的文件，凭什么媒体库里还留着一条死索引）。
///      复用的是「播放时发现文件没了」那条已经存在的移除路径
///      （`MissingMediaController`），所以字幕引用、续播点、播放偏好、
///      作品计数这些旁表的口径与那边**完全一致**。
///   3. **刷新容量**。用户做这件事的动机就是「腾空间」，不刷新的话页头那条
///      容量条会一直显示删之前的数字 —— 那正是他此刻唯一盯着看的数字。
///
/// ## 为什么删完要重列当前目录，而不是从列表里抠掉那几行
///
/// 抠掉是本地推断，而**网盘上到底删没删掉**只有服务端知道：分块删除里
/// 失败的批次、夸克自己保留的目录项，都会让本地列表与服务端不一致。
/// 一次请求换「看到的一定是网盘上现在的内容」，这个项目的目录视图一直是
/// 这个口径（见 `driveListingProvider` 的注释）。
class DriveCleanupController extends Notifier<DriveCleanupState> {
  @override
  DriveCleanupState build() => const DriveCleanupState();

  /// 现在能不能发起一次删除。
  bool get canStart => !state.running;

  /// 删除 [plan] 里的全部条目（它们都在 [crumb] 这一层下面）。
  ///
  /// 返回 `null` 表示**什么都没做**（计划为空、正在跑、或没有可用适配器）。
  /// 调用方据此决定要不要弹结果提示 —— 返回一个「删了 0 项」的提示会让
  /// 用户以为失败了。
  Future<DriveCleanupOutcome?> delete({
    required DriveCrumb crumb,
    required DriveDeletePlan plan,
  }) async {
    if (plan.entries.isEmpty || state.running) return null;

    final adapter =
        ref.read(adapterRegistryProvider).adapterFor(browseProvider);
    if (adapter == null) {
      diag.warn('文件', '批量删除：夸克适配器未注册');
      return null;
    }

    state = DriveCleanupState(running: true, total: plan.count);

    final deletedIds = <String>[];
    var failed = 0;
    String? fatal;

    final chunks = plan.idChunks();
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      try {
        final ok = await adapter.deleteFiles(fileIds: chunk);
        deletedIds.addAll(ok);
        diag.info('文件', '批量删除第 ${i + 1}/${chunks.length} 批：'
            '${ok.length} 项');
      } on DriveException catch (e) {
        failed += chunk.length;
        diag.warn('文件', '批量删除第 ${i + 1}/${chunks.length} 批失败：'
            '${e.message}');

        // ⚠️ 凭证失效 / 网络断了这类错误**不是按批次的** —— 后面每一批都
        // 会以同样的方式失败。继续打下去只有两个后果：几十个注定失败的
        // 请求，以及把夸克那条本来就紧的限流线再顶一下。所以直接停，
        // 并且把**没发出去的**那些也算进失败数：它们确实没删掉，
        // 报告成「成功」是撒谎。
        if (e.needsReauth || e.type == DriveErrorType.network) {
          fatal = _explain(e);
          for (var j = i + 1; j < chunks.length; j++) {
            failed += chunks[j].length;
          }
          break;
        }
      } catch (e) {
        failed += chunk.length;
        diag.warn('文件', '批量删除第 ${i + 1}/${chunks.length} 批异常：$e');
      }
      state = DriveCleanupState(
        running: true,
        done: deletedIds.length + failed,
        total: plan.count,
      );
    }

    final libraryRemoved = await _purgeLibrary(
      crumb: crumb,
      plan: plan,
      deletedIds: deletedIds,
    );

    // 重列这一层。父层不在这里作废：用户就在这一层，而 `autoDispose` 的
    // family 让他回头往上走时本来就会重新请求一次。
    ref.invalidate(driveListingProvider(crumb));

    // 容量条重取 —— 用户按这个按钮的动机里「我刚删完东西」占一大半，
    // 而容量恰恰是那件事唯一会变的数字。
    await ref.read(authControllerProvider.notifier).refreshAccount();

    state = const DriveCleanupState();
    return DriveCleanupOutcome(
      plan: plan,
      deleted: deletedIds.length,
      failed: failed,
      libraryRemoved: libraryRemoved,
      fatalError: fatal,
    );
  }

  /// 把成功删掉的那些条目对应的**本地索引行**也清掉，返回清掉几条。
  ///
  /// ## 两条路径，因为「一个目录」在索引里不是一个 id
  ///
  ///   - **文件**：索引行是按 fid 建的主键（`MediaItem.idFor`），点查即可；
  ///   - **目录**：索引里**没有目录这个概念** —— 它记的是文件在哪个
  ///     `dirPath` 下。所以只能按路径前缀把整棵子树捞出来。漏了这一条，
  ///     用户删掉一个剧集目录之后，那一季几十集会在库里全部变成死索引。
  ///
  /// ⚠️ 只处理**删除请求成功**的那些（`deletedIds`）。失败的批次如果也
  /// 照清，用户会得到「文件还在网盘上，媒体库里却没了」—— 要回来得重扫。
  ///
  /// 「请求成功」不等于「网盘上一定没了」（见 `deleteFiles` 的返回值说明）。
  /// 那种偏差是**可以自我修复**的：清掉的索引行下次扫描会重新建回来；
  /// 反过来（留一条指向已删文件的死索引）则要等用户点到它才暴露。
  /// 所以这里宁可清早，不可清晚。
  Future<int> _purgeLibrary({
    required DriveCrumb crumb,
    required DriveDeletePlan plan,
    required List<String> deletedIds,
  }) async {
    if (deletedIds.isEmpty) return 0;

    final repo = ref.read(mediaRepositoryProvider);
    final gone = deletedIds.toSet();
    final doomed = <String, MediaItem>{};

    for (final entry in plan.entries) {
      if (!gone.contains(entry.id)) continue;

      if (entry.isDirectory) {
        // 用 `crumb.child(dir).path` 而不是 `entry.path`：后者只有扫描器
        // 遍历时才会填（`DriveEntry.path` 的文档），列目录拿到的条目里
        // 它通常是 null —— 静默地什么都匹配不到，而那些索引行会留下来。
        final prefix = crumb.child(entry).path;
        for (final item in await repo.listItems(pathPrefix: prefix)) {
          doomed[item.id] = item;
        }
        continue;
      }

      final item = await repo.itemById(MediaItem.idFor(browseProvider, entry.id));
      // 非视频文件（字幕 / 图片 / 压缩包）在索引里本来就没有行，查不到是
      // 正常情况，不是错误。
      if (item != null) doomed[item.id] = item;
    }

    if (doomed.isEmpty) return 0;
    final n = await ref
        .read(missingMediaControllerProvider)
        .removeMany(doomed.values);
    diag.info('媒体库', '批量删除后清理索引：$n 条（共匹配 ${doomed.length} 条）');
    return n;
  }

  static String _explain(DriveException e) => switch (e.type) {
        DriveErrorType.unauthorized => '登录已失效，剩下的没删（请重新登录后再试）。',
        DriveErrorType.network => '网络中断，剩下的没删（请检查网络后再试）。',
        _ => e.message,
      };
}

final driveCleanupControllerProvider =
    NotifierProvider<DriveCleanupController, DriveCleanupState>(
  DriveCleanupController.new,
);
