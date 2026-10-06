package com.cloudcine.tv.library

/**
 * 同步该做什么 —— **纯决策，不碰 IO**。
 *
 * 单独抽出来是为了能被单测覆盖：这一步是「新机器会不会把网盘上的好备份
 * 冲成空库」的唯一防线，而它的错法全都是**静默**的（两边都显示「同步成功」）。
 *
 * ⛔ 分支顺序与 PC 端 `LibraryBackupService.sync()` **一字不差**，包括
 * 「先判空库、再判冲突、最后比时间」这个次序。把 `conflictsWith` 提到空库
 * 判断前面，新机器（空库）第一次同步就会看到「冲突」提示 —— 而它本来
 * 什么都不该问，直接拉下来就对了。
 */
object SyncDecision {

    /**
     * 该执行的动作。文案与 PC 端 `SyncResult` 里的 message 对齐，
     * 这样电视和电脑上的提示是同一句话。
     */
    enum class Action(val message: String) {
        /** 网盘上还没有任何备份 → 上传本地。 */
        uploadFirst("首次上传到远程"),

        /** 本地是空库 → 无条件让远程赢（新机器的正路）。 */
        restoreLocalEmpty("本地还没有媒体库，已从远程恢复"),

        /** 远程是空备份 → 绝不拿它覆盖本地。 */
        uploadRemoteEmpty("远程备份是空库，已用本地覆盖"),

        /** 两台设备在相近时间都做了备份。 */
        conflict("两台设备在相近时间都做了备份，需要手动选择"),

        /** 本地比远程新 → 上传覆盖。 */
        uploadLocalNewer("本地比远程新，已上传覆盖远程"),

        /** 远程比本地新 → 下载恢复。 */
        restoreRemoteNewer("远程比本地新，已下载恢复本地"),

        /** 时间戳相同 → 无操作。 */
        unchanged("本地与远程时间戳相同");

        /** 这个动作要不要把远程的字节拉下来并覆盖本地库。 */
        val restores: Boolean
            get() = this == restoreLocalEmpty || this == restoreRemoteNewer

        /** 这个动作要不要把本地打包上传。 */
        val uploads: Boolean
            get() = this == uploadFirst || this == uploadRemoteEmpty || this == uploadLocalNewer
    }

    /**
     * @param local 本地清单（由 `exportBackup` 生成，**只取清单**）
     * @param remote 网盘上最新的那份备份的清单；**网盘上没有任何备份时为 `null`**
     */
    fun decide(local: BackupManifest, remote: BackupManifest?): Action {
        // 1. 远程没有备份 → 首次上传
        if (remote == null) return Action.uploadFirst

        // 2. 本地是空库 → 无条件让远程赢。
        //    ⛔ 这一条必须在「比时间」之前：空库的 libraryModifiedAt 是 null，
        //    而 effectiveModifiedAt 会退化成 createdAt（= 现在），
        //    于是「比时间」永远判本地更新 ⇒ 新机器会把网盘冲成空库。
        if (!local.hasLibraryContent) return Action.restoreLocalEmpty

        // 3. 远程是空备份 → 镜像情形（别人从新机器推过一次）→ 用本地覆盖。
        if (!remote.hasLibraryContent) return Action.uploadRemoteEmpty

        // 4. 冲突：不同设备且时间差 < 60 秒。交给用户，不自动选。
        if (local.conflictsWith(remote)) return Action.conflict

        // 5. 比时间戳（effectiveModifiedAt，两边都非空退化路径了）
        val l = local.effectiveModifiedAt
        val r = remote.effectiveModifiedAt
        return when {
            l > r -> Action.uploadLocalNewer
            r > l -> Action.restoreRemoteNewer
            else -> Action.unchanged
        }
    }
}
