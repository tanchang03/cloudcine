import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../data/db/settings_store.dart';
import '../../domain/services/drive_move.dart';
import 'app_providers.dart';
import 'drive_browse_providers.dart';

/// 「最近用过的移动目标目录」保留几条。
///
/// 8 条的依据是**它出现的形态**：这些目录在对话框里是一列可点的行，
/// 而不是一个需要滚动查找的列表。再多就会把「摊开要移动的条目」挤出屏幕，
/// 而那一块才是用户真正要核对的东西。
const int moveTargetRecentsLimit = 8;

/// 最近用过的移动目标目录（**最新在前**）。
///
/// ## 为什么这是一个独立的 provider，而不是塞进 `AppSettings`
///
/// 它不是**偏好**，是**缓存**：`AppSettings` 里那些项（开关、间隔、并发数）
/// 都是「用户选的配置」，会跟着备份同步走，也会被设置页整体读写。而这份
/// 记录只服务一个动作，读坏了唯一的后果是「没有最近记录」。
///
/// 更要紧的是依赖方向：`AppSettings` 在 `settings_providers.dart`，而本文件
/// 要用的 `DriveCrumb` 在 `drive_browse_providers.dart` —— 后者**已经**
/// import 了 `settings_providers.dart`，把记录塞进 `AppSettings` 会造出一个
/// 循环。所以它单独一个键、单独一个 provider。
class MoveTargetsController extends AsyncNotifier<List<MoveTarget>> {
  @override
  Future<List<MoveTarget>> build() async {
    final store = ref.watch(settingsStoreProvider);
    try {
      return _parse(await store.read(SettingKeys.moveTargetRecents));
    } catch (e) {
      // 读设置库**本身**失败（磁盘错、库已关）也退回空列表 ——
      // 理由与 `_parse` 逐字相同，只是发生在更外一层。
      //
      // 这里必须兜住：`build` 抛出去的话，provider 会停在 `AsyncError`，
      // 而 watch 它的是**文件夹页**（对话框也在这条链上）。用户丢掉的
      // 本该只是「最近记录」这一个快捷入口，实际却会看到整页打不开 ——
      // 一份缓存的读失败没有任何理由升级成页面级故障。
      diag.warn('文件', '读取最近移动目录失败：$e');
      return const [];
    }
  }

  /// 记一次「用户选了它」。
  ///
  /// ## 记在**确认**那一刻，而不是移动成功之后
  ///
  /// 用户按下确认就说明「我确实想往这儿放」。而失败（限流、断网）之后他
  /// 马上要重试，重试时最想看到的正是同一个目录 —— 等到成功才记，恰好把
  /// 最需要这份记录的那次场景漏掉。
  Future<void> remember(MoveTarget target) async {
    // ⚠️ 必须先 `await future`，**不能**直接读 `state.valueOrNull`。
    //
    // `remember` 最常被调用的时刻恰好是「provider 刚被创建」—— 用户第一次
    // 移动，对话框第一次 `watch` 它。那一刻 `build()` 还在异步读设置库，
    // `state` 是 `AsyncLoading`、`valueOrNull` 是 `null`。不等它就写
    // `state = AsyncData([target])`，随后 `build()` 完成会**把 state 覆盖回
    // 它读到的那份旧列表** —— 表现为「刚用过的目录没进最近列表」，
    // 而且只在第一次（或冷启动后第一次）出现，看起来像随机的。
    List<MoveTarget> current;
    try {
      current = await future;
    } catch (e) {
      // 第二道网。`build` 已经不抛了（见那里的注释），留着这一层是因为
      // 调用 `remember` 的**是一次已经发出去的移动** —— 真要是漏出来一个
      // 异常，用户看到的是「移动失败」，而文件其实已经动完了。宁可在这里
      // 多兜一次。
      diag.warn('文件', '读取最近移动目录失败：$e');
      current = const [];
    }

    final next = <MoveTarget>[
      target,
      // 按 fid 去重（`MoveTarget.==` 只比 fid）：同一个目录被反复选中时
      // 不该堆出好几条同名记录。用 `where` 而不是 `Set` 是为了保住
      // 「最新在前」这个顺序 —— 顺序正是这个列表的全部意义。
      ...current.where((t) => t != target),
    ].take(moveTargetRecentsLimit).toList();

    state = AsyncData(next);
    try {
      await ref
          .read(settingsStoreProvider)
          .write(SettingKeys.moveTargetRecents, _encode(next));
    } catch (e) {
      // 写失败只影响「下次还能不能一键选中」，不影响这次移动本身。
      // 抛上去会让一次**成功的**移动显示成失败，那是更坏的结果。
      diag.warn('文件', '保存最近移动目录失败：$e');
    }
  }

  static String _encode(List<MoveTarget> targets) =>
      jsonEncode([for (final t in targets) t.toJson()]);

  /// 读不懂一律退回空列表。理由见 `SettingKeys.moveTargetRecents`。
  ///
  /// 逐条校验而不是整份信任：一条坏记录不该让后面几条好的一起作废。
  static List<MoveTarget> _parse(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <MoveTarget>[];
      for (final item in decoded) {
        final target = MoveTarget.fromJson(item);
        if (target != null) out.add(target);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}

final moveTargetsProvider =
    AsyncNotifierProvider<MoveTargetsController, List<MoveTarget>>(
  MoveTargetsController.new,
);

/// 批量移动的进度快照。
class DriveMoveState {
  const DriveMoveState({
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
  String toString() => 'DriveMoveState(running=$running, $done/$total)';
}

/// 一次批量移动的结果。
///
/// 三个数字都要如实带到界面上 —— 与 `DriveCleanupOutcome` 同一条理由：
/// 「移了一部分」被说成「移动完成」，用户在**目标目录**里找不到全部文件，
/// 只会以为功能坏了，然后再移一次（于是同名的来了两份）。
class DriveMoveOutcome {
  const DriveMoveOutcome({
    required this.plan,
    required this.moved,
    required this.failed,
    this.fatalError,
  });

  final DriveMovePlan plan;

  /// 网盘侧确认动了的条目数。
  final int moved;

  /// 失败的条目数（含因致命错误**没发出去**的那些批次）。
  final int failed;

  /// 撞上「再试也没用」的错误（凭证失效 / 网络断了）时的说明。
  ///
  /// 非空表示后面几批**根本没发出去** —— 界面必须说出来，否则用户会以为
  /// 那些是「网盘拒绝移动」，而实际是「这次没试」。
  final String? fatalError;

  /// 结果提示文案。
  String get message {
    final base = plan.movedMessage(moved: moved, failed: failed);
    return fatalError == null ? base : '$base $fatalError';
  }

  @override
  String toString() => 'DriveMoveOutcome(moved=$moved, failed=$failed)';
}

/// 网盘批量移动（目录视图的多选移动走这里）。
///
/// ## 与 `DriveCleanupController` 是刻意对称的两份
///
/// 分块、失败分类、进度上报、结果如实汇报这几件事**一字不差**。之所以不
/// 抽成一个泛型基类：两者真正的差异不在循环，而在**收尾**——删除要顺带
/// 清本地索引（删掉的行会变成死索引），移动**不动索引**（fid 没变，播放
/// 照常），改的是「记住目标目录」这件事。把这两套收尾塞进一个基类，得到
/// 的是一个带两个可选钩子的骨架，读起来比两份直白的循环更难。
class DriveMoveController extends Notifier<DriveMoveState> {
  @override
  DriveMoveState build() => const DriveMoveState();

  /// 现在能不能发起一次移动。
  bool get canStart => !state.running;

  /// 把 [plan] 里的条目移动到 [plan.target]。
  ///
  /// [sourceCrumb] 是这些条目**现在**所在的那一层，用于移完之后重列。
  ///
  /// 返回 `null` 表示**什么都没做**（计划为空、正在跑、没有可用适配器、
  /// 或目标目录不合法）。调用方据此决定要不要弹结果提示 —— 返回一个
  /// 「移动了 0 项」的提示会让用户以为失败了。
  Future<DriveMoveOutcome?> move({
    required DriveCrumb sourceCrumb,
    required DriveMovePlan plan,
  }) async {
    if (plan.entries.isEmpty || state.running) return null;

    // 目标不合法时**在这里也拦一道**。界面已经会用 `invalidTargetReason`
    // 把确认按钮置灰，但那只是界面：这条检查必须跟着动作本身走。
    // 「把目录移进它自己的子目录」是这个功能里唯一能造成结构性损坏的
    // 操作（自引用目录），而它没有撤销入口。
    if (plan.invalidTargetReason() != null) {
      diag.warn('文件', '批量移动被拦下：${plan.invalidTargetReason()}');
      return null;
    }

    final adapter =
        ref.read(adapterRegistryProvider).adapterFor(browseProvider);
    if (adapter == null) {
      diag.warn('文件', '批量移动：夸克适配器未注册');
      return null;
    }

    // 先记目标目录，再发请求。理由见 [MoveTargetsController.remember]。
    await ref.read(moveTargetsProvider.notifier).remember(plan.target);

    state = DriveMoveState(running: true, total: plan.count);

    final movedIds = <String>[];
    var failed = 0;
    String? fatal;

    final chunks = plan.idChunks();
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      try {
        final ok = await adapter.moveFiles(
          fileIds: chunk,
          targetFolderId: plan.target.fid,
        );
        movedIds.addAll(ok);
        diag.info('文件', '批量移动第 ${i + 1}/${chunks.length} 批：'
            '${ok.length} 项');
      } on DriveException catch (e) {
        failed += chunk.length;
        diag.warn('文件', '批量移动第 ${i + 1}/${chunks.length} 批失败：'
            '${e.message}');

        // 与批量删除同一条判据：凭证失效 / 断网**不是按批次的** —— 后面
        // 每一批都会以同样的方式失败。继续打下去只有两个后果：几十个注定
        // 失败的请求，以及把夸克那条本来就紧的限流线再顶一下。所以直接停，
        // 并且把**没发出去的**那些也算进失败数：它们确实没动，
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
        diag.warn('文件', '批量移动第 ${i + 1}/${chunks.length} 批异常：$e');
      }
      state = DriveMoveState(
        running: true,
        done: movedIds.length + failed,
        total: plan.count,
      );
    }

    // 重列**源**目录：移走的那些不该再出现在这里。父层不在这里作废 ——
    // 用户就在这一层，而 `autoDispose` 的 family 让他回头往上走时本来就
    // 会重新请求一次。
    ref.invalidate(driveListingProvider(sourceCrumb));

    // 目标目录也变了（多了这些条目）。它通常没被显示（用户站在源目录里），
    // 所以这一次作废多半是空操作；留着是因为「移进当前目录的子目录」时
    // 它可能正好被缓存着，那时不作废就会显示一份少了这些条目的旧列表。
    ref.invalidate(
      driveListingProvider(
        DriveCrumb(
          id: plan.target.fid,
          name: plan.target.name,
          path: plan.target.path,
        ),
      ),
    );

    // ⚠️ **不动本地媒体库索引**，这与批量删除是刻意的差异：
    // 移动不改 fid，所以索引里那些行**不是死索引**（按 fid 查得到、
    // 播放也照常）。它们的 `dirPath` 会指向旧位置，要等下一次扫描才修正。
    // 反过来「为了保持一致把行删掉」才是错的：用户只是挪了个地方，
    // 媒体库里那部片子凭什么消失（而且再扫回来会丢续播点与播放偏好）。
    diag.info('文件', '批量移动完成：${movedIds.length} 项 → ${plan.target.label}'
        '（本地索引不动，dirPath 待下次扫描修正）');

    state = const DriveMoveState();
    return DriveMoveOutcome(
      plan: plan,
      moved: movedIds.length,
      failed: failed,
      fatalError: fatal,
    );
  }

  static String _explain(DriveException e) => switch (e.type) {
        DriveErrorType.unauthorized => '登录已失效，剩下的没动（请重新登录后再试）。',
        DriveErrorType.network => '网络中断，剩下的没动（请检查网络后再试）。',
        _ => e.message,
      };
}

final driveMoveControllerProvider =
    NotifierProvider<DriveMoveController, DriveMoveState>(
  DriveMoveController.new,
);
