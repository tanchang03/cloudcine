import 'package:cloudcine/core/utils/player_buffer_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// mpv 缓冲参数 —— 桌面与电视两套。
///
/// 为什么值得测：这组数字**改错了不会报错**。把 1 GB 留在电视上，应用照样
/// 能播，只是每过一会儿卡一下；而开发机（桌面）上永远复现不出来。
/// 于是唯一能挡住它的就是断言。
void main() {
  group('桌面那一套保持原值', () {
    test('1 GB 缓存 / 无限预读 / 关 stream 缓存', () {
      expect(PlayerBufferConfig.bufferSizeFor(tv: false), 1024 * 1024 * 1024);
      expect(PlayerBufferConfig.readaheadSecsFor(tv: false), '9999');
      expect(PlayerBufferConfig.disableStreamCacheFor(tv: false), isTrue);
    });
  });

  group('电视那一套', () {
    test('缓存显著小于桌面 —— 1 GB 会持续往 eMMC 写', () {
      final tv = PlayerBufferConfig.bufferSizeFor(tv: true);

      expect(
        tv,
        lessThan(PlayerBufferConfig.bufferSizeFor(tv: false)),
        reason: 'media_kit 硬编码了 cache-on-disk=yes，超出的部分落盘；'
            '电视盒子的 eMMC 比桌面 SSD 慢一个数量级',
      );
    });

    test('但也不能小到扛不住一次网络抖动', () {
      // 下限取 100 MB：8 Mbps 的片子 ≈ 100 秒。低于这个量级，一次几秒的
      // Wi-Fi 掉速就会直接打到播放头 —— 那正是「卡帧」最直观的来源。
      expect(
        PlayerBufferConfig.bufferSizeFor(tv: true),
        greaterThanOrEqualTo(100 * 1024 * 1024),
      );
    });

    test('预读有上限 —— 9999 会让 mpv 全程全速拉流', () {
      // 电视上的 SoC 要同时跑解码、网络、UI。让播放器一路拉到底，
      // 等于把这三样一起饿死。
      expect(
        int.parse(PlayerBufferConfig.readaheadSecsFor(tv: true)),
        lessThan(600),
      );
    });

    test('开回 stream 缓存：电视上没人看那个 KB/s，抖动却直接变卡顿', () {
      // 桌面上关掉它是为了让界面上的「缓冲网速」等于真实下载速率。
      // 电视上那个数字没人看，而它挡住的抖动是实实在在的。
      expect(PlayerBufferConfig.disableStreamCacheFor(tv: true), isFalse);
    });
  });

  group('硬件解码：只有电视开', () {
    test('电视下发 auto-safe', () {
      // 背景：mpv 的 `hwdec` 默认是 `no`（纯软解），media_kit 那张默认属性表
      // 里**也没有这一项** —— 全项目搜 `hwdec` 一处都没有。
      // 于是电视盒子一直在软解高码率原画，而那颗 SoC 通常只够软解 1080p：
      // 解码跟不上音频 → mpv 跳帧追主时钟 → 「卡帧 + 音画不同步」。
      // 缓冲参数解决不了这一条 —— 那是「数据没到位」，这是「解码跟不上」。
      expect(PlayerBufferConfig.hwdecFor(tv: true), 'auto-safe');
    });

    test('桌面**不下发**这一项 —— 返回 null，不是 "no"', () {
      // ⛔ 返回 `'no'` 也是改了桌面行为：那会把 mpv 的默认**显式化**，
      // 并且挡住将来有人给桌面开硬解。`null` 才表示「apply 里根本不会调
      // setProperty」—— 这是「桌面代码不动」那条要求的守卫。
      expect(PlayerBufferConfig.hwdecFor(tv: false), isNull);
    });

    test('不写死 mediacodec、也不用 auto', () {
      // 写死 `mediacodec` 是直通路径，渲染端配不上就是**黑屏**；
      // `auto` 会把不安全的 API 一起试（崩溃 / 花屏）。
      // `auto-safe` 配不上时回落到软解 —— 最坏情况等于没改。
      final tv = PlayerBufferConfig.hwdecFor(tv: true);
      expect(tv, isNot('mediacodec'));
      expect(tv, isNot('auto'));
      expect(tv, isNot('no'));
    });
  });
}
