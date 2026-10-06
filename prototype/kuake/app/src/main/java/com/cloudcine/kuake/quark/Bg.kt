package com.cloudcine.kuake.quark

import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors

/**
 * 「后台线程干活、主线程收结果」。
 *
 * ⛔ 这个类**存在的唯一理由是云影踩过的那个坑**：云影的中继（上游 TLS 握手、
 * 记录解密、HTTP 解析、分块拷贝）**全跑在 Dart 主 isolate 上**，而 Flutter 的
 * Dart isolate **就是 Android 主线程** —— 于是下载一忙，UI 就饿死。
 *
 * 本工程所有网络调用都在这个池子里，主线程只做 `setText` / `invalidate`。
 */
object Bg {

    private val pool = Executors.newFixedThreadPool(4)
    private val main = Handler(Looper.getMainLooper())

    /**
     * @param work 在后台线程执行（**不能碰任何 View**）
     * @param done 在主线程回调，`err` 非空表示失败
     */
    fun <T> run(work: () -> T, done: (value: T?, err: Throwable?) -> Unit) {
        pool.execute {
            var value: T? = null
            var err: Throwable? = null
            try {
                value = work()
            } catch (t: Throwable) {
                err = t
            }
            val v = value
            val e = err
            main.post { done(v, e) }
        }
    }

    /** 只要副作用、不要结果的写法。 */
    fun run(work: () -> Unit) = run<Unit>({ work() }, { _, _ -> })
}
