import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/tv_device.dart';
import '../../data/auth/baidu_qr_driver.dart';
import '../../data/auth/baidu_qr_login.dart';
import '../../data/auth/quark_qr_driver.dart';
import '../../data/auth/quark_qr_login.dart';
import '../../data/auth/secret_backend.dart';
import '../../data/auth/secure_credential_store.dart';
import '../../data/db/app_database.dart';
import '../../data/db/media_repository_impl.dart';
import '../../data/db/progress_store.dart';
import '../../data/db/progress_sync.dart';
import '../../data/db/settings_store.dart';
import '../../data/http/dio_http_client.dart';
import '../../data/http/http_client.dart';
import '../../data/playback/fvp_playback_engine.dart';
import '../../data/playback/media_kit_playback_engine.dart';
import '../../data/playback/video_player_exo_playback_engine.dart';
import '../../data/registry/adapter_registry.dart';
import '../../data/remote/baidu/baidu_adapter.dart';
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
import '../../domain/services/qr_login_driver.dart';
import '../../domain/services/subtitle_service.dart';
// ⚠️ 与 `auth_providers.dart` 互相 import（那边要 `credentialStoreProvider` /
//    `adapterRegistryProvider`，这边要 `authControllerProvider` 挑备份网盘）。
//    Dart 允许循环 import，而这里两个文件都只有**顶层 provider 声明**，
//    没有求值顺序依赖 —— Riverpod 是惰性的，谁先被 watch 谁先建。
import 'auth_providers.dart';
import 'library_refresh_providers.dart';
import 'settings_providers.dart';

/// 组合根。
///
/// **所有具体实现的唯一装配点。** 领域层只认抽象，这里把它们接到一起。
/// 新增一家网盘 = 在 [adapterRegistryProvider] 里多传一个适配器实例，
/// 其余 provider、页面、播放引擎都不用动。

/// 当前数据库实例的**持有者**。
///
/// ## 为什么需要一个可替换的持有者
///
/// 恢复备份是把备份包里的 **SQLite 文件字节整体覆盖**到 `cloudcine.sqlite`，
/// 所以覆盖前后必须换掉**整个** [AppDatabase]。
///
/// ⛔ 而 Drift 的连接**关掉就不能再开**：`_BaseExecutor.ensureOpen` 里
///    `_closed` 一旦置位，之后任何查询都直接抛
///    `StateError: Can't re-open a database after closing it. Please create a
///    new database connection and open that instead.`
///    —— 2026-10-07 的「恢复备份报错」正是照着「关掉再打开同一个实例」写的：
///    日志停在「数据库 1884160 字节」之后（`writeAsBytes` 之后那一句
///    `_openDatabase()` 抛了），用户看到
///    「恢复失败：Bad state: Can't re-open a database…」。
///
/// 所以让实例本身可替换：恢复流程调 [DatabaseHandle.swap]，[databaseProvider]
/// 以及所有 watch 它的仓储 / 设置缓存随之拿到新实例；新实例的第一次查询会
/// 重新读 `PRAGMA user_version`，于是 `onUpgrade` 照跑，迁移一步不少。
class DatabaseHandle extends Notifier<AppDatabase> {
  DatabaseHandle([this._initial]);

  /// 启动时注入的那一个。为 `null` 说明组合根忘了注入。
  final AppDatabase? _initial;

  /// [swap] 换上的那一个。`null` 表示还没换过。
  ///
  /// ⛔ 必须单独记着，**不能**让 [build] 直接返回 `_initial`：Riverpod 会
  ///    复用 Notifier 实例再调一次 `build()`（`ref.invalidate`、依赖变化、
  ///    热重载都会）。如果那时返回的是 `_initial`，就等于**把刚换上的新库
  ///    又退回给那个已经被 `close()` 的旧实例** —— 之后每一次查询都抛
  ///    `Can't re-open a database after closing it`，而且是在「恢复成功」
  ///    之后才炸，比恢复本身失败更难查。
  AppDatabase? _current;

  @override
  AppDatabase build() {
    // 重建时优先给「当前那一个」：换过库之后，`_current` 才是真的。
    final existing = _current;
    if (existing != null) return existing;
    final initial = _initial;
    if (initial == null) {
      throw UnimplementedError(
        'databaseHandleProvider 必须在 main() 里用 ProviderScope.overrides 注入',
      );
    }
    return initial;
  }

  /// 换上一个**新**实例。
  ///
  /// ⛔ 传进来的必须是一个全新的 [AppDatabase]。把一个已经 `close()` 过的实例
  ///    传回来等于什么都没做 —— 下一次查询照样抛那个 `StateError`。
  void swap(AppDatabase next) {
    _current = next;
    state = next;
  }
}

/// 数据库实例的持有者。在 `main()` 里注入，恢复备份时被 [DatabaseHandle.swap] 替换。
final databaseHandleProvider =
    NotifierProvider<DatabaseHandle, AppDatabase>(DatabaseHandle.new);

/// 本地索引数据库。
///
/// 在 `main()` 里打开后通过 `ProviderScope.overrides` 注入（见
/// [databaseHandleProvider]）—— 打开数据库是异步的（要先拿应用支持目录），
/// 塞不进同步的 Provider 里。
///
/// 值转发给 [databaseHandleProvider]：恢复备份换了实例之后，
/// `mediaRepositoryProvider` / `settingsStoreProvider`（以及 watch 它们的
/// `settingsProvider` 等）会一起重建，于是**不需要重启应用**。
///
/// ⚠️ 这里仍然保持 `Provider` 而不是把持有者直接暴露出去：单测里有 24 处
///    `databaseProvider.overrideWithValue(db)`，而 Riverpod 2.6 里
///    **只有 `Provider` 有 `overrideWithValue`**（`StateProvider` /
///    `NotifierProvider` 都没有）。把类型换掉会一次性打爆那 24 处。
final databaseProvider = Provider<AppDatabase>(
  (ref) => ref.watch(databaseHandleProvider),
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

/// 已接入的网盘适配器。夸克（读写全能力）+ 百度（**只读**：授权 / 遍历 / 取流）。
///
/// ⛔ 注册表里放的是**全部**适配器，而且是**常驻**的 —— 不存在「只注册
///    当前那一家」这种做法。重建注册表会把所有适配器 `dispose` 掉
///    （[ref.onDispose]），而 `dispose` 会丢掉会话 —— 也就是「登出了一家，
///    另一家也跟着掉线」。多家同时在线的前提就是它只建一次。
final adapterRegistryProvider = Provider<AdapterRegistry>((ref) {
  final registry = AdapterRegistry([
    QuarkAdapter(
      http: ref.watch(httpClientProvider),
      credentialStore: ref.watch(credentialStoreProvider),
    ),
    BaiduAdapter(
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
  (ref) => DriftMediaRepository(
    ref.watch(databaseProvider),
    // 进度**独立存储**。仓储的三个写方法会写透到它（见 `DriftMediaRepository`
    // 的类文档），而它自己与 `cloudcine.sqlite` **没有任何关系** ——
    // 清空索引库 / 恢复备份都碰不到它。
    progress: ref.watch(progressStoreProvider),
  ),
);

/// 播放进度的独立存储（`<应用支持目录>/playback_progress.json`）。
///
/// ## 为什么它在组合根，而不是跟着数据库走
///
/// 它是**跨数据库实例存活**的：恢复备份会把 `AppDatabase` 整个换掉
/// （见 [DatabaseHandle]），而进度文件必须在那次替换前后**原样不动** ——
/// 那正是这个功能的全部意义。所以它挂在 `appSupportDirProvider` 上，
/// 与 `databaseProvider` 是两棵互不影响的依赖树。
final progressStoreProvider = Provider<ProgressStore>((ref) {
  final dir = ref.watch(appSupportDirProvider);
  final store = ProgressStore(
    filePath: '$dir${Platform.pathSeparator}${ProgressStore.fileName}',
  );
  // 退出前把内存里最后那几条落盘（防抖窗口里可能还压着东西）。
  ref.onDispose(() => unawaited(store.dispose()));
  return store;
});

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
/// 取字节走**片子自己那家网盘**的 `readFileBytes` —— 字幕直链**没有请求头
/// 参数**（见 `SubtitleResolver` 的类文档），所以字节必须由我们自己取回来。
///
/// ⛔ [provider] 由调用方给（`MediaItem.provider` / `PlayRequest.itemId` 的
///    前缀），**不是**「当前网盘」。媒体库里同时有夸克和百度的片子，
///    用一家去取另一家的字幕只会拿到 404，表现为「字幕加载失败」
///    而用户看不出是网盘弄错了。
final subtitleResolverProvider = Provider<SubtitleResolver>(
  (ref) => SubtitleResolver(
    readBytes: (provider, fileId) => ref
        .read(adapterRegistryProvider)
        .requireAdapter(provider)
        .readFileBytes(fileId),
  ),
);

/// 备份上传/下载落到**哪一家**网盘。
///
/// ## 为什么需要「挑一家」
///
/// `LibraryBackupService` 是**单个**适配器（备份包只落在一处），而多家网盘
/// 同时在线时就有得选了。判据是 `Capabilities.canWrite` —— 百度这次对接是
/// **只读**的（见 `BaiduAdapter.baiduCapabilities`），挑中它的后果是用户点
/// 「备份」只拿到一句 `unsupported`，而他明明已经登录了夸克，只是不知道
/// 该选哪个。
///
/// 一家能写的都没有时返回 `null`（调用方据此给提示），**不退回夸克** ——
/// 退回会让「只登录了百度」的用户看到一串看不懂的错误。
final backupDriveProvider = Provider<DriveProvider?>((ref) {
  final registry = ref.watch(adapterRegistryProvider);
  final accounts =
      ref.watch(authControllerProvider).valueOrNull?.accounts ?? const {};
  for (final provider in registry.providers) {
    if (!accounts.containsKey(provider)) continue;
    final adapter = registry.adapterFor(provider);
    if (adapter == null) continue;
    if (adapter.capabilities.canWrite) return provider;
  }
  return null;
});

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
/// ## 备用内核在 macOS 与 Android TV 上都开
///
/// 理由：macOS 为**杜比视界 P5**；Android TV 为「≥4K 或 DV」。
///
/// ⛔ 判据与 `main.dart` 里那句 `fvp.registerWith` 的 `platforms` 必须
/// **一致** —— 不一致的后果很隐蔽：
///   - 这边开了、那边没注册 → `video_player` 静默走官方那套栈，
///     什么都渲染不对，而且**不报任何错**；
///   - 那边注册了、这边没开 → 只是白注册一次（无害）。
///
/// 两条线各自失败的历史见 `main.dart` 注册块注释与
/// `docs/解决4k片源不卡顿解析方案.md`。
final playbackControllerProvider = Provider<PlaybackController>((ref) {
  // 杜比视界探测。缓存键是 `fileId|档位`，所以同一集只会真的探一次。
  final dvProbe = DolbyVisionProbe();
  final tv = isTvDevice();
  // 备用内核的**工厂**：macOS 走 DV 路由，Android TV 走「≥4K 或 DV」。
  final alternateAvailable = Platform.isMacOS || (Platform.isAndroid && tv);

  final controller = PlaybackController(
    registry: ref.watch(adapterRegistryProvider),
    subtitleResolver: ref.watch(subtitleResolverProvider),
    relay: ref.watch(streamRelayProvider),
    engine: MediaKitPlaybackEngine(tv: tv),
    // Android TV 的「备用内核」改用官方 video_player（= Media3 ExoPlayer）：
    // fvp/libmdk 在 MiTV 上拿不到硬解（VDEC exit + 300% CPU），ExoPlayer 是
    // 夸克那套。macOS 仍用 fvp 走 DV 路。
    dolbyVisionEngine: alternateAvailable
        ? () => Platform.isAndroid
            ? VideoPlayerExoPlaybackEngine()
            : FvpPlaybackEngine()
        : null,
    dolbyVisionProbe: alternateAvailable
        ? ({required key, required url, required headers}) =>
            dvProbe.probe(key: key, url: url, headers: headers)
        : null,
    highResTvRoute: Platform.isAndroid && tv,
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

/// 扫码登录客户端（夸克，主登录链路）。
///
/// 只依赖 [httpClientProvider]，所以它跟网盘适配器共用同一个 HTTP 抽象 ——
/// 单元测试里换成假客户端就能覆盖全部状态分支。
final qrLoginClientProvider = Provider<QuarkQrLoginClient>(
  (ref) => QuarkQrLoginClient(http: ref.watch(httpClientProvider)),
);

/// 扫码登录客户端（百度）。
///
/// 链路与夸克完全不同（三跳都在 `passport.baidu.com`），所以是**两个客户端**
/// 而不是一个带开关的 —— 差异见 `baidu_qr_login.dart` 的类文档。
final baiduQrLoginClientProvider = Provider<BaiduQrLoginClient>(
  (ref) => BaiduQrLoginClient(http: ref.watch(httpClientProvider)),
);

/// 扫码登录驱动的**工厂**。
///
/// ## ⛔ 为什么是工厂，不是 `Provider.family`
///
/// 驱动**持有会话状态**（token / sign / 待兑换的回执）。`family` 会缓存
/// 实例，第二次进扫码页拿到的还是上一次那个会话 —— 表现是「点了刷新，
/// 轮询的却还是旧 sign」。工厂每次调都新建一个，页面自己管生命周期。
final qrLoginDriverFactoryProvider = Provider<QrLoginDriver Function(DriveProvider)>(
  (ref) {
    // 两个客户端都**惰性**建：工厂被求值时不碰它们，只在真正 new 驱动时读。
    return (provider) => switch (provider) {
          DriveProvider.quark =>
            QuarkQrDriver(client: ref.read(qrLoginClientProvider)),
          DriveProvider.baidu =>
            BaiduQrDriver(client: ref.read(baiduQrLoginClientProvider)),
          _ => throw StateError(
              '${provider.displayName} 暂不支持扫码登录'
              '（当前只有夸克与百度接入了扫码链路）',
            ),
        };
  },
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
///
/// ## ⚠️ 绑的是**当前网盘**
///
/// 备份服务。备份包落在 [backupDriveProvider] 挑出来的那一家。
///
/// ⛔ **百度目前是只读适配器**（`uploadFile` 继承基类默认实现，抛
///    `unsupported`）。所以 [backupDriveProvider] 只会挑到夸克；
///    只有百度在线时，备份上传会如实报「不支持」。这是能力如实反映，
///    不是 bug —— 写入链路要等真实账号验证过读链路之后再单独做。
///    进度文件的**上传**同理，而**下载**不受影响。
final libraryBackupServiceProvider = Provider<LibraryBackupService>(
  (ref) {
    final registry = ref.watch(adapterRegistryProvider);
    // ⛔ 没有一家能写的网盘时**退回夸克**，而不是抛。这个服务还负责
    //    **下载**（从网盘恢复），那条路径不需要写权限，也不该因为
    //    「没人能上传」而整个不可用。真去上传时由 `LibraryBackupService`
    //    拿到 `unsupported`，那是准确的、可解释的错误。
    final drive = ref.watch(backupDriveProvider) ?? DriveProvider.quark;
    final adapter = registry.requireAdapter(drive);
    final supportDir = ref.watch(appSupportDirProvider);
    final posterPath = ref.watch(posterCacheDirProvider);
    // 库文件路径要在两个地方用：告诉服务「备份里那份字节该落到哪」，
    // 以及恢复完之后用它建一个**新**的 AppDatabase（见 openDatabase）。
    final dbPath = '$supportDir${Platform.pathSeparator}cloudcine.sqlite';

    return LibraryBackupService(
      adapter: adapter,
      databasePath: dbPath,
      posterCachePath: posterPath,
      deviceId: _getDeviceId(),
      deviceName: _getDeviceName(),
      // ⛔ 必须传真实版本号。这个参数曾经有个 `= 6` 的默认值，而这里没传 ——
      //    于是**每一份备份的清单里都写着 `schema=6`**，「备份来自更高版本」
      //    的校验（`manifest.schemaVersion > _schemaVersion`）永远为假。
      //    改成 `required` 之后，漏传就是编译错误而不是静默错误。
      schemaVersion: AppDatabase.currentSchemaVersion,
      // ⚠️ 必须注入：漏了的话同步会拿「备份文件生成时间」比较，
      // 那等于本机永远比远程新 → 只会上传，新机器会把好备份冲成空库。
      localModifiedAt: () =>
          ref.read(mediaRepositoryProvider).latestLibraryChangeAt(),
      // 恢复备份是拿备份里的字节覆盖**整个** `cloudcine.sqlite` 文件，
      // `settings` 表随之被换掉 —— 而 `SettingsStore` 有一层进程内缓存，
      // 它不知道文件被换了。
      //
      // 不接这一条的表现（**静默**）：在新机器上先打开设置页（缓存记下
      // 「TMDB Key 为空」）→ 从网盘恢复电脑上的备份 → 设置页还是空的、
      // 刮削继续走匿名额度，重启应用才正常。这正是「token / cookie 随备份
      // 恢复」需求的关键一步。
      //
      // ⛔ 用 `ref.read`（回调求值时才取）而不是 `ref.watch`：watch 会让
      //    `libraryBackupServiceProvider` 跟着设置的变化重建，而这个服务
      //    持有设备标识与路径，没有重建的理由。
      onLibraryReplaced: () => ref.read(settingsStoreProvider).invalidate(),
      // ⛔⛔ 这两个钩子是**恢复备份能不能用**的关键。缺了就是
      //      「库看着恢复了，碰追剧的查询却抛 `no such column: followed`」。
      //      两件事必须成对做，顺序不能换：
      //
      //       ① 覆盖文件**之前**关掉旧连接 —— SQLite 还开着的时候文件被换掉，
      //          它手里的页缓存与文件句柄指向的仍是旧库；
      //       ② 覆盖文件**之后**换一个**新实例**并主动叫醒它 —— Drift 只在
      //          打开连接时读一次 `PRAGMA user_version`，据此决定跑不跑
      //          `onUpgrade`。不重开 ⇒ 迁移一步都不跑，磁盘上是旧结构、
      //          连接以为还是新版本。
      //
      //      ⛔ 第 ② 步**不能**写成「把刚才那个实例重新打开」。Drift 的
      //         `close()` 是**终局**的：`_BaseExecutor._closed` 置位之后
      //         `ensureOpen` 直接抛 `StateError: Can't re-open a database
      //         after closing it`。2026-10-07 就是栽在这里 —— 日志停在
      //         「数据库 1884160 字节」之后，用户看到
      //         「恢复失败：Bad state: Can't re-open a database…」。
      //      （Android 端一直是对的：`LibraryDb.replaceWithRawBytes` 也是
      //        `close() → writeBytes() → open()`，但它的 `open()` 是**重建**
      //        连接并补表补列，不是重开旧连接。）
      closeDatabase: () => ref.read(databaseProvider).close(),
      openDatabase: () async {
        final next = AppDatabase.openFile(File(dbPath));
        // 换实例 → `databaseProvider` 及其下游（仓储 / 设置缓存）全部重建。
        ref.read(databaseHandleProvider.notifier).swap(next);
        // 主动叫醒：Drift 是**懒**打开的，`onUpgrade` 要等第一次查询才跑。
        // 少了这一句，迁移会拖到用户下一次点进媒体库，中间那段时间库里
        // 还是旧结构（就是那个 `no such column: followed`）。
        await next.customSelect('SELECT 1').get();

        // ⛔⛔ **把独立进度库铺回刚换上的这份库**。
        //
        // 恢复备份换掉的是**整个** `cloudcine.sqlite`，里面那三列进度跟着
        // 一起被换成了备份里那份（可能是几周前的，也可能来自另一台机器）。
        // 不铺回来的话，用户点一次「从网盘恢复」就把本机所有续播点、
        // 历史进度、已读回执一起丢了 —— 而界面上显示的是「恢复成功」。
        //
        // 放在 `openDatabase` 里而不是 `onLibraryReplaced`：那一个是**同步**
        // 回调（只做清缓存 / invalidate），而这里要读写数据库。
        try {
          final store = ref.read(progressStoreProvider);
          await store.load();
          // 先把这份恢复回来的库里带着的进度**收进**进度库（那可能是另一台
          // 设备还没同步上来的记录），再把合并结果铺回去。
          await store.mergeFrom(
            await ref.read(mediaRepositoryProvider).progressSnapshot(),
          );
          await ref
              .read(mediaRepositoryProvider)
              .applyProgressSnapshot(store.book);
          await store.flush();
        } catch (e) {
          // 回填失败不该让「恢复备份」这个动作报错：库已经换好了，
          // 进度下一轮启动同步时会再铺一次。
          diag.warn('进度', '恢复备份后回填进度失败（下次同步会重试）：$e');
        }
      },
    );
  },
);

/// 播放进度的**静默同步服务**。
///
/// 三个依赖各自负责一件事：进度库（本地真源）、仓储（播种与回填）、
/// 以及网盘那两个动作（读 / 写进度文件）。
///
/// ⚠️ 网盘那一步绑的是 `libraryBackupServiceProvider` 的两个方法，
///    而不是整个服务对象 —— 服务本身只需要「读一个文件 / 写一个文件」，
///    收窄之后单测用两个闭包就能覆盖全部分支。
final progressSyncServiceProvider = Provider<ProgressSyncService>((ref) {
  final backups = ref.watch(libraryBackupServiceProvider);
  return ProgressSyncService(
    store: ref.watch(progressStoreProvider),
    repository: ref.watch(mediaRepositoryProvider),
    downloadRemote: backups.downloadProgressFile,
    uploadRemote: (bytes) => backups.uploadProgressFile(bytes),
  );
});

/// 「现在同步一次进度」的**触发信号**。
///
/// ## 为什么是一个自增计数器，而不是直接调服务
///
/// 与 `library_refresh_providers.dart` 里那几个信号同一个理由：
/// 调用方（播放页的 `dispose`）不该认识 `ProgressSyncService`，
/// 否则「谁在什么时机同步」这件事会散落在页面里。这里只负责**说一声**，
/// 由 [progressSyncSchedulerProvider] 决定怎么跑。
///
/// ## 为什么带节流
///
/// 退出播放页有**四条**路径（返回按钮、系统返回键、手势返回、跳到别的路由）
/// 都经过同一个 `dispose`，而连播模式下用户可能一集一集连着退。
/// 20 秒的窗口把这一串压成一次真正的同步。
class ProgressSyncTrigger extends Notifier<int> {
  @override
  int build() => 0;

  DateTime? _lastRequestAt;

  /// 请求同步一次。返回是否真的发起了（被节流时返回 `false`）。
  bool request() {
    final now = DateTime.now();
    final last = _lastRequestAt;
    if (last != null && now.difference(last) < const Duration(seconds: 20)) {
      return false;
    }
    _lastRequestAt = now;
    state = state + 1;
    return true;
  }
}

final progressSyncTriggerProvider =
    NotifierProvider<ProgressSyncTrigger, int>(ProgressSyncTrigger.new);

/// 进度静默同步的**调度器**（纯副作用 Provider，不产出值）。
///
/// ## 三个触发点
///
/// | 时机 | 延迟 | 为什么是这个时机 |
/// |---|---|---|
/// | 启动 | 12 秒 | 让媒体库首屏先出来 —— 同步要走网络，不该跟首屏抢 |
/// | 每 30 分钟 | — | 两台设备交替使用、且都不退播放器时，靠它兜住 |
/// | 退出播放器 | 节流 20 秒 | 用户「看完这一集」的自然分界点 |
///
/// ⛔ 与 `relayConfigSyncProvider` 同一条规矩：**它不产出值，必须有人
///    watch 才生效**（在 `CloudCineApp.build` 里）。漏了的话表现是
///    「进度永远同步不出去」，而**没有任何报错**。
///
/// ⛔ 两个 `Timer` 都必须在 `onDispose` 里 cancel：Provider 重建
///    （热重载、恢复备份换了库）时会重新执行本函数体，不取消的话每重建
///    一次就多一个永不停止的定时器，最后会同时发起几十次同步。
final progressSyncSchedulerProvider = Provider<void>((ref) {
  final service = ref.watch(progressSyncServiceProvider);

  void run(String why) {
    if (service.isRunning) return;
    unawaited(
      service.syncSilently().then((outcome) {
        if (!outcome.ok) diag.debug('进度', '[$why] 同步未完成：${outcome.message}');
      }),
    );
  }

  // 启动后延迟一次。
  final launchTimer = Timer(const Duration(seconds: 12), () => run('启动'));

  // 每 30 分钟一次。
  final periodic = Timer.periodic(
    const Duration(minutes: 30),
    (_) => run('定时'),
  );

  // 「退出播放器」。
  ref.listen<int>(progressSyncTriggerProvider, (previous, next) {
    if (previous == next) return;
    run('退出播放器');
  });

  ref.onDispose(() {
    launchTimer.cancel();
    periodic.cancel();
  });
});
