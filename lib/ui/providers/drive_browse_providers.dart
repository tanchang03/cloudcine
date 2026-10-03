import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/drive_error.dart';
import '../../core/utils/drive_paths.dart';
import '../../core/utils/file_names.dart';
import '../../domain/entities/drive_entry.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/services/folder_sort.dart';
import '../../domain/services/media_discovery.dart';
import '../../domain/services/media_entry_classifier.dart';
import '../../domain/services/scan_service.dart';
import 'app_providers.dart';
import 'folder_providers.dart';
import 'library_providers.dart';
import 'library_refresh_providers.dart';
import 'scan_providers.dart';
import 'settings_providers.dart';

/// 文件夹视图浏览的网盘。
///
/// 现在只有夸克。写成常量而不是散落的字面量：接第二家网盘时这里是唯一的
/// 改动点（页面上的登录判断、列目录、发现都从它取）。
const DriveProvider browseProvider = DriveProvider.quark;

/// 浏览栈上的一格 —— 一个**真实的网盘目录**。
///
/// ## 为什么必须带 [id]
///
/// 目录视图原先按**展示路径**定位（`/电影/科幻`）。那套只能用在「已经扫过
/// 一遍、路径都写在索引里」的场景；现在要直接读网盘，而网盘的列目录接口
/// 只认目录 ID。所以浏览栈上每一格都必须记着 id。
///
/// 路径仍然留着：它要拼进 `MediaItem.dirPath`（与扫描器同口径），
/// 也是面包屑要显示的东西。
@immutable
class DriveCrumb {
  const DriveCrumb({
    required this.id,
    required this.name,
    required this.path,
  });

  /// 网盘目录 ID。根目录是适配器给的 `rootId`。
  final String id;

  /// 显示名。根目录用 `/`。
  final String name;

  /// 归一化展示路径（不带结尾斜杠，根为 `/`）。
  final String path;

  bool get isRoot => path == driveRootPath;

  /// 这一格下面的子目录格。
  ///
  /// 路径走 [drivePathJoin] 再归一化 —— 拼出来的形状必须与
  /// `MediaItem.dirPath` 同源（同一套 `drive_paths` 规则），
  /// 但**不带结尾斜杠**（面包屑、复制路径都按这个形状给人看）。
  /// 需要扫描器那种带斜杠的形式时，由 `drivePathWithTrailingSlash` 在
  /// 边界上转一次（发现流程就是这么做的），别在这里留两种形状。
  DriveCrumb child(DriveEntry dir) => DriveCrumb(
        id: dir.id,
        name: dir.name,
        path: normalizeDrivePath(drivePathJoin(path, dir.name)),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DriveCrumb &&
          other.id == id &&
          other.name == name &&
          other.path == path;

  @override
  int get hashCode => Object.hash(id, name, path);

  @override
  String toString() => 'DriveCrumb($name, $id, $path)';
}

/// 一个网盘目录的列表内容。
///
/// ## 为什么是「三组」而不是「两组 + 一个计数」
///
/// 这里原先只列**可入库的视频**，其余文件（字幕 / 图片 / 文档 / 压缩包）
/// 用一个 `otherFileCount` 交代存在。理由当时是「列出一堆点了加不进库的
/// `cover.jpg` / `.srt` 只会让用户以为功能坏了」。
///
/// 现在这条理由不成立了：**目录视图就是「网盘上有什么」的视图**，用户把
/// 一个 `.zip` / 一份 `.pdf` 传上来，就是想在同一个地方看见它、拿回去。
/// 只给一个数字等于告诉他「有 3 个文件，但不告诉你是什么、也不让你动」。
///
/// 所以三组都列出来，差别只在**行上的动作**：目录→进、视频→播、
/// 其他文件→下载（见 `downloadDriveEntry`）。
class DriveListing {
  const DriveListing({
    required this.crumb,
    required this.folders,
    required this.videos,
    required this.others,
    this.truncated = false,
  });

  final DriveCrumb crumb;

  /// 子目录，**自然序**（名称）。
  ///
  /// ⚠️ 这里给的是**基线顺序**，不是最终显示顺序。用户在工具条上选的排序
  /// 方式由 `sortListing` 在渲染时叠加上去（见 [driveListingProvider] 的注释：
  /// 排序**不能**放进这个 provider）。
  final List<DriveEntry> folders;

  /// **可播放的视频**（`EntryRole.video`），**自然序**（名称）。
  ///
  /// 判据与「扫描会把什么写进媒体库」严格对齐（共用 `classifyEntry`）——
  /// 列表里说「这是视频」的东西，点「加入媒体库」就一定加得进去。
  final List<DriveEntry> videos;

  /// 其余文件：字幕 / 图片 / 蓝光镜像 / 文档 / 压缩包…
  ///
  /// 它们**不入库、不能播**，但可以**下载**。分组判据同样来自
  /// `classifyEntry`（非目录、非视频的那几类）。
  final List<DriveEntry> others;

  /// 本层里既不是目录也不是视频的文件数。
  ///
  /// 保留成派生值而不是构造参数：老调用点（页头副标题）读的是「有多少个
  /// 非视频文件」这个数，而现在这个数就是 [others] 的长度。
  int get otherFileCount => others.length;

  /// 条目太多、没列完。UI 要如实说出来，否则「怎么少了几部片子」
  /// 会被当成 bug。
  final bool truncated;

  bool get isEmpty => folders.isEmpty && videos.isEmpty && others.isEmpty;

  int get total => folders.length + videos.length + others.length;

  /// 这一层的构成，给人看的一行字：`12 个子目录 · 8 个视频 · 3 个其他文件`。
  ///
  /// **为 0 的那几段不写**：`0 个视频` 与「没有视频」是同一件事，而一个
  /// 全是字幕的目录写成「0 个子目录 · 0 个视频 · 3 个其他文件」只会让这一行
  /// 变长，不增加任何信息。
  ///
  /// 放在实体上而不是各处自己拼：目录视图的**面包屑**与**页头副标题**都要
  /// 说这句话，两处各写一遍的话，将来加一类条目（比如「音频」）只会改一处，
  /// 另一处静默地少说一段。
  String get summary {
    final parts = <String>[
      if (folders.isNotEmpty) '${folders.length} 个子目录',
      if (videos.isNotEmpty) '${videos.length} 个视频',
      if (others.isNotEmpty) '${others.length} 个其他文件',
    ];
    return parts.isEmpty ? '空目录' : parts.join(' · ');
  }
}

/// 列一个目录时每页取多少条。夸克对 `_size` 有上限，100 是实测可用的值。
const int _listPageSize = 100;

/// 单个目录最多列多少条，防止误进一个几万项的目录时把界面拖死。
const int _listMaxEntries = 3000;

/// 浏览栈（根 → 当前目录）。
///
/// **只存栈，不存列表内容** —— 列表由 [driveListingProvider] 按需取。
/// 存内容就会拿着一份过期的快照渲染（表现为翻着翻着突然一片空白，
/// 或者发现完了标记还在）。
class DriveBrowseController extends Notifier<List<DriveCrumb>> {
  @override
  List<DriveCrumb> build() {
    final rootId = ref
        .watch(adapterRegistryProvider)
        .requireAdapter(browseProvider)
        .rootId;
    return [DriveCrumb(id: rootId, name: driveRootPath, path: driveRootPath)];
  }

  /// 进入某个目录（通常是当前层的子目录格）。
  void open(DriveCrumb crumb) {
    final current = state.last;
    if (current == crumb) return;
    // 点面包屑上的一格 = 回退到那一层，而不是往下钻。
    final idx = state.indexOf(crumb);
    if (idx >= 0) {
      state = state.sublist(0, idx + 1);
      return;
    }
    state = [...state, crumb];
  }

  /// 回到上一层。已在根目录时不动。
  void up() {
    if (state.length <= 1) return;
    state = state.sublist(0, state.length - 1);
  }

  void reset() {
    if (state.length == 1) return;
    state = [state.first];
  }
}

final driveBrowseProvider =
    NotifierProvider<DriveBrowseController, List<DriveCrumb>>(
  DriveBrowseController.new,
);

/// 当前所在的网盘目录。
final currentCrumbProvider = Provider<DriveCrumb>(
  (ref) => ref.watch(driveBrowseProvider).last,
);

/// 当前目录的内容（**网盘实时读的**）。
///
/// ## 为什么是 `autoDispose`
///
/// family 的键是目录，用久了会把翻过的每一个目录都留在内存里（每个都是
/// 一整个 `DriveEntry` 列表）。`autoDispose` 让离开的目录随最后一个监听者
/// 一起释放；代价是回退到上一层会重新列一次目录 —— 一次请求，换的是
/// **看到的一定是网盘上现在的内容**，而不是几分钟前的快照。
///
/// ## 为什么不按「内容有变」做缓存
///
/// 网盘没有变更通知，唯一的判据就是重新列一次。加一层 TTL 缓存只会制造
/// 「我明明刚上传的片子怎么没有」这种问题。
final driveListingProvider =
    FutureProvider.autoDispose.family<DriveListing, DriveCrumb>(
  (ref, crumb) async {
    // ⚠️ **刻意不 watch `libraryWriteSignalProvider`**（曾经 watch 过）。
    //
    // 当时的注释写「写库之后重列一次：列表本身没变，但『已入库』标记会变」——
    // 后半句是错的：`DriveListing` 里**没有任何字段来自本地库**（子目录、
    // 视频、其他文件全部来自网盘响应）。「已入库」标记来自另外两个
    // provider —— `_DriveFileRow` 读 `indexedFileIdsProvider`、
    // `_FolderRow` 读 `folderTreeProvider` —— 而它们各自 watch 那个信号。
    //
    // 所以 watch 它只有一个后果：每次发现/扫描写完库，就把**整个目录重新
    // 列一遍**（一个 3000 项的目录是 30 次请求），全打在夸克那条约 3 QPS
    // 的安全线上，换不到任何界面变化。
    final adapter =
        ref.watch(adapterRegistryProvider).requireAdapter(browseProvider);

    final entries = <DriveEntry>[];
    String? pageToken;
    do {
      final page = await adapter.listDirectory(
        dirId: crumb.id,
        pageToken: pageToken,
        pageSize: _listPageSize,
      );
      entries.addAll(page.entries);
      pageToken = page.nextPageToken;
    } while (pageToken != null && entries.length < _listMaxEntries);

    final folders = <DriveEntry>[];
    final videos = <DriveEntry>[];
    final others = <DriveEntry>[];
    for (final entry in entries) {
      switch (classifyEntry(entry)) {
        case EntryRole.directory:
          folders.add(entry);
        case EntryRole.video:
          videos.add(entry);
        case EntryRole.subtitle:
        case EntryRole.image:
        case EntryRole.discImage:
        case EntryRole.other:
          // ⚠️ 三组分法只影响**怎么排、行上给什么动作**，不影响
          // 「什么能入库」—— 那条判据仍然只有 `classifyEntry` 一处，
          // 而且仍然只有 `video` 会被写进媒体库。别让这里的分类回流到
          // 扫描 / 发现那两条路径上。
          others.add(entry);
      }
    }

    // 只排成**自然序**（基线），不在这里读用户选的排序方式。
    //
    // ⚠️ 别把 `folderSortModeProvider` watch 进这个 provider：改了排序方式
    // 就会**把整个目录重新列一遍**（一个 3000 项的目录是 30 次请求，全打在
    // 夸克那条约 3 QPS 的安全线上），而排序本来只要在渲染时重排一下列表就够。
    // 用户看到的差别是「点一下排序卡两秒」和「立刻生效」。
    folders.sort((a, b) => naturalCompare(a.name, b.name));
    videos.sort((a, b) => naturalCompare(a.name, b.name));
    others.sort((a, b) => naturalCompare(a.name, b.name));

    return DriveListing(
      crumb: crumb,
      folders: folders,
      videos: videos,
      others: others,
      truncated: pageToken != null,
    );
  },
);

/// 目录视图当前的排序方式（**真源在设置里**，这里只是给它一个名字）。
///
/// ## 为什么单独一个 provider，而不是各处自己读设置
///
/// 「目录视图按什么排」有两个入口：面包屑那一行的排序按钮、设置页里的
/// 默认值。两处**读写同一份**（都落到 `SettingKeys.folderSortMode`），所以
/// 在工具条上切一次 = 改了设置页里那一项 —— 这是刻意的：两处各存一份的话，
/// 用户在设置页设成「名称」，下次打开目录视图却又是按时间排的，那种
/// 「设置没生效」比根本没有这个设置更让人费解。
///
/// 设置还没读出来时退回默认（修改时间倒序），与 `FolderSortMode.parse`
/// 同口径 —— 目录视图不该因为一次异步读而先按错的顺序闪一下。
final folderSortModeProvider = Provider<FolderSortMode>(
  (ref) =>
      ref.watch(settingsProvider).valueOrNull?.folderSortMode ??
      FolderSortMode.modifiedTime,
);

/// **已入库文件**的 id 集合（本地索引的叠加层）。
///
/// 目录视图的数据源是网盘，但「哪些已经在库里」只有本地索引知道。
/// 分开一个 provider 是为了让「发现」完成后只失效需要失效的东西。
final indexedFileIdsProvider = FutureProvider<Set<String>>((ref) async {
  final tree = await ref.watch(folderTreeProvider.future);
  return tree.fileIds;
});

/// 发现任务的状态快照。
class DiscoveryState {
  const DiscoveryState({
    this.running = false,
    this.target,
    this.progress,
    this.outcome,
    this.error,
  });

  final bool running;

  /// 正在发现的目标（目录或文件）的显示名。
  final String? target;

  final DiscoveryProgress? progress;

  /// 上一次发现的结果。
  final DiscoveryOutcome? outcome;

  /// 上一次发现的失败原因（面向用户）。
  final String? error;

  bool get hasRun => outcome != null || error != null;

  @override
  String toString() => 'DiscoveryState(running=$running, target=$target, '
      'error=${error ?? "-"})';
}

/// 局部发现的控制器：**发起、转播进度、取消、刷新**。
///
/// 真正的逻辑在 [MediaDiscoveryService]（无 UI 依赖，可单测）。
class DiscoveryController extends Notifier<DiscoveryState> {
  ScanCancellation? _cancel;
  bool _disposed = false;

  @override
  DiscoveryState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const DiscoveryState();
  }

  /// 请求停止。协作式：在目录/页边界生效。
  void cancel() => _cancel?.cancel();

  /// 现在能不能发起一次发现。
  ///
  /// **全盘扫描在跑的时候不能**。两个理由：
  ///   1. 两边的节流器是各自的实例（`RequestThrottle` 是每次任务新建的），
  ///      并发跑等于把实际 QPS 翻倍 —— 夸克那条约 3 QPS 的安全线会被顶穿；
  ///   2. 两个任务会同时往同一批作品行上写，`mergeWorkForUpsert` 虽然能兜住
  ///      数据正确性，但用户看到的是「数字在跳」。
  ///
  /// 这是**单向**的守卫（发现让着扫描）：反方向检查会让
  /// `drive_browse_providers` 与 `scan_providers` 互相 import，
  /// 而后者要用的 `buildScanPolicy` 就在这一侧。
  bool get canStart =>
      !state.running && !ref.read(scanControllerProvider).running;

  /// 发现一个目录。`recursive` 为假时只看这一层。
  Future<void> discoverDirectory(
    DriveCrumb crumb, {
    bool recursive = true,
  }) async {
    if (!canStart) return;

    final token = ScanCancellation();
    _cancel = token;
    _emit(DiscoveryState(running: true, target: crumb.path));

    try {
      final service = await _buildService();
      final outcome = await service.discoverDirectory(
        browseProvider,
        dirId: crumb.id,
        dirPath: crumb.path,
        recursive: recursive,
        cancel: token,
        onProgress: (p) => _emit(
          DiscoveryState(running: true, target: crumb.path, progress: p),
        ),
      );
      _emit(DiscoveryState(outcome: outcome, target: crumb.path));
    } on DriveException catch (e) {
      _emit(DiscoveryState(error: _explain(e), target: crumb.path));
    } catch (e) {
      _emit(DiscoveryState(error: '发现失败：$e', target: crumb.path));
    } finally {
      _cancel = null;
      if (!_disposed) _refreshAfterWrite();
    }
  }

  /// 发现**单个文件**（把它加进媒体库）。
  Future<void> discoverFile(DriveEntry entry, DriveCrumb crumb) async {
    if (!canStart) return;

    final token = ScanCancellation();
    _cancel = token;
    _emit(DiscoveryState(running: true, target: entry.name));

    try {
      final service = await _buildService();
      final outcome = await service.discoverFile(
        browseProvider,
        entry: entry,
        dirPath: crumb.path,
        // 配同目录字幕要再列一次这个目录。**用 `crumb.id` 而不是
        // `entry.parentId`**：后者依赖夸克响应里带 `pdir_fid`，缺了就会
        // 静默配不上字幕（用户只会看到「字幕没进来」，猜不到是字段没给）。
        // 而 `crumb` 正是列出这一行的那个目录，一定是对的。
        dirId: crumb.id,
      );
      _emit(DiscoveryState(outcome: outcome, target: entry.name));
    } on DriveException catch (e) {
      _emit(DiscoveryState(error: _explain(e), target: entry.name));
    } catch (e) {
      _emit(DiscoveryState(error: '加入失败：$e', target: entry.name));
    } finally {
      _cancel = null;
      if (!_disposed) _refreshAfterWrite();
    }
  }

  Future<MediaDiscoveryService> _buildService() async {
    return MediaDiscoveryService(
      registry: ref.read(adapterRegistryProvider),
      library: ref.read(mediaRepositoryProvider),
      policy: await buildScanPolicy(ref),
    );
  }

  /// 写库之后的刷新。
  ///
  /// 与 `ScanController` 同一套口径（少一个，用户就会看到「发现了但列表没变」）。
  /// 放在 `finally` 里：**取消和失败也改过库**（每落一批就落盘了），
  /// 只刷新成功路径会让取消后列表停在旧数据上。
  ///
  /// 「目录列表 / 已入库标记」那一侧不在这里直接 invalidate：它们自己
  /// `watch(libraryWriteSignalProvider)`，这里只负责推一下信号 ——
  /// 否则 `drive_browse_providers` 与 `scan_providers` 会互相 import。
  void _refreshAfterWrite() {
    ref.read(libraryWriteSignalProvider.notifier).bump();
    ref.invalidate(workListProvider);
    ref.invalidate(libraryStatsProvider);
    ref.invalidate(playedCountProvider);
    ref.invalidate(categoryCountsProvider);
    ref.invalidate(yearCountsProvider);
    ref.invalidate(genreCountsProvider);
  }

  void _emit(DiscoveryState next) {
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

final discoveryControllerProvider =
    NotifierProvider<DiscoveryController, DiscoveryState>(
  DiscoveryController.new,
);
