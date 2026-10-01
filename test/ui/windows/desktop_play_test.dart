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
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/entities/quality_option.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/windows/desktop_play.dart';
import 'package:cloudcine/ui/windows/player_bridge_host.dart';
import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:cloudcine/ui/windows/player_window_bridge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「刷新过期直链」回路的**主窗口一侧**，外加投递请求时组装的那三样东西
/// （可选档位 / 剧集列表 / 续播位置）。
///
/// 播放窗口那一侧（`stream.log` → `_onTicketExpiryLog`）已经单独测过；
/// 这里补的是它的对岸 —— 一条请求从通道进来之后到底有没有被兑现。
///
/// 这几条都是**出问题完全安静**的故障，所以必须钉住：
///   - `playerBridgeHostProvider` 没人 watch → 回调是 null，播放窗口只会看到
///     「刷不出来」，用户表现为「卡死，只能关窗重开」；
///   - 刷新时把 `qualityId` 丢了 → 用户手选的档位在一次续播后**静默跳回默认**；
///   - 刷新时把 `startPosition` 丢了 → 一次续播把用户丢回片头；
///   - 续播点的取舍写错 → 要么「看了三秒回来还卡在片头」，要么
///     「看完再点开直接跳到大结局」；
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
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final item = _episode();
      final request = await buildPlayRequest(harness.read, item);

      expect(request.url, 'https://cdn.example.com/origin.mp4?sig=abc');
      // 夸克直链缺 Cookie 一律 412 —— 请求头漏传的表现是
      // 「能取到链、一播就报错」，而错误信息里看不出是缺头。
      expect(request.headers, <String, String>{'Cookie': 'k=v'});
      // displayTitle 带年份（`流浪地球2 (2023)`），这里跟着它走。
      expect(request.title, '流浪地球2 (2023)');
      // itemId 同时是「这条请求能不能被刷新」的开关。
      expect(request.itemId, item.id);
      expect(request.itemId, 'quark:fid-1');
    });

    test('传了档位就把这一档要过去，并带上它的 id 与展示名', () async {
      final harness = await _Harness.create(drive: _FakeDrive(ticket: _ticket(withSuper: true)));
      addTearDown(harness.dispose);

      final request = await buildPlayRequest(
        harness.read,
        _episode(),
        qualityId: 'super',
      );

      expect(harness.drive.requestedQualityIds, <String?>['super']);
      expect(request.url, 'https://cdn.example.com/super.mp4?sig=def');
      // id 是刷新时原样带回的（保证还是这一档），label 只用于显示。
      expect(request.qualityId, 'super');
      expect(request.qualityLabel, '超清 1080P');
    });

    test('没传档位时用设置里的默认档 —— 两条播放路径必须选出同一档', () async {
      final harness = await _Harness.create(
        drive: _FakeDrive(ticket: _ticket(withSuper: true)),
        defaultQuality: 'super',
      );
      addTearDown(harness.dispose);

      await buildPlayRequest(harness.read, _episode());

      expect(harness.drive.requestedQualityIds, <String?>['super']);
    });

    test('设置里也是空 → 原样传 null，由适配器自己决定（原画优先）', () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      await buildPlayRequest(harness.read, _episode());

      expect(harness.drive.requestedQualityIds, <String?>[null]);
    });

    test('设置里只有空白 → 当成没设置，不要把它当档位传下去', () async {
      final harness = await _Harness.create(defaultQuality: '   ');
      addTearDown(harness.dispose);

      await buildPlayRequest(harness.read, _episode());

      expect(harness.drive.requestedQualityIds, <String?>[null]);
    });

    test('服务端这次没给要的档 → 落到实际那一档', () async {
      // 关键：带回去的必须是**服务端实际给的那一档**，而不是用户要的那一档。
      // 否则下一次刷新会继续要一个服务端根本不存在的档位，一直降级、一直不匹配。
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final request = await buildPlayRequest(
        harness.read,
        _episode(),
        qualityId: 'super',
      );

      expect(harness.drive.requestedQualityIds, <String?>['super']);
      expect(request.qualityId, 'origin');
      expect(request.qualityLabel, '原画');
    });

    test('服务端没给转码梯度 → qualityId 为 null，可选档位也是空的', () async {
      final harness = await _Harness.create(
        drive: _FakeDrive(ticket: _ticket(noQualities: true)),
      );
      addTearDown(harness.dispose);

      final request = await buildPlayRequest(harness.read, _episode());

      expect(request.qualityId, isNull);
      expect(request.qualityLabel, isNull);
      // 画质弹框据此置灰 —— 空列表是「没有梯度」，不是「还没加载」。
      expect(request.qualities, isEmpty);
      // 但流本身仍然可用。
      expect(request.url, 'https://cdn.example.com/origin.mp4?sig=abc');
    });

    test('可选档位随请求一起带出去（画质弹框的数据源）', () async {
      final harness = await _Harness.create(
        drive: _FakeDrive(ticket: _ticket(withSuper: true)),
      );
      addTearDown(harness.dispose);

      final request = await buildPlayRequest(harness.read, _episode());

      expect(
        request.qualities.map((q) => q.id).toList(),
        <String>['origin', 'super'],
      );
      expect(
        request.qualities.map((q) => q.label).toList(),
        <String>['原画', '超清 1080P'],
      );
      // detail 来自 `QualityOption.displayDetail`（分辨率 · 码率）。
      expect(request.qualities[1].detail, contains('1920×1080'));
    });

    test('片名没有 title 时退回文件名（去掉扩展名）', () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final request = await buildPlayRequest(
        harness.read,
        _episode(title: null, name: '流浪地球2.2023.2160p.mp4'),
      );

      expect(request.title, '流浪地球2.2023.2160p');
    });
  });

  // -------------------------------------------------------------------
  // 续播位置
  // -------------------------------------------------------------------

  group('buildPlayRequest 的续播位置', () {
    test('库里存过续播点 → 自动从那里开始（用户没给显式起点时）', () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final item = _episode(durationMs: 45 * 60 * 1000);
      await harness.repository.upsertItems(<MediaItem>[item]);
      await harness.repository.saveResumePosition(item.id, const Duration(minutes: 12));

      final request = await buildPlayRequest(harness.read, item);

      expect(request.startPosition, const Duration(minutes: 12));
    });

    test('只看了几秒 → 当作没看过，从头播', () async {
      // 不然用户看到的是「卡在片头不动」，会以为播放器坏了。
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final item = _episode(durationMs: 45 * 60 * 1000);
      await harness.repository.upsertItems(<MediaItem>[item]);
      await harness.repository.saveResumePosition(item.id, const Duration(seconds: 3));

      final request = await buildPlayRequest(harness.read, item);

      expect(request.startPosition, Duration.zero);
    });

    test('已经看到结尾 → 清除续播点，从头重看', () async {
      // 不然「看完再点开」会从还差一分钟的地方开始，直接跳到大结局。
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final item = _episode(durationMs: 45 * 60 * 1000);
      await harness.repository.upsertItems(<MediaItem>[item]);
      await harness.repository.saveResumePosition(
        item.id,
        const Duration(minutes: 44, seconds: 30),
      );

      final request = await buildPlayRequest(harness.read, item);

      expect(request.startPosition, Duration.zero);
    });

    test('设置里关了「记住播放进度」→ 既不续播', () async {
      final harness = await _Harness.create(rememberPosition: false);
      addTearDown(harness.dispose);
      final item = _episode(durationMs: 45 * 60 * 1000);
      await harness.repository.upsertItems(<MediaItem>[item]);
      await harness.repository.saveResumePosition(item.id, const Duration(minutes: 12));

      final request = await buildPlayRequest(harness.read, item);

      expect(request.startPosition, Duration.zero);
      // 剧集列表上的进度条也要跟着消失 —— 那个开关是「别记我看过哪儿」，
      // 不只是「别续播」。
      expect(
        request.playlist.map((e) => e.resumePosition),
        everyElement(Duration.zero),
      );
    });

    test('显式给了起点就用它，**不套**「接近结尾就从片头」', () async {
      // 这条是「刷新过期直链」那条路：位置是用户**正在看**的地方。
      // 套了「看完就从片头」的话，用户在最后两分钟里遇到直链过期会被
      // 一把丢回片头。
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final item = _episode(durationMs: 45 * 60 * 1000);
      await harness.repository.upsertItems(<MediaItem>[item]);

      final request = await buildPlayRequest(
        harness.read,
        item,
        startPosition: const Duration(minutes: 44, seconds: 50),
      );

      expect(request.startPosition, const Duration(minutes: 44, seconds: 50));
    });
  });

  // -------------------------------------------------------------------
  // 剧集列表
  // -------------------------------------------------------------------

  group('buildPlayRequest 的剧集列表', () {
    test('同一部作品下的多集拼成列表，集号 / 副标题 / 时长都在', () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final items = <MediaItem>[
        _episode(fileId: 'f1', episode: 1, durationMs: 45 * 60 * 1000),
        _episode(fileId: 'f2', episode: 2, durationMs: 46 * 60 * 1000),
        _episode(fileId: 'f3', episode: 3, durationMs: 47 * 60 * 1000),
      ];
      await harness.repository.upsertItems(items);
      await harness.repository.upsertWorks(<MediaWork>[_work()]);

      final request = await buildPlayRequest(harness.read, items[1]);

      expect(request.playlist, hasLength(3));
      expect(
        request.playlist.map((e) => e.title).toList(),
        <String>['第 1 集', '第 2 集', '第 3 集'],
      );
      expect(request.playlist[1].itemId, items[1].id);
      expect(request.playlist[1].duration, const Duration(minutes: 46));
      // 缩略图是**作品海报**（网盘不给逐集预览图，见 PlaylistEntry 的文档）。
      expect(request.playlist[1].thumbnailUrl, 'https://img.example.com/p.jpg');
    });

    test('每一集的续播点跟着列表一起带上（面板要画进度条）', () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final items = <MediaItem>[
        _episode(fileId: 'f1', episode: 1),
        _episode(fileId: 'f2', episode: 2),
      ];
      await harness.repository.upsertItems(items);
      await harness.repository.saveResumePosition(
        items[0].id,
        const Duration(minutes: 7),
      );

      final request = await buildPlayRequest(harness.read, items[1]);

      expect(request.playlist[0].resumePosition, const Duration(minutes: 7));
      expect(request.playlist[0].hasProgress, isTrue);
      // 没看过的那些不该凭空多出一条进度条。
      expect(request.playlist[1].hasProgress, isFalse);
    });

    test('只有一项时列表为空 —— 电影不该弹出一个只有自己的列表', () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final item = _episode();
      await harness.repository.upsertItems(<MediaItem>[item]);

      final request = await buildPlayRequest(harness.read, item);

      expect(request.playlist, isEmpty);
    });

    test('库里没有这一项时也不崩，列表为空', () async {
      // 手输直链、自检视频那条路会走到这（`item` 不在库里）。
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final request = await buildPlayRequest(harness.read, _episode());

      expect(request.playlist, isEmpty);
      expect(request.itemId, 'quark:fid-1');
    });

    test('多季剧补季前缀 —— 否则第二季的「第 3 集」跟第一季撞名', () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final items = <MediaItem>[
        _episode(fileId: 's1e1', season: 1, episode: 1),
        _episode(fileId: 's2e3', season: 2, episode: 3),
      ];
      await harness.repository.upsertItems(items);

      final request = await buildPlayRequest(harness.read, items[0]);

      expect(
        request.playlist.map((e) => e.title).toList(),
        <String>['第 1 集', 'S2 · 第 3 集'],
      );
    });
  });

  // -------------------------------------------------------------------
  // playerBridgeHostProvider：把两个回调装上
  // -------------------------------------------------------------------

  group('playerBridgeHostProvider（主窗口装回调）', () {
    test('读一下就把刷新回调装上 —— 这是刷新回路的唯一接点', () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      expect(onTicketRefresh, isNull, reason: '还没 watch，应当是空的');

      harness.container.read(playerBridgeHostProvider);

      // 没人 watch 它（比如 `app.dart` 里那行被删了）时，播放窗口只会看到
      // 「刷不出来」，而这是全链路里唯一一处能把回调装上的地方。
      expect(onTicketRefresh, isNotNull);
      expect(onPlaybackProgress, isNotNull);
    });

    test('找到条目 → 带上档位与位置去取链', () async {
      final harness = await _Harness.create(
        drive: _FakeDrive(ticket: _ticket(withSuper: true)),
        defaultQuality: 'origin',
      );
      addTearDown(harness.dispose);

      await harness.repository.upsertItems(<MediaItem>[_episode()]);
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
      expect(harness.drive.requestedQualityIds, <String?>['super']);
      expect(fresh!.qualityId, 'super');
      // 位置原样带回 → 表现为「卡一下接着播」而不是「从头开始」。
      expect(fresh.startPosition, const Duration(minutes: 42));
      expect(fresh.itemId, 'quark:fid-1');
    });

    test('库里找不到条目 → 返回 null，不抛异常', () async {
      // 条目被删、或被重扫换过 id 时会走到这。
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      harness.container.read(playerBridgeHostProvider);

      final fresh = await onTicketRefresh!(
        const TicketRefreshRequest(itemId: 'quark:已经不在了'),
      );

      expect(fresh, isNull);
      expect(harness.drive.requestedQualityIds, isEmpty, reason: '不该白取一次链');
    });

    test('取链抛异常 → 返回 null，不让异常冒到通道上', () async {
      // 冒出去会变成一条平台通道异常，播放窗口那边只能看到一句
      // 没头没尾的 PlatformException，而这里的日志已经把原因写清楚了。
      final harness = await _Harness.create(
        drive: _FakeDrive(ticket: _ticket())..failure = const _Boom('取链挂了'),
      );
      addTearDown(harness.dispose);

      await harness.repository.upsertItems(<MediaItem>[_episode()]);
      harness.container.read(playerBridgeHostProvider);

      final fresh = await onTicketRefresh!(
        const TicketRefreshRequest(itemId: 'quark:fid-1'),
      );

      expect(fresh, isNull);
    });

    test('容器销毁后回调被摘掉 —— 否则热重载后闭包还指向失效的 ref', () async {
      final harness = await _Harness.create();

      harness.container.read(playerBridgeHostProvider);
      expect(onTicketRefresh, isNotNull);

      harness.container.dispose();

      expect(onTicketRefresh, isNull);
      expect(onPlaybackProgress, isNull);
    });
  });

  // -------------------------------------------------------------------
  // 进度回报 → 续播落库
  // -------------------------------------------------------------------

  group('进度回报落库', () {
    test('回报的位置被存成续播点', () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      harness.container.read(playerBridgeHostProvider);
      onPlaybackProgress!(
        const PlaybackProgressReport(
          itemId: 'quark:fid-1',
          position: Duration(minutes: 12),
          duration: Duration(minutes: 45),
        ),
      );
      await harness.settle();

      expect(
        harness.repository.resume['quark:fid-1'],
        const Duration(minutes: 12),
      );
    });

    test('已经看到结尾 → 回报时就把续播点清掉', () async {
      // 不清的话下次打开会从「还差一分钟」开始，直接跳到大结局。
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      await harness.repository.saveResumePosition(
        'quark:fid-1',
        const Duration(minutes: 30),
      );

      harness.container.read(playerBridgeHostProvider);
      onPlaybackProgress!(
        const PlaybackProgressReport(
          itemId: 'quark:fid-1',
          position: Duration(minutes: 44, seconds: 30),
          duration: Duration(minutes: 45),
        ),
      );
      await harness.settle();

      expect(harness.repository.resume, isEmpty);
    });

    test('设置里关了「记住播放进度」→ 不落续播点', () async {
      final harness = await _Harness.create(rememberPosition: false);
      addTearDown(harness.dispose);

      harness.container.read(playerBridgeHostProvider);
      onPlaybackProgress!(
        const PlaybackProgressReport(
          itemId: 'quark:fid-1',
          position: Duration(minutes: 12),
          duration: Duration(minutes: 45),
        ),
      );
      await harness.settle();

      expect(harness.repository.resume, isEmpty);
    });

    test('「最近播放」照旧记 —— 关了续播也不该影响它', () async {
      final harness = await _Harness.create(rememberPosition: false);
      addTearDown(harness.dispose);
      await harness.repository.upsertItems(<MediaItem>[_episode()]);

      harness.container.read(playerBridgeHostProvider);
      onPlaybackProgress!(
        const PlaybackProgressReport(
          itemId: 'quark:fid-1',
          position: Duration(minutes: 12),
          duration: Duration(minutes: 45),
        ),
      );
      await harness.settle();

      final recent = await harness.repository.recentlyPlayed();
      expect(recent.map((i) => i.id), contains('quark:fid-1'));
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
StreamTicket _ticket({bool withSuper = false, bool noQualities = false}) {
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
    width: 1920,
    bitrate: 4200000,
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

/// 一条剧集条目。默认是「流浪地球2 第 1 集」，同一组（`groupKey`）。
MediaItem _episode({
  String fileId = 'fid-1',
  String? title = '流浪地球2',
  String name = '流浪地球2.2023.2160p.mp4',
  int? season,
  int? episode,
  int? durationMs,
}) {
  return MediaItem(
    provider: DriveProvider.quark,
    fileId: fileId,
    name: name,
    dirId: 'd1',
    dirPath: '/电影/流浪地球2 (2023)/',
    groupKey: 'movie:流浪地球2:2023',
    kind: MediaKind.movie,
    title: title,
    year: 2023,
    season: season,
    episode: episode,
    durationMs: durationMs,
    firstSeenAt: DateTime(2026, 9, 30),
    updatedAt: DateTime(2026, 9, 30),
  );
}

MediaWork _work() => MediaWork(
      key: 'movie:流浪地球2:2023',
      provider: DriveProvider.quark,
      kind: MediaKind.movie,
      title: '流浪地球2',
      source: ScrapeSource.local,
      posterUrl: 'https://img.example.com/p.jpg',
      itemCount: 3,
      updatedAt: DateTime(2026, 9, 30),
    );

/// 把「组合根」按测试需要接起来。
///
/// 用真的 [AdapterRegistry] 而不是再写一个假注册表：`requireAdapter` 的
/// 未注册抛错行为本身也是契约的一部分，没必要绕开它。
///
/// ⚠️ 用真的 [AppDatabase.memory] + 真的 [SettingsStore]，不是手写的替身：
/// 「设置读出来是字符串 `'false'`」这类约定只有走真实现才验得到，而它正是
/// 「设置页显示关了、实际照记」这类 bug 的藏身处。
class _Harness {
  _Harness._({
    required this.drive,
    required this.repository,
    required AppDatabase db,
    required this.container,
  }) : _db = db;

  static Future<_Harness> create({
    _FakeDrive? drive,
    String? defaultQuality,
    bool rememberPosition = true,
  }) async {
    final db = AppDatabase.memory();
    final store = SettingsStore(db);
    if (defaultQuality != null) {
      await store.write(SettingKeys.defaultQuality, defaultQuality);
    }
    if (!rememberPosition) {
      await store.writeBool(SettingKeys.rememberPosition, false);
    }

    final repository = InMemoryMediaRepository();
    final realDrive = drive ?? _FakeDrive(ticket: _ticket());
    final container = ProviderContainer(
      overrides: <Override>[
        adapterRegistryProvider.overrideWithValue(AdapterRegistry([realDrive])),
        mediaRepositoryProvider.overrideWithValue(repository),
        settingsStoreProvider.overrideWithValue(store),
      ],
    );
    return _Harness._(
      drive: realDrive,
      repository: repository,
      db: db,
      container: container,
    );
  }

  final _FakeDrive drive;
  final InMemoryMediaRepository repository;
  final AppDatabase _db;
  final ProviderContainer container;

  /// 与 `WidgetRef.read` 同形状，直接喂给 `buildPlayRequest`。
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  /// 等落库那几条「即发即忘」的异步链跑完。
  ///
  /// `onPlaybackProgress` 是**同步**回调（通道处理器不等它），它内部
  /// `unawaited` 了两条写库。这里空转几轮事件循环把它们放完 ——
  /// 比 `sleep` 确定，也不会在慢机器上偶发失败。
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

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
