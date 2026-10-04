import 'dart:convert';
import 'dart:typed_data';

import 'package:cloudcine/core/diagnostics/diag_log.dart';
import 'package:cloudcine/domain/adapters/cloud_drive_adapter.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:cloudcine/domain/services/library_backup_service.dart';
import 'package:cloudcine/ui/pages/diagnostics_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 日志页的取向是「取证材料要能带走」。这里钉住的是**带走路径**那几步：
/// 它们看着不起眼，但少了它们，用户能看见日志却没法把日志交出去 ——
/// 电视上尤其致命：没有访达、拷不出文件、也插不了 U 盘。
void main() {
  /// 诊断页里有一块「本地中继状态」，它要读 Riverpod 容器。
  ///
  /// ⚠️ 这里**不需要** override 任何数据库相关的 Provider：中继 Provider 刻意
  /// 不依赖设置（理由见 `streamRelayProvider` 的文档），构造它只是 new 一个
  /// 纯 Dart 对象 —— 不碰平台通道，也不 bind 端口（端口是 lazy 的）。
  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(home: Scaffold(body: child)),
      );

  /// ⚠️ `TextButton.icon` 造出来的是 `TextButton` 的**私有子类**
  /// （`_TextButtonWithIcon`），而 `find.byType` 只按精确类型匹配 ——
  /// 直接写 `find.byType(TextButton)` 会一个都找不到，且报的是
  /// 「No element」这种看不出原因的错。这里用 predicate 按 `is` 匹配。
  Finder copyPathButton() => find.byWidgetPredicate(
        (widget) => widget is TextButton,
        description: 'TextButton（复制路径）',
      );

  group('LogPathRow', () {
    testWidgets('有路径时显示路径，点了把路径交出去', (tester) async {
      String? copied;

      await tester.pumpWidget(
        wrap(
          LogPathRow(
            path: '/Users/tandy/Library/Containers/com.cloudcine.cloudcine/'
                'Data/Library/Application Support/cloudcine/logs/'
                'cloudcine-2026-09-30.log',
            onCopy: (value) => copied = value,
          ),
        ),
      );

      expect(find.textContaining('cloudcine-2026-09-30.log'), findsOneWidget);

      await tester.tap(find.text('复制路径'));
      await tester.pump();

      // 复制的是**完整绝对路径**，不是文件名、也不是日志内容。
      expect(
        copied,
        '/Users/tandy/Library/Containers/com.cloudcine.cloudcine/'
        'Data/Library/Application Support/cloudcine/logs/'
        'cloudcine-2026-09-30.log',
      );
    });

    testWidgets('路径可划选 —— 不点按钮也能用鼠标带走', (tester) async {
      await tester.pumpWidget(
        wrap(const LogPathRow(path: '/tmp/a.log', onCopy: _noop)),
      );

      // 普通 Text 在 macOS 上选不中，那样「复制路径」就成了唯一出口。
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('没有路径时按钮禁用，并说明原因', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        wrap(LogPathRow(path: null, onCopy: (_) => tapped = true)),
      );

      expect(find.text('日志文件不可写（仅内存）'), findsOneWidget);

      final button = tester.widget<TextButton>(copyPathButton());
      // 禁用而不是复制空串：静默复制一段空文本会让用户以为
      // 「复制成功了但日志是空的」。
      expect(button.onPressed, isNull);

      await tester.tap(find.text('复制路径'), warnIfMissed: false);
      await tester.pump();
      expect(tapped, isFalse);
    });
  });

  group('DiagnosticsPage 接线', () {
    testWidgets('路径那一行接到了日志单例上（未启动时按钮禁用）', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: DiagnosticsPage())),
      );

      final row = find.byType(LogPathRow);
      expect(row, findsOneWidget);

      // 这个用例跑在独立的测试进程里，`diag.start()` 没被调用过，
      // 所以拿到的必然是「不可写」形态 —— 正好验证了降级文案。
      expect(
        find.descendant(
          of: row,
          matching: find.text('日志文件不可写（仅内存）'),
        ),
        findsOneWidget,
      );

      final button = tester.widget<TextButton>(
        find.descendant(of: row, matching: copyPathButton()),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('RelayStatusPanel', () {
    testWidgets('没有会话时说明原因，而不是显示一排 0', (tester) async {
      await tester.pumpWidget(wrap(const RelayStatusPanel()));

      // 显示「0 连接 · 已拉 0 B」会让人以为中继在跑却什么都没拉到，而真相
      // 是它根本没被用上（没开、播的是转码档、或播的是本地文件）。
      expect(find.textContaining('当前没有走中继的流'), findsOneWidget);
    });

    testWidgets('没有会话时不留下 periodic timer', (tester) async {
      await tester.pumpWidget(wrap(const RelayStatusPanel()));

      // ⚠️ 这条不是形式主义：跳秒的 timer 一旦在无会话时也启动，诊断页在
      // 任何 `pumpAndSettle` 的用例里都会**超时**，而报错完全指不到这里。
      await tester.pumpAndSettle();
    });
  });

  /// 诊断页的上传按钮要走完整的 `LibraryBackupService`。
  ///
  /// ⚠️ 这里给的是「**真的服务 + 假的网盘**」，而不是把
  /// `libraryBackupServiceProvider` 换成一个假 service：换掉之后，「备份目录
  /// 没建出来」「同名文件没先删」这类错误正好会被绕过去 —— 而它们恰恰是这条
  /// 路最容易出问题的地方，在真机上表现为「提示上传成功了，网盘里却找不到」。
  LibraryBackupService serviceOn(_RecordingDrive drive) => LibraryBackupService(
        adapter: drive,
        databasePath: '/tmp/cloudcine-test.sqlite',
        posterCachePath: '/tmp/cloudcine-test-posters',
        deviceId: 'test-device',
        deviceName: '测试机',
      );

  Widget pageOn(LibraryBackupService service) => ProviderScope(
        overrides: [libraryBackupServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: DiagnosticsPage()),
      );

  group('日志上传到网盘', () {
    testWidgets('点一下就把日志正文传进「云影备份」目录', (tester) async {
      diag.clearBuffer();
      diag.info('测试', '这是一条用来验证上传的日志');
      addTearDown(diag.clearBuffer);

      final drive = _RecordingDrive();
      await tester.pumpWidget(pageOn(serviceOn(drive)));

      await tester.tap(find.text('上传到网盘'));
      await tester.pumpAndSettle();

      expect(drive.files, hasLength(1));
      final name = drive.files.keys.single;
      // 名字要一眼看出是什么、什么时候、哪台机器 —— 目录会越堆越多。
      expect(name, startsWith('cloudcine-log-'));
      expect(name, endsWith('.txt'));

      final text = utf8.decode(drive.files[name]!);
      // 正文里必须有真日志，而不是只有一段头部。
      expect(text, contains('这是一条用来验证上传的日志'));
      expect(text, contains('# 云影诊断日志'));

      // SnackBar 的自动消失是个 timer，不收掉用例结束会报 pending timer。
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('上传成功要报出「去哪儿找」，不能只说一句成功', (tester) async {
      diag.clearBuffer();
      diag.info('测试', 'x');
      addTearDown(diag.clearBuffer);

      await tester.pumpWidget(pageOn(serviceOn(_RecordingDrive())));

      await tester.tap(find.text('上传到网盘'));
      await tester.pumpAndSettle();

      // 用户拿到「成功」之后的下一个问题是「那我去哪儿看」。
      //
      // ⚠️ 必须**限定在 SnackBar 里**找。这一页会把日志逐行渲染出来，而上传
      // 本身也往日志里写了一行（里面就有目录名）—— 不限定的话同一条信息在
      // 页面上出现两次，断言会因为「找到了两个」而红，看着像功能坏了。
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining(LibraryBackupService.defaultBackupDir),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('上传失败要报错 —— 静默什么都不发生最要命', (tester) async {
      diag.clearBuffer();
      diag.info('测试', 'x');
      addTearDown(diag.clearBuffer);

      final drive = _RecordingDrive()..failUpload = true;
      await tester.pumpWidget(pageOn(serviceOn(drive)));

      await tester.tap(find.text('上传到网盘'));
      await tester.pumpAndSettle();

      // 同样限定在 SnackBar 里：失败那行日志（`诊断日志上传失败`）也会被这一页
      // 渲染出来，页面上有两条含「上传失败」的文本。
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('上传失败'),
        ),
        findsOneWidget,
      );
      // 失败也必须能在日志里事后查到（用户会来翻这一页）。
      expect(diag.lines.join('\n'), contains('诊断日志上传失败'));

      // 失败之后按钮要能再点 —— 否则用户得重启应用才能重试。
      expect(
        tester
            .widget<TextButton>(uploadButton())
            .onPressed,
        isNotNull,
      );
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('一条日志都没有时按钮禁用 —— 传一份空的没有意义', (tester) async {
      diag.clearBuffer();
      addTearDown(diag.clearBuffer);

      // 不 override 服务：这一条根本不会点到上传，构造器不会被碰。
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: DiagnosticsPage())),
      );

      expect(tester.widget<TextButton>(uploadButton()).onPressed, isNull);
    });
  });
}

/// 「上传到网盘」那个按钮。
///
/// ⚠️ `TextButton.icon` 造出来的是 `TextButton` 的**私有子类**，
/// `find.byType(TextButton)` 一个都找不到，只能按 `is` 匹配。
Finder uploadButton() => find.ancestor(
      of: find.textContaining('上传'),
      matching: find.byWidgetPredicate(
        (widget) => widget is TextButton,
        description: 'TextButton（上传到网盘）',
      ),
    );

/// 只实现「列目录 / 建目录 / 上传 / 删除」的内存网盘。
///
/// 其余方法抛 `UnimplementedError` —— 跑到了就说明调用点走错了路。
class _RecordingDrive extends CloudDriveAdapter {
  static const String _root = 'root';
  static const String _dirFid = 'backup-dir';

  final Map<String, Uint8List> files = {};
  bool dirExists = false;
  bool failUpload = false;
  int _seq = 0;

  @override
  DriveProvider get provider => DriveProvider.quark;

  @override
  Capabilities get capabilities =>
      const Capabilities(provider: DriveProvider.quark, canListDirectory: true);

  @override
  String get rootId => _root;

  @override
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  }) async {
    if (dirId == _root) {
      return DrivePage(
        entries: [
          if (dirExists)
            const DriveEntry(
              id: _dirFid,
              name: LibraryBackupService.defaultBackupDir,
              isDirectory: true,
            ),
        ],
      );
    }
    if (dirId == _dirFid) {
      return DrivePage(
        entries: [
          for (final e in files.entries)
            DriveEntry(
              id: 'fid-${e.key}',
              name: e.key,
              isDirectory: false,
              sizeBytes: e.value.length,
            ),
        ],
      );
    }
    return const DrivePage(entries: []);
  }

  @override
  Future<String> createFolder({
    required String parentId,
    required String name,
  }) async {
    dirExists = true;
    return _dirFid;
  }

  @override
  Future<String> uploadFile({
    required String parentId,
    required String fileName,
    required List<int> bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (failUpload) throw Exception('网盘凭证已失效');
    dirExists = true;
    files[fileName] = Uint8List.fromList(bytes);
    onProgress?.call(bytes.length, bytes.length);
    return 'fid-${_seq++}';
  }

  @override
  Future<List<String>> deleteFiles({required List<String> fileIds}) async {
    for (final fid in fileIds) {
      files.removeWhere((k, _) => 'fid-$k' == fid);
    }
    return fileIds;
  }

  @override
  Future<CloudAccount> authorize(AuthCredential credential) =>
      throw UnimplementedError();

  @override
  Future<CloudAccount?> restoreSession() async => null;

  @override
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId}) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> readFileBytes(String fileId, {int maxBytes = 524288}) =>
      throw UnimplementedError();

  @override
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) async =>
      const <DriveEntry>[];

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> signOut() async {}

  @override
  Future<void> dispose() async {}
}

void _noop(String _) {}
