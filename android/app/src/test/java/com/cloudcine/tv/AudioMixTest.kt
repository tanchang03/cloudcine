package com.cloudcine.tv

import androidx.media3.common.audio.ChannelMixingMatrix
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [AudioMix] / [AudioEffect] 的单测。
 *
 * ## 为什么这一组是必测的
 *
 * 音效写错的症状**都不是崩溃**，两种都很难在电视上定位：
 *
 *   1. **漏注册某个声道数** ⇒ `ChannelMixingAudioProcessor.onConfigure()` 抛
 *      `UnhandledAudioFormatException` ⇒ 音频渲染器起不来 ⇒ **整部片没声音**。
 *      用户看到的是「换了个音效就没声了」，不像是代码问题。
 *   2. **系数下标理解反** ⇒ 中置混进了环绕、左右声道不对 ⇒ **能出声，只是不对**。
 *      这一种连日志都没有。
 *
 * 所以下面把「每个声道数都有矩阵」「哪些声道数会下混」「系数落在哪个下标」
 * 全部钉成断言。改坏了立刻红。
 */
class AudioMixTest {

    /** 中置 / 环绕的下混增益，`1/√2`。 */
    private val g = 0.7071

    /** 容差：`1/√2` 存成 float 再转 double 会有 1e-8 量级的误差。 */
    private val eps = 1e-6

    /**
     * 取一个系数并转成 `Double`。
     *
     * ⛔ JUnit 4 只有 `assertEquals(double, double, double)`，**没有 float 重载**；
     *    而 Kotlin 不会把 `Float` 自动放宽成 `Double` —— 直接写
     *    `assertEquals(1f, 系数, 1e-6f)` 会编译不过。
     */
    private fun coef(m: ChannelMixingMatrix, input: Int, output: Int): Double =
        m.getMixingCoefficient(input, output).toDouble()

    // ── 覆盖性：这条对应「没声音」──

    @Test
    fun `每个受支持的声道数都必须能拿到矩阵 且输入声道数与请求一致`() {
        // ⛔ 这条是「没声音」那条红线的直接断言：`ChannelMixingAudioProcessor`
        //    是按**输入声道数**去查表的，查不到就抛异常。
        //    矩阵自己的 `getInputChannelCount()` 必须与请求的那个数**逐位相等** ——
        //    比如给 12 声道请求返回了一个 16 声道的矩阵，查表照样查不到。
        for (ch in 1..AudioMix.MAX_INPUT_CHANNELS) {
            for (effect in AudioEffect.ALL) {
                val m = AudioMix.matrixFor(effect, ch)
                assertEquals(
                    "音效=${effect.id} 声道数=$ch 的矩阵输入声道数不对",
                    ch,
                    m.getInputChannelCount(),
                )
            }
        }
    }

    // ── 跟随片源：必须与「没装音效功能」逐位一致 ──

    @Test
    fun `跟随片源 任何声道数都是单位矩阵 于是处理器整条被跳过`() {
        // ⛔ 这一条决定了「默认档 = 与改动前完全一样」。
        //    `ChannelMixingAudioProcessor.onConfigure()` 只在矩阵 `isIdentity()`
        //    时返回 NOT_SET；返回 NOT_SET 才会让 `AudioProcessingPipeline`
        //    把这个处理器跳过。矩阵不是单位阵 ⇒ 处理器活跃 ⇒ 默认档也会改声音。
        for (ch in 1..AudioMix.MAX_INPUT_CHANNELS) {
            assertTrue(
                "跟随片源在 $ch 声道下不是单位矩阵",
                AudioMix.matrixFor(AudioEffect.follow, ch).isIdentity(),
            )
        }
    }

    // ── 强制立体声：该下混的必须下混，不该动的必须不动 ──

    @Test
    fun `强制立体声 单声道与立体声片源不做任何事`() {
        // 已经是 2.0 就没有可下混的；单声道「补成 2.0」是上混，不是这一档的语义。
        for (ch in 1..2) {
            assertTrue(
                "强制立体声在 $ch 声道下不该动手",
                AudioMix.matrixFor(AudioEffect.stereo, ch).isIdentity(),
            )
        }
    }

    @Test
    fun `强制立体声 没有标准布局的 3 5 7 9 声道原样透传`() {
        // Android 的 `CHANNEL_OUT_*` 只定义了 1 / 2 / 4 / 6 / 8。
        // 猜一个错的下混比不做更坏 —— 症状是「有些片子声音怪怪的」。
        for (ch in intArrayOf(3, 5, 7, 9, 12)) {
            assertTrue(
                "强制立体声在 $ch 声道下不该动手",
                AudioMix.matrixFor(AudioEffect.stereo, ch).isIdentity(),
            )
        }
    }

    @Test
    fun `强制立体声 5_1 是 6 进 2 出`() {
        val m = AudioMix.matrixFor(AudioEffect.stereo, 6)
        assertEquals(6, m.getInputChannelCount())
        assertEquals(2, m.getOutputChannelCount())
        // ⛔ 必须**不是**单位阵：单位阵会被管线跳过，于是「切了没反应」。
        assertFalse("5.1 下混矩阵退化成了单位阵，处理器会被跳过", m.isIdentity())
    }

    @Test
    fun `强制立体声 7_1 是 8 进 2 出`() {
        val m = AudioMix.matrixFor(AudioEffect.stereo, 8)
        assertEquals(8, m.getInputChannelCount())
        assertEquals(2, m.getOutputChannelCount())
        assertFalse(m.isIdentity())
    }

    @Test
    fun `强制立体声 四声道是 4 进 2 出`() {
        val m = AudioMix.matrixFor(AudioEffect.stereo, 4)
        assertEquals(4, m.getInputChannelCount())
        assertEquals(2, m.getOutputChannelCount())
        assertFalse(m.isIdentity())
    }

    // ── 系数：这条对应「能出声但不对」──

    @Test
    fun `5_1 下混 左右声道各自只吃自己那一侧 中置两边都给`() {
        // ⛔ 这条钉的是 `getMixingCoefficient(输入声道, 输出声道)` 的**参数顺序**
        //    与系数数组下标口径（`输入 × 输出数 + 输出`）。
        //    口径搞反的后果：FL 会跑进右声道、中置会跑进环绕 —— 而它不报错。
        val m = AudioMix.matrixFor(AudioEffect.stereo, 6)
        // 5.1 顺序：0=FL 1=FR 2=FC 3=LFE 4=BL 5=BR
        assertEquals(1.0, coef(m, 0, 0), eps) // FL → L
        assertEquals(0.0, coef(m, 1, 0), eps) // FR 不进 L
        assertEquals(0.0, coef(m, 0, 1), eps) // FL 不进 R
        assertEquals(1.0, coef(m, 1, 1), eps) // FR → R
        assertEquals(g, coef(m, 2, 0), eps)   // FC → L
        assertEquals(g, coef(m, 2, 1), eps)   // FC → R
        assertEquals(g, coef(m, 4, 0), eps)   // BL → L
        assertEquals(0.0, coef(m, 5, 0), eps) // BR 不进 L
        assertEquals(0.0, coef(m, 4, 1), eps) // BL 不进 R
        assertEquals(g, coef(m, 5, 1), eps)   // BR → R
    }

    @Test
    fun `5_1 下混 LFE 完全不参与`() {
        // LFE 是 +10dB 的独立低频声道，加进来必然削顶（「一到大场面就破音」）。
        val m = AudioMix.matrixFor(AudioEffect.stereo, 6)
        assertEquals(0.0, coef(m, 3, 0), eps)
        assertEquals(0.0, coef(m, 3, 1), eps)
    }

    @Test
    fun `7_1 下混 侧环绕也进左右声道 中置与 LFE 口径与 5_1 一致`() {
        // 7.1 顺序：0=FL 1=FR 2=FC 3=LFE 4=BL 5=BR 6=SL 7=SR
        val m = AudioMix.matrixFor(AudioEffect.stereo, 8)
        assertEquals(1.0, coef(m, 0, 0), eps)
        assertEquals(1.0, coef(m, 1, 1), eps)
        assertEquals(g, coef(m, 2, 0), eps)
        assertEquals(g, coef(m, 2, 1), eps)
        assertEquals(0.0, coef(m, 3, 0), eps)
        assertEquals(0.0, coef(m, 3, 1), eps)
        assertEquals(g, coef(m, 4, 0), eps)
        assertEquals(g, coef(m, 5, 1), eps)
        assertEquals(g, coef(m, 6, 0), eps)
        assertEquals(g, coef(m, 7, 1), eps)
    }

    @Test
    fun `四声道下混 后左后右分别进左右`() {
        // 四声道顺序：0=FL 1=FR 2=BL 3=BR
        val m = AudioMix.matrixFor(AudioEffect.stereo, 4)
        assertEquals(1.0, coef(m, 0, 0), eps)
        assertEquals(g, coef(m, 2, 0), eps)
        assertEquals(1.0, coef(m, 1, 1), eps)
        assertEquals(g, coef(m, 3, 1), eps)
    }

    @Test
    fun `单位矩阵 是方阵且对角线为 1 其余为 0`() {
        // ⛔ `isIdentity()` 只在**方阵**且对角线为 1 时成立。若把「透传」写成
        //    非方阵（比如 6→6 写成 6 行 2 列），`onConfigure` 会去查
        //    输入声道数的矩阵、拿到的却不是单位阵 ⇒ 默认档也会改声音。
        for (ch in 1..AudioMix.MAX_INPUT_CHANNELS) {
            val m = AudioMix.identity(ch)
            assertTrue("$ch 声道的单位矩阵没被认成单位阵", m.isIdentity())
            for (i in 0 until ch) {
                for (o in 0 until ch) {
                    assertEquals(
                        "单位矩阵 ($i,$o) 位置不对",
                        if (i == o) 1.0 else 0.0,
                        coef(m, i, o),
                        eps,
                    )
                }
            }
        }
    }

    // ── 偏好解析 ──

    @Test
    fun `音效 id 解析 读不懂一律退回默认 不抛异常`() {
        assertEquals(AudioEffect.follow, AudioEffect.parse(null))
        assertEquals(AudioEffect.follow, AudioEffect.parse(""))
        assertEquals(AudioEffect.follow, AudioEffect.parse("stereoo"))
        // ⛔ 旧版本若用序号存过（`"1"`）也必须能读回来而不炸。
        assertEquals(AudioEffect.follow, AudioEffect.parse("1"))
        assertEquals(AudioEffect.stereo, AudioEffect.parse("stereo"))
        assertEquals(AudioEffect.follow, AudioEffect.parse("follow"))
    }

    @Test
    fun `音效 id 是稳定字符串 不是序号`() {
        // ⛔ 存序号的话，以后在中间插一档就会把老用户的「强制立体声」
        //    静默变成别的档（PC 端 `tables.dart` 同一条约定）。
        assertEquals("follow", AudioEffect.follow.id)
        assertEquals("stereo", AudioEffect.stereo.id)
    }

    @Test
    fun `菜单顺序与默认档`() {
        assertEquals(AudioEffect.follow, AudioEffect.DEFAULT)
        assertEquals(
            listOf(AudioEffect.follow, AudioEffect.stereo),
            AudioEffect.ALL,
        )
        // 默认档必须在菜单第一位（OSD 光标初始落点靠它）。
        assertEquals(AudioEffect.follow, AudioEffect.ALL.first())
    }
}
