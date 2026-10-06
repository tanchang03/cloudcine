package com.cloudcine.tv.library

/**
 * 「这个目录名是**容器**还是**作品名**」—— 移植 PC 端
 * `lib/core/utils/directory_title.dart`。
 *
 * ## 它解决的问题
 *
 * 网盘的目录结构里混着大量**不是名字的**目录：`电影` / `1080p` / `来自分享` /
 * `新建文件夹` / `第01集` / `2024`。剧集的片名几乎只能从目录名推出来
 * （`动漫/进击的巨人/S01E01.mkv` 里的「进击的巨人」），所以必须能从一长串
 * 祖先目录里**跳过容器、取到最近的那个真名字**。
 *
 * ⛔ 判据是「**是不是容器**」，不是「像不像名字」。判反了的代价不对称：
 *    * 把容器当名字 ⇒ 一整批片子被归成一部叫「电影」的作品；
 *    * 把名字当容器 ⇒ 片名退化成文件名，分类与刮削都会跑偏。
 *    所以词表宁可长、宁可保守。
 */
object DirectoryTitle {

    private fun norm(s: String): String =
        s.lowercase().replace(Regex("[^a-z0-9\\u4e00-\\u9fff]"), "")

    private val CONTAINER_WORDS = setOf(
        "来自分享", "我的分享", "分享", "转存", "保存到我的网盘", "百度网盘", "阿里云盘",
        "新建文件夹", "未命名文件夹", "未命名", "副本", "未分类", "未整理", "待整理",
        "待分类", "其他", "其它", "下载", "我的资源", "我的视频", "我的电影", "资源",
        "合集", "收藏", "经典", "已整理", "临时", "temp",
        "电影", "电视剧", "剧集", "美剧", "日剧", "韩剧", "港剧", "台剧", "国产剧",
        "欧美剧", "动漫", "动画", "番剧", "新番", "国漫", "日漫", "综艺", "纪录片",
        "纪实", "短片", "微电影", "音乐", "演唱会", "课程", "教程", "学习", "培训",
        "蓝光", "原盘", "高清", "超清", "bd", "hd", "remux", "4k", "1080p", "720p",
    )

    private val CONTAINER_PREFIXES = listOf(
        "来自分享", "我的分享", "新建文件夹", "未命名", "副本",
    )

    private val CONTAINER_PATTERNS = listOf(
        Regex("^day[\\s_\\-]*\\d+$"),
        Regex("^\\d+[\\s._\\-]*(第?[一二三四五六七八九十\\d]+[期季])?[\\s]*(视频|音频|课件|资料|素材|文档|图片|字幕)$"),
        Regex("^\\d+[\\s._\\-]*(基础|进阶|高级|扩展|实战|入门|提高|核心|选修)篇$"),
        Regex("^第[\\s]*\\d+[\\s]*(章|节|讲|课|期|篇|集|话)$"),
        Regex("^第[\\s]*[一二三四五六七八九十\\d]{1,3}[\\s]*季$"),
        Regex("^s(eason)?[\\s._\\-]*\\d{1,2}$"),
        Regex("^\\d+$"),
        Regex("^\\d{4}[-_.]\\d{1,2}[-_.]\\d{1,2}$"),
        Regex("^\\d{3,4}[pi]$"),
        Regex("^[248]k$"),
    )

    fun isContainerSegment(segment: String): Boolean {
        val raw = segment.trim()
        if (raw.isEmpty()) return true
        val lower = raw.lowercase()
        val n = norm(lower)
        // 单字符目录名一律当容器：`a` / `1` 这种名字当片名毫无意义，
        // 而它们又极常见（分卷、临时目录）。
        if (n.length < 2) return true
        for (p in CONTAINER_PATTERNS) if (p.containsMatchIn(lower)) return true
        if (CONTAINER_WORDS.contains(n)) return true
        for (pre in CONTAINER_PREFIXES) if (n.startsWith(pre)) return true
        return false
    }

    /** 从最内层往上找，第一个**不是容器**的目录名就是系列名。 */
    fun seriesTitleOf(dirPath: String): String? = ancestorNames(dirPath).firstOrNull()

    /**
     * 由内到外的祖先目录名（已清洗、已跳过容器）。
     *
     * ⛔ 顺序是**由内到外**，不是由外到内：`/动漫/进击的巨人/S01/` 里我们要的是
     *    「进击的巨人」，不是「动漫」。
     */
    fun ancestorNames(dirPath: String): List<String> {
        val segments = dirPath.split('/').map { it.trim() }.filter { it.isNotEmpty() }
        val out = ArrayList<String>(segments.size)
        for (i in segments.indices.reversed()) {
            if (isContainerSegment(segments[i])) continue
            clean(segments[i])?.let { out.add(it) }
        }
        return out
    }

    /** 去掉书名号 / 括号 / 分隔符，得到能当片名用的字符串。 */
    private fun clean(segment: String): String? {
        var s = segment
        s = s.replace(Regex("[《》〈〉「」『』【】\\[\\]（）()]"), " ")
        s = s.replace(Regex("[._]+"), " ")
        s = s.replace(Regex("^[\\s\\-–—]+"), "")
        s = s.replace(Regex("[\\s\\-–—]+$"), "")
        s = s.replace(Regex("\\s{2,}"), " ").trim()
        return if (s.isEmpty()) null else s
    }
}
