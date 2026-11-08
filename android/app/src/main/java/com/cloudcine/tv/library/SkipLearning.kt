package com.cloudcine.tv.library

import kotlin.math.abs
import kotlin.math.max

/**
 * 片头还是片尾。
 *
 * 存名字而不是序号（见 `LibrarySchema.skipSamples.kind`）：加一种类型时序号会
 * 整体错位，旧数据会**静默**变成另一种类型。
 *
 * ⛔ 与 PC 端 `lib/domain/services/skip_learning.dart` 的 `SkipKind` 必须同源：
 *    `dbName` 逐字等于那边的 `SkipKind.name`（小写）。两边各写一套拼写，
 *    症状是「PC 学的片尾在电视上被当成片头」—— 而两条路看起来都正常。
 */
enum class SkipKind(val label: String) {
    INTRO("片头"),
    OUTRO("片尾");

    /** 落库用的字符串。⛔ 与 PC 端 `SkipKind.name` 逐字一致。 */
    val dbName: String get() = name.lowercase()

    companion object {
        /**
         * 解析数据库里的字符串。认不出来返回 `null`（＝这条样本作废，
         * 而不是「当成片头」—— 猜错会污染整个聚合）。
         */
        fun parse(raw: String?): SkipKind? =
            entries.firstOrNull { it.dbName == raw }
    }
}

/**
 * 一条**原始落点样本**。
 *
 * ## 它记的是「用户做了什么」，不是「片头在哪儿」
 *
 * 单条样本**不足以**推出片头 —— 用户可能只是随便拖了一下。所以这一层只负责
 * 如实记录，判断交给 [SkipLearning.learn] 的跨集聚合。
 *
 * 时间单位与库里一致：**毫秒**（`skip_samples` 的 `anchor_ms` / `duration_ms`）。
 */
data class SkipSample(
    /** 主键：`itemId#kind#毫秒时间戳`（见 [idFor]）。 */
    val id: String,
    val itemId: String,
    val workKey: String,
    val kind: SkipKind,
    /** 落点。片头 = 从开头跳到的位置；片尾 = 「不想再看」的位置。 */
    val anchorMs: Long,
    /** 这次播放的总时长。 */
    val durationMs: Long,
    /** 负样本（用户撤销 / 回拖作废）。不参与聚合。 */
    val negative: Boolean = false,
    /** 产生这条样本的设备（只用于排查，不参与聚合）。 */
    val device: String = "",
    /** Unix **毫秒**（与库里的 `created_at` 同口径）。 */
    val createdAtMs: Long,
) {
    /**
     * 距末尾的偏移。**片尾聚合用的就是它** ——
     * 各集片长不同（正片 45 分钟、特辑 60 分钟），绝对时间跨集不可比，
     * 而「离结尾还有多久开始是片尾」这个量是稳定的。
     */
    val offsetMs: Long get() = durationMs - anchorMs

    companion object {
        /**
         * 生成主键。
         *
         * ⛔ 用「媒体项 + 类型 + 毫秒时间戳」而不是自增 id：两端各自生成 id 时
         *    不会撞车（备份合并之后仍然唯一），而自增 id 在合并两份库时**必然**
         *    冲突 —— 冲突的表现是「样本被覆盖」，不报错。
         */
        fun idFor(itemId: String, kind: SkipKind, atMs: Long): String =
            "$itemId#${kind.dbName}#$atMs"
    }
}

/**
 * 采集器产出的**有效落点**。
 *
 * 「有效」的定义见 [SkipAnchorCollector]：用户在这个位置**停下来看了一会儿**，
 * 而不是拖过去又拖走。
 */
data class SkipAnchor(
    val anchorMs: Long,
    val durationMs: Long,
    /**
     * 这次播放**是从哪儿开始的**。
     *
     * 判片头必须用它：续播（从上次位置继续）时「0 → 落点」这个区间根本不
     * 成立 —— 用户没看过那段，也就谈不上「跳过」。
     */
    val playStartMs: Long,
) {
    /** 落点距末尾的偏移。判片尾用它（各集片长不同，绝对时间不可比）。 */
    val offsetMs: Long get() = durationMs - anchorMs
}

/** 一次 seek 的观测。 */
data class SeekObservation(
    val fromMs: Long,
    val toMs: Long,
    val durationMs: Long,
    val rate: Double,
)

/**
 * **有效落点采集器**。
 *
 * ## 它解决的问题
 *
 * 「用户在进度条上拖了一次」这个动作**动机是多义的**：跳片头、跳片尾、拖到
 * 中间看剧情、误触、扫剧…… 直接把 `(from → to)` 记下来当样本，学出来的东西
 * 会是一团噪声。
 *
 * 所以中间加一层：**只有「拖过去之后真的停下来看了」的落点才算数**。
 *
 * ## 判据
 *
 * | 条件 | 理由 |
 * |---|---|
 * | `rate == 1.0` | 倍速下「位置」的语义变了（用户在扫剧），锚点与其他集不可比 |
 * | `to - from >= minSeekDelta` | 幅度太小是误触 / 防抖抖动 |
 * | `to > from` | 后退是「回看」，不是「跳过什么」 |
 * | 落点之后连续观看 >= `stableWatch` 且不再 seek | 拖过去瞄一眼就再拖走的，不算 |
 *
 * ⛔ 一个实例对应**一次播放**。换集 / 换清晰度 / 重开流都要 [reset] ——
 *    漏了它的后果是 `pending` 带着上一集的落点，把下一集的锚点算错。
 */
class SkipAnchorCollector(
    private val stableWatchMs: Long = SkipLearning.STABLE_WATCH_MS,
    private val minSeekDeltaMs: Long = SkipLearning.MIN_SEEK_DELTA_MS,
) {
    private var pendingMs: Long? = null
    private var pendingDurationMs: Long? = null
    private var playStartMs: Long = 0L

    private var introEmitted = false
    private var outroEmitted = false

    /** 当前有没有一个待确认的落点。测试与排查用。 */
    val pending: Long? get() = pendingMs

    /** 这次播放是从哪儿开始的（判片头要用）。 */
    val playStart: Long get() = playStartMs

    /**
     * 这次播放**正式开始**时调一次。
     *
     * ⛔ 起播位置就是**第一次**拿到的位置，不是「续播点」—— 用户可能手动拖到
     *    第 5 分钟才开始看，那也不算从头起播。所以这个值只写一次。
     */
    fun notePlayStart(positionMs: Long) {
        if (playStartMs != 0L) return
        playStartMs = positionMs
    }

    /**
     * 用户拖了一次（或按了一次快进）。**只记录待确认的落点，不产出锚点。**
     *
     * 过滤掉的三类见类文档的表格。
     */
    fun noteSeek(obs: SeekObservation) {
        // 任何一次 seek 都先作废上一个待确认落点：用户在那儿没停下来。
        pendingMs = null
        pendingDurationMs = null

        if (obs.rate != 1.0) return
        if (obs.durationMs <= 0L) return
        if (obs.toMs <= obs.fromMs) return
        if (obs.toMs - obs.fromMs < minSeekDeltaMs) return

        pendingMs = obs.toMs
        pendingDurationMs = obs.durationMs
    }

    /**
     * 播放头动了。**片头锚点唯一被确认的地方。**
     *
     * 两个分支：
     *   1. `position < pending` ⇒ 用户**回拖**了 ⇒ 待确认落点作废
     *      （这正是「拖拽点不在片头片尾」里最麻烦的那一类）；
     *   2. `position - pending >= stableWatch` ⇒ 用户在那儿停下来看了 ⇒ 确认。
     *
     * ## ⛔ 这里**不产出片尾锚点**，哪怕落点落在片尾窗口里
     *
     * 「看了 15 秒」不足以说明「这里不是片尾」：用户完全可能拖到片尾前一分钟、
     * 看 20 秒、然后把整集看完 —— 那说明那 60 秒里有内容，不是片尾。而停留
     * 确认是**不可撤回**的（确认完 `pending` 就清了），所以这里一旦产出就没法
     * 再纠正。
     *
     * 片尾走的是另一条更强的信号：[noteEpisodeSwitch]。用户「不想看了」这个
     * 意图在**切下一集**这个动作上表达得比任何 seek 都清楚，而且它是终态 ——
     * 没有「再看一会儿」的可能，也就不需要停留确认。
     */
    fun notePosition(positionMs: Long): SkipAnchor? {
        val pending = pendingMs ?: return null

        if (positionMs < pending) {
            pendingMs = null
            pendingDurationMs = null
            return null
        }
        if (positionMs - pending < stableWatchMs) return null

        val duration = pendingDurationMs ?: return null
        pendingMs = null
        pendingDurationMs = null

        val anchor = SkipAnchor(
            anchorMs = pending,
            durationMs = duration,
            playStartMs = playStartMs,
        )
        if (SkipLearning.classify(anchor) != SkipKind.INTRO) return null
        if (introEmitted) return null
        introEmitted = true
        return anchor
    }

    /**
     * 用户**切到了下一集**（或退出播放 / 关掉窗口）。
     *
     * ## 为什么这是片尾最强、也是唯一的信号
     *
     * 用户「跳过片尾」的动作通常不是「拖到末尾」，而是**从某个位置直接切下一集**
     * ——「我不想看了」这个意图在切集这个动作上表达得比任何 seek 都清楚。
     *
     * ⛔ 它**不需要** [stableWatchMs] 确认：切集是终态，没有「再看一会儿」的
     *    可能。这恰好补上了 [notePosition] 的短板 —— 停留确认**不可撤回**，
     *    而「拖到片尾看完」和「拖到片尾切集」在停留那一刻长得一模一样，
     *    只有等到切集时才分得清。
     *
     * ⛔ 传的是**切集那一刻**的播放头位置，不是「用户之前拖到哪儿」。
     *    语义是「用户不想看最后这一段」，而那一段的起点就是他按下切集时所在的
     *    位置。传拖拽落点会把中间看过的内容也算进片尾。
     */
    fun noteEpisodeSwitch(positionMs: Long, durationMs: Long): SkipAnchor? {
        pendingMs = null
        pendingDurationMs = null
        if (durationMs <= 0L) return null

        val anchor = SkipAnchor(
            anchorMs = positionMs,
            durationMs = durationMs,
            playStartMs = playStartMs,
        )
        if (SkipLearning.classify(anchor) != SkipKind.OUTRO) return null
        if (outroEmitted) return null
        outroEmitted = true
        return anchor
    }

    /**
     * 换集 / 换清晰度 / 重开流。**保留不了任何东西** ——
     * 起播位置也要重记，否则下一集会被当成「从头起播」而其实不是。
     */
    fun reset() {
        pendingMs = null
        pendingDurationMs = null
        playStartMs = 0L
        introEmitted = false
        outroEmitted = false
    }
}

/** 学习出的**片头**：`[0, end]`。 */
data class LearnedIntro(
    /** 片头终点。起点恒为 `0`（片头总在开头）。 */
    val endMs: Long,
    /** 参与聚合的样本数。 */
    val samples: Int,
    /** 中位绝对偏差（MAD）—— 「各集落点有多集中」。越小越可信。 */
    val spreadMs: Long,
)

/** 学习出的**片尾**：只有「距末尾的偏移」一个数。 */
data class LearnedOutro(
    /** 距末尾的偏移。播放时用 `duration - offset` 算落点。 */
    val offsetMs: Long,
    val samples: Int,
    val spreadMs: Long,
)

/** 一次完整的学习结果（片头 + 片尾，各自可能没有）。 */
data class SkipLearningOutcome(
    val intro: LearnedIntro? = null,
    val outro: LearnedOutro? = null,
) {
    /**
     * 写进 `media_works.learned_samples` 的那个数：取两者的**较大值**。
     *
     * 用一个数而不是两个，是因为 UI 上只需要回答「这个结果有多少集撑着」——
     * 而片头与片尾的样本常常就是同一批集（用户既跳片头也跳片尾）。
     */
    val samples: Int get() = max(intro?.samples ?: 0, outro?.samples ?: 0)

    /** 什么都没学出来。 */
    val isEmpty: Boolean get() = intro == null && outro == null
}

/**
 * 「为什么还没学出来」—— 把 [SkipLearning.learn] 的拒绝原因摊开给 UI 看。
 *
 * 以前 `learn()` 返回空结论时，调用方只知道「没学出来」，不知道是样本不够、
 * 落点太散、还是中位数跑出了窗口；用户那边就表现为「看了一集又一集，什么
 * 都没发生」。这一层**不改变任何判定**，只是把判定过程讲清楚。
 */
enum class SkipLearnStatus(val label: String) {
    /** 一条有效正样本都没有。 */
    NO_SAMPLES("暂无有效样本"),
    /** 样本还没攒够 [SkipLearning.MIN_SAMPLES]，但落点集中、中位数在窗口内。 */
    COLLECTING("正在攒样本"),
    /** 落点散布（MAD）超标，即使攒够样本也会被拒。 */
    TOO_SPREAD("落点差异较大"),
    /** 中位数跑出了片头 / 片尾窗口。 */
    OUT_OF_WINDOW("落点超出常见范围"),
    /** 三项全过：[SkipLearning.learn] 已学出正式结论。 */
    LEARNED("已识别"),
}

/** 某一类（片头 / 片尾）的学习进度。**两类各自独立计数**。 */
data class SkipKindProgress(
    val kind: SkipKind,
    /** 参与聚合的正样本条数（与 `learn*` 完全同口径：排除负样本）。 */
    val collected: Int,
    /** 被作废的负样本条数（撤销 / 回拖）。只用于说明，不参与聚合。 */
    val negative: Int,
    /** 攒够正式结论需要多少样本，恒等于 [SkipLearning.MIN_SAMPLES]。 */
    val needed: Int,
    val status: SkipLearnStatus,
    /** 这批落点的 MAD。 */
    val spreadMs: Long,
    /**
     * **低置信候选**：样本不足但落点集中、中位数在窗口内时的那个中位数。
     * 片头 = 终点；片尾 = 距末尾偏移。仅 [status] 为
     * [SkipLearnStatus.COLLECTING] 时非 `null`。
     *
     * ⚠️ 它**不是**正式结论，不会自己生效，要用户在 UI 上点一次确认。
     * 这是设计文档 §八「先提示，再自动」的 P1 阶段：用一次用户裁决替代
     * 「攒够 3 集」，把生效从第 4 集提前到第 1 集，而误跳风险为零 ——
     * 确认之前播放器什么都不会做。
     */
    val suggestionMs: Long?,
) {
    val hasSuggestion: Boolean get() = suggestionMs != null

    /** 还差几条才能自动生效；已经 LEARNED 时为 0。 */
    val remaining: Int get() = if (collected >= needed) 0 else needed - collected
}

/** 一次完整的学习进度（片头 + 片尾）。 */
data class SkipLearningProgress(
    val intro: SkipKindProgress,
    val outro: SkipKindProgress,
) {
    fun of(kind: SkipKind): SkipKindProgress =
        if (kind == SkipKind.INTRO) intro else outro

    val hasSuggestion: Boolean get() = intro.hasSuggestion || outro.hasSuggestion

    /**
     * 把**某一类**的候选打包成可直接交给 `saveLearnedSkip` 的结论。
     * 只取 [kind] 那一半：一次落点只可能是片头或片尾，把另一半也写进去
     * 会把「还没采到样本」的那一类凭空固化成一个结论。
     */
    fun outcomeFor(kind: SkipKind): SkipLearningOutcome {
        val p = of(kind)
        val value = p.suggestionMs ?: return SkipLearningOutcome()
        return SkipLearningOutcome(
            intro = if (kind == SkipKind.INTRO)
                LearnedIntro(endMs = value, samples = p.collected, spreadMs = p.spreadMs)
            else null,
            outro = if (kind == SkipKind.OUTRO)
                LearnedOutro(offsetMs = value, samples = p.collected, spreadMs = p.spreadMs)
            else null,
        )
    }
}

/**
 * 「跳过片头 / 片尾」的学习规则。
 *
 * ## ⛔ 与 PC 端必须逐字同源
 *
 * 这份是 `lib/domain/services/skip_learning.dart` 的 Kotlin 移植，**阈值一个都
 * 不能改**。两端各调一套参数的症状是「同一部剧，PC 学得出片头、电视学不出来」
 * —— 而两边都「看起来对」，因为没有任何地方会报错。
 *
 * 要改阈值就两边一起改；`SkipLearningParityTest`（Kotlin）与
 * `skip_learning_test.dart`（Dart）用同一批输入钉住这些数字。
 *
 * ## 为什么用中位数 + MAD，而不是均值 + 标准差
 *
 * 拖错一次就产生一个离群点：均值会被拽偏，标准差会被拉爆（一个 5 分钟的离群
 * 点就能让「12 集都很一致」的片头看起来完全不可信）。中位数与中位绝对偏差
 * （MAD）对离群点**免疫**。
 *
 * ## 认不出来就什么都不做
 *
 * 每一条门槛不满足时都返回 `null`，而不是「取一个近似值」。
 * **宁可不生效，也不勉强生效** —— 用户手动拖一次的成本，远低于被自动跳到
 * 错误位置的成本（那是不可逆的）。
 */
object SkipLearning {
    // ------------------------------------------------------------------
    // 采集侧阈值
    // ------------------------------------------------------------------

    /**
     * 落点之后要连续观看多久才算「停下来了」。
     *
     * ⚠️ **这是最需要真机校准的一个参数**。太短挡不住探索性拖拽；太长会让
     * 「跳完片头紧接着又跳片尾」的连续操作互相干扰。15 秒是估计值。
     */
    const val STABLE_WATCH_MS: Long = 15_000L

    /** 小于这个幅度的 seek 不记（防抖、防误触）。 */
    const val MIN_SEEK_DELTA_MS: Long = 3_000L

    // ------------------------------------------------------------------
    // 分类窗口
    // ------------------------------------------------------------------

    /** 片头落点的下界。比这更短的「片头」跳过去毫无意义，只是让画面抖一下。 */
    const val INTRO_MIN_ANCHOR_MS: Long = 15_000L

    /** 片头落点的上界。**再晚就不是片头了。** */
    const val INTRO_MAX_ANCHOR_MS: Long = 3 * 60_000L

    /**
     * 只有起播位置早于这个值，才认为这一集是**从头起播**的。
     *
     * 续播（从上次位置继续）不产生片头锚点：用户没看过开头，
     * 「0 → 落点」这个区间根本不成立。
     */
    const val FROM_START_MAX_MS: Long = 30_000L

    /** 片尾偏移的下界（`duration - anchor`）。 */
    const val OUTRO_MIN_OFFSET_MS: Long = 10_000L

    /** 片尾偏移的上界。距末尾超过 5 分钟的落点**不是片尾**，是「跳到中后段」。 */
    const val OUTRO_MAX_OFFSET_MS: Long = 5 * 60_000L

    /**
     * 短于这个时长的片子**不学习**。
     *
     * 片头窗口（`0~3min`）与片尾窗口（`duration-5min ~ duration-10s`）在
     * `duration < 8min` 时会重叠，判定不可靠。宁可挡掉短视频，也不要在两个
     * 窗口之间猜。
     */
    const val MIN_DURATION_MS: Long = 8 * 60_000L

    // ------------------------------------------------------------------
    // 聚合侧阈值
    // ------------------------------------------------------------------

    /** 最少样本数。3 集是「不是偶然」的最低门槛。 */
    const val MIN_SAMPLES: Int = 3

    /** 片头落点的最大中位绝对偏差。 */
    const val INTRO_MAX_SPREAD_MS: Long = 8_000L

    /**
     * 片尾偏移的最大中位绝对偏差。
     *
     * 比片头松 2 秒：片尾的落点比片头随意（用户可能看到字幕开始才切，也可能
     * 提前几秒切），这个量天生更散。
     */
    const val OUTRO_MAX_SPREAD_MS: Long = 10_000L

    // ------------------------------------------------------------------
    // 分类
    // ------------------------------------------------------------------

    /**
     * 把一个有效落点分到片头 / 片尾；都不在窗口内返回 `null`。
     *
     * ⛔ **先判片尾再判片头**。两个窗口在短片上会重叠，而 [MIN_DURATION_MS]
     *    已经挡掉了那种情况 —— 所以这里的顺序只影响「恰好同时满足」的边角
     *    情形，而片尾的窗口更窄（10s~5min 距末尾），更可信。
     */
    fun classify(anchor: SkipAnchor): SkipKind? {
        val duration = anchor.durationMs
        if (duration < MIN_DURATION_MS) return null

        val offset = duration - anchor.anchorMs
        if (offset >= OUTRO_MIN_OFFSET_MS && offset <= OUTRO_MAX_OFFSET_MS) {
            return SkipKind.OUTRO
        }

        // 片头必须**从头起播**：续播时用户没看过开头。
        if (anchor.playStartMs > FROM_START_MAX_MS) return null
        if (anchor.anchorMs < INTRO_MIN_ANCHOR_MS) return null
        if (anchor.anchorMs > INTRO_MAX_ANCHOR_MS) return null
        return SkipKind.INTRO
    }

    // ------------------------------------------------------------------
    // 聚合
    // ------------------------------------------------------------------

    /** 一批样本 → 学习结果。 */
    fun learn(samples: List<SkipSample>): SkipLearningOutcome =
        SkipLearningOutcome(
            intro = learnIntro(samples),
            outro = learnOutro(samples),
        )

    /**
     * 一批样本 → **学习进度**（含低置信候选与「为什么还没学出来」）。
     *
     * 与 [learn] 共用同一份判定（[cluster]），所以「进度说已识别」与
     * 「learn 真的学出结论」永远一致，不会出现两套标准各自漂移。
     * 它**不改动** [learn] 的任何门槛：候选只是把「还差几集」这段等待
     * 摊开给用户看，并提供一次「要不要提前生效」的裁决机会。
     */
    fun progress(samples: List<SkipSample>): SkipLearningProgress =
        SkipLearningProgress(
            intro = kindProgress(
                samples, SkipKind.INTRO,
                INTRO_MIN_ANCHOR_MS, INTRO_MAX_ANCHOR_MS, INTRO_MAX_SPREAD_MS,
            ),
            outro = kindProgress(
                samples, SkipKind.OUTRO,
                OUTRO_MIN_OFFSET_MS, OUTRO_MAX_OFFSET_MS, OUTRO_MAX_SPREAD_MS,
            ),
        )

    /** 学出片头区间（`[0, end]`）。认不出来返回 `null`。 */
    fun learnIntro(samples: List<SkipSample>): LearnedIntro? {
        val c = cluster(
            positiveValues(samples, SkipKind.INTRO, intro = true),
            INTRO_MIN_ANCHOR_MS, INTRO_MAX_ANCHOR_MS,
        )
        if (c.count < MIN_SAMPLES) return null
        if (c.spreadMs > INTRO_MAX_SPREAD_MS) return null
        if (!c.withinWindow) return null
        return LearnedIntro(endMs = c.center!!, samples = c.count, spreadMs = c.spreadMs)
    }

    /** 学出片尾偏移。认不出来返回 `null`。 */
    fun learnOutro(samples: List<SkipSample>): LearnedOutro? {
        // ⛔ 用 `offset`（距末尾）而不是 `anchor`（绝对时间）：
        //    各集片长不同，绝对时间跨集不可比。
        val c = cluster(
            positiveValues(samples, SkipKind.OUTRO, intro = false),
            OUTRO_MIN_OFFSET_MS, OUTRO_MAX_OFFSET_MS,
        )
        if (c.count < MIN_SAMPLES) return null
        if (c.spreadMs > OUTRO_MAX_SPREAD_MS) return null
        if (!c.withinWindow) return null
        return LearnedOutro(offsetMs = c.center!!, samples = c.count, spreadMs = c.spreadMs)
    }

    /** 取出某一类、未被作废的样本值。片头取 `anchorMs`，片尾取 `offsetMs`。 */
    private fun positiveValues(
        samples: List<SkipSample>,
        kind: SkipKind,
        intro: Boolean,
    ): List<Long> = samples
        .filter { it.kind == kind && !it.negative }
        .map { if (intro) it.anchorMs else it.offsetMs }

    private fun kindProgress(
        samples: List<SkipSample>,
        kind: SkipKind,
        lowerMs: Long,
        upperMs: Long,
        maxSpreadMs: Long,
    ): SkipKindProgress {
        val c = cluster(
            positiveValues(samples, kind, intro = kind == SkipKind.INTRO),
            lowerMs, upperMs,
        )
        val negative = samples.count { it.kind == kind && it.negative }
        val status = statusOf(c, maxSpreadMs)
        // 只有「还在攒样本、且这批落点本身可信」才给候选。
        // 已经能正式学出结论（LEARNED）时不给 —— 那条路走 learn()，
        // 不需要用户再点一次；样本数为 0 / 散布超标 / 中位数出窗也不给。
        val suggestionMs = if (status == SkipLearnStatus.COLLECTING) c.center else null
        return SkipKindProgress(
            kind = kind,
            collected = c.count,
            negative = negative,
            needed = MIN_SAMPLES,
            status = status,
            spreadMs = c.spreadMs,
            suggestionMs = suggestionMs,
        )
    }

    private fun statusOf(c: Cluster, maxSpreadMs: Long): SkipLearnStatus = when {
        c.count == 0 -> SkipLearnStatus.NO_SAMPLES
        c.spreadMs > maxSpreadMs -> SkipLearnStatus.TOO_SPREAD
        !c.withinWindow -> SkipLearnStatus.OUT_OF_WINDOW
        c.count >= MIN_SAMPLES -> SkipLearnStatus.LEARNED
        else -> SkipLearnStatus.COLLECTING
    }

    /**
     * 中位数。空列表返回 `null`。
     *
     * 偶数个取中间两个的**平均**（而不是任取一个）：取平均不会偏向任何一侧，
     * 而「取较小的那个」在样本数为 4 时会系统性地偏小。
     *
     * ⛔ 整数除法与 Dart 的 `~/` 同为**向零截断**。样本都是正数，两者一致。
     */
    fun median(values: List<Long>): Long? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        val mid = sorted.size / 2
        if (sorted.size % 2 == 1) return sorted[mid]
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /**
     * 中位绝对偏差（MAD）：每个值与 [center] 的距离，再取中位数。
     *
     * 它是「这批落点有多集中」的直接度量 —— 比标准差抗离群点。
     * 空列表返回 `0`（调用方已经先过 [MIN_SAMPLES]）。
     */
    fun medianAbsoluteDeviation(values: List<Long>, center: Long): Long {
        if (values.isEmpty()) return 0L
        val deviations = values.map { abs(it - center) }
        return median(deviations) ?: 0L
    }

    /** [cluster] 的结果：`learn*` 与 [progress] 共用，免得两处各写一遍、日后漂移。 */
    private data class Cluster(
        val count: Int,
        val center: Long?,
        val spreadMs: Long,
        val withinWindow: Boolean,
    )

    /** 一批落点 → 中位数 / MAD / 是否落在窗口内。空列表时 `center` 为 `null`。 */
    private fun cluster(values: List<Long>, lowerMs: Long, upperMs: Long): Cluster {
        val center = median(values) ?: return Cluster(0, null, 0L, false)
        val spread = medianAbsoluteDeviation(values, center)
        return Cluster(values.size, center, spread, center >= lowerMs && center <= upperMs)
    }
}
