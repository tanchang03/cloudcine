import 'package:cloudcine/domain/services/cache_speed_meter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 缓存速度的估算规则。
///
/// 这个类的输出会直接印在缓冲指示上 —— **数字乱跳比没有数字更糟**：
/// 用户会以为网速在抖。所以这里的每一条都不是「结果等于几」，
/// 而是「不该出现什么假象」。
void main() {
  // 一个可以手动走的时钟，避免测试真的去 sleep。
  DateTime clock = DateTime.utc(2026, 1, 1);
  CacheSpeedMeter meter() => CacheSpeedMeter(now: () => clock);

  Duration sec(num v) => Duration(milliseconds: (v * 1000).round());

  /// 走一拍时间再喂一个缓存量，返回这一拍算出来的倍速。
  ///
  /// ⚠️ 必须**先走时间再喂值**：反过来（同一个时刻喂两个值）会让首尾两点
  /// 相距 0 秒，算出「瞬间涨了 N 秒」这种假速度 —— 那正是这一类估算最常
  /// 出的错，测试里也要跟着守规矩。
  double? step(CacheSpeedMeter m, num seconds, [Duration by = const Duration(seconds: 1)]) {
    clock = clock.add(by);
    return m.accept(sec(seconds));
  }

  test('第一个样本不出数（一个点算不出斜率）', () {
    final m = meter();
    expect(m.accept(sec(0)), isNull, reason: '返回 null 而不是 0');
  });

  test('跨度太短不出数（避免舍入误差被放大成几十倍）', () {
    final m = meter();
    m.accept(sec(0));
    expect(
      step(m, 3, const Duration(milliseconds: 50)),
      isNull,
      reason: '50ms 里涨 3 秒会被算成 60×，是假数字',
    );
  });

  test('匀速缓存：倍速是 1', () {
    final m = meter();
    m.accept(sec(0));
    double? speed;
    for (var i = 1; i <= 10; i++) {
      speed = step(m, i);
    }
    // 每秒缓存 1 秒视频 —— 这正好是「下载与播放持平」的分界线。
    expect(speed, closeTo(1.0, 0.01));
  });

  test('比播放快：倍速大于 1', () {
    final m = meter();
    m.accept(sec(0));
    double? speed;
    for (var i = 1; i <= 8; i++) {
      speed = step(m, i * 3);
    }
    expect(speed, closeTo(3.0, 0.01));
  });

  test('阶梯状增长不会出尖峰', () {
    // 切片式下载（HLS 就是）：缓存量长时间不动，然后一次性跳一大截。
    // 拿相邻两点算会得到 0 与 ∞ 交替；窗口平均之后应当还是真实速度。
    final m = meter();
    m.accept(sec(0));
    double? speed;
    for (var i = 1; i <= 8; i++) {
      step(m, (i - 1) * 3); // 不动
      step(m, (i - 1) * 3); // 还不动
      speed = step(m, i * 3); // 跳 3 秒
    }
    expect(speed, isNotNull);
    expect(speed!, closeTo(1.0, 0.2), reason: '阶梯不该被显示成剧烈抖动的速度');
  });

  test('换片源导致缓存归零时不沿用旧样本', () {
    final m = meter();
    m.accept(sec(0));
    for (var i = 1; i <= 6; i++) {
      step(m, i * 5);
    }
    // 换了一部片：缓存清零。若不作废旧样本，分母（时间）会跨越换片点，
    // 算出一个离谱的负数。
    expect(step(m, 0), isNull, reason: '换片后第一个样本要重新起算');

    double? speed;
    for (var i = 1; i <= 6; i++) {
      speed = step(m, i);
    }
    expect(speed, closeTo(1.0, 0.01));
  });

  test('seek 造成的小幅回退同样作废样本', () {
    final m = meter();
    m.accept(sec(0));
    for (var i = 1; i <= 6; i++) {
      step(m, i * 2);
    }
    // 跳回去，缓存作废。不是归零（seek 之后 mpv 也会缓存一点），
    // 所以判据是「比上一个值小」而不是「等于 0」。
    step(m, 1);

    double? speed;
    for (var i = 2; i <= 6; i++) {
      speed = step(m, i);
    }
    expect(speed, closeTo(1.0, 0.01));
  });

  test('窗口过期后速度跟着变（反映最近一段，不是整段平均）', () {
    final m = meter();
    m.accept(sec(0));
    double? slow;
    // 前 10 秒很慢：每秒只缓存 0.1 秒。
    for (var i = 1; i <= 10; i++) {
      slow = step(m, i * 0.1);
    }
    expect(slow, closeTo(0.1, 0.02));

    // 突然变快：每秒 5 秒。窗口 8 秒，所以要走满一个窗口之后才该完全跟上
    // 新速度（前几拍必然还带着旧速度的尾巴，这是窗口平均该有的代价）；
    // 但**必须**跟得上 —— 否则用户会以为网速没恢复。
    double? fast;
    for (var i = 1; i <= 9; i++) {
      fast = step(m, 1.0 + i * 5);
    }
    expect(fast, closeTo(5.0, 0.2));
  });

  test('reset 之后重新起算', () {
    final m = meter();
    m.accept(sec(0));
    for (var i = 1; i <= 6; i++) {
      step(m, i * 4);
    }
    m.reset();
    expect(m.accept(sec(0)), isNull);

    double? speed;
    for (var i = 1; i <= 6; i++) {
      speed = step(m, i);
    }
    expect(speed, closeTo(1.0, 0.01));
  });
}
