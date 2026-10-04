import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/format.dart';
import 'diag_log.dart';

/// 资源采样：定时把 **CPU / 内存 / 磁盘** 这些「跟播放器逻辑无关、却能决定
/// 它卡不卡」的读数写进诊断日志。
///
/// ## 为什么需要它
///
/// 「4K 掉帧」这类问题里，播放器自己的日志只能回答**它做了什么**
/// （解码器是谁、丢了几帧），回答不了**这台机器当时有多忙**：
///
///   * 电视盒子上除了我们的进程，还有 MediaCodec 的解码服务进程
///     （`media.codec` / `media.swcodec`）—— 它**不在** `/proc/self` 里。
///     所以只看本进程 CPU 会得出「CPU 很低啊」的假结论，必须同时看
///     **系统整体** CPU 与 **负载**（loadavg），才能发现「盒子已经被榨干」。
///   * 「拷回内存 + 上传纹理」那条路（`mediacodec-copy`）在 4K 上是
///     每帧 ~12MB 的内存带宽压力。它**不体现为丢帧**，只体现为
///     `vo-delayed-frame-count` 在涨 —— 而如果同时看到进程内存与
///     系统内存被吃紧，就能把「带宽瓶颈」与「内存压力」分开。
///   * 日志是**同步写盘**的（见 [DiagLog] 的类文档）。如果磁盘本身很慢
///     （电视盒子的 eMMC 老化），每 21 秒一次的采样写盘就可能自己变成
///     一个卡顿源。磁盘可用空间与进程写吞吐能把这条嫌疑洗清或坐实。
///
/// ## 采样周期为什么是 10 秒（而不是跟着视频探针的 21 秒）
///
/// 视频管线探针（`MediaKitPlaybackEngine` 里那条 `[解码]`）是 **21 秒**一拍。
/// 而用户报的现象恰好是「**每 21 秒**掉一批帧」—— 两个周期一旦相等就会
/// **拍频锁定**：永远在同一个相位采样，要么每次都采到「正在卡」，
/// 要么每次都采到「刚好不卡」，而真实规律被完全掩盖。
///
/// 10 与 21 互质，相位会一轮轮扫过去，任何周期性现象都躲不掉。
/// 代价是每分钟 6 行 —— 环形缓冲只有 800 行，界面里大约能看到最近
/// 十几分钟；但**文件是不裁剪的**，诊断页的「上传到网盘」取的正是文件。
///
/// ## 读数一律可空
///
/// 每个字段都可空，**可空 = 这台设备/这个平台读不到**，不是「读到了 0」。
/// 把「读不到」当成 0 会把「未知」写成「空闲」，比不写还糟 —— 这正是
/// `MediaKitPlaybackEngine` 里 `hwdec-current` 空串那个坑的同一类错误。
/// 读不到的字段在日志行里**整段消失**，不会伪装成 0。
///
/// ## 数据来源
///
///   * Android / Linux：`/proc` 下的几个文件（自己进程的 `stat` / `status` /
///     `io`，系统级的 `stat` / `meminfo` / `loadavg`）。
///   * macOS：**没有 `/proc`**，内存退回 `dart:io` 的 `ProcessInfo.currentRss`，
///     CPU / 负载 / 磁盘 IO 留空。磁盘可用空间两边都靠 `df -k`。
///
/// 本文件里所有 `parse*` / `format*` / `*Percent*` 都是**纯函数**，与 IO 分离
/// —— 理由同 `nextVideoProbeAction`：真机上才能跑的东西，判断部分必须能单测。

/// `/proc` 里 CPU 时间的单位：**jiffies**。
///
/// 从 Dart 拿不到 `sysconf(_SC_CLK_TCK)`，只能写死。Android/Linux 的
/// 用户态时钟节拍实测就是 100 Hz（`CONFIG_HZ=100`），写错这个常数会让
/// CPU 百分比整体差 10 倍 —— 但**不会报错**，只会让人得出错误结论，
/// 所以这里显式命名、并在日志里说明口径。
const int kProcClockTicksPerSecond = 100;

/// 一次资源采样的读数。字段全可空，语义见本文件的类文档。
@immutable
class ResourceReading {
  const ResourceReading({
    this.rssBytes,
    this.vmSizeBytes,
    this.threads,
    this.procCpuTicks,
    this.sysBusyTicks,
    this.sysTotalTicks,
    this.memAvailableBytes,
    this.memTotalBytes,
    this.load1,
    this.load5,
    this.load15,
    this.diskAvailableBytes,
    this.ioReadBytes,
    this.ioWriteBytes,
    this.procsRunning,
    this.procsBlocked,
  });

  /// 进程常驻内存（RSS），字节
  final int? rssBytes;

  /// 进程虚拟内存，字节。数值虚高是正常的（映射不等于占用），
  /// 它的用处是看**有没有异常膨胀**。
  final int? vmSizeBytes;

  /// 进程线程数
  final int? threads;

  /// 进程累计 CPU 时间（user + sys），单位 jiffies
  final int? procCpuTicks;

  /// 系统累计忙 jiffies（`/proc/stat` 的 `cpu` 汇总行去掉 idle+iowait）
  final int? sysBusyTicks;

  /// 系统累计总 jiffies
  final int? sysTotalTicks;

  /// 系统可用内存（`MemAvailable`），字节
  final int? memAvailableBytes;

  /// 系统总内存，字节
  final int? memTotalBytes;

  /// 1 / 5 / 15 分钟平均负载
  final double? load1;
  final double? load5;
  final double? load15;

  /// 日志所在盘的可用空间，字节
  final int? diskAvailableBytes;

  /// 进程累计**真正落到设备**的读 / 写字节（`/proc/self/io` 的
  /// `read_bytes` / `write_bytes`）。
  ///
  /// ⚠️ 不用 `rchar` / `wchar`：那两个把页缓存也算进去，读一个缓存命中的
  /// 文件也会涨 —— 而这里要回答的是「**磁盘**累不累」。
  final int? ioReadBytes;
  final int? ioWriteBytes;

  /// 瞬时可运行进程数（`/proc/stat` 的 `procs_running`）。
  ///
  /// 这是 [load1] 的**替代读数**，而且比它更该看：`loadavg` 在目标电视上
  /// **根本读不到**（见 [parseProcStatProcs]），而且它是分钟级平均、会把
  /// 「刚刚那一下卡」抹平。绝对值除以核数 = 超订倍数。
  final int? procsRunning;

  /// 瞬时阻塞在 IO 上的进程数（`/proc/stat` 的 `procs_blocked`）。
  /// 大于 0 说明有活卡在磁盘上 —— 与「磁盘拖累播放」那条嫌疑直接相关。
  final int? procsBlocked;

  /// 一个字段都没读到。调用方据此决定「这拍不发日志、只提醒一次」。
  bool get isEmpty =>
      rssBytes == null &&
      vmSizeBytes == null &&
      threads == null &&
      procCpuTicks == null &&
      sysBusyTicks == null &&
      sysTotalTicks == null &&
      memAvailableBytes == null &&
      memTotalBytes == null &&
      load1 == null &&
      load5 == null &&
      load15 == null &&
      diskAvailableBytes == null &&
      ioReadBytes == null &&
      ioWriteBytes == null &&
      procsRunning == null &&
      procsBlocked == null;
}

/// 取一次读数。抽成 typedef 是为了让探针能在单测里注入假读数
/// —— 真读数依赖 `/proc`，跑在 macOS 的 CI 上大半是空的。
typedef ResourceReader = Future<ResourceReading> Function();

// ---------------------------------------------------------------------
// 纯函数：解析
// ---------------------------------------------------------------------

/// 把 `/proc/self/stat` 拆成「comm 之后」的字段表。
///
/// ## 为什么不能直接 `split(' ')`
///
/// 第二个字段是 **comm（进程名）**，它被一对括号包着，而进程名**允许含
/// 空格和括号**（Dart 的 VM 线程名、Java 的进程名都可能带）。所以
/// `split` 出来的下标会整体错位，而**错位不报错** —— 只会读到隔壁字段
/// 的数字，于是 CPU 时间变成了 nice 值、线程数变成了别的什么。
///
/// 唯一可靠的切法是找**最后一个** `)`：comm 里不可能有未转义的 `)`，
/// 所以最后一个 `)` 一定是 comm 的右括号。
///
/// 返回的 `f[0]` 对应 `stat` 的第 3 个字段（state），即 `f[i]` = 第 `i+3` 个。
@visibleForTesting
List<String>? procStatFields(String stat) {
  final end = stat.lastIndexOf(')');
  if (end < 0 || end + 2 > stat.length) return null;
  final rest = stat.substring(end + 2).trim();
  if (rest.isEmpty) return null;
  return rest.split(RegExp(r'\s+'));
}

/// `/proc/self/stat` → 进程累计 CPU 时间（user + sys，jiffies）。
///
/// utime / stime 是第 14 / 15 个字段 → `f[11]` / `f[12]`。
@visibleForTesting
int? parseProcSelfCpuTicks(String stat) {
  final f = procStatFields(stat);
  if (f == null || f.length < 13) return null;
  final utime = int.tryParse(f[11]);
  final stime = int.tryParse(f[12]);
  if (utime == null || stime == null) return null;
  return utime + stime;
}

/// `/proc/self/stat` → 线程数（第 20 个字段 → `f[17]`）。
///
/// 线程数单独值钱：Flutter 的 GPU / IO / raster 线程、mpv 的解复用与解码
/// 线程都在这里。它突然涨上去往往先于「卡」出现。
@visibleForTesting
int? parseProcSelfThreads(String stat) {
  final f = procStatFields(stat);
  if (f == null || f.length < 18) return null;
  return int.tryParse(f[17]);
}

/// `/proc/stat` 的 `cpu` 汇总行 → (忙, 总) 两个累计 jiffies。
///
/// 行的形状是 `cpu  user nice system idle iowait irq softirq steal ...`。
/// 「忙」= 总数 − idle − iowait：**iowait 不算忙**，它恰恰是「在等磁盘」，
/// 把它算进忙会让「磁盘慢」伪装成「CPU 忙」，而这两者的处置完全不同。
///
/// ⚠️ 只认以 `cpu `（带空格）开头的那一行。`cpu0` / `cpu1` 这些**每核**行
/// 也以 `cpu` 开头，但它们是汇总行之后才出现的，且这里用 `startsWith('cpu ')`
/// 已经把 `cpu0` 排除掉了。
@visibleForTesting
(int busy, int total)? parseProcStatCpu(String stat) {
  for (final line in stat.split('\n')) {
    if (!line.startsWith('cpu ')) continue;
    final nums = <int>[];
    for (final token in line.substring(4).trim().split(RegExp(r'\s+'))) {
      final value = int.tryParse(token);
      if (value == null) return null;
      nums.add(value);
    }
    // 至少要有 user/nice/system/idle/iowait 五个
    if (nums.length < 5) return null;
    final total = nums.fold<int>(0, (sum, v) => sum + v);
    final idle = nums[3] + nums[4];
    return (total - idle, total);
  }
  return null;
}

/// `/proc/stat` 的 `procs_running` / `procs_blocked` → (运行中, 阻塞中)。
///
/// ## 为什么必须有这一条（而不是只用 `loadavg`）
///
/// 10-04 在目标电视（MiTV，Android 9 / API 28）上实测：**`/proc/loadavg`
/// 连 `ls -l` 都是 `Permission denied`** —— 这台设备根本不给。而
/// **`/proc/stat` 完全可读**，`procs_running` / `procs_blocked` 就在里面。
///
/// 而且它比 `loadavg` **更适合这个用途**：
///   * `loadavg` 是 1/5/15 分钟**平均**，会把「刚刚那一下卡」抹平；
///     `procs_running` 是**瞬时**可运行进程数 —— 采样间隔是 10 秒，
///     正好用它抓「这一刻有几个活排着队」。
///   * 它是**绝对值**，分母是核数（4 核盒子 `procs_running=14` 就是
///     3.5 倍超订，一眼看出机器被榨干）。所以日志里必须把核数一并写出来。
///   * 连 `media.codec` 那种**别的进程**的负载也算在内 —— 而本进程 CPU
///     恰恰看不见它，这正是「4K 卡而本进程很闲」的关键。
///
/// `procs_blocked` > 0 = 有进程卡在**磁盘 IO** 上，与「磁盘拖累」那条嫌疑直接相关。
///
/// ⚠️ PSI（`/proc/pressure/*`，`some avg10` 那种更精确的读数）在 Android 9
/// 上**不存在**（实测 `No such file or directory`），别指望它。
@visibleForTesting
(int? running, int? blocked) parseProcStatProcs(String stat) {
  int? running;
  int? blocked;
  for (final line in stat.split('\n')) {
    // 'procs_running ' 与 'procs_blocked ' 都是 14 个字符。
    if (line.startsWith('procs_running ')) {
      running = int.tryParse(line.substring(14).trim());
    } else if (line.startsWith('procs_blocked ')) {
      blocked = int.tryParse(line.substring(14).trim());
    }
  }
  return (running, blocked);
}

/// `/proc/self/status` 或 `/proc/meminfo` 里的 `Key:  12345 kB` → 字节。
///
/// 两个文件的这一种行格式完全一样，所以共用一份解析。
/// 用**行首锚定**的 `^Key:`，否则 `MemTotal` 会匹配到 `MemTotalHuge` 之类
/// 的前缀同族键（meminfo 里这种成对出现的键不止一处）。
@visibleForTesting
int? parseKbField(String text, String key) {
  final match = RegExp('^$key:\\s+(\\d+)\\s*kB', multiLine: true).firstMatch(text);
  if (match == null) return null;
  final kb = int.tryParse(match.group(1)!);
  if (kb == null) return null;
  return kb * 1024;
}

/// `/proc/loadavg` → (1, 5, 15 分钟平均负载)。
///
/// 负载是**队列长度**，不是百分比：4 核机器上 4.0 表示「刚好跑满」，
/// 8.0 表示「有一倍的活排不上队」。它比 CPU 百分比更能抓住「盒子被榨干」
/// —— 因为 MediaCodec 的服务进程在别的进程里，不体现为本进程 CPU。
@visibleForTesting
(double, double, double)? parseLoadAvg(String text) {
  final parts = text.trim().split(RegExp(r'\s+'));
  if (parts.length < 3) return null;
  final a = double.tryParse(parts[0]);
  final b = double.tryParse(parts[1]);
  final c = double.tryParse(parts[2]);
  if (a == null || b == null || c == null) return null;
  return (a, b, c);
}

/// `/proc/self/io` → 某个累计字节计数。
@visibleForTesting
int? parseProcSelfIoBytes(String text, String key) {
  final match = RegExp('^$key:\\s+(\\d+)', multiLine: true).firstMatch(text);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// `df -k` 的输出 → 可用字节数。
///
/// ## 为什么用正则而不是按列 split
///
/// 挂载点里**可以有空格**（macOS 上很常见）。按空白 split 之后，
/// 「Available」的下标会随挂载点的空格数漂移，读出来的可能是 Used、
/// 甚至是挂载点本身，而**不会报错**。
///
/// 正则 `^\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%` 从左往右锚定：
/// 文件系统名 → 总块数 → 已用 → **可用** → 容量百分比。前四列在
/// Android 的 toybox `df` 与 macOS 的 BSD `df` 上都是纯数字且顺序一致，
/// 容量百分比是天然的终止锚点。
///
/// 表头行天然不匹配（`1024-blocks` 在 `(\d+)` 后面紧跟 `-` 而非空白），
/// 所以不需要特意跳过第一行。多行时取**最后一行** —— 我们只传一个路径，
/// 多行只可能出现在某些实现的额外输出里。
@visibleForTesting
int? parseDfAvailableBytes(String out) {
  final pattern = RegExp(r'^\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%');
  int? available;
  for (final line in out.split('\n')) {
    final match = pattern.firstMatch(line.trim());
    if (match == null) continue;
    available = int.tryParse(match.group(3)!);
  }
  return available == null ? null : available * 1024;
}

// ---------------------------------------------------------------------
// 纯函数：由两条读数算出的比率
// ---------------------------------------------------------------------

/// 进程 CPU 占用率（**单核口径**：400% = 4 个核全满）。
///
/// 必须**两条**读数才谈得上占用率 —— 单条只有累计时间，没有分母。
/// 所以第一次采样（没有基准）返回 null，调用方据此整段不写 CPU。
///
/// 三条「宁可返回 null 也不给错数」的守卫：
///   * 任一读数为 null → null（读不到 ≠ 空闲）；
///   * 间隔为 0 或负 → null（除零 / 时钟回拨）；
///   * 差值 < 0 → null（计数器回绕，或进程重启换了 `self`）。
@visibleForTesting
double? cpuPercentOfInterval({
  required int? prevTicks,
  required int? currTicks,
  required Duration? elapsed,
  int clockTicksPerSecond = kProcClockTicksPerSecond,
}) {
  if (prevTicks == null || currTicks == null) return null;
  final window = elapsed;
  if (window == null || window <= Duration.zero) return null;
  if (clockTicksPerSecond <= 0) return null;
  final delta = currTicks - prevTicks;
  if (delta < 0) return null;
  final seconds = window.inMicroseconds / 1000000;
  final cpuSeconds = delta / clockTicksPerSecond;
  return cpuSeconds / seconds * 100;
}

/// 系统 CPU 占用率（**全核合计**，0..100）。
///
/// 与进程那条不同，这里是「忙 jiffies / 总 jiffies」，本身就是一个比率，
/// 不需要知道核数。
@visibleForTesting
double? systemCpuPercentOfInterval({
  required int? prevBusy,
  required int? currBusy,
  required int? prevTotal,
  required int? currTotal,
}) {
  if (prevBusy == null || currBusy == null) return null;
  if (prevTotal == null || currTotal == null) return null;
  final busy = currBusy - prevBusy;
  final total = currTotal - prevTotal;
  if (total <= 0 || busy < 0) return null;
  return busy / total * 100;
}

/// 累计字节计数 → 每秒字节数。守卫同上。
@visibleForTesting
double? bytesPerSecondOfInterval({
  required int? prevBytes,
  required int? currBytes,
  required Duration? elapsed,
}) {
  if (prevBytes == null || currBytes == null) return null;
  final window = elapsed;
  if (window == null || window <= Duration.zero) return null;
  final delta = currBytes - prevBytes;
  if (delta < 0) return null;
  return delta / (window.inMicroseconds / 1000000);
}

// ---------------------------------------------------------------------
// 纯函数：拼日志行
// ---------------------------------------------------------------------

String _pct(double value) => '${value.toStringAsFixed(1)}%';

/// 把两条读数拼成**一行**日志。纯函数，方便把「缺哪个字段就少哪一段」
/// 这件事钉在测试里。
///
/// 读不到的字段**整段消失**，不会退化成 0 或「未知」——理由见类文档。
@visibleForTesting
String formatResourceLine({
  required int elapsedSeconds,
  required ResourceReading now,
  ResourceReading? prev,
  Duration? sincePrev,
  int cores = 1,
}) {
  final parts = <String>[];

  final procPct = cpuPercentOfInterval(
    prevTicks: prev?.procCpuTicks,
    currTicks: now.procCpuTicks,
    elapsed: sincePrev,
  );
  if (procPct != null) {
    // 「单核口径」这四个字必须写出来：电视盒子多为 4 核，48% 单核口径
    // 只占整机 12%，看着「不忙」其实是「一个核快满了」。少写这一句，
    // 读数会被系统性误读。
    final perChip = cores > 0 ? procPct / cores : null;
    parts.add(perChip == null
        ? '进程CPU=${_pct(procPct)}（单核口径）'
        : '进程CPU=${_pct(procPct)}（单核口径；折合 $cores 核 ${_pct(perChip)}）');
  }

  final sysPct = systemCpuPercentOfInterval(
    prevBusy: prev?.sysBusyTicks,
    currBusy: now.sysBusyTicks,
    prevTotal: prev?.sysTotalTicks,
    currTotal: now.sysTotalTicks,
  );
  if (sysPct != null) parts.add('系统CPU=${_pct(sysPct)}');

  final l1 = now.load1;
  final l5 = now.load5;
  final l15 = now.load15;
  if (l1 != null && l5 != null && l15 != null) {
    parts.add('负载=${l1.toStringAsFixed(2)}/'
        '${l5.toStringAsFixed(2)}/${l15.toStringAsFixed(2)}');
  }

  // 可运行进程数 —— `负载=` 读不到时的**替代读数**（目标电视上
  // `/proc/loadavg` 是 Permission denied）。
  //
  // ⚠️ 它是**绝对值**，脱离核数就没法读：4 核机器上 `14` 是 3.5 倍超订，
  // 16 核机器上同样的 `14` 等于空闲。所以核数必须一起写出来 ——
  // 少写这一句，读数会被系统性误读成「机器很闲」。
  if (now.procsRunning != null) {
    final running = now.procsRunning!;
    final oversub = cores > 0 ? running / cores : null;
    parts.add(oversub == null
        ? '可运行进程=$running'
        : '可运行进程=$running（$cores 核，超订 ${oversub.toStringAsFixed(2)}×）');
  }
  // 阻塞在磁盘 IO 上的进程。**只在 > 0 时才写**：常态就是 0，
  // 每拍都写一个 0 只会把这一行撑长，反而掩盖真正的异常。
  if ((now.procsBlocked ?? 0) > 0) {
    parts.add('阻塞IO进程=${now.procsBlocked}');
  }

  if (now.rssBytes != null) parts.add('进程内存=${formatBytes(now.rssBytes)}');
  if (now.threads != null) parts.add('线程=${now.threads}');

  final memory = <String>[];
  if (now.memAvailableBytes != null) {
    memory.add('可用 ${formatBytes(now.memAvailableBytes)}');
  }
  if (now.memTotalBytes != null) {
    memory.add('共 ${formatBytes(now.memTotalBytes)}');
  }
  if (memory.isNotEmpty) parts.add('系统内存=${memory.join('／')}');

  if (now.diskAvailableBytes != null) {
    parts.add('磁盘可用=${formatBytes(now.diskAvailableBytes)}');
  }

  final io = <String>[];
  final readRate = bytesPerSecondOfInterval(
    prevBytes: prev?.ioReadBytes,
    currBytes: now.ioReadBytes,
    elapsed: sincePrev,
  );
  if (readRate != null) io.add('读 ${formatBytes(readRate.round())}/s');
  final writeRate = bytesPerSecondOfInterval(
    prevBytes: prev?.ioWriteBytes,
    currBytes: now.ioWriteBytes,
    elapsed: sincePrev,
  );
  if (writeRate != null) io.add('写 ${formatBytes(writeRate.round())}/s');
  if (io.isNotEmpty) parts.add('进程磁盘IO=${io.join(' ')}');

  if (parts.isEmpty) return '第 ${elapsedSeconds}s：（无可用读数）';
  return '第 ${elapsedSeconds}s：${parts.join(' ')}';
}

// ---------------------------------------------------------------------
// 真实读数
// ---------------------------------------------------------------------

/// 读一次本机资源。**绝不抛** —— 它跑在播放路径上，读不到就是读不到。
Future<ResourceReading> readDeviceResources({String? diskPath}) async {
  int? rss;
  int? vmSize;
  int? threads;
  int? procTicks;
  int? sysBusy;
  int? sysTotal;
  int? memAvailable;
  int? memTotal;
  double? load1;
  double? load5;
  double? load15;
  int? ioRead;
  int? ioWrite;
  int? procsRunning;
  int? procsBlocked;

  // `/proc` 只在 Android / Linux 上有。macOS 上这些读全是 null，
  // 由下面的兜底补上内存那一项。
  if (Platform.isLinux || Platform.isAndroid) {
    final stat = await _readOrNull('/proc/self/stat');
    if (stat != null) {
      procTicks = parseProcSelfCpuTicks(stat);
      threads = parseProcSelfThreads(stat);
    }

    final status = await _readOrNull('/proc/self/status');
    if (status != null) {
      rss = parseKbField(status, 'VmRSS');
      vmSize = parseKbField(status, 'VmSize');
    }

    final sysStat = await _readOrNull('/proc/stat');
    if (sysStat != null) {
      final cpu = parseProcStatCpu(sysStat);
      if (cpu != null) {
        sysBusy = cpu.$1;
        sysTotal = cpu.$2;
      }
      // 同一个文件里就有 —— 不额外读一次盘。
      // ⚠️ 这两个字段是 `loadavg` 的**替代**：目标电视上 `/proc/loadavg`
      // 是 Permission denied（见 [parseProcStatProcs]）。
      final procs = parseProcStatProcs(sysStat);
      procsRunning = procs.$1;
      procsBlocked = procs.$2;
    }

    final meminfo = await _readOrNull('/proc/meminfo');
    if (meminfo != null) {
      memAvailable = parseKbField(meminfo, 'MemAvailable');
      memTotal = parseKbField(meminfo, 'MemTotal');
    }

    final loadavg = await _readOrNull('/proc/loadavg');
    if (loadavg != null) {
      final parsed = parseLoadAvg(loadavg);
      if (parsed != null) {
        load1 = parsed.$1;
        load5 = parsed.$2;
        load15 = parsed.$3;
      }
    }

    final io = await _readOrNull('/proc/self/io');
    if (io != null) {
      ioRead = parseProcSelfIoBytes(io, 'read_bytes');
      ioWrite = parseProcSelfIoBytes(io, 'write_bytes');
    }
  }

  // 没有 `/proc` 时的内存兜底：`dart:io` 自己知道 RSS。
  // ⚠️ 这是**跨平台**的（Linux / Android / macOS / Windows），
  // 但它只给常驻内存这一项，CPU 与负载在 macOS 上就只能留空。
  rss ??= _currentRssOrNull();

  final disk = await _readDiskAvailableBytes(diskPath ?? diag.supportPath);

  return ResourceReading(
    rssBytes: rss,
    vmSizeBytes: vmSize,
    threads: threads,
    procCpuTicks: procTicks,
    sysBusyTicks: sysBusy,
    sysTotalTicks: sysTotal,
    memAvailableBytes: memAvailable,
    memTotalBytes: memTotal,
    load1: load1,
    load5: load5,
    load15: load15,
    diskAvailableBytes: disk,
    ioReadBytes: ioRead,
    ioWriteBytes: ioWrite,
    procsRunning: procsRunning,
    procsBlocked: procsBlocked,
  );
}

/// 读一个文件，失败返回 null。**不抛**。
Future<String?> _readOrNull(String path) async {
  try {
    return await File(path).readAsString();
  } catch (_) {
    return null;
  }
}

/// `ProcessInfo.currentRss` 在某些平台会抛 `UnsupportedError`，兜住。
int? _currentRssOrNull() {
  try {
    final rss = ProcessInfo.currentRss;
    return rss > 0 ? rss : null;
  } catch (_) {
    return null;
  }
}

/// `df -k <path>` → 可用字节。
///
/// ⚠️ 用异步的 `Process.run` 而不是 `runSync`：这是**播放路径上的定时任务**，
/// 同步版会在主 isolate 上阻塞十几毫秒 —— 那就成了「诊断本身制造卡顿」，
/// 而诊断工具最不能干的就是这件事。
Future<int?> _readDiskAvailableBytes(String? path) async {
  try {
    final result = await Process.run('df', <String>['-k', path ?? '.']);
    if (result.exitCode != 0) return null;
    return parseDfAvailableBytes('${result.stdout}');
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------
// 探针
// ---------------------------------------------------------------------

/// 定时把资源读数写进诊断日志。**一个播放会话一个实例**，
/// 由引擎在 `open()` 里 `start()`、在 `stop()` / `dispose()` 里 `stop()`。
///
/// ## 为什么由引擎持有，而不是做成全局单例
///
///   * 采样只在**播放中**有意义 —— 常驻采样会把环形缓冲刷满，
///     把真正有用的启动日志挤掉。
///   * 引擎有明确的 `open` / `stop` / `dispose` 生命周期，是天然的边界；
///     而且两个引擎（media_kit / fvp）各持一个，fvp 那条路**至少**也能
///     留下周期性证据（它目前没有任何视频管线探针）。
class ResourceProbe {
  ResourceProbe({
    this.interval = defaultInterval,
    this.tag = '资源',
    ResourceReader? reader,
    DiagLog? log,
    String? diskPath,
  })  : _reader = reader ??
            (() => readDeviceResources(diskPath: diskPath ?? diag.supportPath)),
        _log = log ?? diag;

  /// 采样周期。见类文档里「为什么是 10 秒」。
  static const Duration defaultInterval = Duration(seconds: 10);

  final Duration interval;

  /// 日志标签。默认 `资源`，与 `解码` / `片源` 一样是定宽短标签，
  /// 便于在日志里按 `[资源]` 直接搜。
  final String tag;

  final ResourceReader _reader;
  final DiagLog _log;

  Timer? _timer;
  final Stopwatch _watch = Stopwatch();
  ResourceReading? _prev;
  Duration? _prevAt;
  bool _running = false;
  bool _emptyWarned = false;

  bool get isRunning => _running;

  /// 开始采样。重复调用只会重启（先停旧的）。
  ///
  /// 启动时**先量一拍当基准但不写日志**：CPU 占用率要两条读数才成立，
  /// 没有基准的话第一条日志（10 秒后）只能空着 CPU 那一段 —— 而它恰恰是
  /// 最想看的那段。基准这一拍只花一次几毫秒的文件读。
  void start() {
    stop();
    _running = true;
    _prev = null;
    _prevAt = null;
    _emptyWarned = false;
    _watch
      ..reset()
      ..start();
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
    unawaited(_tick(log: false));
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  /// 读一拍。[log] 为 false 时只更新基准，不写日志。
  ///
  /// 两处「静默」是有意的，理由同 `MediaKitPlaybackEngine._readNetSpeed`：
  /// 读不到不该影响播放，也不该自己变成日志刷屏源。
  Future<void> _tick({bool log = true}) async {
    ResourceReading now;
    try {
      now = await _reader();
    } catch (_) {
      // 读数本身出问题（`/proc` 不存在、权限、进程已被杀）：
      // 这一拍当没有。**不抛**。
      return;
    }
    // `await` 期间可能已经被 stop()（换集、退出播放）——
    // 在飞的那一拍作废，否则会把上一个会话的读数写进新会话的日志里。
    if (!_running) return;

    final prev = _prev;
    final prevAt = _prevAt;
    final nowAt = _watch.elapsed;
    _prev = now;
    _prevAt = nowAt;

    if (!log) return;

    if (now.isEmpty) {
      // 全空只提醒一次。每次都不停地报「读不到」比不报还糟 ——
      // 它会把环形缓冲刷满，正好把要排查的那段挤出去。
      if (!_emptyWarned) {
        _emptyWarned = true;
        _log.warn(tag, '读不到任何资源指标（这台设备没有 /proc，'
            '也没有可用的替代读数）；后续不再重复提醒');
      }
      return;
    }

    _log.info(
      tag,
      formatResourceLine(
        elapsedSeconds: nowAt.inSeconds,
        now: now,
        prev: prev,
        sincePrev: prevAt == null ? null : nowAt - prevAt,
        cores: _cores,
      ),
    );
  }

  /// 核数。拿不到就按 1 算 —— 那只会让「折合几核」那一段消失，
  /// 不会让读数本身出错。
  static int get _cores {
    try {
      final n = Platform.numberOfProcessors;
      return n > 0 ? n : 1;
    } catch (_) {
      return 1;
    }
  }
}
