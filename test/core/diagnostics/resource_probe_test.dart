import 'package:cloudcine/core/diagnostics/diag_log.dart';
import 'package:cloudcine/core/diagnostics/resource_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// 资源采样里**能脱离真机测**的那部分。
///
/// 真读数依赖 `/proc`（macOS 上没有）与 `df`，在 CI 上大半是空的；而这段
/// 代码真正的风险不在「读不到」，在**读错**：`/proc/self/stat` 的字段下标
/// 只要错一位，读到的就是隔壁字段的数字 —— 不报错、不崩，只是把 CPU 时间
/// 报成 nice 值，让人照着假读数去改参数。所以解析部分全部抽成纯函数，
/// 在这里逐位钉住。
void main() {
  group('procStatFields：comm 里的空格和括号不能把字段顶位', () {
    test('comm 含括号与空格时，下标仍然对得上', () {
      // ⚠️ 这是**唯一**会静默出错的地方：comm（进程名）被一对括号包着，
      // 而进程名允许含空格与括号。按空白 split 会让后面所有字段整体前移，
      // 于是「CPU 时间」读到的其实是别的字段。
      const stat = '12345 (my (weird) name) S 1 12345 0 0 -1 4194560 '
          '1234 0 0 0 120 45 0 0 20 0 42 0 987654 123456789 12345';
      final fields = procStatFields(stat);
      expect(fields, isNotNull);
      // f[0] 对应 stat 的第 3 个字段（state）
      expect(fields!.first, 'S');
      expect(fields[11], '120', reason: 'utime 必须是第 14 个字段');
      expect(fields[12], '45', reason: 'stime 必须是第 15 个字段');
      expect(fields[17], '42', reason: 'num_threads 必须是第 20 个字段');
    });

    test('没有右括号就返回 null，而不是猜', () {
      expect(procStatFields('12345 no-parens-here'), isNull);
    });
  });

  group('parseProcSelfCpuTicks / parseProcSelfThreads', () {
    const stat = '12345 (com.example.cloudcine) S 1 12345 0 0 -1 4194560 '
        '1234 0 0 0 120 45 0 0 20 0 42 0 987654 123456789 12345';

    test('CPU 时间 = utime + stime', () {
      expect(parseProcSelfCpuTicks(stat), 165);
    });

    test('线程数取第 20 个字段', () {
      expect(parseProcSelfThreads(stat), 42);
    });

    test('字段不够长时返回 null —— 「读不到」不能伪装成 0', () {
      // 把尾部砍掉，让 num_threads 那一格不存在。
      const short = '12345 (x) S 1 2 3';
      expect(parseProcSelfCpuTicks(short), isNull);
      expect(parseProcSelfThreads(short), isNull);
    });

    test('非数字字段返回 null', () {
      const broken = '1 (x) S 1 2 3 4 5 6 7 8 9 abc def 0 0 0 0 xyz';
      expect(parseProcSelfCpuTicks(broken), isNull);
    });
  });

  group('parseProcStatCpu：忙 = 总 − idle − iowait', () {
    test('iowait 不算忙 —— 它恰恰是「在等磁盘」', () {
      // 用户态 1000、nice 200、system 300、idle 5000、iowait 400。
      // 总 = 1000+200+300+5000+400+50+60 = 7010
      // 忙 = 7010 − 5000 − 400 = 1610
      const stat = 'cpu  1000 200 300 5000 400 50 60 0 0 0\n'
          'cpu0 500 100 150 2500 200 25 30 0 0 0\n'
          'intr 12345\n';
      final parsed = parseProcStatCpu(stat);
      expect(parsed, isNotNull);
      expect(parsed!.$1, 1610, reason: '忙 jiffies');
      expect(parsed.$2, 7010, reason: '总 jiffies');
    });

    test('只认汇总行 cpu，不认 cpu0 —— 用每核行会让「系统 CPU」变成单核读数', () {
      const stat = 'cpu0 500 100 150 2500 200 25 30 0 0 0\n'
          'cpu  1000 200 300 5000 400 50 60 0 0 0\n';
      final parsed = parseProcStatCpu(stat);
      expect(parsed!.$2, 7010);
    });

    test('没有 cpu 行时返回 null', () {
      expect(parseProcStatCpu('intr 1 2 3\nctxt 4\n'), isNull);
    });
  });

  group('parseProcStatProcs：loadavg 读不到时的替代读数', () {
    // 这台电视（MiTV，Android 9）上 `/proc/loadavg` 是 Permission denied，
    // 而 `/proc/stat` 完全可读 —— 所以这两个字段是「机器有多忙」的唯一来源。
    const stat = '''
cpu  123 45 678 9012 34 56 78 90 0 0
cpu0 1 2 3 4 5 6 7 8 0 0
intr 12345
ctxt 67890
btime 1700000000
processes 1234
procs_running 14
procs_blocked 3
softirq 111 222 333
''';

    test('取到运行中与阻塞中两个数', () {
      final (running, blocked) = parseProcStatProcs(stat);
      expect(running, 14);
      expect(blocked, 3);
    });

    test('⚠️ 别把 processes 当成 procs_running', () {
      // `processes` 是「开机以来创建过多少个进程」—— 一个只增不减的大数，
      // 拿它当瞬时值会得到「机器永远在 3 倍超订」的假警报。
      final (running, _) = parseProcStatProcs(stat);
      expect(running, isNot(1234));
    });

    test('缺行返回 null，而不是 0 —— 「读不到」不能伪装成「空闲」', () {
      final (running, blocked) = parseProcStatProcs('cpu  1 2 3 4 5 6 7 8\n');
      expect(running, isNull);
      expect(blocked, isNull);
    });

    test('值不是数字时返回 null', () {
      final (running, _) = parseProcStatProcs('procs_running abc\n');
      expect(running, isNull);
    });
  });

  group('parseKbField：/proc 的 `Key:  123 kB` → 字节', () {
    test('status 里的 VmRSS', () {
      const status = 'Name:\tcom.example.cloudcine\n'
          'VmPeak:\t 3456789 kB\n'
          'VmSize:\t 3234567 kB\n'
          'VmRSS:\t  812345 kB\n'
          'Threads:\t42\n';
      expect(parseKbField(status, 'VmRSS'), 812345 * 1024);
      expect(parseKbField(status, 'VmSize'), 3234567 * 1024);
    });

    test('meminfo 里的 MemAvailable 不会误取到 MemTotal', () {
      const meminfo = 'MemTotal:        3886100 kB\n'
          'MemFree:          123456 kB\n'
          'MemAvailable:    1234567 kB\n';
      expect(parseKbField(meminfo, 'MemAvailable'), 1234567 * 1024);
      expect(parseKbField(meminfo, 'MemTotal'), 3886100 * 1024);
    });

    test('键必须整词匹配 —— 前缀相同的键不能互相串', () {
      // 防的是「没锚行首」这种写法：那样 `MemTotal` 会命中 `MemTotalX`。
      // 现实里的 meminfo 键名成对出现（如 MemFree/MemAvailable），
      // 加锚是为了以后新增键时不踩这个坑。
      const text = 'MemTotalExtra:   999 kB\nMemTotal:        100 kB\n';
      expect(parseKbField(text, 'MemTotal'), 100 * 1024);
    });

    test('单位不是 kB 就不认（宁可读不到，也不给错数）', () {
      expect(parseKbField('MemTotal: 100 MB\n', 'MemTotal'), isNull);
    });

    test('键不存在返回 null', () {
      expect(parseKbField('MemTotal: 100 kB\n', 'Nope'), isNull);
    });
  });

  group('parseLoadAvg', () {
    test('取前三个数', () {
      final parsed = parseLoadAvg('0.52 0.41 0.38 1/1234 5678');
      expect(parsed, isNotNull);
      expect(parsed!.$1, 0.52);
      expect(parsed.$2, 0.41);
      expect(parsed.$3, 0.38);
    });

    test('字段不足返回 null', () {
      expect(parseLoadAvg('0.52 0.41'), isNull);
      expect(parseLoadAvg(''), isNull);
    });
  });

  group('parseProcSelfIoBytes', () {
    test('取 read_bytes / write_bytes，而不是 rchar / wchar', () {
      // ⚠️ rchar/wchar 把页缓存也算进去，读一个缓存命中的文件也会涨 ——
      // 而这里要回答的是「磁盘累不累」。
      const io = 'rchar: 99999999\n'
          'wchar: 88888888\n'
          'read_bytes: 4096\n'
          'write_bytes: 65536\n';
      expect(parseProcSelfIoBytes(io, 'read_bytes'), 4096);
      expect(parseProcSelfIoBytes(io, 'write_bytes'), 65536);
    });

    test('键不存在返回 null', () {
      expect(parseProcSelfIoBytes('rchar: 1\n', 'read_bytes'), isNull);
    });
  });

  group('parseDfAvailableBytes：挂载点里有空格也不能读错列', () {
    test('Android toybox 的形状', () {
      const out = 'Filesystem     1K-blocks     Used Available Use% Mounted on\n'
          '/dev/block/mmcblk0p30 11534336 2345678 9188658  21% /data\n';
      expect(parseDfAvailableBytes(out), 9188658 * 1024);
    });

    test('macOS BSD df 的形状（列更多，且表头带 1024-blocks）', () {
      const out = 'Filesystem   1024-blocks      Used Available Capacity '
          'iused      ifree %iused  Mounted on\n'
          '/dev/disk3s1s1   971350180  12345678 234567890    10%  '
          '567890 1234567890    0%   /\n';
      expect(parseDfAvailableBytes(out), 234567890 * 1024);
    });

    test('挂载点含空格时仍然取「可用」那一列', () {
      // 按空白 split 的写法在这里会整体右移，读出来是 Used 或者挂载点本身。
      const out = '/dev/disk4s1 100 20 70 20% /Volumes/My Passport\n';
      expect(parseDfAvailableBytes(out), 70 * 1024);
    });

    test('表头行不会被当成数据行', () {
      const out = 'Filesystem 1024-blocks Used Available Capacity Mounted on\n';
      expect(parseDfAvailableBytes(out), isNull);
    });

    test('空输出返回 null', () {
      expect(parseDfAvailableBytes(''), isNull);
    });
  });

  group('cpuPercentOfInterval：单核口径', () {
    test('一个核跑满 = 100%', () {
      // 100 jiffies/s，1 秒里烧掉 100 jiffies = 1 秒 CPU 时间。
      expect(
        cpuPercentOfInterval(
          prevTicks: 0,
          currTicks: 100,
          elapsed: const Duration(seconds: 1),
        ),
        100,
      );
    });

    test('四个核跑满 = 400%（这是「单核口径」的意思）', () {
      // 电视盒子多为 4 核：400% 才是「整机满载」。日志里必须写清口径，
      // 否则 48% 会被读成「很闲」。
      expect(
        cpuPercentOfInterval(
          prevTicks: 0,
          currTicks: 400,
          elapsed: const Duration(seconds: 1),
        ),
        400,
      );
    });

    test('缺基准就返回 null，而不是拿累计时间当占用率', () {
      expect(
        cpuPercentOfInterval(
          prevTicks: null,
          currTicks: 100,
          elapsed: const Duration(seconds: 1),
        ),
        isNull,
      );
    });

    test('间隔为 0 返回 null（不能除零）', () {
      expect(
        cpuPercentOfInterval(
          prevTicks: 0,
          currTicks: 100,
          elapsed: Duration.zero,
        ),
        isNull,
      );
    });

    test('计数器变小返回 null（回绕 / 进程重启）', () {
      expect(
        cpuPercentOfInterval(
          prevTicks: 500,
          currTicks: 100,
          elapsed: const Duration(seconds: 1),
        ),
        isNull,
      );
    });
  });

  group('systemCpuPercentOfInterval', () {
    test('忙 1610 / 总 7010 → 约 23%', () {
      final pct = systemCpuPercentOfInterval(
        prevBusy: 0,
        currBusy: 1610,
        prevTotal: 0,
        currTotal: 7010,
      );
      expect(pct, closeTo(22.97, 0.01));
    });

    test('总 jiffies 没有增长返回 null', () {
      expect(
        systemCpuPercentOfInterval(
          prevBusy: 1,
          currBusy: 2,
          prevTotal: 100,
          currTotal: 100,
        ),
        isNull,
      );
    });
  });

  group('bytesPerSecondOfInterval', () {
    test('1 秒写 1 MiB = 1048576 B/s', () {
      expect(
        bytesPerSecondOfInterval(
          prevBytes: 0,
          currBytes: 1048576,
          elapsed: const Duration(seconds: 1),
        ),
        1048576,
      );
    });

    test('计数器变小返回 null', () {
      expect(
        bytesPerSecondOfInterval(
          prevBytes: 10,
          currBytes: 5,
          elapsed: const Duration(seconds: 1),
        ),
        isNull,
      );
    });
  });

  group('formatResourceLine：读不到的字段整段消失', () {
    const full = ResourceReading(
      rssBytes: 800 * 1024 * 1024,
      threads: 42,
      procCpuTicks: 100,
      sysBusyTicks: 1610,
      sysTotalTicks: 7010,
      memAvailableBytes: 1200 * 1024 * 1024,
      memTotalBytes: 3800 * 1024 * 1024,
      load1: 3.2,
      load5: 2.8,
      load15: 2.4,
      diskAvailableBytes: 8 * 1024 * 1024 * 1024,
      ioReadBytes: 0,
      ioWriteBytes: 0,
    );

    /// 上一拍的读数。⚠️ 它必须和 [full] **真的不一样** —— 占用率是两条读数
    /// 之差，拿同一条读数当基准，差值是 0，`systemCpuPercentOfInterval` 会
    /// 因为「总 jiffies 没涨」而返回 null，于是断言「有系统CPU」就会失败。
    /// （这不是测试的迂腐：真实场景里读数永远在变，同值只可能是采样坏了。）
    const baseline = ResourceReading(
      procCpuTicks: 0,
      sysBusyTicks: 100,
      sysTotalTicks: 1000,
      ioReadBytes: 0,
      ioWriteBytes: 0,
    );

    test('CPU 口径必须写明，否则 48% 会被误读', () {
      final line = formatResourceLine(
        elapsedSeconds: 30,
        now: full,
        prev: baseline,
        sincePrev: const Duration(seconds: 10),
        cores: 4,
      );
      expect(line, startsWith('第 30s：'));
      expect(line, contains('单核口径'));
      expect(line, contains('折合 4 核'));
      expect(line, contains('系统CPU='));
      expect(line, contains('负载=3.20/2.80/2.40'));
      expect(line, contains('进程内存=800.0 MB'));
      expect(line, contains('线程=42'));
      expect(line, contains('系统内存=可用 1.2 GB／共 3.7 GB'));
      expect(line, contains('磁盘可用=8.0 GB'));
    });

    test('⚠️ 可运行进程必须带核数，否则 14 会被读成「很闲」', () {
      // 14 在 4 核上是 3.5 倍超订（机器被榨干），在 16 核上等于空闲 ——
      // 同一个数字两种结论，所以核数必须写在同一段里。
      const busy = ResourceReading(procsRunning: 14, procsBlocked: 0);
      final line = formatResourceLine(
        elapsedSeconds: 40,
        now: busy,
        prev: baseline,
        sincePrev: const Duration(seconds: 10),
        cores: 4,
      );
      expect(line, contains('可运行进程=14'));
      expect(line, contains('4 核'));
      expect(line, contains('超订 3.50×'));
    });

    test('阻塞进程为 0 时不写 —— 常态就是 0，写了只会掩盖异常', () {
      const idle = ResourceReading(procsRunning: 2, procsBlocked: 0);
      final line = formatResourceLine(
        elapsedSeconds: 40,
        now: idle,
        prev: baseline,
        sincePrev: const Duration(seconds: 10),
        cores: 4,
      );
      expect(line, contains('可运行进程=2'));
      expect(line, isNot(contains('阻塞IO进程')));
    });

    test('阻塞进程大于 0 时写出来 —— 那是「有活卡在磁盘上」', () {
      const stuck = ResourceReading(procsRunning: 2, procsBlocked: 5);
      final line = formatResourceLine(
        elapsedSeconds: 40,
        now: stuck,
        prev: baseline,
        sincePrev: const Duration(seconds: 10),
        cores: 4,
      );
      expect(line, contains('阻塞IO进程=5'));
    });

    test('读不到 procs 时整段消失（macOS 没有 /proc/stat）', () {
      const noProcs = ResourceReading(rssBytes: 100 * 1024 * 1024);
      final line = formatResourceLine(
        elapsedSeconds: 40,
        now: noProcs,
        prev: baseline,
        sincePrev: const Duration(seconds: 10),
        cores: 4,
      );
      expect(line, isNot(contains('可运行进程')));
      expect(line, isNot(contains('阻塞IO进程')));
    });

    test('没有基准时整段不写 CPU，而不是写 0%', () {
      final line = formatResourceLine(
        elapsedSeconds: 10,
        now: full,
        prev: null,
        sincePrev: null,
        cores: 4,
      );
      expect(line, isNot(contains('进程CPU=')));
      expect(line, isNot(contains('系统CPU=')));
      // 其余读数照写 —— 缺一段不该把整行吞掉。
      expect(line, contains('进程内存='));
    });

    test('macOS 那种「只有内存和磁盘」的读数也能成行', () {
      const macOnly = ResourceReading(
        rssBytes: 500 * 1024 * 1024,
        diskAvailableBytes: 100 * 1024 * 1024 * 1024,
      );
      final line = formatResourceLine(
        elapsedSeconds: 20,
        now: macOnly,
        prev: macOnly,
        sincePrev: const Duration(seconds: 10),
        cores: 8,
      );
      expect(line, contains('进程内存=500.0 MB'));
      expect(line, contains('磁盘可用='));
      expect(line, isNot(contains('系统CPU=')));
      expect(line, isNot(contains('负载=')));
      expect(line, isNot(contains('线程=')));
    });

    test('一个字段都没有时给一行明确的说明，而不是空串', () {
      final line = formatResourceLine(
        elapsedSeconds: 10,
        now: const ResourceReading(),
      );
      expect(line, '第 10s：（无可用读数）');
    });

    test('系统内存只读到一项时不留悬空的分隔符', () {
      final line = formatResourceLine(
        elapsedSeconds: 10,
        now: const ResourceReading(memTotalBytes: 1024 * 1024 * 1024),
      );
      expect(line, contains('系统内存=共 1.0 GB'));
      expect(line, isNot(contains('／')));
    });
  });

  group('ResourceProbe：生命周期与静默', () {
    test('start() 先量基准：第一条日志就已经带 CPU', () async {
      final log = DiagLog.forTesting();
      var reads = 0;
      final probe = ResourceProbe(
        interval: const Duration(milliseconds: 20),
        log: log,
        reader: () async {
          reads++;
          // 每拍烧掉 1 秒 CPU，间隔 20ms → 读数一定是个正数。
          return ResourceReading(procCpuTicks: reads * 100);
        },
      );

      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 140));
      probe.stop();

      final lines =
          log.lines.where((l) => l.contains('[资源]')).toList(growable: false);
      expect(lines.length, greaterThanOrEqualTo(2));
      // 基准那一拍只读、不写 —— 它存在的唯一目的就是给 CPU 当分母。
      expect(reads, greaterThan(lines.length));
      // 也正因为有基准，第一条日志就带得上 CPU；否则最想看的那段要等到
      // 第二拍才出现（第一条只能空着 CPU）。
      expect(lines.first, contains('进程CPU='));
      expect(lines.last, contains('进程CPU='));
      expect(lines.first, contains('INFO'));
    });

    test('stop() 之后不再写日志', () async {
      final log = DiagLog.forTesting();
      final probe = ResourceProbe(
        interval: const Duration(milliseconds: 10),
        log: log,
        reader: () async => const ResourceReading(rssBytes: 1024),
      );

      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      probe.stop();
      expect(probe.isRunning, isFalse);

      final after = log.lines.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(log.lines.length, after,
          reason: '停了还在写 = 换集之后日志里会混进上一个会话的读数');
    });

    test('全空只提醒一次，不刷屏', () async {
      final log = DiagLog.forTesting();
      final probe = ResourceProbe(
        interval: const Duration(milliseconds: 10),
        log: log,
        reader: () async => const ResourceReading(),
      );

      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 90));
      probe.stop();

      final resource =
          log.lines.where((l) => l.contains('[资源]')).toList(growable: false);
      expect(resource.length, 1, reason: '每次都不停地报「读不到」比不报还糟');
      expect(resource.single, contains('WARN'));
      expect(resource.single, contains('读不到任何资源指标'));
    });

    test('读数抛异常时静默跳过，绝不影响播放', () async {
      final log = DiagLog.forTesting();
      final probe = ResourceProbe(
        interval: const Duration(milliseconds: 10),
        log: log,
        reader: () async => throw Exception('读 /proc 失败'),
      );

      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      probe.stop();

      expect(log.lines.where((l) => l.contains('[资源]')), isEmpty);
    });
  });
}
