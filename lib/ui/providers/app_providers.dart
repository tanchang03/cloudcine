import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/tv_device.dart';
import '../../data/auth/quark_qr_login.dart';
import '../../data/auth/secret_backend.dart';
import '../../data/auth/secure_credential_store.dart';
import '../../data/db/app_database.dart';
import '../../data/db/media_repository_impl.dart';
import '../../data/db/settings_store.dart';
import '../../data/http/dio_http_client.dart';
import '../../data/http/http_client.dart';
import '../../data/playback/fvp_playback_engine.dart';
import '../../data/playback/media_kit_playback_engine.dart';
import '../../data/registry/adapter_registry.dart';
import '../../data/remote/quark/quark_adapter.dart';
import '../../data/scrape/douban_client.dart';
import '../../data/scrape/poster_cache.dart';
import '../../data/stream/dolby_vision_probe.dart';
import '../../data/stream/local_stream_relay.dart';
import '../../domain/adapters/credential_store.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/services/library_backup_service.dart';
import '../../domain/services/playback_controller.dart';
import '../../domain/services/subtitle_service.dart';
import 'library_refresh_providers.dart';
import 'settings_providers.dart';

/// 组合根。
///
/// **所有具体实现的唯一装配点。** 领域层只认抽象，这里把它们接到一起。
/// 新增一家网盘 = 在 [adapterRegistryProvider] 里多传一个适配器实例，
/// 其余 provider、页面、播放引擎都不用动。

/// 本地索引数据库。
///
/// 在 `main()` 里打开后通过 `ProviderScope.overrides` 注入 —— 打开数据库是
/// 异步的（要先拿应用支持目录），塞不进同步的 Provider 里。
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError(
    'databaseProvider 必须在 main() 里用 ProviderScope.overrides 注入',
  ),
);

/// 海报/背景图的磁盘缓存目录。与 [databaseProvider] 同理在 `main()` 里注入。
final posterCacheDirProvider = Provider<String>(
  (ref) => throw UnimplementedError(
    'posterCacheDirProvider 必须在 main() 里用 ProviderScope.overrides 注入',
  ),
);

/// 应用支持目录。与 [databaseProvider] 同理在 `main()` 里注入。
///
/// 凭证文件要落在它下面，所以必须和数据库、海报缓存用**同一个**目录 ——
/// 各自调一次 `getApplicationSupportDirectory()` 虽然结果一样，
/// 但会多一次平台通道往返，也让「数据都放哪」变得不好追。
final appSupportDirProvider = Provider<String>(
  (ref) => throw UnimplementedError(
    'appSupportDirProvider 必须在 main() 里用 ProviderScope.overrides 注入',
  ),
);

/// 凭证存储。落点按平台挑，理由见 [SecretBackend.forPlatform]。
final credentialStoreProvider = Provider<CredentialStore>(
  (ref) => SecureCredentialStore(
    backend: SecretBackend.forPlatform(
      supportDirPath: ref.watch(appSupportDirProvider),
    ),
  ),
);

final httpClientProvider = Provider<HttpClientLike>((ref) => DioHttpClient());

/// 已接入的网盘适配器。目前只有夸克。
final adapterRegistryProvider = Provider<AdapterRegistry>((ref) {
  final registry = AdapterRegistry([
    QuarkAdapter(
      http: ref.watch(httpClientProvider),
      credentialStore: ref.watch(credentialStoreProvider),
    ),
  ]);
  ref.onDispose(() {
    for (final adapter in registry.all) {
      unawaited(adapter.dispose());
    }
  });
  return registry;
});

final mediaRepositoryProvider = Provider<MediaRepository>(
  (ref) => DriftMediaRepository(ref.watch(databaseProvider)),
);

/// 应用设置的读写（`settings` 表的薄封装）。
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => SettingsStore(ref.watch(databaseProvider)),
);

/// 海报 / 背景图的磁盘缓存。
///
/// 做成 Provider 而不是让每个 widget 自己 new 一个：缓存对象内部持有
/// 「正在下载中」的表，共用一个实例才能让同一张海报的并发请求合成一次。
final posterCacheProvider = Provider<PosterCache>(
  (ref) {
    final registry = ref.watch(adapterRegistryProvider);
    return PosterCache(
      http: ref.watch(httpClientProvider),
      dirPath: ref.watch(posterCacheDirProvider),
      // 海报有三个来源：
      //   - TMDB（`image.tmdb.org`）—— 裸链即可；
      //   - **网盘自己生成的视频缩略图**（夸克 `/file/video/preview?fid=…`）——
      //     实测必须带 Cookie，且夸克每次响应轮换 `__puus`；
      //   - **豆瓣**（`img*.doubanio.com`）—— 实测缺 `Referer` 一律 418。
      //
      // 回调在发请求时才求值，所以拿到的永远是当前会话的 Cookie。
      //
      // 用 `ownsUrl` 反查归属而不是写死「夸克」：接第二家网盘时只要它
      // 实现了那两个方法，海报缓存不用改一行。豆瓣不是网盘、没有适配器，
      // 所以它单独判一次 —— 但把判断交给 `DoubanScraper` 自己（而不是在这里
      // 写 `endsWith('doubanio.com')`），是为了让「豆瓣的图要带什么头」
      // 这件事留在豆瓣那个文件里。
      headersFor: (url) {
        for (final adapter in registry.all) {
          if (adapter.ownsUrl(url)) return adapter.imageHeaders();
        }
        if (DoubanScraper.ownsImageUrl(url)) {
          return DoubanScraper.imageHeaders();
        }
        return const <String, String>{};
      },
    );
  },
);

/// 字幕内容的取用与解码。
///
/// 取字节走当前网盘的 `readFileBytes` —— 字幕直链**没有请求头参数**
/// （见 `SubtitleResolver` 的类文档），所以字节必须由我们自己取回来。
final subtitleResolverProvider = Provider<SubtitleResolver>(
  (ref) => SubtitleResolver(
    readBytes: (fileId) => ref
        .read(adapterRegistryProvider)
        .requireAdapter(DriveProvider.quark)
        .readFileBytes(fileId),
  ),
);

/// 本地流式中继（多连接并发预取网盘直链）。
///
/// ⚠️ **刻意不读设置**。读设置就得依赖 `settingsProvider`，而它是异步的、
/// 底下连着数据库 —— 任何只想「看一眼中继状态」的地方（诊断页）都会被拖着
/// 把数据库建一遍，单元测试里还会直接炸。设置由 [relayConfigSyncProvider]
/// 单独推过来。
final streamRelayProvider = Provider<LocalStreamRelay>((ref) {
  final relay = LocalStreamRelay();
  ref.onDispose(() => unawaited(relay.dispose()));
  return relay;
});

/// 把设置里的中继开关推给 [streamRelayProvider]。**不产出值**。
///
/// ## 两个「不能」
///
/// 1. **不能让它去建中继**（`watch` 出来再改）：设置一变就会重建中继对象
///    → `dispose` → 关掉所有会话 → 掐断 mpv 正在读的那条流。用户只是在
///    设置页拨了一下开关，不该把正在播的视频搞停 —— 而这是最难联想到的
///    一种因果关系。所以走 [LocalStreamRelay.configure]（就地改），不重建。
/// 2. **不能没人 watch**：副作用 Provider 不产出值，必须在 `CloudCineApp`
///    的 `build` 里 watch 一次才生效。漏了它的表现是「设置页开关点了没反应」，
///    而且**没有任何报错**。
final relayConfigSyncProvider = Provider<void>((ref) {
  final relay = ref.watch(streamRelayProvider);
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return;
  relay.configure(
    enabled: settings.streamRelay,
    connections: settings.relayConnections,
  );
});

/// 播放控制器。
///
/// 用 `Provider` + `ListenableBuilder` 而不是 `ChangeNotifierProvider`：
/// 后者在 riverpod 2.6 已经标了 `@Deprecated('will be removed in 3.0.0')`，
/// 而 `PlaybackController` 本身就是个 `ChangeNotifier`，直接听更直白。
///
/// ## 两个内核在这里装配（见 `PlaybackController` 的类文档）
///
///   - **默认内核**：media_kit（mpv）。除杜比视界以外的片源全走它。
///   - **杜比视界内核**：fvp（libmdk），**惰性建**（`dolbyVisionEngine` 是工厂）。
///
/// ## 备用内核只在 macOS 上开
///
/// 理由只有一个：**杜比视界 P5**（要探测流的头部字节）。
///
/// ⛔ 2026-10-04 试过在 Android TV 上也开（「≥1440p 走 fvp 直出」），
/// **两轮真机都失败**，最后一轮是「4K 看不到画面，只有声音」+ 原生崩溃。
/// 经过与证据见 `main.dart` 的注册块注释。别再开第二条线。
///
/// ⛔ 判据与 `main.dart` 里那句 `fvp.registerWith` 的 `platforms` 必须
/// **一致** —— 不一致的后果很隐蔽：
///   - 这边开了、那边没注册 → `video_player` 静默走官方那套栈，
///     什么都渲染不对，而且**不报任何错**；
///   - 那边注册了、这边没开 → 只是白注册一次（无害）。
///
/// Android 上两个都不开：mpv 在那边虽然拿不到零拷贝硬解（4K 会卡），
/// 但**有画面**；而 mdk 会丢掉音效、字幕样式、缓冲进度
/// （见 `EngineCapabilities.mdk`），还带崩过进程。
final playbackControllerProvider = Provider<PlaybackController>((ref) {
  // 杜比视界探测。缓存键是 `fileId|档位`，所以同一集只会真的探一次。
  final dvProbe = DolbyVisionProbe();
  final tv = isTvDevice();
  // 备用内核的**工厂**：只有 macOS 的 DV 要它。
  final alternateAvailable = Platform.isMacOS;

  final controller = PlaybackController(
    registry: ref.watch(adapterRegistryProvider),
    subtitleResolver: ref.watch(subtitleResolverProvider),
    relay: ref.watch(streamRelayProvider),
    engine: MediaKitPlaybackEngine(tv: tv),
    dolbyVisionEngine: alternateAvailable ? () => FvpPlaybackEngine() : null,
    dolbyVisionProbe: Platform.isMacOS
        ? ({required key, required url, required headers}) =>
            dvProbe.probe(key: key, url: url, headers: headers)
        : null,
  );

  // 播放进度落库。**在组合根接而不是在播放页接**：这样即使用户在播放中
  // 返回媒体库，进度也还在记 —— 播放页只是「显示进度」的人，不是
  // 「记录进度」的人。
  controller.onPositionTick = (position) {
    final item = controller.item;
    if (item == null) return;

    // 播放记录一变，「最近播放」那一栏就得重取。**换条时才真的重取**
    // （`report` 自己判）—— 这个回调每 10 秒来一次，每次都刷的话，
    // 用户在主窗口看海报墙时它会每 10 秒重建一遍。
    //
    // 独立播放窗口那条路不经过这里（它的播放发生在另一个引擎里），
    // 由 `playerBridgeHostProvider` 在落库的同一处报告。
    ref.read(playbackLibraryLinkProvider.notifier).report(item.id);

    final repo = ref.read(mediaRepositoryProvider);

    unawaited(
      repo.markPlayed(item.id, DateTime.now()).catchError((Object e) {
        // 落库失败不该打断播放，但也不能静默 —— 否则「续播位置丢了」
        // 会变成一个无从查起的问题。
        diag.error('播放', '播放进度落库失败：$e');
      }),
    );

    // 「历史最大位置」—— 作品详情页文件列表底下那条细进度条读的就是它。
    //
    // ⚠️ 这条**必须写**，哪怕 macOS 上播放走的是独立窗口：内置播放页是
    // Android TV 上**唯一**的播放路径，漏了它电视上就永远没有进度条
    // （而且不会报错，只是那条线从来不出现）。
    //
    // 与 `markPlayed` 分开两次写：那一个记「什么时候看的」（决定列表顺序），
    // 这一个记「看到哪儿了」（决定进度条）。一个失败不该带走另一个。
    unawaited(
      repo.saveMaxPosition(item.id, position).then((_) {
        // ⚠️ 写完**再**推刷新信号：反过来的话，详情页收到信号去读库时
        // 这一笔还没落盘，进度条永远慢一拍（每 10 秒白刷一次）。
        ref.read(playbackProgressSignalProvider.notifier).bump();
      }).catchError((Object e) {
        diag.error('播放', '历史进度落库失败：$e');
      }),
    );
  };

  ref.onDispose(controller.dispose);
  return controller;
});

/// 扫码登录客户端（主登录链路）。
///
/// 只依赖 [httpClientProvider]，所以它跟网盘适配器共用同一个 HTTP 抽象 ——
/// 单元测试里换成假客户端就能覆盖全部状态分支。
final qrLoginClientProvider = Provider<QuarkQrLoginClient>(
  (ref) => QuarkQrLoginClient(http: ref.watch(httpClientProvider)),
);

/// 本机设备唯一标识。
///
/// macOS 上用 `IOPlatformUUID`（硬件 UUID，不会变）。
/// 用 `platform` 包取不到它（`Platform` 没有 UUID），所以走平台通道
/// 或直接用 `ios_utils` —— 但为了不引入额外依赖，这里先用 `Platform.hostname`
/// 加 `Platform.localHostname` 做拼接。不够完美但够用：同一台机器两次运行
/// 拿到的值一定一样，不同机器大概率不一样。
///
/// ⚠️ macOS 上 `Platform.localHostname` 跟「电脑名称」走，
/// 用户改名 → 标识变化 → 跨机同步可能误判为不同设备。
/// 真正的 UUID 需要走 `IOPlatform.uuid` 或 `device_info_plus`。
/// 这里先用它，因为备份同步的冲突判定只依赖 UUID 做设备区分，
/// UUID 变了最坏后果是把「同设备先后备份」当成冲突交给用户 ——
/// 不会丢数据。
String _getDeviceId() {
  // macOS 的机器标识
  final hostname = Platform.localHostname;
  final os = Platform.operatingSystem;
  return '${hostname}_$os';
}

/// 设备名称（用户可读）。
String _getDeviceName() {
  return Platform.localHostname;
}

/// 备份同步服务。
///
/// 依赖 [adapterRegistryProvider]（网盘上传/下载）、[appSupportDirProvider]
/// （数据库路径）、[posterCacheDirProvider]（海报缓存路径），
/// 以及 [mediaRepositoryProvider] 提供的「库内容最后变更时间」。
final libraryBackupServiceProvider = Provider<LibraryBackupService>(
  (ref) {
    final registry = ref.watch(adapterRegistryProvider);
    final adapter = registry.requireAdapter(DriveProvider.quark);
    final supportDir = ref.watch(appSupportDirProvider);
    final posterPath = ref.watch(posterCacheDirProvider);

    return LibraryBackupService(
      adapter: adapter,
      databasePath: '$supportDir${Platform.pathSeparator}cloudcine.sqlite',
      posterCachePath: posterPath,
      deviceId: _getDeviceId(),
      deviceName: _getDeviceName(),
      // ⚠️ 必须注入：漏了的话同步会拿「备份文件生成时间」比较，
      // 那等于本机永远比远程新 → 只会上传，新机器会把好备份冲成空库。
      localModifiedAt: () =>
          ref.read(mediaRepositoryProvider).latestLibraryChangeAt(),
    );
  },
);
