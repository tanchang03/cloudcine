package com.cloudcine.tv

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.cloudcine.tv.library.StartupSync
import com.cloudcine.tv.pan.CredStore

/**
 * 启动页 —— 只做一件事：按登录态把用户送进该去的地方。
 *
 * ⛔ **首页是媒体库（[LibraryActivity]），不是网盘文件列表**。
 *    媒体库读的是**本地索引**，不需要登录态也不需要网络 —— 打开就能看海报墙。
 *    网盘目录（[BrowseActivity]）降级为媒体库里的一个入口
 *    （一级导航的「文件列表」/ MENU），因为它是「找一个还没入库的文件」时才
 *    需要去的地方，不是每天打开电视要看的东西。
 *
 * ⛔ 没登录时仍然先去 [LoginActivity]：媒体库本身能看，但「同步 / 上传备份 /
 *    从网盘恢复 / 扫描」全都要登录态，而登录页是电视上唯一能输入凭证的地方。
 *
 * ★ 这里还是**「每次启动 App」的计时零点**（[StartupSync.beginLaunch]）：媒体库页
 *    会据此问一句「网盘上有更新的备份，要不要同步」——
 *    见 [LibraryActivity.probeRemoteBackupAtStartup]。
 *
 * ⛔ PC 端（Flutter）那边这里是 `MainActivity` 承载整个 go_router；本工程刻意让
 * 每个页面是一个独立 Activity，**这样「返回键」的语义由系统保证**，不用自己维护
 * 一份导航栈 —— 而导航栈正是「遥控器按返回键行为诡异」的常见来源。
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // ⛔ 「每次启动 App」的零点就在这一行。理由：本 Activity 是 LAUNCHER
        //    入口，而且它自己 `finish()` 掉 —— 从电视桌面点一次图标，就一定会
        //    新建一次它。媒体库页的「网盘上有更新的备份」探测（见
        //    [LibraryActivity.probeRemoteBackupAtStartup]）按这个零点决定要不要
        //    问用户；放在媒体库页上就会变成「从文件列表返回一次问一次」。
        StartupSync.beginLaunch()

        val store = CredStore(this)
        startActivity(
            Intent(
                this,
                if (store.loggedIn) LibraryActivity::class.java else LoginActivity::class.java,
            ),
        )
        finish()
    }
}
