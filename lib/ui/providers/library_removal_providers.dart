import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/services/drive_batch.dart';
import '../../domain/services/library_batch_delete.dart';
import 'app_providers.dart';
import 'auth_providers.dart';
import 'library_providers.dart';

/// 一次「媒体库批量移除」的结果。
class LibraryRemovalOutcome {
  const LibraryRemovalOutcome({required this.removedItems, this.drive});

  /// 真正从库里删掉的文件行数。
  final int removedItems;

  /// 网盘那一侧的账；没勾「一并删」时为 `null`（**不是** `deleted: 0`）。
  ///
  /// 这个区别很重要：`null` 表示「这次没打算删网盘」，提示里该说「网盘
  /// 文件未动」；而 `deleted: 0, failed: 0` 是「想删但一个文件都没匹配到」，
  /// 说成「未动」会让用户以为自己的勾选没生效。
  final DriveRemovalSummary? drive;

  @override
  String toString() =>
      'LibraryRemovalOutcome(removed=$removedItems, drive=$drive)';
}

/// 「这批作品名下的网盘文件，几个能删、几个删不了」。
class DriveFileTally {
  const DriveFileTally({required this.deletable, required this.undeletable});

  /// 落在**可写**网盘上的文件数 —— 勾「一并删网盘」时会被删掉的正是这些。
  final int deletable;

  /// 落在**只读**网盘（百度）上的文件数 —— 只能从媒体库移除。
  final int undeletable;

  @override
  String toString() =>
      'DriveFileTally(deletable=$deletable, undeletable=$undeletable)';
}

/// 媒体库批量移除的执行者 —— 把「勾了什么」变成「库里、网盘上各动了什么」。
///
/// ## 顺序：先删网盘，再删索引（⛔ 不能反过来）
///
/// 索引一删，`itemsForWork` 就查不到那些文件了 —— 网盘的 fid 只存在
/// `media_items` 里（`provider:fileId`），没有第二份。反过来先删网盘再删
/// 索引，才拿得到要删的 fid。
///
/// ## 网盘删失败了，索引还删不删？**删**
///
/// 用户点的是「从媒体库移除」，勾上「一并删网盘」只是**加**一个动作。
/// 让主操作因为附加动作失败而变成空操作，用户会看到「点了没反应」。
/// 代价是失败的那些文件仍留在网盘上、下次扫描又出现在库里 —— 这正好是
/// 可以自愈的方向（与 `DriveCleanupController._purgeLibrary` 里「宁可
/// 清早，不可清晚」同一条思路），而提示里会把失败数如实说出来。
///
/// ## 为什么按 provider 分组
///
/// 多网盘并存（见 `AuthState`），每家一个适配器。混在一批里删是不可能的
/// —— `deleteFiles` 是某一家网盘的方法。
class LibraryRemovalController {
  LibraryRemovalController(this._ref);

  final Ref _ref;

  /// 移除 [keys] 这几部作品；[alsoDeleteFromDrive] 为真时先把它们名下的
  /// 网盘文件删掉。
  ///
  /// 不返回 `null`：这条路径没有「什么都没做」的合法情形（对话框已经确认
  /// 过一次），调用方总是要弹一句结果提示。
  ///
  /// [onProgress] 只在这条路走起来之后才会被调（删网盘可能几十秒，界面
  /// 上那层模态进度靠它驱动）。不传就等于「没人看」，内部照常干活。
  Future<LibraryRemovalOutcome> remove({
    required Iterable<String> keys,
    bool alsoDeleteFromDrive = false,
    void Function(RemovalProgress progress)? onProgress,
  }) async {
    final keyList = keys.toSet();
    // ⛔ 网盘那一步必须在 `removeWorks` 之前：它会清掉 `media_items` 里
    //    那些行，而 fid 只存在那里。
    final drive =
        alsoDeleteFromDrive ? await _deleteFromDrive(keyList, onProgress) : null;

    // 网盘删完、索引还没清 —— 这一句必须报：进度条这时正好满格，用户会
    // 以为已经结束了，而库里那几部其实还在。换句话告诉他还有一步。
    //
    // 只在真删过网盘时才报：没删网盘的话整件事就是本地的几十毫秒，报这一
    // 句只会让调用方以为「有东西在跑」。
    if (drive != null) {
      onProgress?.call(const RemovalProgress(phase: RemovalPhase.library));
    }

    final removed = await _ref
        .read(missingMediaControllerProvider)
        .removeWorks(keyList);

    if (drive != null && drive.deleted > 0) {
      // 容量条重取：用户勾「一并删」的动机就是腾空间，而页头那个数字正是
      // 他此刻唯一盯着看的东西。`refreshAccount` 内部已经吞掉所有异常，
      // 这里不会把一次成功的删除变成失败。
      await _ref.read(authControllerProvider.notifier).refreshAccount();
    }

    return LibraryRemovalOutcome(removedItems: removed, drive: drive);
  }

  /// 数一下这几部作品名下**能删 / 不能删**的网盘文件各有多少。
  ///
  /// 弹窗要在**用户勾之前**就把「会删几个」写出来，而那个数字必须与
  /// [_deleteFromDrive] 实际会去删的集合**同一口径**（同一份 `itemsForWork`
  /// 并集 + 同一条 `canWrite` 判断）。两处各写一遍的话，界面说 24 个、
  /// 实际删 22 个，而用户没有任何办法发现 —— 所以两边共用 [_itemsOf]。
  Future<DriveFileTally> tally(Iterable<String> keys) async {
    final items = await _itemsOf(keys.toSet());
    var deletable = 0;
    var undeletable = 0;
    for (final item in items) {
      if (_canDelete(item.provider)) {
        deletable++;
      } else {
        undeletable++;
      }
    }
    return DriveFileTally(deletable: deletable, undeletable: undeletable);
  }

  /// 这几部作品名下的**全部**媒体项（并集口径），按 id 去重。
  ///
  /// 去重不是洁癖：勾选里同时有别名行和它的目标作品时，同一集会被两次
  /// `itemsForWork` 拿到，重复的 fid 会让「删了几个」虚高、也会让同一批
  /// 请求里出现两个相同的 id。
  Future<List<MediaItem>> _itemsOf(Set<String> keys) async {
    final repo = _ref.read(mediaRepositoryProvider);
    final byId = <String, MediaItem>{};
    for (final key in keys) {
      for (final item in await repo.itemsForWork(key)) {
        byId[item.id] = item;
      }
    }
    return byId.values.toList(growable: false);
  }

  /// 这家网盘的文件**现在**能不能删。
  ///
  /// 只读网盘（百度）在这里被判掉，**不计入失败**：`LibraryBatchDeletePlan`
  /// 在弹窗里已经把它们从「会删的文件数」里摘掉，并单独说过一句
  /// 「只会从媒体库移除」。算进失败数会让提示自相矛盾。
  bool _canDelete(DriveProvider provider) {
    final adapter = _ref.read(adapterRegistryProvider).adapterFor(provider);
    return adapter != null && adapter.capabilities.canWrite;
  }

  /// 删掉这几部作品名下的**全部**网盘文件（并集口径），返回账目。
  Future<DriveRemovalSummary> _deleteFromDrive(
    Set<String> keys,
    void Function(RemovalProgress progress)? onProgress,
  ) async {
    final registry = _ref.read(adapterRegistryProvider);

    final byProvider = <DriveProvider, List<String>>{};
    var skipped = 0;
    for (final item in await _itemsOf(keys)) {
      if (!_canDelete(item.provider)) {
        skipped++;
        continue;
      }
      (byProvider[item.provider] ??= <String>[]).add(item.fileId);
    }
    if (skipped > 0) {
      diag.info('媒体库', '批量删除：$skipped 个文件所在网盘不支持删除，已跳过');
    }
    if (byProvider.isEmpty) {
      return const DriveRemovalSummary(deleted: 0, failed: 0);
    }

    // 分母在**发第一批之前**就要定下来：等删到一半才知道总数，进度条就
    // 会先从「不确定」跳到 12/40，用户会以为刚才那几批白删了。
    var total = 0;
    for (final fids in byProvider.values) {
      total += fids.length;
    }
    var done = 0;
    void report() => onProgress?.call(
          RemovalProgress(
            phase: RemovalPhase.drive,
            done: done,
            total: total,
          ),
        );
    report();

    var deleted = 0;
    var failed = 0;
    String? fatal;

    for (final entry in byProvider.entries) {
      final adapter = registry.adapterFor(entry.key);
      if (adapter == null) {
        // 适配器在这一瞬间没了（账号被移除）：这些文件删不成，但进度条
        // 不能因此永远差一截 —— 把它们算作「处理过」。
        done += entry.value.length;
        report();
        continue;
      }
      final chunks = chunkFids(entry.value);

      for (var i = 0; i < chunks.length; i++) {
        try {
          final ok = await adapter.deleteFiles(fileIds: chunks[i]);
          deleted += ok.length;
          diag.info('媒体库', '批量删除（${entry.key.displayName}）'
              '第 ${i + 1}/${chunks.length} 批：${ok.length} 个');
        } on DriveException catch (e) {
          failed += chunks[i].length;
          diag.warn('媒体库', '批量删除（${entry.key.displayName}）'
              '第 ${i + 1}/${chunks.length} 批失败：${e.message}');

          // 凭证失效 / 断网**不是按批次的**：后面每一批都会以同样的方式
          // 失败，继续打只会把限流线顶穿。把没发出去的也算进失败数 ——
          // 它们确实没删掉，报成成功是撒谎。
          if (e.needsReauth || e.type == DriveErrorType.network) {
            fatal = _explain(e);
            for (var j = i + 1; j < chunks.length; j++) {
              failed += chunks[j].length;
            }
            // 没发出去的那几批也算「到此为止」：进度条停在 30% 上关窗，
            // 看起来像被掐断，而不是「删完了，有一部分没成功」。
            done = total;
            report();
            break;
          }
        } catch (e) {
          failed += chunks[i].length;
          diag.warn('媒体库', '批量删除（${entry.key.displayName}）异常：$e');
        }
        // 失败的那一批也算「处理完」：用户看到的是「还剩多少没走完」，
        // 不是「成功了多少」。卡在失败的那一批上不动才是真的像死机。
        done += chunks[i].length;
        report();
      }
      // 已经撞上致命错误就不要再打下一家网盘了 —— 同样的凭证 / 网络问题
      // 会让每一家都失败一遍，而用户等的是结果，不是几十次超时。
      if (fatal != null) break;
    }

    return DriveRemovalSummary(
      deleted: deleted,
      failed: failed,
      fatalError: fatal,
    );
  }

  static String _explain(DriveException e) => switch (e.type) {
        DriveErrorType.unauthorized => '登录已失效，剩下的没删',
        DriveErrorType.network => '网络中断，剩下的没删',
        _ => e.message,
      };
}

final libraryRemovalControllerProvider = Provider<LibraryRemovalController>(
  (ref) => LibraryRemovalController(ref),
);
