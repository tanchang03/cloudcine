import '../adapters/media_repository.dart';
import '../entities/media_item.dart';

/// 追剧：**「这一集我看过没有」** 的唯一判据（2026-10-07）。
///
/// ## 为什么要有这个文件
///
/// 「已读」原先只有一个判据：`media_items.max_position_ms` 非空。而那一列只在
/// **进度上报**时写，进度上报又只在**整十秒边界**触发（`ProgressThrottle`）
/// ⇒ **点开一集看一眼（不到 10 秒）等于什么都没发生**。
///
/// 2026-10-07 真实现场：用户点开 `Z 遮 天 E184` 播了 **3 秒**、`E183` 播了
/// **2 秒**就关窗（日志里一次进度回报都没有），库里 `max_position_ms` /
/// `last_played_at` / `resume_position_ms` 三列全是 NULL ⇒ 行上的 `■ NEW`
/// 不消失、海报上「更新 2」也不动。用户的口径很明确：
///
/// > 「**无论播放了多长时间，只要点击了，就去掉 new 标记**」
///
/// ## 判据 = 两条记录取或
///
///   - `max_position_ms` 非空 —— 「**看到哪儿了**」。看了 10 秒以上就一定有值；
///   - `last_played_at` 非空 —— 「**这一条被播过**」，即已读回执。起播那一刻
///     `playItem` 就会写它（`MediaRepository.markPlayed`）。
///
/// ## ⛔ 起播时**不**写 `max_position_ms`
///
/// 那一列是「位置」。写一个假的极小值（1 毫秒）有两个后果：
///
///   1. 每一行**点过**的条目都会画出一条 0% 的进度槽 —— `_WatchedBar` 的槽
///      是**不透明**的（`panel2`），看得见；
///   2. 项目里已经把「播了但不足 1 秒」定义为「从没播过」
///      （见 `WorkDetail.maxPositions` 的注释），自己打自己的脸。
///
/// 已读回执归 `last_played_at`，位置归 `max_position_ms`，两列各司其职。
///
/// ⚠️ **Android 端目前只看 `maxPositionMs`**（`Work.isNewSinceFollow`）。
///    要两端行为一致的话那边也要补这一条（`LibraryItem` 同样带
///    `lastPlayedAt`，无需改表）。
bool isItemWatched(MediaItem item, Map<String, Duration> maxPositions) =>
    maxPositions[item.id] != null || item.lastPlayedAt != null;

/// 重算一部作品的「还没看过的新集数」，并在**变小**时写回 `new_item_count`。
///
/// 返回写回后的计数（没写回时返回库里原来那个）。
///
/// [workKey] 可以是**别名 key**（被归一折叠掉的那一行）：函数会自己顺着
/// `mergedInto` 走到目标作品。调用方手里通常只有一个 `MediaItem`，而它的
/// `groupKey` 是**文件名解析**出来的归组键 —— 刮削归一之后那就不再是作品的
/// key 了（2026-10-07 现场：`media_items.group_key = 'z遮天'`，而
/// `media_works.key = 'shroudingtheheavens'`，别名行 `.merged_into` 指向它）。
/// 直接拿 `groupKey` 去查会落在别名行上，而那行的 `followed` 是 false
/// ⇒ 提前 return ⇒ **角标永远降不下来，且不报错**。
///
/// ## 为什么需要它
///
/// `new_item_count` 由 `applyFollowCheck` **增量累加**（语义 = 「有 N 集我
/// 还不知道的新东西」）。用户点开一集之后这个数字该跟着降 —— 否则海报上
/// 写着「更新 2」、而他刚看完其中一集，角标却一动不动（2026-10-07 现场原话：
/// 「媒体库列表中的『更新 2』标记也没有相应的调整」）。
///
/// ## ⛔ 只下调，绝不上调
///
/// 上调会让**打开一次详情页就可能凭空冒出角标**：这里的口径是
/// 「追剧以来新增 ∧ 没看过」，它比 `applyFollowCheck` 的累加口径更宽
/// （例如「追剧之后、但被全盘扫描而不是追更检查发现的集」）。那些集该不该
/// 让角标亮，是 `applyFollowCheck` 该决定的事，不该由「用户打开了详情页」
/// 顺手决定。
///
/// 下调则永远是安全的：用户确实看过的那几集，无论被谁发现的，都不该再算未读。
///
/// ⛔ 与详情页 `workDetailProvider` 里那段是**同一套判据**（`isNewSinceFollow`
/// + [isItemWatched]，连「跟着 `mergedInto` 走」这一步也一样）。两处口径必须
/// 一起改 —— 一边改了另一边没改，表现是「列表里一条 NEW 都没有了、海报上还
/// 挂着 2」。
Future<int> syncFollowReadCount(MediaRepository repo, String workKey) async {
  var found = await repo.workByKey(workKey);
  if (found == null) return 0;

  // 别名行要**跟着走到目标**：角标挂在目标作品上（口径与 `workDetailProvider`
  // 一致）。⛔ 只走一跳就够 —— 折叠不允许成链（`mergeWorksInto` 会拒绝把
  // 别名当目标），这一点由仓储层保证。
  final target = found.mergedInto;
  if (target != null) {
    final resolved = await repo.workByKey(target);
    if (resolved != null) found = resolved;
  }

  // 提成 `final`：`found` 是可变的，Dart 不对它做类型提升，闭包里用不了。
  final work = found;
  if (!work.followed) return work.newItemCount;

  final items = await repo.itemsForWork(work.key);
  if (items.isEmpty) return work.newItemCount;

  final maxPositions = await repo.maxPositions(
    items.map((i) => i.id).toList(growable: false),
  );
  final remaining = items
      .where((i) => work.isNewSinceFollow(
            firstSeenAt: i.firstSeenAt,
            played: isItemWatched(i, maxPositions),
          ))
      .length;

  if (remaining >= work.newItemCount) return work.newItemCount;

  await repo.setFollowNewItemCount(work.key, remaining);
  return remaining;
}
