import 'package:cloudcine/data/stream/relay_reader_arbiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // window=8 块、minStreamBytes=8 MiB：阈值本身由中继按预取窗口换算。
  RelayReaderArbiter build() =>
      RelayReaderArbiter(window: 8, minStreamBytes: 8 * 1024 * 1024);

  group('isStream', () {
    test('开放式 Range（放到文件尾）算在放片子', () {
      // mpv/ffmpeg 播放时一律发 `bytes=N-`，范围动辄几个 GiB。
      expect(build().isStream(17 * 1024 * 1024 * 1024), isTrue);
    });

    test('读文件尾那一小段（MKV 的 Cues）不算 —— 那是探索引', () {
      // 实测 mpv 开流时会请求 bytes=18351436158-，只剩 2 块。若让它推动锚点，
      // 预取窗口会整个挪到文件末尾，正在播的位置立刻饿死。
      expect(build().isStream(4 * 1024 * 1024), isFalse);
    });
  });

  group('RelayReaderArbiter', () {
    test('起播：第一个在放片子的读取器接管锚点', () {
      final arbiter = build();
      arbiter.attach(1, stream: true);
      expect(arbiter.currentReader, 1);
      expect(arbiter.decide(readerId: 1, index: 100), ReaderDemand.anchor);
      expect(arbiter.anchor, 100);
    });

    test('顺读：锚点跟着当前读取器一格一格推进', () {
      final arbiter = build();
      arbiter.attach(1, stream: true);
      for (var i = 100; i <= 105; i++) {
        expect(arbiter.decide(readerId: 1, index: i), ReaderDemand.anchor);
      }
      expect(arbiter.anchor, 105);
    });

    test('并行连接落在窗口内：照常服务，且只能把窗口往前推', () {
      // mpv 一条流常开好几个连接（实测 2 个），位置彼此很近。
      // 它们都能立刻拿到数据，但**不能**各自去改窗口 —— 否则窗口会被拽来拽去。
      final arbiter = build();
      arbiter.attach(1, stream: true);
      arbiter.decide(readerId: 1, index: 100);

      // 落在后面：不许往回拖。
      expect(arbiter.decide(readerId: 2, index: 96), ReaderDemand.serve);
      expect(arbiter.anchor, 100, reason: '往回拖会把窗口拽在播放头身后');

      // 落在前面：允许往前推（万一当家的那个不动了，窗口还能走）。
      expect(arbiter.decide(readerId: 2, index: 104), ReaderDemand.serve);
      expect(arbiter.anchor, 104);
    });

    test('seek：新开的在放片子的读取器直接接管（不需要两次确认）', () {
      final arbiter = build();
      arbiter.attach(1, stream: true);
      arbiter.decide(readerId: 1, index: 100);

      // 拖进度条 → 新连接。它一到达就是当前读取器。
      arbiter.attach(2, stream: true);
      expect(arbiter.currentReader, 2);
      expect(arbiter.decide(readerId: 2, index: 1800), ReaderDemand.anchor);
      expect(arbiter.anchor, 1800);
    });

    test('拉锯复现：被抛弃的旧读取器不得把锚点拽回去', () {
      // 这是实测到的真实故障序列（真 libmpv + 真夸克原画，seek 到 1500s）：
      // 旧读取器 A 一直留在原处继续读，新读取器 C 跳到了远处。
      // 修复前锚点在 92 ↔ 1779 之间反复拉锯，8 路 worker 被来回改派，
      // 旧位置吃掉 78% 带宽，新位置饿死 —— 这就是「拖完进度条看一会卡一会」。
      final arbiter = build();
      arbiter.attach(1, stream: true);
      arbiter.decide(readerId: 1, index: 70);
      arbiter.decide(readerId: 1, index: 91);

      arbiter.attach(3, stream: true); // C 拖到远处
      expect(arbiter.decide(readerId: 3, index: 1779), ReaderDemand.anchor);
      expect(arbiter.anchor, 1779);

      // A 继续在原处读 —— 关键断言：锚点必须留在新位置。
      for (var i = 92; i <= 120; i++) {
        expect(arbiter.decide(readerId: 1, index: i), ReaderDemand.stale,
            reason: '旧读取器只能进低优先队列，不许抢 worker');
      }
      expect(arbiter.anchor, 1779, reason: '旧读取器绝不允许拽走预取窗口');

      // C 照常顺读。
      expect(arbiter.decide(readerId: 3, index: 1781), ReaderDemand.anchor);
      expect(arbiter.anchor, 1781);
    });

    test('探索引：读文件尾那几块照常立刻服务，但不动锚点', () {
      final arbiter = build();
      arbiter.attach(1, stream: true);
      arbiter.decide(readerId: 1, index: 100);

      arbiter.attach(2, stream: false); // 短范围
      expect(arbiter.currentReader, 1, reason: '探索引不得篡位');
      for (final index in [9000, 9001]) {
        expect(arbiter.decide(readerId: 2, index: index), ReaderDemand.serve,
            reason: '探索引必须马上拿到数据，否则开流会卡在等索引');
      }
      expect(arbiter.anchor, 100);
    });

    test('当前读取器自己跳远：立刻换锚点', () {
      // 同一个连接上再 seek（ffmpeg 的 http 层会复用连接发新请求）。
      final arbiter = build();
      arbiter.attach(1, stream: true);
      arbiter.decide(readerId: 1, index: 100);
      expect(arbiter.decide(readerId: 1, index: 1800), ReaderDemand.anchor);
      expect(arbiter.anchor, 1800);
    });

    test('当前读取器结束：让位给下一个在放片子的读取器', () {
      // 让不了位的话锚点再没人推动、窗口冻在原地 ——
      // 表现是「画面停住不动，日志里却没有任何错误」。
      final arbiter = build();
      arbiter.attach(1, stream: true);
      arbiter.attach(2, stream: true);
      expect(arbiter.currentReader, 2);

      arbiter.release(2);
      expect(arbiter.currentReader, 1, reason: '应让位给还在的那个');

      arbiter.release(1);
      expect(arbiter.currentReader, isNull);
      // 都没了：下一个来的读取器接管。
      expect(arbiter.decide(readerId: 5, index: 500), ReaderDemand.anchor);
      expect(arbiter.anchor, 500);
    });

    test('释放探索引：不影响当前读取器', () {
      final arbiter = build();
      arbiter.attach(1, stream: true);
      arbiter.attach(2, stream: false);
      arbiter.release(2);
      expect(arbiter.currentReader, 1);
      expect(arbiter.streamReaderCount, 1);
    });

    test('重复 attach 同一个读取器不会重复计数', () {
      final arbiter = build();
      arbiter.attach(1, stream: true);
      arbiter.attach(1, stream: true);
      expect(arbiter.streamReaderCount, 1);
      arbiter.release(1);
      expect(arbiter.currentReader, isNull);
    });

    test('seed：把锚点摆到续播点，读取器一到就接管', () {
      final arbiter = build();
      arbiter.seed(900);
      expect(arbiter.anchor, 900);
      expect(arbiter.currentReader, isNull);
      arbiter.attach(1, stream: true);
      expect(arbiter.decide(readerId: 1, index: 900), ReaderDemand.anchor);
      expect(arbiter.currentReader, 1);
    });

    test('seed 负值夹到 0', () {
      final arbiter = build();
      arbiter.seed(-5);
      expect(arbiter.anchor, 0);
    });
  });
}
