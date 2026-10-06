package com.cloudcine.kuake

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * 二维码位图。
 *
 * ⛔ 用 **zxing** 而不是自己写编码器：QR 的掩码/纠错级别选错时**不会报错**，
 * 只会「有些手机扫不出来」—— 那种问题在电视上排查一次要十分钟。
 * `com.google.zxing:core` 是一个纯 Java jar，不引任何 Android 组件。
 */
object QrCode {

    /**
     * @param quietZone 静区（单位：模块数）。⛔ **不能是 0**：标准要求 ≥4，
     *   少了的话很多扫码器直接识别不出来，而屏幕上看起来「二维码明明是对的」。
     */
    fun bitmap(text: String, sizePx: Int, quietZone: Int = 2): Bitmap {
        val hints = mapOf(
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
            EncodeHintType.MARGIN to quietZone,
            EncodeHintType.CHARACTER_SET to "UTF-8",
        )
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, sizePx, sizePx, hints)
        val w = matrix.width
        val h = matrix.height
        val pixels = IntArray(w * h)
        val black = Color.BLACK
        val white = Color.WHITE
        for (y in 0 until h) {
            val row = y * w
            for (x in 0 until w) {
                pixels[row + x] = if (matrix.get(x, y)) black else white
            }
        }
        return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply {
            setPixels(pixels, 0, w, 0, 0, w, h)
        }
    }
}
