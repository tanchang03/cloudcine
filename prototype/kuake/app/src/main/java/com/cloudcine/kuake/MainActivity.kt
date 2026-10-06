package com.cloudcine.kuake

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.cloudcine.kuake.quark.QuarkStore

/**
 * 启动页 —— 只做一件事：按登录态把用户送进该去的地方。
 *
 * ⛔ 云影那边这里是 `MainActivity` 承载整个 go_router；本原型刻意让每个页面
 * 是一个独立 Activity，**这样「返回键」的语义由系统保证**，不用自己维护
 * 一份导航栈 —— 而导航栈正是「遥控器按返回键行为诡异」的常见来源。
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val store = QuarkStore(this)
        startActivity(
            Intent(
                this,
                if (store.loggedIn) BrowseActivity::class.java else LoginActivity::class.java,
            ),
        )
        finish()
    }
}
