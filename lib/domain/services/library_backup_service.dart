import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/diagnostics/diag_log.dart';
import '../adapters/cloud_drive_adapter.dart';
import 'library_backup.dart';

/// 媒体库备份与同步服务。
///
/// 职责：
/// 1. **导出**：将本地 SQLite 数据库 + 海报缓存目录打包成一个备份包。
/// 2. **导入**：从备份包恢复数据库和海报缓存。
/// 3. **上传**：将备份包上传到网盘指定目录。
/// 4. **下载**：从网盘拉取远程备份包。
/// 5. **同步**：比对本地与远程备份版本，执行 Last-Write-Wins 合并。
///
/// ## 备份包格式（`.ccbak`）
///
/// 不是 ZIP —— 而是一个自描述的内存结构，分两部分：
///   1. 头部 4 字节：magic `CCBK` + 4 字节 manifest 长度（big-endian uint32）
///   2. manifest JSON（UTF-8）
///   3. 数据库字节
///   4. 海报缓存字节（如果包含）
///
/// 不用 ZIP 归档的理由：
///   - `dart:io` 没有内置 ZIP 支持，引入 `archive` 包多一个依赖；
///   - 备份内容只有两种文件（数据库 + 海报目录），不需要 ZIP 的随机文件访问；
///   - 自描述二进制格式的解析代码不到 20 行，比 ZIP 简单得多。
///
/// ## ⚠️ 不备份的内容
///
/// - **网盘凭证**（`__pus` / `__puus`）：它们是会话 Cookie，
///   寿命只有几天到几周，备份了到另一台机器上也早已过期。
///   新机器需要重新扫码登录。
/// - **TMDB API Key / 豆瓣 Cookie / OpenSubtitles Key**：
///   这些存在 `settings` 表里，会随数据库一起备份。
///   但用户可能不想让它们在多台机器间同步（比如公司机器 vs 家用机器）——
///   所以导入时提供「只恢复索引库、不恢复设置」的选项。
class LibraryBackupService {
  LibraryBackupService({
    required CloudDriveAdapter adapter,
    required String databasePath,
    required String posterCachePath,
    required String deviceId,
    required String deviceName,
    // 写进备份清单的 schema 版本。
    //
    // ⛔ **必填**，且必须传 `AppDatabase.currentSchemaVersion`。
    //    这里曾经有个 `= 6` 的默认值，而组合根没传 —— 于是**每一份备份的
    //    清单里都写着 `schema=6`**，`importBackup` 的「备份来自更高版本」
    //    校验（`manifest.schemaVersion > _schemaVersion`）永远为假、形同虚设。
    //    去掉默认值就是为了让「忘了传」变成**编译错误**，而不是一个只在
    //    排查兼容性问题时才暴露的静默错误（2026-10-07 实际踩到）。
    required int schemaVersion,
    Future<DateTime?> Function()? localModifiedAt,
    void Function()? onLibraryReplaced,
    // 覆盖库文件**之前**调用：组合根在这里关掉数据库连接。
    Future<void> Function()? closeDatabase,
    // 覆盖库文件**之后**调用：组合根在这里换一个**全新**的数据库实例
    // （并借这次打开触发 schema 迁移）。⛔ 不是「重开旧连接」——
    //    Drift 的 `close()` 是终局的，理由见 `_openDatabase` 的文档。
    Future<void> Function()? openDatabase,
  })  : _adapter = adapter,
        _databasePath = databasePath,
        _posterCachePath = posterCachePath,
        _deviceId = deviceId,
        _deviceName = deviceName,
        _schemaVersion = schemaVersion,
        _localModifiedAt = localModifiedAt,
        _onLibraryReplaced = onLibraryReplaced,
        _closeDatabase = closeDatabase,
        _openDatabase = openDatabase;

  final CloudDriveAdapter _adapter;
  final String _databasePath;
  final String _posterCachePath;
  final String _deviceId;
  final String _deviceName;
  final int _schemaVersion;

  /// 取「本地媒体库最后一次内容变更时间」的回调。
  ///
  /// 由组合根注入（查 `media_works.updated_at` 等列的最大值）。
  /// 为 `null` 时 [exportBackup] 不写 `libraryModifiedAt`，
  /// 同步会退化成拿 `createdAt` 比较 —— 那等于「永远本机新」，
  /// 只适合单机场景。**生产环境必须注入**。
  final Future<DateTime?> Function()? _localModifiedAt;

  /// 数据库文件被**整体替换**之后的钩子（[importBackup] 末尾调一次）。
  ///
  /// ## 为什么必须有这个钩子
  ///
  /// 恢复备份换掉的是**整个 `cloudcine.sqlite` 文件的字节**，`settings` 表
  /// 跟着一起变。而进程内凡是「读过设置」的地方都还拿着旧值：
  /// `SettingsStore._cache`、以及它上游的 `SettingsController` 状态。
  ///
  /// 后果静默且容易撞：在新机器上打开设置页（缓存里记下「TMDB Key 为空」）
  /// → 恢复电脑上的备份 → **设置页还是空的**，刮削继续走匿名额度。
  /// 这正是「token / cookie 随备份恢复」这条需求能不能成立的关键一步。
  ///
  /// ⛔ 由组合根注入，领域层不 import Riverpod：这里只知道「库换了，
  ///    你该把你那边的缓存扔掉」。
  final void Function()? _onLibraryReplaced;

  /// 覆盖库文件**之前**关连接。
  ///
  /// 只服务于「用备份包覆盖**整个**库文件」这一步：SQLite 连接还开着的时候
  /// 文件被换掉，它手里的页缓存与文件句柄指向的仍是旧库。
  ///
  /// ⛔ 与 [openDatabase] 必须**成对**使用，中间夹着写文件那一步。
  final Future<void> Function()? _closeDatabase;

  /// 覆盖库文件**之后**把连接接回去（并借这次打开触发 schema 迁移）。
  ///
  /// ⛔⛔ 这里**不是**「把刚才那个连接重新打开」—— 实现方必须换一个**全新的**
  ///    数据库实例。Drift 的 `close()` 是**终局**的：`_BaseExecutor._closed`
  ///    一旦置位，之后任何查询都抛
  ///    `StateError: Can't re-open a database after closing it. Please create a
  ///    new database connection and open that instead.`
  ///    （2026-10-07 的「恢复备份报错」正是这么写出来的：日志停在
  ///    「数据库 N 字节」之后，因为 `writeAsBytes` 之后那句「重开」抛了，
  ///    后面那行 `数据库已写入 …` 永远打不出来 —— 而库文件其实已经换掉了，
  ///    于是应用进入「文件是新的、连接是死的」状态，重启才好。）
  ///
  /// 为什么非重开不可：Drift 只在**打开连接时**读一次 `PRAGMA user_version`，
  /// 据此决定跑不跑 `onUpgrade`。不重开 ⇒ 迁移一步都不跑 ⇒ 磁盘上是旧结构、
  /// 连接以为还是当前版本 ⇒ 碰新列的查询抛 `no such column: followed`。
  final Future<void> Function()? _openDatabase;

  /// 备份包的 magic bytes。
  static const List<int> _magic = [0x43, 0x43, 0x42, 0x4B]; // 'CCBK'

  /// 备份包文件扩展名。
  static const String backupExtension = '.ccbak';

  /// 备份包在网盘中的默认目录名。
  static const String defaultBackupDir = '云影备份';

  // -------------------------------------------------------------------
  // 导出（本地打包）
  // -------------------------------------------------------------------

  /// 将本地媒体库打包成备份字节流。
  ///
  /// [includePosters] 为 `false` 时只备份数据库（体积小，适合频繁同步）。
  ///
  /// ⚠️ **[includeSettings] 目前只是清单上的标注，不做实际裁剪。**
  /// 设置项存在 `cloudcine.sqlite` 的 `settings` 表里，而这里导出的是
  /// **整个数据库文件的原始字节**（见下方 `dbBytesToWrite`），所以在字节
  /// 层面剔掉一张表是做不到的。传 `false` 的后果只有两条：
  ///   1. 日志里多一行「标注不含设置」；
  ///   2. manifest 的 `note` 变成「不含设置」。
  /// 设置**照样**在包里。要真正做到「不带走设置」，得先把库 `VACUUM INTO`
  /// 一份副本、在副本上 `DELETE FROM settings`、再读副本的字节 —— 目前没做，
  /// 而且 UI 三条通道（上传备份 / 同步 / 从网盘恢复）全部传 `true`，
  /// 所以这个分支当下是够不到的。
  ///
  /// 返回的字节流可以直接写文件或上传网盘。
  Future<Uint8List> exportBackup({
    bool includePosters = true,
    bool includeSettings = true,
    String? note,
  }) async {
    diag.info('备份', '开始导出备份'
        '（含海报=$includePosters, 含设置=$includeSettings）');

    // 1. 读数据库
    final dbFile = File(_databasePath);
    if (!await dbFile.exists()) {
      throw StateError('数据库文件不存在：$_databasePath');
    }
    final dbBytes = await dbFile.readAsBytes();
    diag.info('备份', '数据库 ${dbBytes.length} 字节');

    // 2. 读海报缓存（可选）
    Uint8List? posterBytes;
    var posterCount = 0;
    if (includePosters) {
      final posterDir = Directory(_posterCachePath);
      if (await posterDir.exists()) {
        final entries = posterDir.listSync(recursive: false);
        posterCount = entries.whereType<File>().length;
        if (posterCount > 0) {
          // 把海报目录打包：用简单的 length-prefix 格式
          final packed = _packDirectory(posterDir);
          posterBytes = packed;
          diag.info('备份', '海报缓存 $posterCount 个文件 '
              '${packed.length} 字节');
        }
      }
    }

    // 3. 设置不单独处理 —— 它就是数据库里的一张表，跟着 dbBytes 一起走。
    //    ⚠️ 这里**没有**「剔除 settings 表」的实现（原因见 exportBackup 的
    //    文档：SQLite 没法在字节层面删表）。保留 includeSettings 参数是为了
    //    清单语义与将来的实现，不要误以为传 false 就真的不带设置。
    Uint8List dbBytesToWrite = dbBytes;
    if (!includeSettings) {
      diag.info('备份', '标注不含设置（导入时保留本地设置）');
      // 仅标注，见上方说明。
    }

    // 4. 构造 manifest
    final fileNames = <String>[
      'cloudcine.sqlite',
      if (posterBytes != null) 'posters/',
    ];
    // 库内容变更时间：同步的 LWW 判据。取不到（空库 / 没注入回调）时为 null。
    final modifiedAt = await _localModifiedAt?.call();
    final manifest = BackupManifest(
      deviceId: _deviceId,
      deviceName: _deviceName,
      createdAt: DateTime.now().toUtc(),
      libraryModifiedAt: modifiedAt?.toUtc(),
      schemaVersion: _schemaVersion,
      fileNames: fileNames,
      note: note ?? (includeSettings ? null : '不含设置'),
    );
    diag.info('备份', '清单：库内容变更时间='
        '${modifiedAt?.toIso8601String() ?? "无（空库）"}');

    // 5. 组装字节流
    //
    // 格式：[magic(4)][manifestLen(4)][manifest][dbLen(4)][dbBytes][posterData]
    // dbLen 前缀让导入时能精确切分数据库与海报数据。
    final manifestBytes = manifest.toBytes();
    final header = _encodeHeader(manifestBytes.length);
    final dbLenBytes = ByteData(4)..setUint32(0, dbBytesToWrite.length);

    final output = BytesBuilder();
    output.add(header);
    output.add(manifestBytes);
    output.add(dbLenBytes.buffer.asUint8List());
    output.add(dbBytesToWrite);
    final packedPosters = posterBytes;
    if (packedPosters != null) {
      output.add(packedPosters);
    }

    final result = output.toBytes();
    diag.info('备份', '导出完成：${result.length} 字节'
        '（manifest=${manifestBytes.length}, '
        'db=${dbBytesToWrite.length}, '
        'posters=${posterBytes?.length ?? 0}）');
    return result;
  }

  // -------------------------------------------------------------------
  // 导入（本地恢复）
  // -------------------------------------------------------------------

  /// 从备份字节流恢复媒体库。
  ///
  /// [targetDbPath] 是恢复后数据库的写入路径（通常就是 `_databasePath`）。
  /// [targetPosterPath] 是海报缓存的写入目录。
  ///
  /// ⚠️ **[restoreSettings] 同样只是标注，不做实际过滤。** 导入是把整个
  /// 数据库文件覆盖过去（见下方 `dbFile.writeAsBytes`），`settings` 表随之
  /// 一起被覆盖 —— SQLite 没法在字节层面只留一部分表。传 `false` 的效果只有
  /// 一行日志。UI 三条通道全部用默认的 `true`，所以这个分支当下够不到。
  /// 真要「保留本地设置」，做法是先写库、再打开数据库把本地设置回写一遍。
  ///
  /// ⚠️ 恢复前必须先关掉数据库连接、写完再换一个**新实例**接回去 ——
  /// 这两步由 [closeDatabase] / [openDatabase] 两个回调交给组合根做，
  /// 缺了它们恢复一定坏（见 [openDatabase] 的文档）。
  Future<BackupManifest> importBackup(
    Uint8List bytes, {
    String? targetDbPath,
    String? targetPosterPath,
    bool restoreSettings = true,
  }) async {
    diag.info('备份', '开始导入备份（${bytes.length} 字节）');

    // 1. 解析头部
    final manifestLen = _decodeHeader(bytes);
    if (manifestLen < 0) {
      throw const FormatException('备份包格式错误：magic 不匹配');
    }

    // 2. 解析 manifest
    final manifestStart = _magic.length + 4;
    if (manifestStart + manifestLen > bytes.length) {
      throw const FormatException('备份包格式错误：manifest 长度超出包范围');
    }
    final manifestBytes = bytes.sublist(manifestStart, manifestStart + manifestLen);
    final manifest = BackupManifest.fromBytes(
      Uint8List.fromList(manifestBytes),
    );
    diag.info('备份', '清单：$manifest');

    // 3. 校验 schema 版本。
    //
    // ⛔ 两个方向都要说清楚，因为它们**都**会发生，而且**都**能正常工作
    //    （第 5 步写完文件后会重开连接，Drift 按库文件里真实的 `user_version`
    //    跑 `onUpgrade` 逐级补齐）：
    //      · 更高版本（别人用新版 App 备份的）：本机代码不认识多出来的列，
    //        迁移也补不回来，只能警告；
    //      · 更低版本（v6 / v16 的老备份）：`onUpgrade` 会把缺的表 / 列逐级
    //        补上 —— 这是**正常路径**，但必须留一行日志：一旦迁移失败，
    //        排查的人得先知道「这份备份是旧的」。
    if (manifest.schemaVersion > _schemaVersion) {
      diag.warn('备份', '备份来自更高版本的数据库'
          '（${manifest.schemaVersion} > $_schemaVersion），'
          '多出来的列会被忽略');
    } else if (manifest.schemaVersion < _schemaVersion) {
      diag.info('备份', '备份来自较低版本的数据库'
          '（${manifest.schemaVersion} < $_schemaVersion），'
          '恢复后会跑 schema 迁移补齐');
    }

    // 4. 提取数据库字节
    //
    // 格式：[magic(4)][manifestLen(4)][manifest][dbLen(4)][dbBytes][posterData]
    // 先读 dbLen，再按长度切分。
    final dataOffset = _magic.length + 4 + manifestLen;
    if (dataOffset + 4 > bytes.length) {
      throw const FormatException('备份包格式错误：缺少数据库长度');
    }
    final dbLen = ByteData.sublistView(bytes, dataOffset, dataOffset + 4)
        .getUint32(0);
    final dbStart = dataOffset + 4;
    final dbEnd = dbStart + dbLen;
    if (dbEnd > bytes.length) {
      throw FormatException(
        '备份包格式错误：数据库字节超出包范围'
        '（需要 $dbEnd，只有 ${bytes.length}）',
      );
    }
    final dbBytes = bytes.sublist(dbStart, dbEnd);
    diag.info('备份', '数据库 ${dbBytes.length} 字节');

    // 5. 写入数据库文件。
    //
    // ⛔⛔ **必须先关连接，写完再把连接接回来**。这是 2026-10-07 那次
    //     「恢复备份后报 `no such column: followed`」的根因，两个后果都要说清楚：
    //
    //   ① **不关就写**：SQLite 连接还开着，文件被换掉之后它手里的页缓存与
    //      文件句柄指向的仍是旧库。写入本身可能侥幸成功（`flush: true`），
    //      于是日志里一切正常 —— 坏在下一步。
    //
    //   ② **不重开**：Drift 只在**打开连接时**读一次 `PRAGMA user_version`
    //      并据此决定跑不跑 `onUpgrade`。连接没重开 ⇒ 它仍然认为库就是当前
    //      版本 ⇒ **迁移一步都不跑**。而磁盘上的文件其实是旧版本的结构
    //      （v16 没有 `followed` / `follow_started_at` / `follow_checked_at` /
    //      `new_item_count` 四列）⇒ 恢复之后凡是碰追剧的查询都抛
    //      `no such column`，**其它查询却正常** —— 表现就是「库看着恢复了，
    //      但某个功能炸了」。
    //
    //   ⛔⛔ 而第 ② 步**不能**实现成「把刚才那个连接重新打开」：Drift 的
    //      `close()` 是终局的，关掉之后任何查询都抛
    //      `StateError: Can't re-open a database after closing it`。
    //      实现方（组合根）必须换一个**全新实例**，详见 [_openDatabase] 的文档。
    //      2026-10-07 第二轮就是栽在这里：库文件换掉了、连接却再也起不来，
    //      用户看到「恢复失败：Bad state: Can't re-open a database…」，
    //      而日志停在「数据库 1884160 字节」之后一行不多。
    //
    //    Android 端一直是对的（`LibraryDb.replaceWithRawBytes` 也是
    //    `close() → writeBytes() → open()`）—— 它的 `open()` 会**重建**连接
    //    并补表补列，不是重开旧连接。PC 端这次是照抄了前半句、漏了「重建」。
    final dbPath = targetDbPath ?? _databasePath;
    final dbFile = File(dbPath);
    await dbFile.parent.create(recursive: true);
    if (_closeDatabase == null || _openDatabase == null) {
      // ⛔ 缺这两个回调时**一定会坏**（见上），所以不能静默放过：
      //    生产组合根必须注入；只做 export 的调用方（多为单测）可以不注入。
      diag.warn('备份', '未注入 closeDatabase / openDatabase —— '
          '覆盖库文件后不会重开连接，schema 迁移不会运行，'
          '碰新列的查询会抛 no such column');
    }
    await _closeDatabase?.call();
    await dbFile.writeAsBytes(dbBytes, flush: true);
    await _openDatabase?.call();
    diag.info('备份', '数据库已写入 $dbPath（已换新连接，迁移随之完成）');

    // 6. 恢复海报缓存（如果备份包含且指定了目标路径）
    final posterPath = targetPosterPath ?? _posterCachePath;
    if (manifest.fileNames.contains('posters/') && dbEnd < bytes.length) {
      final posterBytes = bytes.sublist(dbEnd);
      final posterDir = Directory(posterPath);
      if (!await posterDir.exists()) {
        await posterDir.create(recursive: true);
      }
      final count = _unpackDirectory(posterBytes, posterDir);
      diag.info('备份', '海报缓存已恢复 $count 个文件到 $posterPath');
    }

    // 7. 设置表已经跟着数据库文件一起被覆盖了 —— 见 importBackup 的文档。
    //    这里不做任何过滤，只留一行日志说明调用方**意图**是什么。
    if (!restoreSettings) {
      diag.info('备份', '调用方要求保留本地设置，但当前实现无法做到'
          '（settings 表随数据库文件一起覆盖）');
    }

    // 8. 通知组合根「库已经换人了」。
    //
    // ⛔ 放在**最后**、而且**无条件**调：前面任何一步抛异常都不会走到这里，
    //    而那时候库文件可能已经写了一半 —— 让调用方去读一份半成品设置
    //    不如让它在下次成功恢复时再清。
    // ⛔ 这里必须**同步**调（不是 `await` 一个 Future）：调用方要做的事就是
    //    「清一个内存 Map + invalidate 一个 provider」，都是同步的；
    //    做成异步的话，紧接着读设置的那段代码有概率抢在清缓存之前跑。
    _onLibraryReplaced?.call();

    return manifest;
  }

  // -------------------------------------------------------------------
  // 网盘上传 / 下载
  // -------------------------------------------------------------------

  /// 确保备份目录存在于网盘根目录下，返回其 fid。
  ///
  /// 如果备份目录不存在就创建。同名目录重复创建是幂等的。
  Future<String> ensureBackupDir({String dirName = defaultBackupDir}) async {
    // 先在根目录搜一下
    final page = await _adapter.listDirectory(
      dirId: _adapter.rootId,
      pageSize: 200,
    );
    for (final entry in page.entries) {
      if (entry.isDirectory && entry.name == dirName) {
        diag.info('备份', '备份目录已存在：fid=${entry.id}');
        return entry.id;
      }
    }
    // 不存在则创建
    final fid = await _adapter.createFolder(
      parentId: _adapter.rootId,
      name: dirName,
    );
    diag.info('备份', '备份目录已创建：fid=$fid');
    return fid;
  }

  /// 上传备份包到网盘。
  ///
  /// [bytes] 是 `exportBackup` 返回的字节流。
  /// 返回上传后的文件 fid。
  Future<String> uploadBackupToDrive(
    Uint8List bytes, {
    String dirName = defaultBackupDir,
    String? fileName,
    void Function(int sent, int total)? onProgress,
  }) {
    final name = fileName ??
        'cloudcine_backup_${DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first}$backupExtension';

    return uploadFileToBackupDir(
      fileName: name,
      bytes: bytes,
      dirName: dirName,
      onProgress: onProgress,
      logTag: '备份',
      what: '备份包',
    );
  }

  /// 把一个**任意文件**上传到网盘备份目录（目录不存在则创建）。
  ///
  /// 与 [uploadBackupToDrive] 是同一个动作，只是**不带备份包的语义假设**：
  /// 文件名与扩展名由调用方给全。诊断日志就是靠它上云的 —— 它借用的只是
  /// 「往那个已经存在的目录里放个文件」这条通道，不需要也不该被打包成备份。
  ///
  /// ⚠️ **同名覆盖是「先删后传」**，中间有一段「旧文件已经没了、新文件还没上去」
  /// 的空窗。所以调用方给的文件名**必须带时间戳**，别用固定名 ——
  /// 否则一次失败的上传会把上一份日志也一起带走。
  ///
  /// [logTag] 只影响日志里的分类标签，[what] 只影响日志正文的措辞。
  Future<String> uploadFileToBackupDir({
    required String fileName,
    required List<int> bytes,
    String dirName = defaultBackupDir,
    void Function(int sent, int total)? onProgress,
    String logTag = '上传',
    String what = '文件',
  }) async {
    final dirFid = await ensureBackupDir(dirName: dirName);

    diag.info(logTag, '上传$what「$fileName」（${bytes.length} 字节）'
        '到目录「$dirName」');

    // 如果同名文件已存在，先删掉（覆盖语义）
    final existing = await _adapter.listDirectory(
      dirId: dirFid,
      pageSize: 100,
    );
    for (final entry in existing.entries) {
      if (!entry.isDirectory && entry.name == fileName) {
        diag.info(logTag, '同名文件已存在，先删除旧文件 fid=${entry.id}');
        await _adapter.deleteFiles(fileIds: [entry.id]);
        break;
      }
    }

    final fid = await _adapter.uploadFile(
      parentId: dirFid,
      fileName: fileName,
      bytes: bytes,
      onProgress: onProgress,
    );
    diag.info(logTag, '上传完成 fid=$fid');
    return fid;
  }

  /// 列出网盘备份目录中可用的备份文件。
  ///
  /// 返回值按修改时间倒序排列（最新在前）。
  Future<List<RemoteBackupEntry>> listRemoteBackups({
    String dirName = defaultBackupDir,
  }) async {
    final dirFid = await ensureBackupDir(dirName: dirName);
    final page = await _adapter.listDirectory(
      dirId: dirFid,
      pageSize: 100,
    );

    final entries = page.entries
        .where((e) => !e.isDirectory && e.name.endsWith(backupExtension))
        .map((e) => RemoteBackupEntry(
              fileId: e.id,
              name: e.name,
              sizeBytes: e.sizeBytes ?? 0,
              modifiedAt: e.modifiedAt,
            ))
        .toList();

    entries.sort((a, b) {
      final ma = a.modifiedAt;
      final mb = b.modifiedAt;
      if (ma == null && mb == null) return 0;
      if (ma == null) return 1;
      if (mb == null) return -1;
      return mb.compareTo(ma);
    });

    return entries;
  }

  /// 从网盘下载指定备份文件。
  ///
  /// 返回备份包的字节流。
  Future<Uint8List> downloadBackup(RemoteBackupEntry entry) async {
    diag.info('备份', '下载备份「${entry.name}」（${entry.sizeBytes}B）');
    // readFileBytes 内部自己解析直链，不需要先 resolveStream。
    final bytes = await _adapter.readFileBytes(
      entry.fileId,
      maxBytes: 512 * 1024 * 1024, // 512MB 上限（含海报缓存时可能较大）
    );
    diag.info('备份', '下载完成：${bytes.length}B');
    return bytes;
  }

  // -------------------------------------------------------------------
  // 播放进度文件（独立于媒体库备份的一条小通道）
  // -------------------------------------------------------------------

  /// 播放进度在网盘上的**固定文件名**。
  ///
  /// ## ⛔ 为什么是固定名，而备份包必须带时间戳
  ///
  /// 两者是**相反的**需求，别把规则串了：
  ///
  ///   * 备份包（`.ccbak`）是**多份历史**：用户会想「退回昨天那份」，所以
  ///     文件名带时间戳、每次上传都是一份新文件；
  ///   * 进度文件是**一份当前状态**：它要的是「两端看到同一个文件」，
  ///     所以固定名 + 覆盖写。带时间戳的话，每次同步都会在网盘上堆一个新
  ///     文件，而下一轮又只会去读**最新**的那一个 —— 目录会无限膨胀，
  ///     且「哪份才是当前状态」要靠修改时间猜。
  ///
  /// ⛔ 代价是「同名覆盖 = 先删后传」中间有一段空窗（见
  ///    [uploadFileToBackupDir]）。进度是**可再生 + 逐条合并**的数据：
  ///    真丢了也只是这一轮同步白跑，下一轮 30 分钟后会重来。所以这个空窗
  ///    在这里是可接受的，而备份包那边不可接受。
  static const String progressFileName = 'playback_progress.json';

  /// 下载网盘上的进度文件。**网盘上还没有 / 目录不存在时返回 `null`。**
  ///
  /// ⛔ 这条路**绝不创建目录**：它是每次启动都会跑的只读探测，从没备份过的
  ///    用户不该被塞一个空目录。创建只在 [uploadProgressFile] 里发生。
  Future<Uint8List?> downloadProgressFile({
    String dirName = defaultBackupDir,
    int maxBytes = 32 * 1024 * 1024,
  }) async {
    final dirFid = await _findBackupDir(dirName);
    if (dirFid == null) {
      diag.info('进度', '网盘上还没有「$dirName」目录，跳过下载');
      return null;
    }
    final page = await _adapter.listDirectory(dirId: dirFid, pageSize: 200);
    for (final e in page.entries) {
      if (e.isDirectory || e.name != progressFileName) continue;
      final bytes = await _adapter.readFileBytes(e.id, maxBytes: maxBytes);
      diag.info('进度', '已下载远程进度文件：${bytes.length} 字节');
      return bytes;
    }
    diag.info('进度', '网盘上没有「$progressFileName」，跳过');
    return null;
  }

  /// 把进度文件覆盖上传到网盘（目录不存在则创建）。返回 fid。
  Future<String> uploadProgressFile(
    Uint8List bytes, {
    String dirName = defaultBackupDir,
  }) {
    diag.info('进度', '上传进度文件（${bytes.length} 字节）');
    return uploadFileToBackupDir(
      fileName: progressFileName,
      bytes: bytes,
      dirName: dirName,
      logTag: '进度',
      what: '进度文件',
    );
  }

  /// 在根目录下找一个**已存在**的目录，不存在返回 `null`（不创建）。
  Future<String?> _findBackupDir(String dirName) async {
    final page = await _adapter.listDirectory(
      dirId: _adapter.rootId,
      pageSize: 200,
    );
    for (final entry in page.entries) {
      if (entry.isDirectory && entry.name == dirName) return entry.id;
    }
    return null;
  }

  // -------------------------------------------------------------------
  // 同步逻辑
  // -------------------------------------------------------------------

  /// 同步本地与远程备份。
  ///
  /// 策略（Last-Write-Wins，比的是**库内容变更时间**，不是备份文件时间）：
  /// - 远程比本地新 → 下载远程并恢复本地
  /// - 本地比远程新 → 导出本地并上传覆盖远程
  /// - 相同时间戳 → 无操作
  /// - 不同设备且时间戳差 < 60s → 冲突，交给用户
  ///
  /// ⚠️ **空库永远让远程赢**：本地库还没有任何内容时（[BackupManifest
  /// .libraryModifiedAt] 为 `null`），直接走「下载恢复」。这是新机器的
  /// 正路 —— 否则刚装好的机器会拿空库把网盘上的好备份覆盖掉。
  ///
  /// 返回同步结果描述。
  Future<SyncResult> sync({
    String dirName = defaultBackupDir,
    bool includePosters = true,
    bool includeSettings = true,
  }) async {
    diag.info('同步', '开始同步（dir=$dirName）');

    // 1. 导出本地备份（临时，只取 manifest 对比时间戳）
    final localBytes = await exportBackup(
      includePosters: false,
      includeSettings: false,
    );
    // 从本地字节流中提取 manifest 做时间戳对比
    final localManifest = _extractManifest(localBytes);
    diag.info('同步', '本地库内容变更时间：'
        '${localManifest.libraryModifiedAt?.toIso8601String() ?? "无（空库）"}');

    // 2. 列出远程备份
    final remoteBackups = await listRemoteBackups(dirName: dirName);

    // 3. 没有远程备份 → 直接上传本地
    if (remoteBackups.isEmpty) {
      diag.info('同步', '远程无备份，执行首次上传');
      final bytes = await exportBackup(
        includePosters: includePosters,
        includeSettings: includeSettings,
      );
      await uploadBackupToDrive(bytes, dirName: dirName);
      return SyncResult.uploaded(
        localManifest.effectiveModifiedAt,
        '首次上传到远程',
      );
    }

    // 4. 取最新的一份远程备份
    final latestRemote = remoteBackups.first;
    diag.info('同步', '远程最新备份：${latestRemote.name}');

    // 5. 下载远程备份的 manifest（下载整个文件后解析）
    //    对于较大的备份包，这里下载完整包是为了能提取 manifest
    //    —— 实际场景中媒体库备份包通常在几 MB 到几十 MB，可接受。
    final remoteBytes = await downloadBackup(latestRemote);
    final remoteManifest = _extractManifest(remoteBytes);
    diag.info('同步', '远程库内容变更时间：'
        '${remoteManifest.effectiveModifiedAt.toIso8601String()}');

    // 6. 本地是空库 → 无条件让远程赢（新机器的正路）
    if (!localManifest.hasLibraryContent) {
      diag.info('同步', '本地是空库，直接下载恢复远程备份');
      await importBackup(remoteBytes, restoreSettings: includeSettings);
      return SyncResult.restored(
        remoteManifest.effectiveModifiedAt,
        '本地还没有媒体库，已从远程恢复',
      );
    }

    // 7. 远程是空备份 → 绝不拿它覆盖本地（镜像情形：别人从新机器推过一次）
    if (!remoteManifest.hasLibraryContent) {
      diag.info('同步', '远程是空备份，忽略它并上传本地');
      final bytes = await exportBackup(
        includePosters: includePosters,
        includeSettings: includeSettings,
      );
      await uploadBackupToDrive(bytes, dirName: dirName);
      return SyncResult.uploaded(
        localManifest.effectiveModifiedAt,
        '远程备份是空库，已用本地覆盖',
      );
    }

    // 8. 对比时间戳
    if (localManifest.conflictsWith(remoteManifest)) {
      return SyncResult.conflict(
        localManifest,
        remoteManifest,
        '两台设备在相近时间都做了备份，需要手动选择',
      );
    }

    final localNewer =
        localManifest.effectiveModifiedAt.isAfter(remoteManifest.effectiveModifiedAt);

    if (localNewer) {
      // 本地新 → 上传
      diag.info('同步', '本地比远程新，上传覆盖远程');
      final bytes = await exportBackup(
        includePosters: includePosters,
        includeSettings: includeSettings,
      );
      await uploadBackupToDrive(bytes, dirName: dirName);
      return SyncResult.uploaded(
        localManifest.effectiveModifiedAt,
        '本地比远程新，已上传覆盖远程',
      );
    } else if (remoteManifest.effectiveModifiedAt
        .isAfter(localManifest.effectiveModifiedAt)) {
      // 远程新 → 下载恢复
      diag.info('同步', '远程比本地新，下载恢复本地');
      await importBackup(
        remoteBytes,
        restoreSettings: includeSettings,
      );
      return SyncResult.restored(
        remoteManifest.effectiveModifiedAt,
        '远程比本地新，已下载恢复本地',
      );
    } else {
      // 时间戳相同 → 无操作
      diag.info('同步', '本地与远程时间戳相同，无需同步');
      return SyncResult.unchanged('本地与远程时间戳相同');
    }
  }

  // -------------------------------------------------------------------
  // 内部工具
  // -------------------------------------------------------------------

  /// 编码头部：magic(4) + manifest 长度(4, big-endian)。
  Uint8List _encodeHeader(int manifestLen) {
    final header = ByteData(8);
    for (var i = 0; i < 4; i++) {
      header.setUint8(i, _magic[i]);
    }
    header.setUint32(4, manifestLen);
    return header.buffer.asUint8List();
  }

  /// 解码头部，返回 manifest 长度。失败返回 -1。
  int _decodeHeader(Uint8List bytes) {
    if (bytes.length < 8) return -1;
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) return -1;
    }
    return ByteData.sublistView(bytes, 4, 8).getUint32(0);
  }

  /// 从备份字节流中提取 manifest（不恢复数据）。
  BackupManifest _extractManifest(Uint8List bytes) {
    final manifestLen = _decodeHeader(bytes);
    if (manifestLen < 0) {
      throw const FormatException('备份包格式错误');
    }
    final manifestBytes =
        bytes.sublist(_magic.length + 4, _magic.length + 4 + manifestLen);
    return BackupManifest.fromBytes(Uint8List.fromList(manifestBytes));
  }

  /// 把目录打包成字节流。
  ///
  /// 格式：对每个文件写 `[nameLen(4)][name(utf8)][dataLen(4)][data]`，
  /// 末尾写 `[0]` 表示结束。
  Uint8List _packDirectory(Directory dir) {
    final output = BytesBuilder();
    final entries = dir.listSync(recursive: false);
    for (final entry in entries) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final nameBytes = utf8.encode(name);
      final data = entry.readAsBytesSync();

      final nameHeader = ByteData(4)..setUint32(0, nameBytes.length);
      output.add(nameHeader.buffer.asUint8List());
      output.add(nameBytes);

      final dataHeader = ByteData(4)..setUint32(0, data.length);
      output.add(dataHeader.buffer.asUint8List());
      output.add(data);
    }
    final terminator = ByteData(4)..setUint32(0, 0);
    output.add(terminator.buffer.asUint8List());
    return output.toBytes();
  }

  /// 从字节流解包目录。返回解出的文件数。
  int _unpackDirectory(Uint8List bytes, Directory dir) {
    var offset = 0;
    var count = 0;
    while (offset < bytes.length) {
      if (offset + 4 > bytes.length) break;
      final nameLen = ByteData.sublistView(bytes, offset, offset + 4)
          .getUint32(0);
      offset += 4;
      if (nameLen == 0) break; // 终止标记

      if (offset + nameLen > bytes.length) break;
      final name = utf8.decode(bytes.sublist(offset, offset + nameLen));
      offset += nameLen;

      if (offset + 4 > bytes.length) break;
      final dataLen = ByteData.sublistView(bytes, offset, offset + 4)
          .getUint32(0);
      offset += 4;

      if (offset + dataLen > bytes.length) break;
      final data = bytes.sublist(offset, offset + dataLen);
      offset += dataLen;

      final file = File('${dir.path}${Platform.pathSeparator}$name');
      file.writeAsBytesSync(data, flush: true);
      count++;
    }
    return count;
  }
}

/// 远程备份条目。
class RemoteBackupEntry {
  const RemoteBackupEntry({
    required this.fileId,
    required this.name,
    required this.sizeBytes,
    this.modifiedAt,
  });

  final String fileId;
  final String name;
  final int sizeBytes;
  final DateTime? modifiedAt;

  @override
  String toString() =>
      'RemoteBackupEntry(name=$name, size=$sizeBytes, at=$modifiedAt)';
}

/// 同步结果。
class SyncResult {
  const SyncResult._({
    required this.action,
    required this.message,
    this.localTimestamp,
    this.remoteTimestamp,
  });

  final SyncAction action;
  final String message;
  final DateTime? localTimestamp;
  final DateTime? remoteTimestamp;

  factory SyncResult.uploaded(DateTime at, String msg) =>
      SyncResult._(action: SyncAction.uploaded, message: msg, localTimestamp: at);
  factory SyncResult.restored(DateTime at, String msg) =>
      SyncResult._(action: SyncAction.restored, message: msg, remoteTimestamp: at);
  factory SyncResult.unchanged(String msg) =>
      SyncResult._(action: SyncAction.unchanged, message: msg);
  factory SyncResult.conflict(
    BackupManifest local,
    BackupManifest remote,
    String msg,
  ) => SyncResult._(
      action: SyncAction.conflict,
      message: msg,
      localTimestamp: local.createdAt,
      remoteTimestamp: remote.createdAt,
    );
}

/// 同步执行的动作。
enum SyncAction {
  uploaded('已上传'),
  restored('已恢复'),
  unchanged('无变化'),
  conflict('冲突');

  const SyncAction(this.label);
  final String label;
}
