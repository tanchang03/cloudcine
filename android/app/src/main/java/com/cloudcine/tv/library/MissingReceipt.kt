package com.cloudcine.tv.library

/**
 * 播放页留下的一张**回执**：这个文件在网盘上已经没有了。
 *
 * ## 为什么不用 `startActivityForResult` 的返回值
 *
 * `PlayerActivity` 是 `launchMode="singleTask"`（换集要走 `onNewIntent`，见它的
 * 类注释）。而 `singleTask` 目标**不保证**把结果回给调用方 —— 系统在部分路径上
 * 会当场回一个 `RESULT_CANCELED`（调用方的 `onActivityResult` 在**起播那一刻**
 * 就跑完了，而不是用户退出的那一刻）。把「要不要移除死索引」挂在那条协议上，
 * 表现会是「有时问、有时不问」，而且**不报错**。
 *
 * 所以改用进程内的一个槽位：
 *
 *   * 播放页发现 `notFound` ⇒ [put]；
 *   * 媒体库页 `onResume` ⇒ [take]（**消费式**，取走就清空）。
 *
 * `onResume` 是唯一一个「用户真的回到这一页」的可靠信号，与 launchMode 无关。
 *
 * ## 为什么是内存里的一个槽位，不是数据库 / SharedPreferences
 *
 * 它描述的是「刚刚发生在这两个页面之间的一件事」，不是需要跨重启保留的状态。
 * 落盘反而更糟：进程被杀之后重启，用户会收到一个**几天前**的提问。
 */
data class MissingReceipt(
    /** 没了的那一条的 fid。 */
    val fid: String,
    /** 它属于哪家网盘（`quark` / `baidu`）—— 主键 `provider:fileId` 的前半段。 */
    val provider: String,
    /** 播放页拿到的文件名（`EXTRA_NAME`）。可能为空，调用方自己兜底。 */
    val name: String,
    /** 同一部作品的 `group_key`，用来数「还剩几集」。可能为空。 */
    val groupKey: String,
) {
    /** `media_items.id` 的形状（与 `DriveProviders` 的跨端契约一致）。 */
    val itemId: String get() = "$provider:$fid"
}

/**
 * 回执的**唯一**存放处。见 [MissingReceipt] 的类文档。
 *
 * ⛔ [take] 必须是**消费式**的：媒体库页每次 `onResume` 都会调它，不清空的话
 *    用户每进出一次别的页面就会被问一遍同一个文件。
 */
object MissingReceipts {

    @Volatile
    private var pending: MissingReceipt? = null

    /** 播放页发现文件没了 ⇒ 留一张回执（覆盖上一张：只关心最后一次）。 */
    fun put(receipt: MissingReceipt) {
        pending = receipt
    }

    /**
     * 取链又成功了 ⇒ 把回执撤掉。
     *
     * ⛔ 必须有这一步：换集时前一集可能刚报过「文件没了」，不清的话用户回到
     *    媒体库会被问一个**已经能播的**文件要不要移除。
     */
    fun clear() {
        pending = null
    }

    /** 媒体库页 `onResume` 取走回执（取走即清空）。 */
    fun take(): MissingReceipt? {
        val r = pending
        pending = null
        return r
    }

    /** 只在测试里用：把槽位恢复到干净状态，避免用例之间互相污染。 */
    fun resetForTest() {
        pending = null
    }
}
