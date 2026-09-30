import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/adapters/cloud_drive_adapter.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/quality_option.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/windows/desktop_play.dart';
import 'package:cloudcine/ui/windows/player_bridge_host.dart';
import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:cloudcine/ui/windows/player_window_bridge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「刷新过期直链」回路的**主窗口一侧**。
///
/// 播放窗口那一侧（`stream.log` → `_onTicketExpiryLog`）已经单独测过；
/// 这里补的是它的对岸 —— 一条请求从通道进来之后到底有没有被兑现。
///
/// 这几条都是**出问题完全安静**的故障，所以必须钉住：
///   - `playerBridgeHostProvider` 没人 watch → 回调是 null，播放窗口只会看到
///     「刷不出来」，日志里只有一条 warn，用户表现为「卡死，只能关窗重开」；
///   - 刷新时把 `qualityId` 丢了 → 用户手选的档位在一次续播后**静默跳回默认**；
///   - 刷新时把 `startPosition` 丢了 → 一次续播把用户丢回片头；
///   - 取链抛异常直接冒出去 → 播放窗口只能收到一句没头没尾的平台异常。
void main() {
  setUp(() {
    // 这两个是**进程级全局**（见 `player_window_bridge.dart` 的说明），
    // 用例之间必须隔离 —— 否则上一条用例装上的回调会让下一条「找不到条目」
    // 的用例仍然拿到一个非 null 的处理器。
    onPlaybackProgress = null;
    onTicketRefresh = null;
  });

  tearDown(() {
    onPlaybackProgress = null;
    onTicketRefresh = null;
  });

  // -------------------------------------------------------------------
  // buildPlayRequest：把票据落成「投给播放窗口的请求」
  // -------------------------------------------------------------------

  group('buildPlayRequest（主窗口取链）', () {
    test('直链、请求头、片名、库记录 id 一个都不能少', () async {
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      final item = _item();
      final request = await buildPlayRequest(harness.read, item);

      expect(request.url, 'https://cdn.example.com/origin.mp4?sig=abc');
      // 夸克直链缺 Cookie 一律 412 —— 请求头漏传的表现是
      // 「能取到链、一播就报错」，而错误信息里看不出是缺头。
      expect(request.headers, <String, String>{'Cookie': 'k=v'});
      expect(request.title, '流浪地球2');
      // itemId 同时是「这条请求能不能被刷新」的开关。
      expect(request.itemId, item.id);
      expect(request.itemId, 'quark:fid-1');
    });

    test('传了档位就把这一档要过去，并带上它的 id 与展示名', () async {
      final drive = _FakeDrive(ticket: _ticket(withSuper: true));
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      final request =
          await buildPlayRequest(harness.read, _item(), qualityId: 'super');

      expect(drive.requestedQualityIds, <String?>['super']);
      expect(request.url, 'https://cdn.example.com/super.mp4?sig=def');
      // id 是刷新时原样带回的（保证还是这一档），label 只用于显示。
      expect(request.qualityId, 'super');
      expect(request.qualityLabel, '超清 1080P');
    });

    test('没传档位时用设置里的默认档 —— 两条播放路径必须选出同一档', () async {
      final drive = _FakeDrive(ticket: _ticket(withSuper: true));
      final harness = _Harness(drive: drive, defaultQuality: 'super');
      addTearDown(harness.dispose);

      await buildPlayRequest(harness.read, _item());

      expect(drive.requestedQualityIds, <String?>['super']);
    });

    test('设置里也是空 → 原样传 null，由适配器自己决定（原画优先）', () async {
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      await buildPlayRequest(harness.read, _item());

      expect(drive.requestedQualityIds, <String?>[null]);
    });

    test('设置里只有空白 → 当成没设置，不要把它当档位传下去', () async {
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive, defaultQuality: '   ');
      addTearDown(harness.dispose);

      await buildPlayRequest(harness.read, _item());

      expect(drive.requestedQualityIds, <String?>[null]);
    });

    test('服务端这次没给要的档 → 落到实际那一档', () async {
      // 关键：带回去的必须是**服务端实际给的那一档**，而不是用户要的那一档。
      // 否则下一次刷新会继续要一个服务端根本不存在的档位，一直降级、一直不匹配。
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      final request =
          await buildPlayRequest(harness.read, _item(), qualityId: 'super');

      expect(drive.requestedQualityIds, <String?>['super']);
      expect(request.qualityId, 'origin');
      expect(request.qualityLabel, '原画');
    });

    test('服务端没给转码梯度 → qualityId 为 null（UI 据此置灰清晰度菜单）',
        () async {
      final drive = _FakeDrive(ticket: _ticket(noQualities: true));
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      final request = await buildPlayRequest(harness.read, _item());

      expect(request.qualityId, isNull);
      expect(request.qualityLabel, isNull);
      // 但流本身仍然可用 —— 只是没有梯度可选。
      expect(request.url, 'https://cdn.example.com/origin.mp4?sig=abc');
    });

    test('startPosition 原样填回 —— 刷新不能把用户丢回片头', () async {
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      final at = const Duration(hours: 1, minutes: 23, seconds: 45);
      final request =
          await buildPlayRequest(harness.read, _item(), startPosition: at);

      expect(request.startPosition, at);
    });

    test('不传 startPosition 时从头开始，不是 null', () async {
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      final request = await buildPlayRequest(harness.read, _item());

      expect(request.startPosition, Duration.zero);
    });

    test('片名没有 title 时退回文件名（去掉扩展名）', () async {
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      final request = await buildPlayRequest(
        harness.read,
        _item(title: null, name: '流浪地球2.2023.2160p.mp4'),
      );

      expect(request.title, '流浪地球2.2023.2160p');
    });
  });

  // -------------------------------------------------------------------
  // playerBridgeHostProvider：把两个回调装上
  // -------------------------------------------------------------------

  group('playerBridgeHostProvider（主窗口装回调）', () {
    test('读一下就把刷新回调装上 —— 这是刷新回路的唯一接点', () async {
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      expect(onTicketRefresh, isNull, reason: '还没 watch，应当是空的');

      harness.container.read(playerBridgeHostProvider);

      // 没人 watch 它（比如 `app.dart` 里那行被删了）时，播放窗口只会看到
      // 「刷不出来」，而这是全链路里唯一一处能把回调装上的地方。
      expect(onTicketRefresh, isNotNull);
      expect(onPlaybackProgress, isNotNull);
    });

    test('找到条目 → 带上档位与位置去取链', () async {
      final drive = _FakeDrive(ticket: _ticket(withSuper: true));
      final harness = _Harness(drive: drive, defaultQuality: 'origin');
      addTearDown(harness.dispose);

      final repo = harness.repository;
      await repo.upsertItems(<MediaItem>[_item()]);
      harness.container.read(playerBridgeHostProvider);

      final fresh = await onTicketRefresh!(
        const TicketRefreshRequest(
          itemId: 'quark:fid-1',
          qualityId: 'super',
          position: Duration(minutes: 42),
        ),
      );

      expect(fresh, isNotNull);
      // 档位原样带回 → 用户手选的档位不会在一次续播后静默跳回设置默认值。
      expect(drive.requestedQualityIds, <String?>['super']);
      expect(fresh!.qualityId, 'super');
      // 位置原样带回 → 表现为「卡一下接着播」而不是「从头开始」。
      expect(fresh.startPosition, const Duration(minutes: 42));
      expect(fresh.itemId, 'quark:fid-1');
    });

    test('库里找不到条目 → 返回 null，不抛异常', () async {
      // 条目被删、或被重扫换过 id 时会走到这。
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      harness.container.read(playerBridgeHostProvider);

      final fresh = await onTicketRefresh!(
        const TicketRefreshRequest(itemId: 'quark:已经不在了'),
      );

      expect(fresh, isNull);
      expect(drive.requestedQualityIds, isEmpty, reason: '不该白取一次链');
    });

    test('取链抛异常 → 返回 null，不让异常冒到通道上', () async {
      // 冒出去会变成一条平台通道异常，播放窗口那边只能看到一句
      // 没头没尾的 PlatformException，而这里的日志已经把原因写清楚了。
      final drive = _FakeDrive(ticket: _ticket())
        ..failure = const _Boom('取链挂了');
      final harness = _Harness(drive: drive);
      addTearDown(harness.dispose);

      await harness.repository.upsertItems(<MediaItem>[_item()]);
      harness.container.read(playerBridgeHostProvider);

      final fresh = await onTicketRefresh!(
        const TicketRefreshRequest(itemId: 'quark:fid-1'),
      );

      expect(fresh, isNull);
    });

    test('容器销毁后回调被摘掉 —— 否则热重载后闭包还指向失效的 ref', () async {
      final drive = _FakeDrive(ticket: _ticket());
      final harness = _Harness(drive: drive);

      harness.container.read(playerBridgeHostProvider);
      expect(onTicketRefresh, isNotNull);

      harness.container.dispose();

      expect(onTicketRefresh, isNull);
      expect(onPlaybackProgress, isNull);
    });
  });
}

// ---------------------------------------------------------------------------
// 测试脚手架
// ---------------------------------------------------------------------------

/// 一份可用的票据。
///
/// 默认只有「原画」一档（服务端常见形态）；[withSuper] 再加一档转码流，
/// [noQualities] 则模拟服务端完全没给梯度。
StreamTicket _ticket({
  bool withSuper = false,
  bool noQualities = false,
}) {
  final origin = QualityOption(
    id: 'origin',
    label: '原画',
    isOriginal: true,
    url: Uri.parse('https://cdn.example.com/origin.mp4?sig=abc'),
  );
  final superStream = QualityOption(
    id: 'super',
    label: '超清 1080P',
    height: 1080,
    url: Uri.parse('https://cdn.example.com/super.mp4?sig=def'),
  );

  return StreamTicket(
    url: origin.url!,
    // 夸克直链缺 Cookie 一律 412。
    headers: const <String, String>{'Cookie': 'k=v'},
    expiresAt: DateTime(2026, 9, 30, 21),
    contentLength: 9799538,
    qualities: noQualities
        ? const <QualityOption>[]
        : <QualityOption>[origin, if (withSuper) superStream],
  );
}

MediaItem _item({String? title = '流浪地球2', String name = '流浪地球2.2023.2160p.mp4'}) {
  return MediaItem(
    provider: DriveProvider.quark,
    fileId: 'fid-1',
    name: name,
    dirId: 'd1',
    dirPath: '/电影/流浪地球2 (2023)/',
    groupKey: 'movie:流浪地球2:2023',
    kind: MediaKind.movie,
    title: title,
    year: 2023,
    firstSeenAt: DateTime(2026, 9, 30),
    updatedAt: DateTime(2026, 9, 30),
  );
}

/// 把「组合根」按测试需要接起来。
///
/// 用真的 [AdapterRegistry] 而不是再写一个假注册表：`requireAdapter` 的
/// 未注册抛错行为本身也是契约的一部分，没必要绕开它。
class _Harness {
  _Harness({
    required _FakeDrive drive,
    String? defaultQuality,
  }) : repository = InMemoryMediaRepository() {
    final db = AppDatabase.memory();
    _db = db;
    final store = SettingsStore(db);
    if (defaultQuality != null) {
      // 同步写完再交出去：`buildPlayRequest` 会立刻 `readAll`。
      store.write(SettingKeys.defaultQuality, defaultQuality);
    }
    container = ProviderContainer(
      overrides: <Override>[
        adapterRegistryProvider.overrideWithValue(AdapterRegistry([drive])),
        mediaRepositoryProvider.overrideWithValue(repository),
        settingsStoreProvider.overrideWithValue(store),
      ],
    );
  }

  final InMemoryMediaRepository repository;
  late final AppDatabase _db;
  late final ProviderContainer container;

  /// 与 `WidgetRef.read` 同形状，直接喂给 `buildPlayRequest`。
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  void dispose() {
    container.dispose();
    _db.close();
  }
}

/// 只实现取链的假网盘。其余能力一律 `UnimplementedError` ——
/// 本文件测的路径不该碰到它们，碰到了就该响。
class _FakeDrive extends CloudDriveAdapter {
  _FakeDrive({required this.ticket});

  final StreamTicket ticket;

  /// 每次取链记下「上层要的是哪一档」（null 表示没指定）。
  final List<String?> requestedQualityIds = <String?>[];

  /// 非 null 时取链直接抛它。
  Object? failure;

  @override
  DriveProvider get provider => DriveProvider.quark;

  @override
  Capabilities get capabilities => const Capabilities(
        provider: DriveProvider.quark,
        // 夸克实测：直链必须带 Cookie。
        directLinkNeedsHeaders: true,
      );

  @override
  String get rootId => '0';

  @override
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId}) async {
    requestedQualityIds.add(qualityId);
    final boom = failure;
    if (boom != null) throw boom;
    return ticket;
  }

  @override
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  }) =>
      throw UnimplementedError('本文件不测遍历');

  @override
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) =>
      throw UnimplementedError('本文件不测搜索');

  @override
  Future<CloudAccount?> restoreSession() async => null;

  @override
  Future<CloudAccount> authorize(AuthCredential credential) =>
      throw UnimplementedError('本文件不测授权');

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> dispose() async {}
}

class _Boom implements Exception {
  const _Boom(this.message);

  final String message;

  @override
  String toString() => '_Boom($message)';
}
