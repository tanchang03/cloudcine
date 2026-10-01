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
/// ⚠️ 它**只实现列目录**：取流、授权、搜索都抛 `UnimplementedError`。
/// 那几条路径不该被这个替身覆盖到 —— 真跑到了就说明调用点错了。
class FakeDriveAdapter extends CloudDriveAdapter {
  FakeDriveAdapter(
    this.tree, {
    this.onList,
    this.failWith,
    this.failFor,
    this.rootIdValue = 'root',
    this.pageSizeOverride,
  });

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

  /// 按顺序记下每次列目录的目录 id。
  final List<String> listedDirs = [];

  @override
  DriveProvider get provider => DriveProvider.quark;

  @override
  Capabilities get capabilities =>
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
