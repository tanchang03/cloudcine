package com.cloudcine.tv

import android.content.Context
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink

/**
 * 播放器的「音效」—— **播放端对输出的处理方式**。
 *
 * ## ⛔ 与「音轨」是两件完全不同的事，别合并
 *
 *   * **音轨**（`PlayerActivity` 里 `ROW_AUDIO` 那一行）是**片源里封着的流**：
 *     一部 MKV 里可以同时封着国语 / 粤语 / 英语几条，能切几条完全由发布组
 *     决定，换一集就换一批。菜单标签是**「音轨」**。
 *   * **音效**（本文件）与片源封了什么无关 —— 同一部片子谁都能选立体声。
 *     菜单标签是**「音效」**。
 *
 * ⛔ 这两个名字只差一个字、在 OSD 里还挨着，所以**标签不能写错**。
 *    2026-10-06 之前 Android 端把音轨那一行标成了「音效」，用户看到菜单里
 *    写着「韩语 · 立体声 · 杜比+」的直接反馈就是「音效感觉像是音轨，
 *    找不到音轨在哪」—— 而 PC 端的 `player_audio_effect.dart` 里早就写着
 *    「合并后的第一个后果是用户会以为『音效』里那一列就是能选的音轨」，
 *    两边对照着看是同一个坑。
 *
 * ## 为什么只有两档（而不是像夸克那样有 EQ / 人声增强 / 虚拟环绕）
 *
 * 那几样都要**音频 DSP 滤镜**。这边不是「没做」，而是手头唯一现成的混音器
 * `ChannelMixingAudioProcessor` 只做**声道重映射**，没有 EQ 那一套。
 * 列一个点不动的档位等于给用户埋一个「功能没做」的印象 —— 所以菜单里
 * **只列真做得到的**。PC 端同一条约定（见 `PlayerAudioEffect` 的类文档）。
 */
enum class AudioEffect(
    /** 存进 `AppPrefs` 的稳定字符串。**改它等于让老用户的设置失效**。 */
    val id: String,
    /** OSD 里的名字。 */
    val label: String,
    /** 切换时那句说明 —— 必须写清「什么时候它才有区别」。 */
    val detail: String,
) {
    /**
     * 跟随片源：**不做任何处理**，多声道片源交给输出设备自己去下混。默认。
     *
     * 这一档必须与「没装音效功能之前」**逐位一致**：装进去的是单位矩阵，
     * `ChannelMixingAudioProcessor` 会因此判定自己不活跃、被整条管线跳过
     * （见 [AudioMix.matrixFor]）。
     */
    follow("follow", "跟随片源", "按输出设备的能力自动下混"),

    /**
     * 强制立体声：多声道片源也下混成 2.0。
     *
     * ⚠️ **只在音频被解码成 PCM 时才有区别**。若片源是 AC-3 / DTS 且这台设备
     * 走了直通（HDMI 功放），码流根本没经过解码器，下混无从谈起 —— 这一档
     * 就成了「点了没反应」。这是**已知限制**，理由与「为什么不顺手修掉」见
     * [AudioEffectRenderersFactory] 的类文档。
     */
    stereo("stereo", "强制立体声", "多声道片源也下混成 2.0"),
    ;

    companion object {
        val DEFAULT = follow

        /** 菜单里的顺序。 */
        val ALL: List<AudioEffect> = entries.toList()

        /**
         * 从 `AppPrefs` 读出来的字符串还原。
         *
         * ⛔ **任何读不懂的值都退回默认**，不抛异常：偏好是用户能手动改的
         *    （也能被旧版本写坏），为一个字符串把播放器拦在启动之前不值得。
         */
        fun parse(raw: String?): AudioEffect =
            entries.firstOrNull { it.id == raw } ?: DEFAULT
    }
}

/**
 * 「音效」→ `ChannelMixingAudioProcessor` 矩阵的**唯一**映射表。
 *
 * ## ⛔ 为什么必须给**每一个**输入声道数都注册矩阵
 *
 * `ChannelMixingAudioProcessor.onConfigure()` 在**找不到对应输入声道数的矩阵**时
 * 是**抛 `UnhandledAudioFormatException`**，不是「原样透传」。
 * 2026-10-06 读 media3 1.5.1 的字节码确认过：那一段就是
 * `ldc "No mixing matrix for input channel count"` + `athrow`。
 *
 * 而 `AudioProcessingPipeline.configure()` 会把它原样抛给 `DefaultAudioSink`，
 * 再变成 `AudioSink.ConfigurationException` ⇒ **音频渲染器起不来 ⇒ 整部片没声音**。
 * 所以 [matrixFor] 对**任何**输入声道数都必须返回一个矩阵，且对未知声道数
 * 一律返回**单位矩阵**（= 透传，不会把声音弄坏）。
 *
 * ## 声道顺序
 *
 * 系数表按 media3 的约定排：`CHANNEL_OUT_*` 的顺序，即
 *   1 → FC；2 → FL,FR；4 → FL,FR,BL,BR；
 *   6 → FL,FR,FC,LFE,BL,BR；8 → FL,FR,FC,LFE,BL,BR,SL,SR。
 *
 * 下标 = `输入声道 × 输出声道数 + 输出声道`（`ChannelMixingMatrix.getMixingCoefficient`
 * 就是这个口径，[AudioMixTest] 把这条钉住了 —— 它一旦理解错，
 * 下混出来的不是「左右声道」而是把中置混进了环绕里，而且**不报错**）。
 */
object AudioMix {

    /**
     * 会注册矩阵的声道数上限。
     *
     * ⛔ 定成 16 而不是 8，纯粹是**兜底**：`DefaultAudioSink` 自己会把
     *    `channelCount > 8` 的格式判成不支持，但那条判断不在我们能保证的
     *    范围内（它可能随版本变），而漏注册的后果是**没声音**。
     *    多注册几个单位矩阵的代价是几百字节。
     */
    const val MAX_INPUT_CHANNELS = 16

    /**
     * 中置 / 环绕声道的下混增益：`1/√2` ≈ 0.7071（-3 dB）。
     *
     * ⛔ 不能用 1.0：中置与环绕和左右主声道是**相关信号**，直接按 1.0 相加会
     *    过载削顶 —— 症状是「一到大场面就破音」，而没人会想到是下混系数。
     *    0.7071 是 ITU-R BS.775 给的下混系数。
     */
    private const val SURROUND_GAIN = 0.7071f

    /**
     * 某个音效在 [inputChannels] 声道输入下该用的矩阵。**纯函数、无副作用。**
     *
     * @return **单位矩阵** ⇒ `ChannelMixingAudioProcessor` 判定自己不活跃，
     *   被 `AudioProcessingPipeline` 整条跳过，于是行为与「没装它」逐位一致。
     */
    fun matrixFor(effect: AudioEffect, inputChannels: Int): ChannelMixingMatrix {
        val identity = identity(inputChannels)
        if (effect != AudioEffect.stereo) return identity
        // 已经是 2.0 或更少：没有可下混的东西。
        // ⚠️ 单声道也返回单位矩阵、不「补成 2.0」—— 那是上混，不是这一档的语义，
        //    而且输出设备本来就会把单声道铺到两个扬声器上。
        if (inputChannels <= 2) return identity
        return when (inputChannels) {
            4 -> quadToStereo()
            6 -> fiveOneToStereo()
            8 -> sevenOneToStereo()
            // 3 / 5 / 7 声道在 Android 里**没有标准布局**（`CHANNEL_OUT_*` 只定义了
            // 1 / 2 / 4 / 6 / 8）。宁可原样透传也不猜一个下混 —— 猜错的代价是
            // 「有些片子声音怪怪的」，而排查时没人会想到是这里。
            else -> identity
        }
    }

    /**
     * 单位矩阵：每个输入声道原样进同一个输出声道。
     *
     * 矩阵**必须是方形**（输入声道数 == 输出声道数）：`ChannelMixingMatrix`
     * 的 `isIdentity()` 只在方形且对角线为 1 时成立，而
     * `ChannelMixingAudioProcessor.onConfigure()` 正是靠它决定「透传」。
     */
    fun identity(channels: Int): ChannelMixingMatrix {
        val n = channels.coerceIn(1, MAX_INPUT_CHANNELS)
        val c = FloatArray(n * n)
        for (i in 0 until n) c[i * n + i] = 1f
        return ChannelMixingMatrix(n, n, c)
    }

    /**
     * 按「(输入声道, 输出声道) → 增益」造矩阵。
     *
     * ⛔ 下标口径**只在这一个地方出现**：`系数[输入声道 × 输出声道数 + 输出声道]`。
     *    这是 `ChannelMixingMatrix.getMixingCoefficient` 的字节码口径
     *    （`coefficients[arg1 * outputChannelCount + arg2]`，2026-10-06 核对）。
     *    [AudioMixTest] 把正反两个方向都断言了 —— 这里理解反了，下混出来的
     *    不是「左右声道」而是把中置混进了环绕里，而且**不报错**。
     */
    private fun matrix(
        inputChannels: Int,
        outputChannels: Int,
        gains: Map<Pair<Int, Int>, Float>,
    ): ChannelMixingMatrix {
        val c = FloatArray(inputChannels * outputChannels)
        for ((pair, g) in gains) c[pair.first * outputChannels + pair.second] = g
        return ChannelMixingMatrix(inputChannels, outputChannels, c)
    }

    /**
     * 四声道（FL,FR,BL,BR）→ 2.0。
     *
     * ```
     * L = FL + 0.7071·BL
     * R = FR + 0.7071·BR
     * ```
     */
    private fun quadToStereo(): ChannelMixingMatrix = matrix(
        4, 2, mapOf(
            0 to 0 to 1f,                 // FL → L
            2 to 0 to SURROUND_GAIN,      // BL → L
            1 to 1 to 1f,                 // FR → R
            3 to 1 to SURROUND_GAIN,      // BR → R
        ),
    )

    /**
     * 5.1（FL,FR,FC,LFE,BL,BR）→ 2.0。
     *
     * ```
     * L = FL + 0.7071·FC + 0.7071·BL
     * R = FR + 0.7071·FC + 0.7071·BR
     * ```
     *
     * ⛔ **LFE 不参与**：它本身就是 +10 dB 电平的独立低频声道，直接加进来必然
     *    削顶；主流播放器的立体声下混也都不含它。
     */
    private fun fiveOneToStereo(): ChannelMixingMatrix = matrix(
        6, 2, mapOf(
            0 to 0 to 1f,                 // FL → L
            2 to 0 to SURROUND_GAIN,      // FC → L
            4 to 0 to SURROUND_GAIN,      // BL → L
            1 to 1 to 1f,                 // FR → R
            2 to 1 to SURROUND_GAIN,      // FC → R
            5 to 1 to SURROUND_GAIN,      // BR → R
        ),
    )

    /**
     * 7.1（FL,FR,FC,LFE,BL,BR,SL,SR）→ 2.0。
     *
     * ```
     * L = FL + 0.7071·FC + 0.7071·BL + 0.7071·SL
     * R = FR + 0.7071·FC + 0.7071·BR + 0.7071·SR
     * ```
     */
    private fun sevenOneToStereo(): ChannelMixingMatrix = matrix(
        8, 2, mapOf(
            0 to 0 to 1f,                 // FL → L
            2 to 0 to SURROUND_GAIN,      // FC → L
            4 to 0 to SURROUND_GAIN,      // BL → L
            6 to 0 to SURROUND_GAIN,      // SL → L
            1 to 1 to 1f,                 // FR → R
            2 to 1 to SURROUND_GAIN,      // FC → R
            5 to 1 to SURROUND_GAIN,      // BR → R
            7 to 1 to SURROUND_GAIN,      // SR → R
        ),
    )
}

/**
 * 把「音效」装进 `AudioSink` 的 [DefaultRenderersFactory]。
 *
 * ## 为什么只能在这一层做
 *
 * 音效靠 `ChannelMixingAudioProcessor` 实现，而它必须由
 * `DefaultAudioSink.Builder.setAudioProcessors(...)` 在**造 AudioSink 时**交进去；
 * AudioSink 又是 [buildAudioSink] 在**建播放器时**造出来的。
 * media3 1.5.1 **没有**「运行期换 AudioSink / 换处理器链」的接口
 * （`setAudioProcessorChain` 同样只挂在 Builder 上），
 * 而 `ChannelMixingAudioProcessor` 的输出声道数在 `onConfigure()` 里就定死了
 * （`queueInput()` 虽然每块都重读矩阵，但输出缓冲区是按当时的声道数分配的）。
 *
 * ⇒ **改音效只能重建播放器**，见 `PlayerActivity.applyAudioEffect`。
 *
 * ## ⛔ 只接受 16 bit 整数 PCM，所以**不许**打开浮点输出
 *
 * `ChannelMixingAudioProcessor.onConfigure()` 对非 `ENCODING_PCM_16BIT` 的输入
 * **直接抛 `UnhandledAudioFormatException`**（字节码里就是 `iconst_2; if_icmpeq`）。
 * 而 `DefaultAudioSink` 只在 `enableFloatOutput == false` 时才会把上游一路降到
 * 16 bit 整数 PCM；打开浮点输出后管线末端是 `ENCODING_PCM_FLOAT`，
 * 我们这个处理器会**当场把音频链打断**（表现：整部片没声音）。
 *
 * 所以这里**忽略** `enableFloatOutput` 参数，恒传 `false`。
 * 代价只是「浮点输出那点动态范围」—— 电视上用不着，而弄错就是没声音。
 *
 * ## ⚠️ 已知限制：直通（HDMI 功放）时这一档不起作用
 *
 * 若片源是 AC-3 / DTS 且设备报告支持直通，`DefaultAudioSink.configure()` 收到的
 * 是**压缩格式**（不是 `audio/raw`），处理器链根本不会被配置 ⇒ 下混不发生。
 *
 * ⛔ **不要**在这里「顺手」把 `AudioCapabilities` 砍成只支持 PCM 来强行解码：
 *    那会让**没有 AC-3 解码器**的机器从「有声音」直接变成「没声音」，
 *    而这两个方向都没在电视上实测过。等真机量到「直通下强制立体声无效」
 *    再动，且动之前要能在功放上确认解码器存在。
 */
class AudioEffectRenderersFactory(
    context: Context,
    private val effect: AudioEffect,
) : DefaultRenderersFactory(context) {

    /** 交给 [DefaultAudioSink] 的混音器。持有它是为了能在日志里核对档位。 */
    val mixing = ChannelMixingAudioProcessor()

    init {
        // ⛔ 必须**建好就注册全部声道数**：`onConfigure()` 在缺表时是抛异常，
        //    不是透传（见 [AudioMix] 的类文档）。
        for (ch in 1..AudioMix.MAX_INPUT_CHANNELS) {
            mixing.putChannelMixingMatrix(AudioMix.matrixFor(effect, ch))
        }
    }

    override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioTrackPlaybackParams: Boolean,
    ): AudioSink = DefaultAudioSink.Builder(context)
        // ⛔ 恒 false，理由见类文档（处理器只吃 16 bit 整数 PCM）。
        .setEnableFloatOutput(false)
        .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
        .setAudioProcessors(arrayOf<AudioProcessor>(mixing))
        .build()
}
