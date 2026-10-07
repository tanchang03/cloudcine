package android.text;

import java.util.Iterator;
import java.util.regex.Pattern;

/**
 * `android.text.TextUtils` 的**单测替身**。
 *
 * ## ⛔ 为什么需要这个文件
 *
 * JVM 单测跑的不是真 Android，而是 AGP 生成的 `mockable-android-*.jar`——
 * 里面每个框架方法都是空壳。工程里开了
 * `testOptions.unitTests.isReturnDefaultValues = true`（见 `app/build.gradle.kts`，
 * 为了 `android.util.Log` 不抛异常），于是空壳方法**静默返回默认值**：
 * `boolean` 一律 `false`、数组一律 `null`。
 *
 * 这在 `isEmpty` 上会变成一个**死循环**，而不是一个失败。Media3 的
 * `WebvttParser.java:86` 是一句「跳过头部后的空行」的循环：
 *
 * ```java
 * while (!TextUtils.isEmpty(parsableWebvttData.readLine())) { ... }
 * ```
 *
 * `isEmpty(...)` 恒为 `false` ⇒ `while (true)`；`readLine()` 读到头之后一直返回
 * `null`，于是**永远转下去**。实测：`ExternalSubtitleTest.VTT 能解析` 单条用例
 * 烧满一个核（371 秒里 367 秒 CPU），整个 `:app:testDebugUnitTest` 永远不返回，
 * `assembleRelease`（它依赖单测）也跟着挂死。
 *
 * ⛔ **不要删掉这个文件、也不要把它挪进 `src/main`**：`src/main` 里那份会被真机
 * 上的 `android.jar` 覆盖，而这个文件只在单测的 classpath 上生效
 * （测试源集的输出排在 `mockable-android-*.jar` 之前）。
 *
 * ## 补上它之后发生了什么（2026-10-07 的完整修复链）
 *
 * 1. **这个替身一上，死循环就没了** —— `ExternalSubtitleTest` 从「永远挂着」
 *    变成「跑完并报错」：`Cue` 构造器 NPE（空壳造出来的 `text` 是 `null`）。
 * 2. 那个错说明 **Media3 1.5.1 的字幕解析器在 JVM 上根本跑不起来** ——
 *    它们造的是 `Spanned` 富文本，一路依赖 `SpannableStringBuilder` /
 *    `StyleSpan` / `SparseArray` 一整套框架类。所以测试改成给
 *    `ExternalSubtitle.parse` 注入**假解析器**（见那个函数的 `factory` 参数），
 *    只验我们自己写的那一段（编码 / 排序 / 结束时间兜底 / 二分）。
 * 3. ⇒ **当前测试集已经不再经过这个类**。留着它是为了「防下一次」：哪天有人
 *    再写一个走真解析器（或任何依赖 `TextUtils` 的 Media3 代码）的用例，
 *    结果是**报错**，而不是安静地把整个构建挂死。
 *
 * 配套的第二道保险是 `app/build.gradle.kts` 里给 `Test` 任务加的兜底超时。
 *
 * ## 只补真正用到的方法
 *
 * 全量扫过 Media3 1.5.1 里单测会加载到的类，只用到两个：
 *
 * | 调用点 | 方法 |
 * |---|---|
 * | `webvtt/WebvttParser` · `webvtt/WebvttCueParser` · `webvtt/WebvttCssParser` · `webvtt/WebvttCssStyle` · `subrip/SubripParser` | `isEmpty` |
 * | `ssa/SsaStyle` · `ssa/SsaStyle$Format` · `ssa/SsaDialogueFormat` · `ttml/TextEmphasis` | `split` |
 *
 * 其余几个（`equals` / `isDigitsOnly` / `join` / `concat` / `getTrimmedLength`）
 * 是**纯函数且语义没有歧义**，顺手补上，免得下次换个字幕格式又撞上
 * `NoSuchMethodError`。
 *
 * ⛔ **不要在这里补 `ellipsize` / `htmlEncode` / `getLayoutDirectionFromLocale`
 * 之类的**：它们的真实行为牵扯 `Layout` / ICU，凭印象写一个「差不多」的实现
 * 比没有更坏 —— 那种错会静默产出错误的字幕排版，而不是报错。
 */
public final class TextUtils {

    private TextUtils() {
    }

    /**
     * 截断位置。
     *
     * ⛔ 必须带上：这个替身是**整类替换**（不是「加几个静态方法」），
     * 主源码里的 `TextUtils.TruncateAt.END` 虽然在单测里不会被加载，
     * 但少一个内部类会让「哪天有人写了个碰 `TvOsdView` 的测试」直接
     * `NoClassDefFoundError`。
     */
    public enum TruncateAt {
        START,
        MIDDLE,
        END,
        MARQUEE,
    }

    private static final String[] EMPTY_STRING_ARRAY = new String[0];

    /** `null` 与**空串**都是「空」。真机语义就是这个，别改成 `String.isEmpty()`。 */
    public static boolean isEmpty(CharSequence str) {
        return str == null || str.length() == 0;
    }

    /**
     * 按分隔符切分，**保留末尾空段**（`String.split(regex, -1)`）。
     *
     * ⛔ 第二个参数是**正则**（真机语义）。Media3 的 SSA 解析传的是 `","`，
     * 恰好也是字面量；但不能因此改成 `indexOf` 手写切分 —— 一旦有人传
     * `"\\s*,\\s*"` 就会静默切成错的段数。
     */
    public static String[] split(String text, String expression) {
        if (text.length() == 0) {
            return EMPTY_STRING_ARRAY;
        }
        return text.split(expression, -1);
    }

    /** 同上，正则已经编译好的形态。 */
    public static String[] split(String text, Pattern pattern) {
        if (text.length() == 0) {
            return EMPTY_STRING_ARRAY;
        }
        return pattern.split(text, -1);
    }

    /** 逐字符比较，两个 `null` 相等、一个 `null` 不等。 */
    public static boolean equals(CharSequence a, CharSequence b) {
        if (a == b) {
            return true;
        }
        if (a == null || b == null) {
            return false;
        }
        int length = a.length();
        if (length != b.length()) {
            return false;
        }
        if (a instanceof String && b instanceof String) {
            return a.equals(b);
        }
        for (int i = 0; i < length; i++) {
            if (a.charAt(i) != b.charAt(i)) {
                return false;
            }
        }
        return true;
    }

    /** 只含 `0`~`9`；空串返回 `false`（真机语义）。 */
    public static boolean isDigitsOnly(CharSequence str) {
        final int len = str.length();
        for (int i = 0; i < len; i++) {
            if (!Character.isDigit(str.charAt(i))) {
                return false;
            }
        }
        return len > 0;
    }

    /** 去掉**首尾**空白后的长度。 */
    public static int getTrimmedLength(CharSequence s) {
        final int len = s.length();
        int start = 0;
        while (start < len && s.charAt(start) <= ' ') {
            start++;
        }
        int end = len;
        while (end > start && s.charAt(end - 1) <= ' ') {
            end--;
        }
        return end - start;
    }

    public static String join(CharSequence delimiter, Object[] tokens) {
        StringBuilder sb = new StringBuilder();
        boolean first = true;
        for (Object token : tokens) {
            if (first) {
                first = false;
            } else {
                sb.append(delimiter);
            }
            sb.append(token);
        }
        return sb.toString();
    }

    public static String join(CharSequence delimiter, Iterable<?> tokens) {
        StringBuilder sb = new StringBuilder();
        boolean first = true;
        Iterator<?> it = tokens.iterator();
        while (it.hasNext()) {
            if (first) {
                first = false;
            } else {
                sb.append(delimiter);
            }
            sb.append(it.next());
        }
        return sb.toString();
    }

    /** 顺次拼接。`null` 元素被忽略（真机语义）。 */
    public static CharSequence concat(CharSequence... text) {
        if (text.length == 0) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        for (CharSequence cs : text) {
            if (cs != null) {
                sb.append(cs);
            }
        }
        return sb.toString();
    }
}
