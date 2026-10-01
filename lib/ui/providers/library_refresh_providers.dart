import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 播放活动 → 媒体库列表的**刷新信号**。
///
/// ## 为什么需要它
///
/// 「最近播放」那一栏的内容和顺序都由播放记录决定，而播放记录是在**播放中**
/// 写进库的（内置播放页走 `onPositionTick`，独立播放窗口走
/// `onPlaybackProgress`）。这两条路都发生在媒体库之外，不主动说一声的话，
/// 用户看完一部回到媒体库，那一栏还是他离开时的样子 —— 刚看完的那部不在
/// 最前面，而「最近播放」在最常用的路径上看起来就是坏的。
///
/// ## 为什么是「版本号」而不是直接 invalidate
///
/// 它只对外暴露一个自增的整数，由 [workListProvider] 之类的**消费方**自己
/// `watch`。这样这个文件不依赖任何仓储或列表 Provider ——
/// 组合根（`app_providers.dart`）才能反过来引用它。
///
/// 直接让组合根去 `invalidate(workListProvider)` 会形成
/// `app_providers → library_providers → app_providers` 的**循环 import**，
/// 而本项目里组合根是被依赖的一方，方向不能倒过来。
///
/// ## 为什么只在**换条**时推进版本号
///
/// 列表顺序只由「谁最后被播过」决定。同一部片子每 10 秒一次的进度回报
/// 只会把**它自己**的时间戳往后推，不会让它与别的作品换位 —— 所以换条时
/// 推进一次就够了。每次都推的话，用户在主窗口看媒体库、播放窗口在另一块屏
/// 上播片时，海报墙会每 10 秒重建一遍。
class PlaybackLibraryLink extends Notifier<int> {
  @override
  int build() => 0;

  /// 上一次报告的那一条。挂在实例字段上：Provider 重建时它跟着重置，
  /// 而重建本身就意味着下游要全量重取，不需要再记得谁播过。
  String? _lastItemId;

  /// 报告「这一条正在播」。返回是否真的推进了版本号（**换条才算**）。
  bool report(String itemId) {
    if (_lastItemId == itemId) return false;
    _lastItemId = itemId;
    state = state + 1;
    return true;
  }
}

final playbackLibraryLinkProvider =
    NotifierProvider<PlaybackLibraryLink, int>(PlaybackLibraryLink.new);

/// 「本地索引刚被写过」的**刷新信号**。
///
/// ## 为什么需要它
///
/// 现在有**两条**入口会往库里写：全盘扫描与文件夹里的「发现媒体」。而
/// 目录视图的叠加层（`folderTreeProvider` 的「已入库」标记、列表里每个
/// 文件行的「已在库」）读的正是这张表 —— 不主动说一声，用户发现完一部新片，
/// 那一行还写着「加入媒体库」，看起来像什么都没发生。
///
/// ## 为什么是「版本号」而不是让写入方去 invalidate
///
/// 与 [PlaybackLibraryLink] 同一个理由：目录视图那几个 provider 住在
/// `drive_browse_providers.dart`，而扫描控制器住在 `scan_providers.dart`。
/// 让扫描去 `invalidate` 目录视图的 provider，两个文件就互相 import 了
/// （`scan_providers → drive_browse_providers → scan_providers`）—— 而
/// `drive_browse_providers` 还要用 `scan_providers` 的 `buildScanPolicy`。
///
/// 所以信号放在这个**谁都不依赖的叶子文件**里：写入方 `bump()`，
/// 读取方自己 `watch`。方向永远是单向的。
class LibraryWriteSignal extends Notifier<int> {
  @override
  int build() => 0;

  /// 报告「索引库刚被写入过」。
  void bump() => state = state + 1;
}

final libraryWriteSignalProvider =
    NotifierProvider<LibraryWriteSignal, int>(LibraryWriteSignal.new);
