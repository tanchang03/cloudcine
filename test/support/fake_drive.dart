import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/domain/adapters/cloud_drive_adapter.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';

/// 测试用的假网盘：`目录 id → 条目`，按 `pageSize` 分页。
///
/// 全盘扫描、局部发现、目录浏览三个测试都需要它，所以放在 `support/` 下
/// 共用 —— 各写一份的话，三处的分页/报错行为会慢慢分叉，而「假网盘比真网盘
/// 强」的差异不会让测试变红，只会让测试给出**错误的信心**。
///
/// ⚠️ 它只实现**列目录、删除与移动**：取流、授权、搜索都抛
/// `UnimplementedError`。那几条路径不该被这个替身覆盖到 —— 真跑到了就
/// 说明调用点错了。
class FakeDriveAdapter extends CloudDriveAdapter {
  FakeDriveAdapter(
    Map<String, List<DriveEntry>> tree, {
    this.onList,
    this.failWith,
    this.failFor,
    this.rootIdValue = 'root',
    this.pageSizeOverride,
    this.deleteFailsWith,
    this.deleteFailsOnBatch,
    this.moveFailsWith,
    this.moveFailsOnBatch,
    this.rejectIds,
    this.capabilitiesOverride,
  }) : tree = {
          for (final e in tree.entries) e.key: [...e.value],
        };

  /// 假网盘自己的目录树。
  ///
  /// ⚠️ **构造时把传进来的那份拷了一份**，`tree` 与调用方手上那个 map
  /// （以及里面每个列表）从此是两个对象。
  ///
  /// 为什么非拷不可：删除与移动是**真的从这棵树上摘条目**（`removeWhere`），
  /// 那正是它们能验「操作完重列，条目确实不见了」的原因。但要是直接持有
  /// 调用方那个列表，被摘掉的就是**调用方自己那个变量** ——
  /// `setup(tree: {'root': entries})` 之后，测试里 `expect(..., entries.length)`
  /// 的 `entries.length` 会在操作完成后变成 0。而报错会指着那条断言说
  /// 「丢了一条」，把人引去查控制器（那里其实是对的）。
  ///
  /// 真网盘也不会因为你在远端挪了个文件就清空你本地那个数组，所以拷贝
  /// 同时也让这个替身更贴近被替的那一方。
  final Map<String, List<DriveEntry>> tree;

  /// 每次列目录时回调。测试用它制造「扫到一半」的时刻或记录调用顺序。
  final void Function(String dirId)? onList;

  /// 对**所有**目录都抛这个异常（模拟凭证失效）。
  final DriveException? failWith;

  /// 只对这几个目录抛网络错误（模拟「单个目录无权限 / 超时」）。
  final Set<String>? failFor;

  final String rootIdValue;

  /// 强制每页条数。为 `null` 时用调用方传的 `pageSize`。
  final int? pageSizeOverride;

  /// 删除时**每一批**都抛这个异常。
  final DriveException? deleteFailsWith;

  /// 只让第几批（从 1 开始）删除失败。
  ///
  /// 与 [deleteFailsWith] 分开：那个模拟「这条路整体不通」（凭证失效 /
  /// 断网），这个模拟「某一批被限流」—— 两者在控制器里的处置**完全不同**
  /// （前者要中止后面的批次，后者要继续），必须能分别构造。
  final Set<int>? deleteFailsOnBatch;

  /// 移动时**每一批**都抛这个异常。与 [deleteFailsWith] 同一套语义。
  final DriveException? moveFailsWith;

  /// 只让第几批（从 1 开始）移动失败。理由与 [deleteFailsOnBatch] 相同。
  final Set<int>? moveFailsOnBatch;

  /// 服务端**逐条拒掉**的 fid：不抛异常，只是不出现在返回值里、也没真的动。
  ///
  /// ## 为什么这个形状必须能造出来
  ///
  /// 百度的删除/移动响应里带**每一条**的 `errno`（见 `BaiduAdapter.deleteFiles`
  /// 与 `moveFiles` 里的 `info[]` 解析）。一个请求里 100 条，其中 3 条被拒
  /// （比如正在被别的客户端占用），接口照样返回 `errno: 0` —— 那 3 条只是
  /// 不出现在成功列表里。于是 `deleteFiles` / `moveFiles` 的返回值**比入参
  /// 短**，这是夸克那条路径上不存在的形状。
  ///
  /// 控制器若只按「返回值长度」记账，提示就是「已删除 100 项」而列表里还
  /// 剩 3 个 —— 用户会以为界面没刷新，再点一次删除。差额必须算成失败。
  ///
  /// ⚠️ 被拒的条目**留在树上**（它确实没动）。这一点与 [deleteFailsOnBatch]
  /// 不同：那个是整批抛异常、树上一条没少。
  final Set<String>? rejectIds;

  /// 这一批里真正会被接受（会动、会出现在返回值里）的 fid。
  List<String> _accepted(List<String> fileIds) {
    final rejected = rejectIds;
    if (rejected == null || rejected.isEmpty) return fileIds;
    return fileIds.where((id) => !rejected.contains(id)).toList(growable: false);
  }

  /// 顶掉默认的能力声明。
  ///
  /// ⚠️ 三个写能力位（`canWrite` / `canDelete` / `canMove`）**默认全 true**，
  /// 与夸克一致。要测「这家不支持删除 / 移动时界面怎么表现」就必须能单独
  /// 关掉其中一个 —— 而 UI 读的是**能力位本身**，不是网盘名，所以这里
  /// 只翻位、不改 `provider`（改了的话 `AdapterRegistry` 按 provider 建索引，
  /// `browseProvider` 就找不到这个替身了，页面会直接空掉）。
  final Capabilities? capabilitiesOverride;

  /// 按顺序记下每次列目录的目录 id。
  final List<String> listedDirs = [];

  /// 删除请求收到的每一批 fid（**按批次**记录，用来验分块）。
  final List<List<String>> deleteBatches = [];

  /// 全部被请求删除的 fid（拍平）。
  List<String> get deletedIds => [for (final b in deleteBatches) ...b];

  /// 移动请求收到的每一批 fid（**按批次**记录，用来验分块）。
  final List<List<String>> moveBatches = [];

  /// 每次移动请求带的目标目录 id。
  final List<String> moveTargets = [];

  /// 全部被请求移动的 fid（拍平）。
  List<String> get movedIds => [for (final b in moveBatches) ...b];

  @override
  Future<List<String>> deleteFiles({required List<String> fileIds}) async {
    deleteBatches.add(List.of(fileIds));

    final fatal = deleteFailsWith;
    if (fatal != null) throw fatal;
    if (deleteFailsOnBatch?.contains(deleteBatches.length) ?? false) {
      throw const DriveException(
        type: DriveErrorType.rateLimited,
        message: 'busy',
      );
    }

    // 真的从树里抠掉：测试要验「删完之后重列，那些条目确实不见了」，
    // 而只记一笔请求的话，重列还会把同一批条目吐回来 —— 那样测试就会
    // 对「界面有没有刷新」给出错误的信心。
    //
    // 只抠**被接受的**那些：`rejectIds` 里的条目服务端没删，树上也就
    // 不该少（见 [rejectIds]）。
    final accepted = _accepted(fileIds);
    for (final entries in tree.values) {
      entries.removeWhere((e) => accepted.contains(e.id));
    }
    return accepted;
  }

  @override
  Future<List<String>> moveFiles({
    required List<String> fileIds,
    required String targetFolderId,
  }) async {
    moveBatches.add(List.of(fileIds));
    moveTargets.add(targetFolderId);

    final fatal = moveFailsWith;
    if (fatal != null) throw fatal;
    if (moveFailsOnBatch?.contains(moveBatches.length) ?? false) {
      throw const DriveException(
        type: DriveErrorType.rateLimited,
        message: 'busy',
      );
    }

    // 与删除同理：**真的在树里搬**，否则「移完之后重列源目录，那些条目
    // 确实不见了」这条断言就是空的。
    //
    // 两趟走：先把要搬的收齐，再从原来的位置摘掉，最后挂到目标目录下。
    // ⚠️ 不能边遍历 `tree.values` 边 `putIfAbsent` —— 那会改 map 的结构，
    // 遍历中抛 `ConcurrentModificationError`（只在目标目录还没出现在树上
    // 时复现，是个很难看的间歇失败）。
    final moving = <DriveEntry>[];
    final accepted = _accepted(fileIds);
    for (final entries in tree.values) {
      moving.addAll(entries.where((e) => accepted.contains(e.id)));
    }
    for (final entries in tree.values) {
      entries.removeWhere((e) => accepted.contains(e.id));
    }
    if (moving.isNotEmpty) {
      tree.putIfAbsent(targetFolderId, () => <DriveEntry>[]).addAll(moving);
    }
    return accepted;
  }

  @override
  DriveProvider get provider => DriveProvider.quark;

  @override
  Capabilities get capabilities =>
      capabilitiesOverride ??
      const Capabilities(provider: DriveProvider.quark, canListDirectory: true);

  @override
  String get rootId => rootIdValue;

  @override
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  }) async {
    listedDirs.add(dirId);
    onList?.call(dirId);

    final fatal = failWith;
    if (fatal != null) throw fatal;
    if (failFor?.contains(dirId) ?? false) {
      throw const DriveException(
        type: DriveErrorType.network,
        message: 'timeout',
      );
    }

    final all = tree[dirId] ?? const <DriveEntry>[];
    final size = pageSizeOverride ?? pageSize ?? 50;
    final start = int.tryParse(pageToken ?? '') ?? 0;
    final end = (start + size) > all.length ? all.length : (start + size);
    return DrivePage(
      entries: all.sublist(start, end),
      nextPageToken: end < all.length ? '$end' : null,
    );
  }

  @override
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) async =>
      const <DriveEntry>[];

  @override
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId}) =>
      throw UnimplementedError('这个替身只用于列目录');

  @override
  Future<CloudAccount?> restoreSession() async => null;

  @override
  Future<CloudAccount> authorize(AuthCredential credential) =>
      throw UnimplementedError('这个替身只用于列目录');

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> dispose() async {}
}
