import 'package:cloudcine/domain/services/library_backup.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测 BackupManifest 的序列化与同步判据。
///
/// 这组测试只覆盖纯逻辑（不碰 IO），因为跨机同步的正确性全靠
/// manifest 的字段判定 —— 序列化丢字段或冲突判定写反了，
/// 同步就会静默地往错误方向覆盖，而且**不报错**。
void main() {
  group('BackupManifest 序列化往返', () {
    test('toJson → fromJson 拿回全部字段', () {
      final m = BackupManifest(
        deviceId: 'uuid-abc-123',
        deviceName: 'Tandy的MacBook Pro',
        createdAt: DateTime.utc(2026, 10, 1, 12, 0, 0),
        schemaVersion: 6,
        fileNames: const ['cloudcine.sqlite', 'posters/'],
        note: '测试备份',
      );

      final restored = BackupManifest.fromJson(m.toJson());

      expect(restored.deviceId, 'uuid-abc-123');
      expect(restored.deviceName, 'Tandy的MacBook Pro');
      expect(restored.createdAt, m.createdAt);
      expect(restored.schemaVersion, 6);
      expect(restored.fileNames, ['cloudcine.sqlite', 'posters/']);
      expect(restored.note, '测试备份');
    });

    test('toBytes → fromBytes 拿回全部字段（字节层面往返）', () {
      final m = BackupManifest(
        deviceId: 'dev-x',
        deviceName: '工作站',
        createdAt: DateTime.utc(2026, 9, 30, 8, 30),
        schemaVersion: 6,
        fileNames: const ['cloudcine.sqlite'],
      );

      final restored = BackupManifest.fromBytes(m.toBytes());

      expect(restored.deviceId, 'dev-x');
      expect(restored.deviceName, '工作站');
      expect(restored.createdAt, m.createdAt);
      expect(restored.fileNames, ['cloudcine.sqlite']);
      expect(restored.note, isNull);
    });

    test('缺字段时安全降级（老版本备份可能没有 note / deviceName）', () {
      final restored = BackupManifest.fromJson({});

      expect(restored.deviceId, 'unknown');
      expect(restored.deviceName, '未知设备');
      // epoch 时间作为兜底
      expect(
        restored.createdAt,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      expect(restored.schemaVersion, 1);
      expect(restored.fileNames, isEmpty);
    });
  });

  group('sameDevice', () {
    test('同一 deviceId → true', () {
      final a = _manifest(deviceId: 'aaa', at: DateTime.utc(2026, 1, 1));
      final b = _manifest(deviceId: 'aaa', at: DateTime.utc(2026, 6, 1));
      expect(a.sameDevice(b), isTrue);
    });

    test('不同 deviceId → false', () {
      final a = _manifest(deviceId: 'aaa', at: DateTime.utc(2026, 1, 1));
      final b = _manifest(deviceId: 'bbb', at: DateTime.utc(2026, 1, 1));
      expect(a.sameDevice(b), isFalse);
    });
  });

  group('isNewerThan', () {
    test('晚 1 秒 → true', () {
      final a = _manifest(at: DateTime.utc(2026, 1, 1, 0, 0, 1));
      final b = _manifest(at: DateTime.utc(2026, 1, 1, 0, 0, 0));
      expect(a.isNewerThan(b), isTrue);
    });

    test('早 1 秒 → false', () {
      final a = _manifest(at: DateTime.utc(2026, 1, 1, 0, 0, 0));
      final b = _manifest(at: DateTime.utc(2026, 1, 1, 0, 0, 1));
      expect(a.isNewerThan(b), isFalse);
    });

    test('完全相同 → false（不是严格 after）', () {
      final t = DateTime.utc(2026, 1, 1);
      final a = _manifest(at: t);
      final b = _manifest(at: t);
      expect(a.isNewerThan(b), isFalse);
    });
  });

  group('conflictsWith —— 不同设备且 60 秒内才算冲突', () {
    final baseTime = DateTime.utc(2026, 10, 1, 12, 0, 0);

    test('不同设备 + 30 秒差 → 冲突', () {
      final a = _manifest(
        deviceId: 'machine-a',
        at: baseTime,
      );
      final b = _manifest(
        deviceId: 'machine-b',
        at: baseTime.add(const Duration(seconds: 30)),
      );
      expect(a.conflictsWith(b), isTrue);
      expect(b.conflictsWith(b), isFalse); // 同设备不冲突
    });

    test('不同设备 + 60 秒整 → 不冲突（边界 < 60）', () {
      final a = _manifest(
        deviceId: 'machine-a',
        at: baseTime,
      );
      final b = _manifest(
        deviceId: 'machine-b',
        at: baseTime.add(const Duration(seconds: 60)),
      );
      expect(a.conflictsWith(b), isFalse);
    });

    test('不同设备 + 59 秒差 → 冲突', () {
      final a = _manifest(
        deviceId: 'machine-a',
        at: baseTime,
      );
      final b = _manifest(
        deviceId: 'machine-b',
        at: baseTime.add(const Duration(seconds: 59)),
      );
      expect(a.conflictsWith(b), isTrue);
    });

    test('同设备 + 1 秒差 → 不冲突（同设备先短路）', () {
      final a = _manifest(
        deviceId: 'same-machine',
        at: baseTime,
      );
      final b = _manifest(
        deviceId: 'same-machine',
        at: baseTime.add(const Duration(seconds: 1)),
      );
      expect(a.conflictsWith(b), isFalse);
    });

    test('不同设备 + 1 小时差 → 不冲突', () {
      final a = _manifest(
        deviceId: 'machine-a',
        at: baseTime,
      );
      final b = _manifest(
        deviceId: 'machine-b',
        at: baseTime.add(const Duration(hours: 1)),
      );
      expect(a.conflictsWith(b), isFalse);
    });

    test('反向也对称：b 比 a 早 30 秒 → 冲突', () {
      final a = _manifest(
        deviceId: 'machine-a',
        at: baseTime,
      );
      final b = _manifest(
        deviceId: 'machine-b',
        at: baseTime.subtract(const Duration(seconds: 30)),
      );
      expect(a.conflictsWith(b), isTrue);
    });
  });
}

/// 测试便利构造器。
BackupManifest _manifest({
  String deviceId = 'dev',
  String deviceName = '测试设备',
  required DateTime at,
  int schemaVersion = 6,
  List<String> fileNames = const ['cloudcine.sqlite'],
  String? note,
}) =>
    BackupManifest(
      deviceId: deviceId,
      deviceName: deviceName,
      createdAt: at,
      schemaVersion: schemaVersion,
      fileNames: fileNames,
      note: note,
    );
