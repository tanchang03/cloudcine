package com.cloudcine.tv.library

/**
 * 启动时那句「网盘上有更新的媒体库备份，要不要同步」的**判据** ——
 * 纯函数，不碰 IO，可单测。
 *
 * ## 为什么只挑一半的动作来问
 *
 * 启动探测拿到的是 [SyncDecision] 的七个动作之一，而它们**不是**都值得弹窗：
 *
 * | 动作 | 弹不弹 | 为什么 |
 * |---|---|---|
 * | [SyncDecision.Action.restoreRemoteNewer] | **弹** | 用户要的就是这一条：网盘上有更新的备份 |
 * | [SyncDecision.Action.restoreLocalEmpty] | **弹** | 新机器 / 刚清空过 —— 不提示的话用户只能自己去菜单里翻 |
 * | [SyncDecision.Action.uploadLocalNewer] | 不弹 | 本地更新是**常态**（看一集就变了）。每次启动都问「要不要上传」＝每次启动都烦一次 |
 * | [SyncDecision.Action.uploadFirst] | 不弹 | 网盘上还没有备份。这是「还没开始用这个功能」，不是「有更新的备份」 |
 * | [SyncDecision.Action.uploadRemoteEmpty] | 不弹 | 同上：要推的是**本地**，不是拉 |
 * | [SyncDecision.Action.conflict] | 不弹 | 两台设备同时改过，选哪边要看得见两边的库 —— 一个两行的弹窗承担不了这个决定 |
 * | [SyncDecision.Action.unchanged] | 不弹 | 没事发生 |
 *
 * ⛔ 只弹「会**改本地库**」的两个（`restores`）。剩下五个里，有三个要改的是
 *    **网盘**，两个什么都不做 —— 把它们也弹出来，用户学到的会是
 *    「启动弹窗一律按取消」，于是真正该看的那一次也被划掉了。
 *
 * ⛔ 用**穷举的 `when`**（不是 `action.restores`）：以后往 [SyncDecision.Action]
 *    里加第八个动作时，这里会编译不过，逼着做一次「它要不要在启动时问用户」的
 *    决定。这正是这个类存在的意义 —— 漏掉一次判断的后果是静默的
 *    （不弹 = 用户根本不知道有这回事）。
 */
object StartupSync {

    /**
     * 「本次启动已经探测过网盘备份」。
     *
     * ## ⛔ 为什么这个状态不能放在 LibraryActivity 里
     *
     * 本工程每个页面是一个独立 Activity，**从「文件列表」返回媒体库会重建
     * LibraryActivity** —— 状态挂在它身上（不管实例字段还是进程级静态字段），
     * 都会变成「来回切一次弹一次」。
     *
     * 而「每次启动 App」的真正信号是 [com.cloudcine.tv.MainActivity]：它是
     * LAUNCHER 入口，且自己 `finish()` 掉 —— 从电视桌面点一次图标就一定新建
     * 一次它。所以零点在那边（[beginLaunch]），媒体库页只负责置位（[markProbed]）。
     */
    @Volatile
    var probedThisLaunch = false
        private set

    /** 「本次启动」的零点 —— 由 `MainActivity.onCreate` 调。 */
    fun beginLaunch() {
        probedThisLaunch = false
    }

    /**
     * 标记「这次启动已经探测过了」。
     *
     * ⛔ 在探测**发起时**置位，不等它跑完：探测要走网络（列目录 + 读 64 KiB），
     *    慢的时候用户可能已经点进「文件列表」又退回来 —— 那时重建出来的
     *    LibraryActivity 会**再发一次**探测。置位放在发起处，这种事就不会发生，
     *    而且探测失败也不重试（启动路径上的网络失败不值得当场再试一遍）。
     */
    fun markProbed() {
        probedThisLaunch = true
    }

    /** 这个动作要不要在启动时**问用户**（而不是直接做 / 直接不做）。 */
    fun shouldPrompt(action: SyncDecision.Action): Boolean = when (action) {
        SyncDecision.Action.restoreRemoteNewer,
        SyncDecision.Action.restoreLocalEmpty,
        -> true

        SyncDecision.Action.uploadFirst,
        SyncDecision.Action.uploadRemoteEmpty,
        SyncDecision.Action.uploadLocalNewer,
        SyncDecision.Action.conflict,
        SyncDecision.Action.unchanged,
        -> false
    }
}
