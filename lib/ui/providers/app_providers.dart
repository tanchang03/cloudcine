import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../data/auth/quark_qr_login.dart';
import '../../data/auth/secure_credential_store.dart';
import '../../data/db/app_database.dart';
import '../../data/db/media_repository_impl.dart';
import '../../data/db/settings_store.dart';
import '../../data/http/dio_http_client.dart';
import '../../data/http/http_client.dart';
import '../../data/registry/adapter_registry.dart';
import '../../data/remote/quark/quark_adapter.dart';
import '../../data/scrape/poster_cache.dart';
import '../../domain/adapters/credential_store.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/services/playback_controller.dart';
import '../../domain/services/subtitle_service.dart';

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

/// 凭证存储。落系统钥匙串。
final credentialStoreProvider = Provider<CredentialStore>(
  (ref) => SecureCredentialStore(),
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
  (ref) => PosterCache(
    http: ref.watch(httpClientProvider),
    dirPath: ref.watch(posterCacheDirProvider),
  ),
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

/// 播放控制器。
///
/// 用 `Provider` + `ListenableBuilder` 而不是 `ChangeNotifierProvider`：
/// 后者在 riverpod 2.6 已经标了 `@Deprecated('will be removed in 3.0.0')`，
/// 而 `PlaybackController` 本身就是个 `ChangeNotifier`，直接听更直白。
final playbackControllerProvider = Provider<PlaybackController>((ref) {
  final controller = PlaybackController(
    registry: ref.watch(adapterRegistryProvider),
    subtitleResolver: ref.watch(subtitleResolverProvider),
  );

  // 播放进度落库。**在组合根接而不是在播放页接**：这样即使用户在播放中
  // 返回媒体库，进度也还在记 —— 播放页只是「显示进度」的人，不是
  // 「记录进度」的人。
  controller.onPositionTick = (position) {
    final item = controller.item;
    if (item == null) return;
    unawaited(
      ref
          .read(mediaRepositoryProvider)
          .markPlayed(item.id, DateTime.now())
          .catchError((Object e) {
        // 落库失败不该打断播放，但也不能静默 —— 否则「续播位置丢了」
        // 会变成一个无从查起的问题。
        diag.error('播放', '播放进度落库失败：$e');
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
