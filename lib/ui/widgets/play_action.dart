import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../domain/entities/drive_entry.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/services/directory_anchor_loader.dart';
import '../../domain/services/follow_read.dart';
import '../../domain/services/media_discovery.dart';
import '../../domain/services/media_entry_classifier.dart';
import '../../domain/services/missing_media.dart';
import '../providers/app_providers.dart';
import '../providers/library_refresh_providers.dart';
import '../windows/desktop_play.dart';
import 'missing_media_dialog.dart';

/// 「播这一条」—— 全应用**唯一**的起播入口。
///
/// ## 为什么必须只有一份
///
/// 起播有两条路：桌面端的独立播放窗口，以及其它平台（或窗口起不来时）的
/// 内置播放页。两处页面各写一份的话，迟早会出现「从海报墙点进去走窗口、
/// 从详情页点进去走内置页」这种分裂 —— 而用户只会觉得「有时候是窗口、
/// 有时候不是，说不清什么时候」。
///
/// ## 降级是**静默**的
///
/// 用户点播放的意图是看片，不是体验多窗口。所以「窗口开不出来」不该变成
/// 一个错误弹窗 —— 直接退回内置播放页，原因进诊断日志
/// （见 `openInPlayerWindow`）。
///
/// ## 唯一一个例外：文件已经不在网盘上了
///
/// 那时**不**退回内置播放页。内置页会拿同一个 fid 再取一次链，必然以同样的
/// 方式失败：白烧一次请求，还把用户晾在一个注定打不开的页面上。取链这一步
/// 在 `buildPlayRequest` 里已经做过了（就在开窗口之前），所以文件没了这件
/// 事在**主窗口**就知道 —— 直接在这里问「要不要从媒体库里移除」。
Future<void> playItem(
  BuildContext context,
  WidgetRef ref,
  MediaItem item, {
  String? qualityId,
}) async {
  try {
    if (await openInPlayerWindow(ref, item, qualityId: qualityId)) {
      unawaited(_markOpened(ref, item));
      return;
    }
  } on DriveException catch (e) {
    // `openInPlayerWindow` 只把「文件没了」这一类抛出来，其余一律吞掉并
    // 退回内置页。这里的判据是**再确认一次**而不是信任调用约定 —— 万一
    // 哪天那边放宽了口径，这里也不会拿「登录失效」去问用户要不要删片。
    if (isMissingFileError(e)) {
      if (!context.mounted) return;
      await removeMissingMedia(context, ref, item);
      return;
    }
  }
  if (!context.mounted) return;
  unawaited(_markOpened(ref, item));
  // `extra` 带的是**对象本身**，不是 id：未入库的条目（目录视图直接点播）
  // 库里没有这一行，内置播放页拿 id 去查会查不到（见 `PlayerPage` 的
  // `item` 字段）。已经入库的条目带上它也无害 —— 同一个对象，省一次点查。
  await context.push(
    '/play?item=${Uri.encodeComponent(item.id)}',
    extra: item,
  );
}

/// 「**点开即已读**」—— 与播放了多久**无关**（2026-10-07）。
///
/// ## 为什么必须有这一步
///
/// 原先「这一集看过了没有」只看 `media_items.max_position_ms`，而那一列只在
/// **进度上报**时写，进度上报又只在**整十秒边界**触发
/// （`ProgressThrottle`）⇒ **点开一集看一眼（不到 10 秒）等于什么都没发生**。
///
/// 2026-10-07 真实现场：用户点开 `Z 遮 天 E184` 播了 **3 秒**、`E183` 播了
/// **2 秒**就关窗（日志里一次进度回报都没有），库里
/// `max_position_ms` / `last_played_at` / `resume_position_ms` 三列全是 NULL
/// ⇒ 行上的 `■ NEW` 不消失、海报上「更新 2」也不动。用户的口径很明确：
///
/// > 「**无论播放了多长时间，只要点击了，就去掉 new 标记**」
///
/// ## 写的是「已读回执」，不是「播放位置」
///
/// `markPlayed` 只写 `last_played_at`（它同时是「最近播放」的排序键），
/// **不写** `max_position_ms` —— 后者是「看到哪儿了」，写一个假的极小值会在
/// 每一行点过的条目上画出一条 0% 的进度槽。理由与取舍见
/// `domain/services/follow_read.dart`。
///
/// ## ⛔ 三个 `ref.read` 必须全部在第一个 `await` 之前
///
/// 内置播放页那条路紧接着就 `context.push` 把这一页换掉了，之后再碰 `ref`
/// 会抛「Cannot use ref after the widget was disposed」。所以先把仓储与三个
/// 通知器取到手上，再去做异步的写库。
///
/// ⚠️ 刻意**不**推 `libraryWriteSignalProvider`：它下游挂着
/// `folderTreeProvider`（每次要读全表两万行），而播放写的只是播放记录。
/// 与 `playbackControllerProvider.onPositionTick` 同一套口径 —— 那条路也只推
/// 播放进度信号与「最近播放」换条信号。
Future<void> _markOpened(WidgetRef ref, MediaItem item) async {
  final repo = ref.read(mediaRepositoryProvider);
  final progress = ref.read(playbackProgressSignalProvider.notifier);
  final list = ref.read(libraryListSignalProvider.notifier);
  try {
    // 1) 已读回执。⛔ 不写 `max_position_ms`（那是位置，理由见上）。
    await repo.markPlayed(item.id, DateTime.now());
    // 2) 追剧角标跟着降（只下调）。见 `syncFollowReadCount` 的文档。
    //
    // ⚠️ 这里传的是 `item.groupKey`（文件名解析出来的归组键），**不是**作品
    //    key —— 刮削归一之后两者不再相等（`group_key='z遮天'` 而
    //    `media_works.key='shroudingtheheavens'`）。`syncFollowReadCount`
    //    会自己顺着 `mergedInto` 走到目标作品，所以传别名 key 是安全的。
    await syncFollowReadCount(repo, item.groupKey);
    // 3) 通知读库的视图：
    //    - 详情页 —— 那一行的 `■ NEW` 与进度条（它 watch 播放进度信号）；
    //    - 海报墙 / 分类栏「追剧 N」角标 —— 作品级列表（它们 watch 列表信号）。
    progress.bump();
    list.bump();
  } catch (e) {
    // 落库失败不该拦住播放（用户点的是「看片」），但也不能静默 ——
    // 否则「NEW 标记点了不消失」会变成一个无从查起的问题。
    diag.debug('播放', '起播「已读」落库失败：$e');
  }
}

/// 「播网盘上的这一个文件」—— **不需要它已经在媒体库里**。
///
/// ## 为什么要有这条入口
///
/// 目录视图列的是**网盘上的东西**，而媒体库只装「扫过 / 发现过的东西」。
/// 两者之间那段差额（新上传的、上次扫漏的、别人分享过来还没入库的）原先
/// 只能「先点『加入媒体库』、再点播放」。而用户点播放的意图是**看片**，
/// 不是整理媒体库；那个中间步骤还会真的改库（多一条记录、多一部作品），
/// 而他可能只是想先看一眼画质对不对。
///
/// ## 它**不写库**
///
/// 这里造的 `MediaItem` 只活在内存里（[parseTransientMedia]），一行都不落。
/// 起播链本来就不依赖本地库：`PlaybackController.open` 只收一个 `MediaItem`，
/// 直链由 `adapter.resolveStream(fid)` 现取。
///
/// 代价是**六项能力静默降级**（库里没有这一行）：续播点、剧集连播、同目录
/// 字幕、逐片播放偏好、片头标记、直链过期自动续播。最后一项由
/// [rememberTransientItem] 补上（见那张表的文档）；其余五项本来就要求
/// 「库里认得这一条」，用户没入库就不该指望它们。
///
/// ## 为什么非视频一律拒绝
///
/// UI 只对视频行给入口，这里是**防御**：别让一个 `cover.jpg` 或一个 `.srt`
/// 变成一次注定失败的取链（会拿一个图片 fid 去打 `play/info`）。判据与
/// 扫描 / 发现共用 [classifyEntry]。
Future<void> playDriveEntry(
  BuildContext context,
  WidgetRef ref, {
  required DriveProvider provider,
  required DriveEntry entry,
  required String dirPath,
}) async {
  if (classifyEntry(entry) != EntryRole.video) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('这不是可播放的视频文件'),
      ),
    );
    return;
  }

  // 目录锚点：与「加入媒体库」那条路**同一份判据**。不传的话，这个文件
  // 在内存里的 `groupKey` 会与它入库后的那一条不同 —— 表现是「直接播完
  // 再去媒体库里找它，下一集/续播对不上」，而它不报任何错。
  final anchors = await loadDirectoryAnchors(ref.read(mediaRepositoryProvider));

  final item = parseTransientMedia(
    entry: entry,
    provider: provider,
    dirPath: dirPath,
    anchors: anchors,
  ).item;

  // 记一份给「直链过期自动续播」用：那条路发生在**另一个引擎**里，只能回
  // 主窗口问，而主窗口查库查不到这一条（它没入库）。见 `desktop_play.dart`
  // 里 `_transientItems` 的文档。
  rememberTransientItem(item);

  // 上面读锚点跨了一次 async gap —— 页面可能已经被关掉了。
  if (!context.mounted) return;
  await playItem(context, ref, item);
}
