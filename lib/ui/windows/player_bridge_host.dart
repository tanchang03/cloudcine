import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../core/utils/player_audio_effect.dart';
import '../../core/utils/text_encoding.dart';
import '../../data/db/settings_store.dart';
import '../../data/remote/subtitle/opensubtitles_client.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/entities/playback_preference.dart';
import '../../domain/services/missing_media.dart';
import '../../domain/services/playback_resume.dart';
import '../../domain/services/subtitle_query.dart';
import '../providers/app_providers.dart';
import '../providers/library_providers.dart';
import '../providers/library_refresh_providers.dart';
import 'desktop_play.dart';
import 'player_protocol.dart';
import 'player_window_bridge.dart';

/// 主窗口这一侧的「跨引擎服务台」。
///
/// 独立播放窗口跑在**自己的 Flutter 引擎**里，碰不到主窗口的 Riverpod 容器，
/// 需要什么都得通过通道问。这个 Provider 把主窗口能提供的两种服务装上：
///
///   1. [onPlaybackProgress] —— 播放窗口报「我看到这里了」，这里落库；
///   2. [onTicketRefresh] —— 播放窗口报「直链失效了」，这里重新取链。
///
/// ## 为什么必须由 UI 层装
///
/// `player_window_bridge.dart` 里的处理器在 `main()` 阶段就被注册了，那时
/// 还没有 Riverpod 容器、拿不到仓储与适配器。所以协议文件只声明两个可空的
/// 全局回调，由这里（容器已经起来之后）填上。
///
/// ## 为什么是「纯副作用 Provider」
///
/// 它不产出值，只负责装回调。用 `Provider` + 在 `CloudCineApp.build` 里
/// `watch` 它是 Riverpod 里的常规写法：容器销毁时 `onDispose` 会把回调摘掉，
/// 避免热重载后闭包还指向一个已经失效的 `ref`（那会在下一次回报时抛）。
final playerBridgeHostProvider = Provider<void>((ref) {
  // -------------------------------------------------------------------
  // 服务一：进度落库
  // -------------------------------------------------------------------
  //
  // 内置播放页那条路，进度落库挂在 `playbackControllerProvider` 的
  // `onPositionTick` 上（见 `app_providers.dart`）。但独立窗口那条路播放发生
  // 在**另一个引擎**里，主窗口的 `PlaybackController` 根本没被 `open()` 过，
  // 那个回调永远不会触发 → `lastPlayedAt` 不更新，「最近播放」排序与已看标记
  // 都停在上一次用内置播放页的时候。
  //
  // ⚠️ `markPlayed` 落的是**时间戳**，不是播放位置 —— 它管的是「最近播放」
  // 排序。**续播位置是另一列**（`resumePositionMs`），由下面那段单独写。
  // ⚠️ 这个回调是 `async` 的，且**真的会等到写库完成**：`handlePlayerWindowCall`
  // 会 await 它（理由见那里的注释）。切集时「先落库、再读库算续播点」的顺序
  // 全靠这一步，不能退回 fire-and-forget。
  onPlaybackProgress = (report) async {
    diag.debug(
      '播放',
      '播放窗口回报进度：${report.itemId} @ ${report.position.inSeconds}s',
    );

    final repo = ref.read(mediaRepositoryProvider);
    unawaited(
      repo.markPlayed(report.itemId, DateTime.now()).catchError((Object e) {
        // 落库失败不该打断播放，但也不能静默 —— 否则「最近播放不更新」
        // 会变成一个无从查起的问题。
        diag.error('播放', '播放窗口进度落库失败：$e');
      }),
    );

    // 播放记录变了，媒体库的「最近播放」那一栏就得重取。**只有换条时才真的
    // 重取**（`report` 自己判）—— 这条回报每 10 秒来一次，每次都刷的话，
    // 用户在主窗口看海报墙时它会每 10 秒重建一遍。
    //
    // 内置播放页那条路不走这里：那个播放发生在主窗口自己的
    // `PlaybackController` 上，由 `playbackControllerProvider` 的
    // `onPositionTick` 报告。
    ref.read(playbackLibraryLinkProvider.notifier).report(report.itemId);

    // 续播位置。**独立一段、独立 try** —— 它与「最近播放」是两件事，
    // 一个失败不该把另一个也带走。
    //
    // ⚠️ 这里**刻意不用 `unawaited`**：这段要是异步飘出去，`onPlaybackProgress`
    // 就会在写库完成之前返回，播放窗口切集时读到的就是旧进度（见
    // `player_window_bridge.dart` 里为什么要 await）。
    try {
      // 用户可以在设置里关掉「记住播放进度」。不认这个开关的话，
      // 那个开关对独立窗口就是摆设（它会照记照续）。
      final store = ref.read(settingsStoreProvider);
      if (await store.read(SettingKeys.rememberPosition) == 'false') return;

      // ⚠️ 「已看完」要**清掉**续播点，而不是留着。
      // 留着的话下次打开会从「还差一分钟」开始 —— 直接跳到结尾出字幕，
      // 用户会以为这个视频坏了。判据见 [PlaybackResume]。
      final finished =
          PlaybackResume.isFinished(report.position, report.duration);
      await repo.saveResumePosition(
        report.itemId,
        finished ? null : report.position,
      );
      if (finished) {
        diag.info('播放', '已看完 ${report.itemId}，清除续播点');
      }
    } catch (e) {
      diag.error('播放', '续播位置落库失败：$e');
    }

    // 历史最大位置。**规则与上面那条恰好相反**：看完也**不清**，而且只增
    // 不减（`saveMaxPosition` 自己在 SQL 层用 `max()` 保证）。
    //
    // 详情页「文件」列表底下那条细进度条读的就是它。不能复用续播点：看完的
    // 那一集续播点会被上面清成 NULL，用它画进度条等于「刚看完的一集显示
    // 0%」—— 恰好是用户最想看到 100% 的时刻。
    //
    // ⚠️ 放在上面那个 `rememberPosition` 闸门**之后**：用户关掉「记住播放
    // 进度」时，任何进度都不该被记下来，进度条自然也就不该出现。
    //
    // 独立一段、独立 try —— 它失败不该让「续播点写失败」这条日志说谎。
    try {
      await repo.saveMaxPosition(report.itemId, report.position);
      // 写完再推刷新信号（理由同 `app_providers.dart`：先推的话详情页会读到
      // 还没落盘的值，进度条永远慢一拍）。只影响详情页，不影响海报墙 ——
      // 那是 `playbackLibraryLinkProvider` 的事，两者分工见那个文件。
      ref.read(playbackProgressSignalProvider.notifier).bump();
    } catch (e) {
      diag.error('播放', '历史进度落库失败：$e');
    }
  };

  // -------------------------------------------------------------------
  // 服务二：刷新过期直链
  // -------------------------------------------------------------------
  //
  // 播放窗口手里只有一条带签名的直链，它没有（也不该有）重新取链的能力 ——
  // 取链要凭证、要走四路由降级，那套东西留在主窗口。
  //
  // 这里用**同一份取链逻辑**（`buildPlayRequest`）换一条新链，并把播放窗口
  // 报来的位置填回 `startPosition`，于是刷新对用户表现为「卡一下接着播」
  // 而不是「从头开始」。选档也走同一个入口，所以刷新不会把用户手选的档位
  // 换成设置里的默认档。
  onTicketRefresh = (request) async {
    try {
      final item =
          await ref.read(mediaRepositoryProvider).itemById(request.itemId) ??
              // 库里没有这一行时，可能是**目录视图里直接播的**那一条
              // （没入库）。主窗口在开播时把它登记在了这张表里，取回来就
              // 能照常刷新 —— 否则用户在片长过半时遇到直链过期，只会看到
              // 一句「刷新失败」，而那条链其实完全刷得出来。
              recallTransientItem(request.itemId);
      if (item == null) {
        // 条目被删、或被重扫换过 id 时会走到这。
        diag.warn('窗口', '刷新直链失败：库里找不到 ${request.itemId}');
        return null;
      }
      return await buildPlayRequest(
        ref.read,
        item,
        qualityId: request.qualityId,
        startPosition: request.position,
      );
    } on DriveException catch (e, st) {
      diag.error('窗口', '刷新直链时取链失败', error: e, stackTrace: st);
      // 「文件已经不在网盘上」**必须抛回去**，而不是像其它失败那样返回 null。
      //
      // 返回 null 在播放窗口那边是「刷新失败，停在原地」，于是用户点了
      // 「下一集」之后什么都不会发生 —— 一个静默失败。而自动连播撞上它时
      // 表现更糟：一集播完就没动静了，没有任何提示。
      //
      // 抛出去之后，播放窗口靠 `code` 认出这一类，进而问用户「要不要把这条
      // 已经失效的索引删掉」（见 `player_window_app.dart`）。
      if (isMissingFileError(e)) throw _asMissingFileError(e);
      return null;
    } catch (e, st) {
      // 其余失败（登录失效、网络断了、路由全挂）返回 null 而不是让它抛：
      // 抛出去会变成一条没头没尾的平台通道异常，而这里的日志已经把原因
      // 写清楚了。
      diag.error('窗口', '刷新直链时取链失败', error: e, stackTrace: st);
      return null;
    }
  };

  // -------------------------------------------------------------------
  // 服务七：播放窗口撞上「文件没了」之后的查询与移除
  // -------------------------------------------------------------------
  //
  // 这两条是上面「服务二」抛出 `drive/notFound` 之后的后续两步：播放窗口
  // 手里只有一句失败，而「能删到哪一层」要读库才知道（它连 `groupKey`
  // 都没有），删除本身更是只能由主窗口执行 —— 库与仓储都装在这边。
  onQueryMissingMedia = (itemId) async {
    final item = await ref.read(mediaRepositoryProvider).itemById(itemId);
    if (item == null) return null;
    final plan =
        await ref.read(missingMediaControllerProvider).planFor(item);
    return MissingMediaBrief(
      itemId: itemId,
      itemTitle: plan.itemTitle,
      itemPath: plan.itemPath,
      workTitle: plan.workTitle,
      kind: plan.kind.name,
      fileCount: plan.fileCount,
    );
  };

  onRemoveMissingMedia = (request) async {
    final item =
        await ref.read(mediaRepositoryProvider).itemById(request.itemId);
    if (item == null) return false;
    // 走同一个控制器：删完之后媒体库的所有列表都要重取，那些 provider 都
    // 装在主窗口 —— 播放窗口不需要知道，也不该知道。
    return ref
        .read(missingMediaControllerProvider)
        .remove(item, scope: request.scope);
  };

  // -------------------------------------------------------------------
  // 服务八：剧集面板的缩略图
  // -------------------------------------------------------------------
  //
  // 与取字幕同一条边界：夸克缩略图**缺 Cookie 一律 401**（而且它每个响应
  // 轮换 `__puus`，陈旧 Cookie 是 `401 auth expired`），播放窗口在另一个
  // 引擎里拿不到凭证。
  //
  // ⚠️ 走 `PosterCache` 而不是自己下，是为了**白捡磁盘缓存**：媒体库里
  // 已经显示过的缩略图早就落盘了（文件名里带 URL 散列，见 `fileNameFor`），
  // 于是打开剧集面板这一步对大部分条目**一次网络都不发**。这也正是
  // 「不把请求头塞进 `PlayRequest`、让播放窗口自己 `Image.network`」的理由
  // —— 那条路每次开窗都得重下，还会绕开主窗口的 HTTP 配置。
  //
  // `pathFor` 自己会记日志、失败返回 null，这里只兜住它可能抛的那一层
  // （缓存目录不可写之类），免得把一条平台通道异常甩到播放窗口去。
  onFetchThumbnail = (itemId, url) async {
    try {
      return await ref.read(posterCacheProvider).pathFor(
            // 空 itemId（老版本主窗口投来的请求）退化成用 URL 当键：
            // 文件名难看一点，但图仍然取得回来、也仍然会命中缓存。
            key: itemId.isEmpty ? url : itemId,
            url: url,
          );
    } catch (e, st) {
      diag.error('窗口', '取缩略图失败', error: e, stackTrace: st);
      return null;
    }
  };

  // -------------------------------------------------------------------
  // 服务三：取网盘字幕的正文
  // -------------------------------------------------------------------
  //
  // 播放窗口自己取不了：夸克直链缺 Cookie 一律 412，而 `media_kit` 的
  // `SubtitleTrack.uri` / `.data` 都**没有请求头参数**；编码上，中文外挂字幕
  // 大量是 GBK，mpv 的自动探测经常失败 → 满屏乱码。所以字节由主窗口取、
  // 用 `decodeTextBytes`（先严格 UTF-8、失败再 GBK）解成 UTF-8 文本再过去。
  //
  // 与另外两个服务不同，这个回调**只在用户真的选中一条字幕时**才被调，
  // 频率极低 —— 所以不用像进度回报那样考虑节流。
  onFetchSubtitleText = (fileId) async {
    try {
      final adapter =
          ref.read(adapterRegistryProvider).requireAdapter(DriveProvider.quark);
      // `readFileBytes` 返回的是**非空** `Uint8List`（不支持时抛，见
      // `CloudDriveAdapter` 的能力文档），所以只判空内容。
      final bytes = await adapter.readFileBytes(fileId);
      if (bytes.isEmpty) {
        diag.warn('窗口', '字幕为空 fid=$fileId');
        return null;
      }
      final text = decodeTextBytes(bytes);
      diag.info('窗口', '已取字幕正文 fid=$fileId ${text.length} 字符');
      return text;
    } catch (e, st) {
      // 与刷新直链同样的处理：返回 null 而不是抛。抛出去只会变成一条
      // 没头没尾的 PlatformException，而播放窗口能做的也只是提示一句。
      diag.error('窗口', '取字幕正文失败 fid=$fileId', error: e, stackTrace: st);
      return null;
    }
  };

  // -------------------------------------------------------------------
  // 服务四 / 五：在线字幕（OpenSubtitles）搜索与下载
  // -------------------------------------------------------------------
  //
  // 客户端**现造现用**而不是做成一个 Provider：它的配置来自设置库，而读库是
  // 异步的 —— 做成同步 Provider 就得在启动阶段阻塞读一次，然后设置改了不同步。
  // 这两个回调本来就是低频的（用户手动点一次），每次读一遍设置没有代价。
  Future<OpenSubtitlesClient> openSubtitlesOf(Ref ref) async {
    final store = ref.read(settingsStoreProvider);
    final values = await store.readAll(const [
      SettingKeys.opensubtitlesApiKey,
      SettingKeys.opensubtitlesBase,
    ]);
    final base = values[SettingKeys.opensubtitlesBase];
    return OpenSubtitlesClient(
      http: ref.read(httpClientProvider),
      config: OpenSubtitlesConfig(
        apiKey: values[SettingKeys.opensubtitlesApiKey] ?? '',
        baseUrl: (base != null && base.trim().isNotEmpty)
            ? base.trim()
            : OpenSubtitlesConfig.defaultBaseUrl,
      ),
    );
  }

  onSearchOnlineSubtitles = (request) async {
    // 播放窗口只报 `itemId`，条件由这边从库里补全 —— 季/集号、年份这些
    // 结构化的东西只有库里有（理由见 `SubtitleSearchRequest` 的类文档）。
    final item = request.itemId.isEmpty
        ? null
        : await ref.read(mediaRepositoryProvider).itemById(request.itemId);
    final search = SubtitleQuery.build(item, fallback: request.fallbackQuery);
    if (search.isEmpty) {
      // 不是错误，是「没什么可搜的」：手输直链、自检视频，而且连标题都没有。
      diag.warn('窗口', '在线字幕搜索没有片名可用：$request');
      return const <OnlineSubtitleBrief>[];
    }
    diag.info('窗口', '在线字幕搜索条件：$search');

    try {
      final hits = await (await openSubtitlesOf(ref)).search(
        query: search.query,
        type: search.type,
        year: search.year,
        season: search.season,
        episode: search.episode,
      );
      diag.info('窗口', '在线字幕搜到 ${hits.length} 条：${search.query}');
      return [
        for (final h in hits)
          OnlineSubtitleBrief(
            fileId: h.fileId,
            fileName: h.fileName,
            language: h.language,
            title: h.title,
            downloadCount: h.downloadCount,
          ),
      ];
    } on OpenSubtitlesException catch (e) {
      // 抛给播放窗口：它要把这句人话显示出来。吞掉的话用户只会看到
      // 「搜不到」，而实际是「Api-Key 没配对」—— 排查方向完全不同。
      diag.warn('窗口', '在线字幕搜索失败：${e.failure.name} ${e.message}');
      throw _asChannelError(e);
    }
  };

  onFetchOnlineSubtitle = (fileId) async {
    try {
      return await (await openSubtitlesOf(ref)).fetchText(fileId);
    } on OpenSubtitlesException catch (e) {
      diag.warn('窗口', '在线字幕下载失败：${e.failure.name} ${e.message}');
      throw _asChannelError(e);
    }
  };

  // -------------------------------------------------------------------
  // 服务六：保存手标的片头区间
  // -------------------------------------------------------------------
  //
  // 播放窗口在**另一个引擎**里，它的「片头」菜单只能把「标了什么」报回来 ——
  // 库、仓储、`groupKey` 全都在主窗口这边。所以这里要做的是「把 itemId 翻译成
  // 作品行，再写那两列」。
  //
  // ⚠️ 三个仓储方法**分开调**，不要试图合成一个：
  // `setWorkIntroStart` / `setWorkIntroEnd` / `clearWorkIntroRange` 之所以
  // 是三个而不是一个带可空参数的，正是因为 `copyWith` 的 `??` 把 `null`
  // 当成「不改」——用一个方法表达不了「清除」。
  onSaveIntroRange = (request) async {
    final repo = ref.read(mediaRepositoryProvider);
    final item = await repo.itemById(request.itemId);
    if (item == null) {
      // 条目被删、或被重扫换过 id。返回 null 让播放窗口如实提示，
      // 而不是假装存上了 —— 那会让用户以为标好了，下次播却不跳。
      diag.warn('窗口', '保存片头区间失败：库里找不到 ${request.itemId}');
      return null;
    }

    final key = item.groupKey;
    try {
      if (request.clear) {
        await repo.clearWorkIntroRange(key);
      } else {
        // 允许只写一半：用户是先标起点、播一段、再标终点的。
        // 中间那段时间库里存着「半条标记」是正常状态 ——
        // `IntroMarker.fromMilliseconds` 会把半条当没有，所以不会误跳。
        if (request.startMs case final ms?) {
          await repo.setWorkIntroStart(key, ms);
        }
        if (request.endMs case final ms?) {
          await repo.setWorkIntroEnd(key, ms);
        }
      }

      // 回**落库之后的真实值**，不是一个 bool：播放窗口拿到 true 也仍然不知道
      // 「现在到底存的是什么」，只能照自己的请求猜 —— 而它猜不出「只标了
      // 起点」这种半条状态在库里是被接受还是被拒。
      final work = await repo.workByKey(key);
      final snapshot = IntroRangeSnapshot(
        startMs: work?.introStartMs,
        endMs: work?.introEndMs,
      );
      diag.info('窗口', '片头区间已保存：$key → $snapshot');
      return snapshot;
    } catch (e, st) {
      // 不抛：抛出去会变成一条没头没尾的 PlatformException，而播放窗口
      // 能做的也只是提示一句。日志里已经把原因写清楚了。
      diag.error('窗口', '保存片头区间失败：$key', error: e, stackTrace: st);
      return null;
    }
  };

  // -------------------------------------------------------------------
  // 播放窗口的「音效」菜单选了什么
  // -------------------------------------------------------------------
  //
  // 与片头标记同一条边界：播放窗口在**另一个引擎**里，读不到设置库。
  // 它在本地把音效设进 mpv 之后，只把「选了哪一档」报回来，落库在这边做。
  //
  // ⚠️ 不返回值、也不回传错误：音效在播放窗口那边**已经生效了**，
  // 落库只决定「下次还记不记得」。为一次写库失败让用户看到一个错误提示，
  // 与他的操作（换个音效）毫无关系。
  onSaveAudioEffect = (preset) async {
    try {
      await ref
          .read(settingsStoreProvider)
          .write(SettingKeys.playerAudioEffect, preset.value);
      diag.info('窗口', '音效已存为「${PlayerAudioEffect.label(preset)}」');
    } catch (e, st) {
      diag.error('窗口', '音效没能存下来（本次播放已生效）', error: e, stackTrace: st);
    }
  };

  // -------------------------------------------------------------------
  // 播放窗口的「音轨 / 字幕 / 字幕开关」选了什么
  // -------------------------------------------------------------------
  //
  // 与音效、片头标记同一条边界：播放窗口在**另一个引擎**里，读不到库。
  // 它把「这部片现在是什么状态」整份报回来，落库在这边做。
  //
  // ⚠️ 这里必须自己把 `itemId` 翻成 `groupKey` —— 播放窗口连 groupKey 是什么
  // 都不知道（它只从 `PlayRequest` 拿到 itemId）。而同剧继承的回退查询要用
  // 这一列，所以**只有主窗口能写对**。
  onSavePlaybackPreference =
      (String itemId, PlaybackPreference preference) async {
    try {
      final repo = ref.read(mediaRepositoryProvider);
      final item = await repo.itemById(itemId);
      if (item == null) {
        // 条目被删、或被重扫换过 id。**不写**：写了就是一条挂不到任何文件上
        // 的孤儿偏好，而它在任何界面上都看不到。
        diag.warn('窗口', '播放偏好保存失败：库里找不到 $itemId');
        return;
      }
      await repo.savePlaybackPreference(itemId, item.groupKey, preference);
      diag.info('窗口', '播放偏好已保存：$itemId → $preference');
    } catch (e, st) {
      // 与音效同一条边界：不抛、不弹提示。播放窗口那边早就生效了，
      // 落库只决定「下次还记不记得」—— 为一次写库失败给用户报错，
      // 与他的操作（换条字幕）毫无关系。
      diag.error('窗口', '播放偏好没能存下来（本次播放已生效）', error: e, stackTrace: st);
    }
  };

  ref.onDispose(() {
    onPlaybackProgress = null;
    onTicketRefresh = null;
    onFetchSubtitleText = null;
    onFetchThumbnail = null;
    onSearchOnlineSubtitles = null;
    onFetchOnlineSubtitle = null;
    onSaveIntroRange = null;
    onQueryMissingMedia = null;
    onRemoveMissingMedia = null;
    onSaveAudioEffect = null;
    onSavePlaybackPreference = null;
  });
});

/// 把字幕站的异常翻译成**跨引擎通道能原样送达**的形状。
///
/// ## 为什么必须过这一道
///
/// 通道的错误只有一种编码：`PlatformException` 的三段 `code` / `message` /
/// `details`。别的异常从处理器里抛出来，框架会兜底成
/// `code='error'`、`message=<整段 toString>` —— 于是用户看到的提示是
/// `OpenSubtitlesException(notConfigured, 还没填 OpenSubtitles 的 Api-Key…)`。
/// 一句本该很干净的话，被包了一层内部类型的名字。
///
/// 拆开之后两边各取所需：`code` 是机器可读的失败种类（`opensubtitles/badApiKey`），
/// 只进日志；`message` 是能直接显示给用户的中文。播放窗口那边拿到的
/// `WindowChannelException` 就是这两段。
PlatformException _asChannelError(OpenSubtitlesException e) => PlatformException(
      code: 'opensubtitles/${e.failure.name}',
      message: e.message,
      details: e.statusCode,
    );

/// 把「文件已经不在网盘上」翻译成跨引擎通道的形状。
///
/// 与 [_asChannelError] 同一条理由，但这里多一层要求：**`code` 必须稳定**。
/// 播放窗口靠它把「这次没取到」和「文件没了」分开 —— 只有后者才该给出
/// 「从媒体库移除」这个出口。写错或改名的后果是那个出口永远不出现，
/// 而用户在自动连播时只会看到「播完一集就没动静了」。
PlatformException _asMissingFileError(DriveException e) => PlatformException(
      code: PlayerBridgeError.missingFile,
      message: '文件不存在或已被删除（可能网盘侧删掉了）',
      details: e.message,
    );
