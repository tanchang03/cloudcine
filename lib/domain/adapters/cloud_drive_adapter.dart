import 'dart:typed_data';

import '../../core/error/drive_error.dart';
import '../entities/auth_credential.dart';
import '../entities/capabilities.dart';
import '../entities/cloud_account.dart';
import '../entities/drive_entry.dart';
import '../entities/drive_provider.dart';
import '../entities/stream_ticket.dart';

/// 云盘适配器契约。
///
/// **这是整个多云盘架构的唯一边界。** 上层（扫描调度器、播放引擎、
/// 索引库、UI）只依赖这个抽象，不认识任何网盘的私有字段与错误码。
///
/// 新增一家网盘 = 实现一个本类 + 在 [DriveProvider] 加一个枚举值，
/// 其余代码零改动。
///
/// **用 `extends` 而不是 `implements`**：本类里带有默认实现的方法
/// （如 [readFileBytes]）表达的是「这个能力可以不支持」。`implements` 只继承
/// 接口、不继承实现，会让每个实现方被迫写一个抛异常的空壳 —— 那是噪音，
/// 不是表达。子类只在真正支持该能力时才覆写。
///
/// 实现约定：
///   - **所有异常必须归一化**为 `DriveException`，不允许把 `DioException`
///     或网盘原始错误码抛到上层；
///   - **限流由适配器内部处理**（令牌桶 + 退避），调用方无需关心 QPS；
///   - 适配器实例是**长生命周期**的，内部持有 HTTP 客户端与会话状态，
///     由 `DriveAdapterRegistry` 管理，用完调 [dispose]。
abstract class CloudDriveAdapter {
  /// 本适配器服务的网盘
  DriveProvider get provider;

  /// 能力声明。**必须如实**——上层据此决定 UI 与降级策略。
  Capabilities get capabilities;

  // ---------------------------------------------------------------------
  // 授权
  // ---------------------------------------------------------------------

  /// 用已持久化的凭证恢复会话。
  ///
  /// - 凭证有效 → 返回 [CloudAccount]
  /// - 无凭证 → 返回 `null`（不是错误，是「还没授权」）
  /// - 凭证存在但已失效 → 抛 `DriveException(unauthorized)`
  ///
  /// 这是 App 启动时的入口：先 `restoreSession()`，拿到 `null` 就引导授权。
  Future<CloudAccount?> restoreSession();

  /// 用一份新凭证授权并持久化。
  ///
  /// 实现应**先校验再落库**：校验失败抛 `DriveException(unauthorized)`，
  /// 避免把废凭证写进钥匙串。
  Future<CloudAccount> authorize(AuthCredential credential);

  /// 清除本地凭证。不做服务端登出（自用接口也没有登出接口）。
  Future<void> signOut();

  // ---------------------------------------------------------------------
  // 遍历与搜索
  // ---------------------------------------------------------------------

  /// 列目录。
  ///
  /// [dirId] 为 `'0'` 时表示根目录（各网盘根 ID 语义不同，
  /// 由 `CloudDriveAdapter.rootId` 统一给出）。
  ///
  /// [pageToken] 传 `null` 取第一页；返回值的 `nextPageToken` 非空则还有下一页。
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  });

  /// 关键词搜索。
  ///
  /// 网盘搜索通常是**全盘**的（不限定目录），因此可作为全量遍历的补充：
  /// 遍历负责完整性与路径，搜索负责「用户只想找某一首歌」的快路径。
  ///
  /// ⚠️ **返回值可能包含目录**。夸克实测：搜索命中的前 20 条全是目录
  /// （默认按 `file_type:asc` 排序），目录项的 `sizeBytes` 为 0。
  /// 调用方若只要文件，**必须自行过滤 `entry.isFile`**，
  /// 否则会把目录当成曲目。
  ///
  /// 能力不支持时应抛 `DriveException(unsupported)`，UI 依据
  /// [Capabilities.canSearch] 提前隐藏入口，不会走到这里。
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  });

  /// 取播放直链。
  ///
  /// 返回值必须包含播放器所需的一切：URL + 必需的请求头 + 过期时间。
  ///
  /// **实现方应自行处理「哪条路由能拿到链」**：网盘的下载接口与播放接口
  /// 往往有不同的体积门槛（夸克：下载 50MiB / 播放无限制），
  /// 适配器内部要按「先试能播的那条、失败再兜底」的顺序走完，
  /// 不要把这个复杂度漏给上层。参见 `QuarkAdapter.resolveStream`。
  ///
  /// [qualityId] 是**期望档位**，取值来自上一次返回的
  /// `StreamTicket.qualities` 里某一项的 `QualityOption.id`。
  ///
  /// 它是「偏好」而不是「命令」，语义有三条：
  ///   - 传 `null` → 由适配器自己选最合适的一档（一般是原画）；
  ///   - 传了但服务端这次没给这一档 → **降级到可用档位并如实返回**，
  ///     绝不抛错。片源在不同时间返回的档位集合本来就会变；
  ///   - 适配器的取流路由**不支持多档位**（比如只剩兜底路由）时，
  ///     返回的 `StreamTicket.qualities` 为空，上层据此把清晰度菜单置灰。
  ///
  /// 之所以把档位放在这里而不是让上层「自己取一次链」：多条路由的降级
  /// 逻辑在适配器内部，只有它知道这一次实际走通了哪条、能拿到哪些档位。
  ///
  /// 所有路由都失败时才抛 `DriveException`；其中 [DriveErrorType.fileTooLarge]
  /// 表示**取链接口**拒绝了该文件，而不是文件本身有问题。
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId});

  /// 读取一个**小文件的原始字节**。
  ///
  /// 目前唯一的用途是读 `.cue` 分轨表（几 KB 的纯文本），因此刻意不做成
  /// 通用的「下载文件」：没有进度、没有分片、没有断点续传，只有
  /// 「把这点字节拿回来」。要下载音乐文件请走 [resolveStream]。
  ///
  /// **返回原始字节而不是 `String`** 是必须的：中文抓轨的 CUE 大量是 GBK，
  /// 谁先把它解成字符串，非法字节就已经变成 `�`，编码判定再也做不了。
  /// 解码交给调用方（见 `decodeCueBytes`）。
  ///
  /// [maxBytes] 是**防御性上限**：超过就抛错，避免某个路径把整个
  /// 765MB 的整轨 WAV 当成「小文本文件」拉进内存。
  ///
  /// 默认实现抛 `unsupported` —— 不是每家网盘都提供这条路径，而它只服务于
  /// 「CUE 增强」这一项**可选**能力：不支持时扫描照常进行，只是不展开整轨。
  /// 子类实现时也应保持这个契约：失败一律归一成 [DriveException]，
  /// 不要抛 dio / 平台异常。
  Future<Uint8List> readFileBytes(
    String fileId, {
    int maxBytes = 512 * 1024,
  }) {
    throw const DriveException(
      type: DriveErrorType.unsupported,
      message: '该网盘不支持读取文件内容',
    );
  }

  // ---------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------

  /// 根目录 ID。遍历的起点。
  String get rootId;

  /// 轻量健康检查：凭证是否仍然可用。用于「连接诊断」功能。
  Future<bool> ping();

  /// 释放资源。
  Future<void> dispose();
}

/// 适配器注册表。
///
/// UI 通过它枚举「当前支持哪些网盘」，扫描器通过它按 provider 取适配器。
/// 这样新增网盘只需在组合根注册一次。
abstract class DriveAdapterRegistry {
  /// 取指定网盘的适配器。未注册返回 `null`。
  CloudDriveAdapter? adapterFor(DriveProvider provider);

  /// 取指定网盘的适配器，未注册抛 [StateError]。
  CloudDriveAdapter requireAdapter(DriveProvider provider);

  /// 已注册的全部适配器
  List<CloudDriveAdapter> get all;

  /// 已注册的网盘列表
  List<DriveProvider> get providers => all.map((a) => a.provider).toList();
}
