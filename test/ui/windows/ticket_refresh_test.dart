import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「刷新过期直链」这条链上有两个纯逻辑件：
/// **报什么**（[TicketRefreshRequest]）与**什么时候还能再刷**（[TicketRefreshGuard]）。
///
/// 两者出错都不会崩窗口，只会安静地坏掉：
///   - 请求编解码不对称 → 主窗口收到一个没有 itemId 的请求 → 刷不出来；
///   - 重试闸失灵 → 要么死循环（取链请求 + 窗口反复重开），
///     要么一次用满之后再也不能刷新（长片后半段彻底卡死）。
void main() {
  final t0 = DateTime(2026, 9, 30, 20, 0, 0);

  group('TicketRefreshRequest 编解码', () {
    test('字段能原样过一趟通道', () {
      const original = TicketRefreshRequest(
        itemId: '102',
        qualityId: '4k',
        position: Duration(minutes: 42, seconds: 17),
      );

      final restored = TicketRefreshRequest.fromJson(original.toJson());

      expect(restored, original);
      expect(restored!.qualityId, '4k');
      expect(restored.position, const Duration(minutes: 42, seconds: 17));
    });

    test('没有 itemId 就刷不了 —— 返回 null', () {
      const raws = <Object?>[
        null,
        'string',
        42,
        <String>[],
        <String, Object?>{},
        <String, Object?>{'qualityId': '4k'},
        <String, Object?>{'itemId': ''},
        <String, Object?>{'itemId': 102},
      ];

      for (final raw in raws) {
        expect(() => TicketRefreshRequest.fromJson(raw), returnsNormally,
            reason: 'raw=$raw');
        expect(TicketRefreshRequest.fromJson(raw), isNull, reason: 'raw=$raw');
      }
    });

    test('qualityId 缺省或空串都归一成 null（等于「按默认档重新选」）', () {
      for (final raw in const <Object?>[null, '', 42]) {
        final restored = TicketRefreshRequest.fromJson(<String, Object?>{
          'itemId': '102',
          'qualityId': raw,
        })!;

        expect(restored.qualityId, isNull, reason: 'raw=$raw');
      }
    });

    test('位置为负或非整数时按 0 处理', () {
      for (final raw in const <Object?>[-5, 'abc', null, 1.5]) {
        final restored = TicketRefreshRequest.fromJson(<String, Object?>{
          'itemId': '102',
          'positionMs': raw,
        })!;

        expect(restored.position, Duration.zero, reason: 'raw=$raw');
      }
    });

    test('值语义：字段全同即相等', () {
      const a = TicketRefreshRequest(
        itemId: '102',
        qualityId: '4k',
        position: Duration(seconds: 30),
      );
      const b = TicketRefreshRequest(
        itemId: '102',
        qualityId: '4k',
        position: Duration(seconds: 30),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('档位不同就不相等 —— 否则「用户中途换了清晰度」会被当成同一条请求', () {
      const a = TicketRefreshRequest(itemId: '102', qualityId: '4k');
      const b = TicketRefreshRequest(itemId: '102', qualityId: 'super');

      expect(a == b, isFalse);
    });
  });

  group('TicketRefreshGuard 重试闸', () {
    test('新闸是空的：没刷新过、也不曾用尽', () {
      final guard = TicketRefreshGuard();

      expect(guard.attempts, 0);
      expect(guard.exhausted, isFalse);
    });

    test('用满 maxAttempts 之后 begin 一律返回 false', () {
      final guard = TicketRefreshGuard(maxAttempts: 2);

      expect(guard.begin(Duration.zero, now: t0), isTrue);
      // 两次调用必须拉开到超过冷却窗口 —— 真实场景里它们本来就隔着几秒。
      // 用同一个时刻连调两次会被**去抖**挡下，那是「冷却」那组用例在验的事。
      expect(
        guard.begin(Duration.zero, now: t0.add(const Duration(seconds: 30))),
        isTrue,
      );
      expect(guard.attempts, 2);
      expect(guard.exhausted, isTrue);

      // 第三次必须被挡住 —— 这就是「不死循环」的全部保证。
      expect(guard.begin(Duration.zero, now: t0), isFalse);
      expect(guard.attempts, 2, reason: '被挡下的那次不该计数');
    });

    test('没刷新过时 observe 什么也不做', () {
      final guard = TicketRefreshGuard();

      expect(
        guard.observe(const Duration(hours: 1), now: t0.add(const Duration(hours: 1))),
        isFalse,
      );
      expect(guard.attempts, 0);
    });

    test('时间不够时不判有效 —— 这是为了排除「拖进度条」造成的假恢复', () {
      final guard = TicketRefreshGuard();
      guard.begin(const Duration(minutes: 10), now: t0);

      // 用户往后拖了 45 秒，但只过了 10 秒墙钟。真出问题的话，
      // mpv 在这 10 秒里就该再报错了。
      final ok = guard.observe(
        const Duration(minutes: 10, seconds: 45),
        now: t0.add(const Duration(seconds: 10)),
      );

      expect(ok, isFalse);
      expect(guard.attempts, 1, reason: '不该清零');
    });

    test('位置没往前走时不判有效 —— 停在原地反复重连不算恢复', () {
      final guard = TicketRefreshGuard();
      guard.begin(const Duration(minutes: 10), now: t0);

      expect(
        guard.observe(
          const Duration(minutes: 10),
          now: t0.add(const Duration(minutes: 5)),
        ),
        isFalse,
      );
      expect(guard.attempts, 1);
    });

    test('位置往回走时也不判有效', () {
      final guard = TicketRefreshGuard();
      guard.begin(const Duration(minutes: 10), now: t0);

      expect(
        guard.observe(
          const Duration(minutes: 9),
          now: t0.add(const Duration(minutes: 5)),
        ),
        isFalse,
      );
      expect(guard.attempts, 1);
    });

    test('时间够了、位置也往前走了 → 清零并返回 true', () {
      final guard = TicketRefreshGuard();
      guard.begin(const Duration(minutes: 10), now: t0);

      final ok = guard.observe(
        const Duration(minutes: 10, seconds: 45),
        now: t0.add(const Duration(seconds: 45)),
      );

      expect(ok, isTrue);
      expect(guard.attempts, 0);
      expect(guard.exhausted, isFalse);
    });

    test('清零之后又能用满一次额度 —— 长片里撞上多次过期才救得回来', () {
      final guard = TicketRefreshGuard(maxAttempts: 1);

      guard.begin(const Duration(minutes: 10), now: t0);
      expect(guard.exhausted, isTrue);
      expect(guard.begin(Duration.zero, now: t0), isFalse);

      // 这次刷新被证明有效
      expect(
        guard.observe(
          const Duration(minutes: 11),
          now: t0.add(const Duration(minutes: 1)),
        ),
        isTrue,
      );

      expect(guard.exhausted, isFalse);
      expect(guard.begin(Duration.zero, now: t0), isTrue);
    });

    test('清零只报一次 —— 否则会跟着 position 流刷屏', () {
      final guard = TicketRefreshGuard();
      guard.begin(const Duration(minutes: 10), now: t0);

      expect(
        guard.observe(
          const Duration(minutes: 11),
          now: t0.add(const Duration(minutes: 1)),
        ),
        isTrue,
      );
      // 再喂同样的位置（position 是高频流）
      expect(
        guard.observe(
          const Duration(minutes: 11, seconds: 1),
          now: t0.add(const Duration(minutes: 1, seconds: 1)),
        ),
        isFalse,
      );
    });

    test('手动 reset 不受闸限制 —— 用户点的按钮不该被自动计数挡住', () {
      final guard = TicketRefreshGuard(maxAttempts: 1);

      guard.begin(Duration.zero, now: t0);
      expect(guard.exhausted, isTrue);

      guard.reset();

      expect(guard.attempts, 0);
      expect(guard.begin(Duration.zero, now: t0), isTrue);
    });

    test('观察窗口可配', () {
      final guard = TicketRefreshGuard(healthyWindow: const Duration(seconds: 5));
      guard.begin(const Duration(seconds: 100), now: t0);

      // 位置已经走过 100+5 秒的阈值了，但墙钟只过了 4 秒。
      expect(
        guard.observe(
          const Duration(seconds: 106),
          now: t0.add(const Duration(seconds: 4)),
        ),
        isFalse,
        reason: '位置够了，时间还差一点',
      );
      expect(
        guard.observe(
          const Duration(seconds: 106),
          now: t0.add(const Duration(seconds: 6)),
        ),
        isTrue,
      );
    });
  });

  group('TicketRefreshGuard 冷却窗口', () {
    test('同一批回声只批一次 —— 一次 seek 失败会连出好几条 4xx', () {
      final guard = TicketRefreshGuard();

      expect(guard.begin(Duration.zero, now: t0), isTrue);
      // 毫秒级跟进的后续报错：同一次故障的回声，不该各占一次额度。
      expect(
        guard.begin(Duration.zero, now: t0.add(const Duration(milliseconds: 50))),
        isFalse,
      );
      expect(
        guard.begin(Duration.zero, now: t0.add(const Duration(seconds: 3))),
        isFalse,
      );
      expect(guard.attempts, 1, reason: '被去抖挡下的不该计数');
      expect(
        guard.exhausted,
        isFalse,
        reason: '冷却不是用满 —— 调用方要能分辨，否则会误报「已停止自动重试」',
      );
    });

    test('过了冷却窗口又能刷新 —— 不能因为去抖把真过期也挡住', () {
      final guard = TicketRefreshGuard();

      guard.begin(Duration.zero, now: t0);
      expect(
        guard.begin(Duration.zero, now: t0.add(const Duration(seconds: 11))),
        isTrue,
      );
      expect(guard.attempts, 2);
    });

    test('冷却窗口可配', () {
      final guard = TicketRefreshGuard(minInterval: const Duration(seconds: 2));

      guard.begin(Duration.zero, now: t0);
      expect(
        guard.begin(Duration.zero, now: t0.add(const Duration(seconds: 1))),
        isFalse,
      );
      expect(
        guard.begin(Duration.zero, now: t0.add(const Duration(seconds: 3))),
        isTrue,
      );
    });

    test('手动 reset 也要重新起冷却 —— 否则旧流回声立刻烧掉刚清空的额度', () {
      final guard = TicketRefreshGuard(maxAttempts: 1);

      guard.begin(Duration.zero, now: t0);
      expect(guard.exhausted, isTrue);

      // 用户点了「重新取链并续播」：额度清空，但冷却从这一刻重新算。
      guard.reset(now: t0.add(const Duration(seconds: 30)));
      expect(guard.attempts, 0);
      expect(guard.exhausted, isFalse);

      // 旧流那批回声紧接着到 —— 必须被冷却挡住，额度要留给真正的新问题。
      expect(
        guard.begin(Duration.zero, now: t0.add(const Duration(seconds: 31))),
        isFalse,
      );
      expect(guard.attempts, 0, reason: '额度不该被回声烧掉');
    });

    test('换片时 reset() 不带时刻 → 冷却一并清掉', () {
      final guard = TicketRefreshGuard();

      guard.begin(Duration.zero, now: t0);
      guard.reset();

      // 新片是全新的流，跟上一部片的冷却无关。
      expect(guard.begin(Duration.zero, now: t0), isTrue);
    });

    test('刷新被证明有效后冷却也清掉', () {
      final guard = TicketRefreshGuard();

      guard.begin(const Duration(minutes: 10), now: t0);
      expect(
        guard.observe(
          const Duration(minutes: 10, seconds: 45),
          now: t0.add(const Duration(seconds: 45)),
        ),
        isTrue,
      );

      expect(guard.begin(Duration.zero, now: t0), isTrue);
    });
  });

  group('isHttp4xxLog 过期信号识别', () {
    test('认出实测到的那条原文 —— 逐字取自 mpv 的真实输出', () {
      // ⚠️ 下面这个字符串是**跑出来的**，不是编的：用 ctypes 拉起产物里的
      // Mpv.framework，让它去拉一个「任何请求都回 403」的本地服务，mpv 报的是
      //   level='warn' prefix='ffmpeg' text='http: HTTP error 403 Forbidden\n'
      // （media_kit 会先 `.trim()` 再交给我们，所以这里不带结尾换行。）
      //
      // 注意它的级别是 **warn**：media_kit 默认只请求 error 级，这条消息本来
      // 根本到不了 Dart —— 所以 `PlayerWindowApp._ensurePlayer` 必须把
      // `logLevel` 抬到 `MPVLogLevel.warn`。两处是配套的。
      expect(isHttp4xxLog('http: HTTP error 403 Forbidden'), isTrue);
      // 去掉正文里的 `http: ` 前缀也认：mpv 给 av_log 挂什么 prefix / 怎么拼
      // 正文取决于 context 名，按正文判才稳。
      expect(isHttp4xxLog('HTTP error 403 Forbidden'), isTrue);
    });

    test('其它 4xx 也认', () {
      expect(isHttp4xxLog('http: HTTP error 401 Unauthorized'), isTrue);
      // 夸克直链缺 Cookie 会回 412，重取一条带头的链就能救回来。
      expect(isHttp4xxLog('http: HTTP error 412 Precondition Failed'), isTrue);
      expect(isHttp4xxLog('HTTP error 404 Not Found'), isTrue);
    });

    test('大小写不敏感', () {
      expect(isHttp4xxLog('HTTP Error 403 Forbidden'), isTrue);
    });

    test('5xx 不认 —— 那是服务端自己的问题，重取链解决不了', () {
      expect(isHttp4xxLog('HTTP error 500 Internal Server Error'), isFalse);
      expect(isHttp4xxLog('HTTP error 503 Service Unavailable'), isFalse);
    });

    test('2xx / 3xx 不认', () {
      expect(isHttp4xxLog('HTTP error 200 OK'), isFalse);
      expect(isHttp4xxLog('HTTP error 302 Found'), isFalse);
    });

    test('别的报错不认 —— 尤其别把解码错误当成过期', () {
      expect(isHttp4xxLog('Error while decoding frame!'), isFalse);
      // 二级症状走 stream.error 那条路，两条刻意不重叠。
      expect(isHttp4xxLog('Failed to open https://x/y'), isFalse);
      expect(isHttp4xxLog(''), isFalse);
    });

    test('同一次故障的**其它**日志不能触发刷新 —— 逐字取自实测', () {
      // 这几条是播放途中那次 403 前后脚报出来的（见 isHttp4xxLog 的实测记录）。
      // 它们描述的是同一个问题，但「重新取一条链」对它们没有额外意义 ——
      // 让它们也触发刷新只会白烧额度。
      expect(
        isHttp4xxLog(
          'http: Will reconnect at 65536 in 0 second(s), error=Input/output error.',
        ),
        isFalse,
        reason: 'reconnect 通告同时含 http 和 error，但它是**退避**，不是过期',
      );
      expect(
        isHttp4xxLog(
          'http: Stream ends prematurely at 65536, should be 9799538',
        ),
        isFalse,
      );
      expect(isHttp4xxLog('Seek failed (to 8162141, size -78)'), isFalse);
      expect(
        isHttp4xxLog(
          'mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset 0x7c8b5d: partial file',
        ),
        isFalse,
      );
    });
  });

  group('redactUrls 抹掉直链签名', () {
    test('抹掉路径与查询串，只留主机名', () {
      final out = redactUrls(
        'Failed to open https://cdn.example.com/video.mkv?sign=abc123&exp=999.',
      );

      expect(out, contains('cdn.example.com'));
      expect(out, isNot(contains('sign=abc123')));
      expect(out, isNot(contains('exp=999')));
      expect(out, isNot(contains('video.mkv')));
    });

    test('mpv 的整句报错里也抹得掉，且结尾句号补得回来', () {
      final out = redactUrls(
        'Failed to open https://pcdn.quark.cn/f/xyz?auth_key=deadbeef.',
      );

      expect(out, startsWith('Failed to open '));
      expect(out, isNot(contains('deadbeef')));
      expect(out, isNot(contains('xyz')));
      expect(out, endsWith('.'), reason: '不补的话日志看起来像被截断了');
    });

    test('http:// 的 scheme 不被改写成 https://', () {
      final out = redactUrls('open http://a.b.com/x?y=1 now');

      expect(out, contains('http://a.b.com'));
      expect(out, isNot(contains('https://a.b.com')));
    });

    test('一句话里多个 URL 全部抹掉', () {
      final out = redactUrls(
        'https://a.com/1?sig=aaa and https://b.com/2?sig=bbb',
      );

      expect(out, isNot(contains('sig=aaa')));
      expect(out, isNot(contains('sig=bbb')));
      expect(out, contains('a.com'));
      expect(out, contains('b.com'));
    });

    test('没有 URL 时原样返回', () {
      expect(redactUrls('Failed to open the file.'), 'Failed to open the file.');
    });
  });
}
