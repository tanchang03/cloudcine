import 'dart:io';
import 'dart:typed_data';

import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/domain/adapters/cloud_drive_adapter.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:cloudcine/domain/services/library_backup.dart';
import 'package:cloudcine/domain/services/library_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试 `LibraryBackupService` 的导出/导入字节流往返与备份包格式。
///
/// 这组测试**不碰网络**：
/// - `exportBackup` 只读写本地文件，不需要适配器。
/// - `importBackup` 也只写本地文件。
/// - 备份包格式的 magic/manifest/dbLen 头部解析是往返正确性的关键 ——
///   字段偏移写错或长度算错，导入时会**静默地读到错位字节**，
///   不一定抛异常，但写出的 SQLite 文件会损坏。
///
/// 同步逻辑（`sync()`）需要网络替身，单独在下一组测试覆盖。
void main() {
  late Directory tempDir;
  late String dbPath;
  late String posterPath;
  late LibraryBackupService service;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('cloudcine_backup_test_');
  });

  setUp(() async {
    // 每个用例用独立的子目录，避免互相干扰
    final caseDir = Directory('${tempDir.path}/${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);

    dbPath = '${caseDir.path}/cloudcine.sqlite';
    posterPath = '${caseDir.path}/posters';

    // 创建一个假的 SQLite 文件（不需要真正的 SQLite，只要字节对就行）
    final fakeDb = File(dbPath);
    await fakeDb.writeAsBytes(_fakeSqliteHeader());

    // 创建海报缓存目录，放几张假图片
    final posterDir = Directory(posterPath);
    await posterDir.create(recursive: true);
    await File('${posterDir.path}/poster_001.jpg')
        .writeAsBytes(Uint8List.fromList(List.generate(256, (i) => i)));
    await File('${posterDir.path}/poster_002.jpg')
        .writeAsBytes(Uint8List.fromList(List.generate(128, (i) => i * 2)));

    service = LibraryBackupService(
      adapter: _NoOpAdapter(),
      databasePath: dbPath,
      posterCachePath: posterPath,
      deviceId: 'test-device-001',
      deviceName: '测试机器',
      schemaVersion: 6,
    );
  });

  tearDownAll(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('exportBackup → importBackup 往返', () {
    test('含海报 + 含设置：数据库字节和海报都原样恢复', () async {
      // 导出
      final bytes = await service.exportBackup(
        includePosters: true,
        includeSettings: true,
      );

      // 验证备份包头部
      expect(bytes[0], 0x43); // 'C'
      expect(bytes[1], 0x43); // 'C'
      expect(bytes[2], 0x42); // 'B'
      expect(bytes[3], 0x4B); // 'K'

      // 导入到新路径
      final restoreDbPath = '${tempDir.path}/restored.sqlite';
      final restorePosterPath = '${tempDir.path}/restored_posters';
      final manifest = await service.importBackup(
        bytes,
        targetDbPath: restoreDbPath,
        targetPosterPath: restorePosterPath,
      );

      // manifest 字段
      expect(manifest.deviceId, 'test-device-001');
      expect(manifest.deviceName, '测试机器');
      expect(manifest.schemaVersion, 6);
      expect(manifest.fileNames, contains('cloudcine.sqlite'));
      expect(manifest.fileNames, contains('posters/'));

      // 数据库字节原样恢复
      final originalDb = await File(dbPath).readAsBytes();
      final restoredDb = await File(restoreDbPath).readAsBytes();
      expect(restoredDb.length, originalDb.length);
      expect(restoredDb, equals(originalDb));

      // 海报文件也恢复了
      final restoredPosterDir = Directory(restorePosterPath);
      expect(restoredPosterDir.existsSync(), isTrue);
      final posterFiles = restoredPosterDir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet();
      expect(posterFiles, containsAll(['poster_001.jpg', 'poster_002.jpg']));

      // 海报内容原样
      final originalPoster = await File('$posterPath/poster_001.jpg').readAsBytes();
      final restoredPoster = await File('$restorePosterPath/poster_001.jpg').readAsBytes();
      expect(restoredPoster, equals(originalPoster));
    });

    test('不含海报：备份包更小，文件名只有 cloudcine.sqlite', () async {
      final withPosters = await service.exportBackup(includePosters: true);
      final withoutPosters = await service.exportBackup(includePosters: false);

      expect(withoutPosters.length, lessThan(withPosters.length));

      // 从不带海报的包中提取 manifest
      final manifest = _extractManifest(withoutPosters);
      expect(manifest.fileNames, ['cloudcine.sqlite']);
      expect(manifest.fileNames, isNot(contains('posters/')));
    });

    test('不含设置时 manifest 的 note 标注了', () async {
      final bytes = await service.exportBackup(
        includePosters: false,
        includeSettings: false,
      );
      final manifest = _extractManifest(bytes);
      expect(manifest.note, isNotNull);
      expect(manifest.note!, contains('不含设置'));
    });
  });

  group('备份包格式校验', () {
    test('magic bytes 必须是 CCBK', () async {
      final bytes = await service.exportBackup();

      // 前 4 字节是 magic
      expect(bytes.sublist(0, 4), Uint8List.fromList([0x43, 0x43, 0x42, 0x4B]));
    });

    test('manifest 长度字段正确编码（big-endian uint32）', () async {
      final bytes = await service.exportBackup();

      // bytes[4..8] 是 manifest 长度（big-endian）
      final manifestLen = ByteData.sublistView(bytes, 4, 8).getUint32(0);
      expect(manifestLen, greaterThan(0));
      expect(manifestLen, lessThan(10000)); // manifest JSON 不会很大

      // manifest 字节区间
      final manifestBytes = bytes.sublist(8, 8 + manifestLen);
      // 能解析成 JSON
      final manifest = BackupManifest.fromBytes(
        Uint8List.fromList(manifestBytes),
      );
      expect(manifest.deviceId, 'test-device-001');
    });

    test('数据库长度前缀（4 字节 big-endian）正确', () async {
      final bytes = await service.exportBackup(includePosters: false);

      // 布局：[magic(4)][manifestLen(4)][manifest][dbLen(4)][dbBytes]
      final manifestLen = ByteData.sublistView(bytes, 4, 8).getUint32(0);
      final dbLenOffset = 8 + manifestLen;
      final dbLen = ByteData.sublistView(bytes, dbLenOffset, dbLenOffset + 4)
          .getUint32(0);

      final originalDb = await File(dbPath).readAsBytes();
      expect(dbLen, originalDb.length);

      // dbBytes 紧跟 dbLen
      final dbStart = dbLenOffset + 4;
      final dbEnd = dbStart + dbLen;
      expect(dbEnd, bytes.length); // 不含海报时 dbBytes 到尾
    });

    test('损坏的 magic → 抛 FormatException', () async {
      final bytes = await service.exportBackup();
      // 篡改 magic
      bytes[0] = 0x00;

      expect(
        () => service.importBackup(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('截断的备份包 → 抛 FormatException', () async {
      final bytes = await service.exportBackup();
      // 截断到只有头部 + manifest 的一部分
      final truncated = bytes.sublist(0, 10);

      expect(
        () => service.importBackup(truncated),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('海报目录打包/解包', () {
    test('多个文件往返不丢、不重、不重命名', () async {
      final bytes = await service.exportBackup(includePosters: true);

      final restorePosterPath = '${tempDir.path}/poster_roundtrip';
      await service.importBackup(
        bytes,
        targetDbPath: '${tempDir.path}/db_rt.sqlite',
        targetPosterPath: restorePosterPath,
      );

      final restoredDir = Directory(restorePosterPath);
      final files = restoredDir.listSync().whereType<File>().toList();
      expect(files.length, 2);

      final names = files.map((f) => f.uri.pathSegments.last).toSet();
      expect(names, {'poster_001.jpg', 'poster_002.jpg'});
    });

    test('空海报目录 → 导出不含 posters/ 标记', () async {
      // 清空海报目录
      final dir = Directory(posterPath);
      for (final f in dir.listSync().whereType<File>()) {
        f.deleteSync();
      }

      final bytes = await service.exportBackup(includePosters: true);
      final manifest = _extractManifest(bytes);
      expect(manifest.fileNames, isNot(contains('posters/')));
    });
  });
}

/// 从备份字节流中提取 manifest（复刻 service 内部逻辑，供测试自验）。
BackupManifest _extractManifest(Uint8List bytes) {
  const magic = [0x43, 0x43, 0x42, 0x4B];
  if (bytes.length < 8) {
    throw const FormatException('备份包过短');
  }
  for (var i = 0; i < 4; i++) {
    if (bytes[i] != magic[i]) {
      throw const FormatException('magic 不匹配');
    }
  }
  final manifestLen = ByteData.sublistView(bytes, 4, 8).getUint32(0);
  final manifestBytes = bytes.sublist(8, 8 + manifestLen);
  return BackupManifest.fromBytes(Uint8List.fromList(manifestBytes));
}

/// 生成一个假的 SQLite 文件头（16 字节 magic + 随机填充）。
Uint8List _fakeSqliteHeader() {
  final header = Uint8List(256);
  // SQLite magic: "SQLite format 3\0"
  const sqliteMagic = [
    0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
    0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00,
  ];
  for (var i = 0; i < sqliteMagic.length; i++) {
    header[i] = sqliteMagic[i];
  }
  // 剩余填充非零字节，让测试能区分「是不是原样恢复了」
  for (var i = 16; i < 256; i++) {
    header[i] = (i * 7) & 0xFF;
  }
  return header;
}

/// 不操作的适配器 —— 导出/导入测试不需要网络。
class _NoOpAdapter extends CloudDriveAdapter {
  @override
  DriveProvider get provider => DriveProvider.quark;

  @override
  Capabilities get capabilities =>
      const Capabilities(provider: DriveProvider.quark, canListDirectory: true);

  @override
  String get rootId => 'root';

  @override
  Future<CloudAccount> authorize(AuthCredential credential) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}

  @override
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  }) async => const DrivePage(entries: []);

  @override
  Future<bool> ping() async => true;

  @override
  Future<Uint8List> readFileBytes(String fileId, {int maxBytes = 524288}) =>
      throw UnimplementedError();

  @override
  Future<CloudAccount?> restoreSession() async => null;

  @override
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId}) =>
      throw UnimplementedError();

  @override
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) async => const <DriveEntry>[];

  @override
  Future<void> signOut() async {}
}
