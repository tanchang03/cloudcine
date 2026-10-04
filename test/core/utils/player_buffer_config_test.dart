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
    test('电视下发 mediacodec,auto-safe —— 直通在前、拷贝兜底', () {
      // 背景：mpv 的 `hwdec` 默认是 `no`（纯软解），media_kit 那张默认属性表
      // 里**也没有这一项**。于是电视盒子一直在软解高码率原画，而那颗 SoC
      // 通常只够软解 1080p。
      //
      // 10-04 真机日志把「4K 掉帧」钉在**上屏路径**上：4K 原画 21 秒丢
      // 141 帧（37.6%），同一文件转 810p 只丢 7 帧（1.3%），而每一拍
      // `解码丢帧=0`。掉帧率随**分辨率**缩放、与解码能力无关 —— 典型的一拷
      // 一上传（4K 约 580 MB/s）打满内存带宽。
      //
      // ⚠️ 但光下发这一项**不够**：`hwdec-current` 实测恒为 `mediacodec-copy`。
      // 根因不是白名单，是 **media_kit 在 `open()` 之后才写 `vo=null` + `hwdec`**
      // —— 解码器定型时 VO 交不出 surface，`mediacodec` 只能静默退回拷贝档。
      // 所以引擎侧还必须在 Surface 挂上之后重发一次 `hwdec`（见
      // `MediaKitPlaybackEngine._awaitVideoSurface`）。
      expect(PlayerBufferConfig.hwdecFor(tv: true), 'mediacodec,auto-safe');
    });

    test('桌面**不下发**这一项 —— 返回 null，不是 "no"', () {
      // ⛔ 返回 `'no'` 也是改了桌面行为：那会把 mpv 的默认**显式化**，
      // 并且挡住将来有人给桌面开硬解。`null` 才表示「apply 里根本不会调
      // setProperty」—— 这是「桌面代码不动」那条要求的守卫。
      expect(PlayerBufferConfig.hwdecFor(tv: false), isNull);
    });

    test('直通必须排第一 —— 排在后面等于没改', () {
      // mpv 的 `--hwdec` 是**逗号列表**，按顺序试、先成的胜出（手册里
      // `vaapi,auto` 就是这个语义）。所以 `mediacodec` 一旦不在首位，
      // 前面的那个会先成功，零拷贝永远轮不到。
      final tv = PlayerBufferConfig.hwdecFor(tv: true)!;
      expect(tv.split(',').first, 'mediacodec');
    });

    test('必须有兜底项 —— 光写 mediacodec 失败只剩软解，4K 直接不能看', () {
      // ⛔ 这条是本组最重要的断言。`mediacodec` 在 mpv 手册里属于
      // 「不安全档」：它强制 RGB 转换、10bit 降到 8bit，而且要求
      // `--vo=gpu` + `--gpu-context=android`（media_kit 恰好满足，但
      // 别的构建不保证）。没有逗号后面的兜底项时，一旦它配不上，
      // mpv 只会回落到**软件解码** —— 那比现在的拷贝路更糟。
      final tv = PlayerBufferConfig.hwdecFor(tv: true)!;
      final parts = tv.split(',');
      expect(parts.length, greaterThan(1));
      expect(parts.first, isNot('no'));
      // 兜底那一段不能是空串，也不能又是 mediacodec（那等于没有兜底）。
      expect(parts.sublist(1).every((p) => p.trim().isNotEmpty), isTrue);
      expect(parts.sublist(1).contains('mediacodec'), isFalse);
    });
  });

  group('isCopyHwdec：读出来的解码器算不算「拷贝档」', () {
    // 这条判据决定了引擎**要不要**再逼 mpv 重建一次解码器。判错的两个方向
    // 代价不对称，所以四条都要钉住。

    test('零拷贝直通不算拷贝档', () {
      // 这是「已经修好了」的那一种。若把它误判成拷贝档，引擎会在片头白白
      // 重建一次解码器 —— 用户看到的是「改完反而开头卡了一下」。
      expect(PlayerBufferConfig.isCopyHwdec('mediacodec'), isFalse);
      expect(PlayerBufferConfig.isCopyHwdec('vaapi'), isFalse);
    });

    test('带 -copy 的都算拷贝档（不只是 mediacodec-copy）', () {
      // ⛔ 判据取「名字里带 copy」而不是与某个具体值相等：同族的
      // `vaapi-copy` / `d3d11va-copy` / `vdpau-copy` 是同一个病，
      // 写死字符串会在别的平台上静默失效。
      expect(PlayerBufferConfig.isCopyHwdec('mediacodec-copy'), isTrue);
      expect(PlayerBufferConfig.isCopyHwdec('vaapi-copy'), isTrue);
      expect(PlayerBufferConfig.isCopyHwdec('d3d11va-copy'), isTrue);
    });

    test('大小写不影响判定', () {
      // mpv 给的是小写，但这一条只是为了让判据在日志被人手抄过之后仍然成立。
      expect(PlayerBufferConfig.isCopyHwdec('MediaCodec-Copy'), isTrue);
    });

    test('空串**不算**拷贝档 —— 它只是还没有读数', () {
      // ⛔ 最容易写错、代价最大的一条：`loadfile` 之后的一小段时间里
      // `hwdec-current` 就是空串。把它算成「退回了拷贝」会触发一次
      // 没必要的解码器重建，而且是在片头最不该抖的时候。
      expect(PlayerBufferConfig.isCopyHwdec(''), isFalse);
      expect(PlayerBufferConfig.isCopyHwdec('   '), isFalse);
    });

    test('过渡值不是软解 —— 重建那一瞬间也不能掉出硬解', () {
      // ⛔ 过渡值若写成 `no`，重建时解码器会被拽到**软解**：4K 软解直接卡死，
      // 比「留在拷贝档」更糟。所以过渡值必须是硬解族里的另一个值。
      expect(PlayerBufferConfig.hwdecKickTransient, isNot('no'));
      expect(PlayerBufferConfig.hwdecKickTransient, isNotEmpty);
      // 而且它必须与目标值不同，否则 mpv 视作空操作、根本不重建。
      expect(
        PlayerBufferConfig.hwdecKickTransient,
        isNot(PlayerBufferConfig.hwdecFor(tv: true)),
      );
    });
  });
}
