import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:cloudcine/ui/windows/player_window_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跨引擎通道的**主窗口一侧**是纯逻辑，不需要真窗口就能测。
///
/// 这里每一条用例都对应一个「出问题时完全安静」的故障：
///   - 待取盒子没清 → 「重新自检」会把同一部片反复重播；
///   - 进度回报没路由 → 「最近播放」永远不更新；
///   - 未实现的方法不抛 → 协议两边悄悄错位，没人发现。
void main() {
  setUp(_resetGlobals);

  tearDown(_resetGlobals);

  group('handlePlayerWindowCall（主窗口侧）', () {
    test('ping → pong', () async {
      expect(
        await handlePlayerWindowCall(const MethodCall(PlayerBridgeMethod.ping)),
        'pong',
      );
    });

    test('fetchPendingPlay 把请求交出去', () async {
      const request = PlayRequest(
        url: 'https://cdn.example.com/a.mp4',
        title: '银翼杀手',
        itemId: '102',
        headers: <String, String>{'Cookie': 'k=v'},
        qualityLabel: '4k(2160p)',
      );
      debugSetPendingPlayRequest(request);

      final raw = await handlePlayerWindowCall(
        const MethodCall(PlayerBridgeMethod.fetchPendingPlay),
      );

      expect(PlayRequest.fromJson(raw), request);
    });

    test('fetchPendingPlay 只交付一次 —— 否则「重新自检」会反复重播同一部片', () async {
      debugSetPendingPlayRequest(
        const PlayRequest(url: 'https://a/b.mp4', title: 'x'),
      );

      expect(
        await handlePlayerWindowCall(
          const MethodCall(PlayerBridgeMethod.fetchPendingPlay),
        ),
        isNotNull,
      );
      expect(
        await handlePlayerWindowCall(
          const MethodCall(PlayerBridgeMethod.fetchPendingPlay),
        ),
        isNull,
        reason: '第二次必须拿到 null',
      );
      expect(debugPendingPlayRequest, isNull);
    });

    test('盒子里没有请求时返回 null，不抛异常', () async {
      expect(
        await handlePlayerWindowCall(
          const MethodCall(PlayerBridgeMethod.fetchPendingPlay),
        ),
        isNull,
      );
    });

    test('reportProgress 把回报交给 UI 层装上的回调', () async {
      final received = <PlaybackProgressReport>[];
      // 回调是 async 的：切集时主窗口要「先写完库再取新链」，
      // 回报必须能被 await（见 player_window_bridge.dart 的字段文档）。
      onPlaybackProgress = (r) async {
        received.add(r);
      };

      final result = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.reportProgress,
          const PlaybackProgressReport(
            itemId: '102',
            position: Duration(seconds: 30),
            duration: Duration(minutes: 96),
          ).toJson(),
        ),
      );

      expect(result, isNull);
      expect(received, hasLength(1));
      expect(received.single.itemId, '102');
      expect(received.single.position, const Duration(seconds: 30));
      expect(received.single.duration, const Duration(minutes: 96));
    });

    test('解不开的进度回报不回调、不抛异常', () async {
      var called = false;
      onPlaybackProgress = (_) async {
        called = true;
      };

      for (final raw in const <Object?>[
        null,
        'string',
        <String, Object?>{},
        <String, Object?>{'itemId': ''},
        <String, Object?>{'itemId': 102},
      ]) {
        expect(
          () => handlePlayerWindowCall(
            MethodCall(PlayerBridgeMethod.reportProgress, raw),
          ),
          returnsNormally,
          reason: 'raw=$raw',
        );
      }

      expect(called, isFalse);
    });

    test('还没装上落库回调时安静丢弃 —— 不能因此崩掉主窗口', () async {
      // 进度每 10 秒来一条，这条路径必须容忍「容器还没起来」。
      final result = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.reportProgress,
          const PlaybackProgressReport(
            itemId: '102',
            position: Duration(seconds: 10),
          ).toJson(),
        ),
      );

      expect(result, isNull);
    });

    test('refreshTicket 把新链交回去', () async {
      onTicketRefresh = (request) async => PlayRequest(
            url: 'https://cdn.example.com/fresh.mp4',
            title: '银翼杀手',
            itemId: request.itemId,
            qualityId: request.qualityId,
            startPosition: request.position,
          );

      final raw = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.refreshTicket,
          const TicketRefreshRequest(
            itemId: '102',
            qualityId: '4k',
            position: Duration(minutes: 42),
          ).toJson(),
        ),
      );

      final fresh = PlayRequest.fromJson(raw)!;
      expect(fresh.url, 'https://cdn.example.com/fresh.mp4');
      // 位置必须原样带回 —— 丢了它刷新会把用户扔回片头。
      expect(fresh.startPosition, const Duration(minutes: 42));
      // 档位同理：丢了它主窗口只能退回设置里的默认档。
      expect(fresh.qualityId, '4k');
    });

    test('取链回调返回 null → 原样返回 null，不抛异常', () async {
      onTicketRefresh = (_) async => null;

      final raw = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.refreshTicket,
          const TicketRefreshRequest(itemId: '102').toJson(),
        ),
      );

      expect(raw, isNull);
    });

    test('取链回调自己抛了 → 异常冒出去（由播放窗口那侧兜）', () async {
      // 刻意不在这里吞掉：吞掉会让「取链挂了」和「服务端说刷不出来」
      // 变成同一个结果，而前者是需要被看见的故障。
      onTicketRefresh = (_) async => throw StateError('取链挂了');

      await expectLater(
        handlePlayerWindowCall(
          MethodCall(
            PlayerBridgeMethod.refreshTicket,
            const TicketRefreshRequest(itemId: '102').toJson(),
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('没装上取链回调 → 返回 null，不抛异常', () async {
      final raw = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.refreshTicket,
          const TicketRefreshRequest(itemId: '102').toJson(),
        ),
      );

      expect(raw, isNull);
    });

    test('解不开的刷新请求不回调、不抛异常', () async {
      var called = false;
      onTicketRefresh = (_) async {
        called = true;
        return null;
      };

      for (final raw in const <Object?>[
        null,
        'string',
        <String, Object?>{},
        <String, Object?>{'itemId': ''},
        <String, Object?>{'itemId': 102},
      ]) {
        expect(
          () => handlePlayerWindowCall(
            MethodCall(PlayerBridgeMethod.refreshTicket, raw),
          ),
          returnsNormally,
          reason: 'raw=$raw',
        );
      }

      expect(called, isFalse);
    });

    test('未实现的方法一律抛 MissingPluginException', () async {
      // 静默吞掉会让协议两边悄悄错位 —— 必须显式暴露。
      await expectLater(
        handlePlayerWindowCall(const MethodCall('nope')),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });

  group('handleMainWindowCall（播放窗口侧）', () {
    test('ping → pong', () async {
      expect(
        await handleMainWindowCall(const MethodCall(PlayerBridgeMethod.ping)),
        'pong',
      );
    });

    test('play 不在这里处理 —— 它要操作播放器，由 PlayerWindowApp 包一层', () async {
      // 这个纯函数只负责协议层面的事情。放进来会让「拿一个 MethodCall
      // 就能控制播放器」，测试也没法在不建引擎的情况下覆盖。
      await expectLater(
        handleMainWindowCall(const MethodCall(PlayerBridgeMethod.play)),
        throwsA(isA<MissingPluginException>()),
      );
    });

    test('未实现的方法一律抛 MissingPluginException', () async {
      await expectLater(
        handleMainWindowCall(const MethodCall('nope')),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });

  group('fetchSubtitleText（网盘字幕正文）', () {
    test('把 fileId 交给回调，正文原样交回去', () async {
      String? asked;
      onFetchSubtitleText = (fileId) async {
        asked = fileId;
        return '1\n00:00:01,000 --> 00:00:02,000\n你好\n';
      };

      final text = await handlePlayerWindowCall(
        const MethodCall(
          PlayerBridgeMethod.fetchSubtitleText,
          <String, Object?>{'fileId': 'f1'},
        ),
      );

      expect(asked, 'f1');
      expect(text, contains('你好'));
    });

    test('没有 fileId 时不回调 —— 拿一个空 id 去取只会得到一次无谓的请求', () async {
      var called = false;
      onFetchSubtitleText = (_) async {
        called = true;
        return 'x';
      };

      for (final raw in const <Object?>[
        null,
        <String, Object?>{},
        <String, Object?>{'fileId': ''},
        <String, Object?>{'fileId': 42},
      ]) {
        expect(
          await handlePlayerWindowCall(
            MethodCall(PlayerBridgeMethod.fetchSubtitleText, raw),
          ),
          isNull,
          reason: 'raw=$raw',
        );
      }

      expect(called, isFalse);
    });

    test('取不到时返回 null —— 播放窗口要据此提示，不能假装成功', () async {
      onFetchSubtitleText = (_) async => null;

      expect(
        await handlePlayerWindowCall(
          const MethodCall(
            PlayerBridgeMethod.fetchSubtitleText,
            <String, Object?>{'fileId': 'f1'},
          ),
        ),
        isNull,
      );
    });

    test('没装上回调时返回 null，不抛异常', () async {
      expect(
        await handlePlayerWindowCall(
          const MethodCall(
            PlayerBridgeMethod.fetchSubtitleText,
            <String, Object?>{'fileId': 'f1'},
          ),
        ),
        isNull,
      );
    });
  });

  group('fetchThumbnail（剧集面板的缩略图）', () {
    test('itemId 与地址一起交给回调，回来的本地路径原样交回去', () async {
      // 播放窗口拿这个路径去 `Image.file` —— 它自己下不了这张图（夸克缩略图
      // 缺 Cookie 一律 401，凭证在主窗口这边）。
      String? askedItem;
      String? askedUrl;
      onFetchThumbnail = (itemId, url) async {
        askedItem = itemId;
        askedUrl = url;
        return '/tmp/posters/quark_f1_ab12cd34.jpg';
      };

      final path = await handlePlayerWindowCall(
        const MethodCall(
          PlayerBridgeMethod.fetchThumbnail,
          <String, Object?>{
            'itemId': 'quark:f1',
            'url': 'https://drive.example.com/thumb-f1',
          },
        ),
      );

      expect(askedItem, 'quark:f1');
      expect(askedUrl, 'https://drive.example.com/thumb-f1');
      expect(path, '/tmp/posters/quark_f1_ab12cd34.jpg');
    });

    test('没有地址时不回调 —— 拿一条空 URL 去下只会白烧一次请求', () async {
      var called = false;
      onFetchThumbnail = (_, _) async {
        called = true;
        return '/tmp/x.jpg';
      };

      for (final raw in const <Object?>[
        null,
        'not-a-map',
        <String, Object?>{},
        <String, Object?>{'url': ''},
        <String, Object?>{'url': 42},
      ]) {
        expect(
          await handlePlayerWindowCall(
            MethodCall(PlayerBridgeMethod.fetchThumbnail, raw),
          ),
          isNull,
          reason: 'raw=$raw',
        );
      }

      expect(called, isFalse);
    });

    test('itemId 缺失（老版本主窗口投来的请求）退化成空串，图照样取得回来', () async {
      // 缓存键那时退化成 URL 本身 —— 文件名难看一点，但图不能取不到。
      String? askedItem;
      onFetchThumbnail = (itemId, _) async {
        askedItem = itemId;
        return '/tmp/x.jpg';
      };

      final path = await handlePlayerWindowCall(
        const MethodCall(
          PlayerBridgeMethod.fetchThumbnail,
          <String, Object?>{'url': 'https://drive.example.com/t'},
        ),
      );

      expect(askedItem, '');
      expect(path, '/tmp/x.jpg');
    });

    test('取不到时返回 null —— 约 30% 的视频夸克还没生成预览图', () async {
      // 这不是错误路径，是常态。播放窗口拿到 null 安静退回占位图即可。
      onFetchThumbnail = (_, _) async => null;

      expect(
        await handlePlayerWindowCall(
          const MethodCall(
            PlayerBridgeMethod.fetchThumbnail,
            <String, Object?>{'url': 'https://drive.example.com/t'},
          ),
        ),
        isNull,
      );
    });

    test('没装上回调时返回 null，不抛异常', () async {
      expect(
        await handlePlayerWindowCall(
          const MethodCall(
            PlayerBridgeMethod.fetchThumbnail,
            <String, Object?>{'url': 'https://drive.example.com/t'},
          ),
        ),
        isNull,
      );
    });
  });

  group('searchOnlineSubtitles（在线搜索）', () {
    test('把整个 SubtitleSearchRequest 交给回调 —— 片名由主窗口按 itemId 补全', () async {
      SubtitleSearchRequest? asked;
      onSearchOnlineSubtitles = (request) async {
        asked = request;
        return const <OnlineSubtitleBrief>[
          OnlineSubtitleBrief(
            fileId: 12345,
            fileName: 'Movie.chs.srt',
            language: 'zh-cn',
            downloadCount: 88,
          ),
        ];
      };

      final raw = await handlePlayerWindowCall(
        const MethodCall(
          PlayerBridgeMethod.searchOnlineSubtitles,
          <String, Object?>{'itemId': '102', 'fallbackQuery': '银翼杀手'},
        ),
      );

      expect(asked?.itemId, '102');
      expect(asked?.fallbackQuery, '银翼杀手');

      // 回给播放窗口的必须是**可解码的 JSON 形状**，不是 Dart 对象 ——
      // 中间要过一趟方法通道的编解码。
      final list = raw! as List<Object?>;
      final brief = OnlineSubtitleBrief.fromJson(list.single)!;
      expect(brief.fileId, 12345);
      expect(brief.downloadCount, 88);
    });

    test('搜不到 = 空列表，**不是** null —— 与「请求失败」必须分开', () async {
      onSearchOnlineSubtitles = (_) async => const <OnlineSubtitleBrief>[];

      final raw = await handlePlayerWindowCall(
        const MethodCall(
          PlayerBridgeMethod.searchOnlineSubtitles,
          <String, Object?>{'itemId': '102'},
        ),
      );

      expect(raw, isEmpty);
      expect(raw, isNotNull);
    });

    test('两个参数都空时不回调 —— 没什么可搜，发出去只会白烧一次额度', () async {
      var called = false;
      onSearchOnlineSubtitles = (_) async {
        called = true;
        return const <OnlineSubtitleBrief>[];
      };

      for (final raw in const <Object?>[
        null,
        <String, Object?>{},
        <String, Object?>{'itemId': '', 'fallbackQuery': '   '},
      ]) {
        expect(
          await handlePlayerWindowCall(
            MethodCall(PlayerBridgeMethod.searchOnlineSubtitles, raw),
          ),
          isEmpty,
          reason: 'raw=$raw',
        );
      }

      expect(called, isFalse);
    });

    test('回调抛异常时**原样冒出去** —— 吞掉会变成「这部片没有字幕」', () async {
      // 这是这条协议里最要紧的一条：搜索失败与搜不到必须能被区分开，
      // 否则「Api-Key 没配对」会表现成「这部片没字幕」，排查方向完全不同。
      // ⚠️ 异常类型是 `PlatformException` 而不是随便什么异常：跨引擎通道只认识
      // 它那三段编码，别的异常到了对面会退化成一个 `code='error'`、
      // `message=<整段 toString>` 的兜底错误 —— 用户看到的就是一坨内部类型名。
      onSearchOnlineSubtitles = (_) async => throw PlatformException(
            code: 'opensubtitles/badApiKey',
            message: 'OpenSubtitles 的 Api-Key 不被接受，去设置页检查一下',
          );

      await expectLater(
        handlePlayerWindowCall(
          const MethodCall(
            PlayerBridgeMethod.searchOnlineSubtitles,
            <String, Object?>{'itemId': '102'},
          ),
        ),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'opensubtitles/badApiKey')
              .having((e) => e.message, 'message', contains('Api-Key')),
        ),
      );
    });

    test('没装上回调时返回空列表，不抛异常', () async {
      expect(
        await handlePlayerWindowCall(
          const MethodCall(
            PlayerBridgeMethod.searchOnlineSubtitles,
            <String, Object?>{'itemId': '102'},
          ),
        ),
        isEmpty,
      );
    });
  });

  group('fetchOnlineSubtitle（在线字幕正文）', () {
    test('fileId 是数字字符串时也能解析 —— 通道不保证把 int 原样送回来', () async {
      int? asked;
      onFetchOnlineSubtitle = (fileId) async {
        asked = fileId;
        return '字幕正文';
      };

      final text = await handlePlayerWindowCall(
        const MethodCall(
          PlayerBridgeMethod.fetchOnlineSubtitle,
          <String, Object?>{'fileId': '12345'},
        ),
      );

      expect(asked, 12345);
      expect(text, '字幕正文');
    });

    test('没有 fileId 时不回调', () async {
      var called = false;
      onFetchOnlineSubtitle = (_) async {
        called = true;
        return 'x';
      };

      for (final raw in const <Object?>[
        null,
        <String, Object?>{},
        <String, Object?>{'fileId': 'abc'},
      ]) {
        expect(
          await handlePlayerWindowCall(
            MethodCall(PlayerBridgeMethod.fetchOnlineSubtitle, raw),
          ),
          isNull,
          reason: 'raw=$raw',
        );
      }

      expect(called, isFalse);
    });

    test('额度用完之类的失败要冒出去 —— 那句话必须能显示给用户', () async {
      onFetchOnlineSubtitle = (_) async => throw PlatformException(
            code: 'opensubtitles/quotaExceeded',
            message: 'OpenSubtitles 今天的下载额度用完了（HTTP 429）',
          );

      await expectLater(
        handlePlayerWindowCall(
          const MethodCall(
            PlayerBridgeMethod.fetchOnlineSubtitle,
            <String, Object?>{'fileId': 12345},
          ),
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.message,
            'message',
            contains('额度用完'),
          ),
        ),
      );
    });
  });

  group('supportsMultiWindow 平台闸', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('桌面三平台放行', () {
      for (final platform in const [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(supportsMultiWindow, isTrue, reason: '$platform');
      }
    });

    test('移动端拦住 —— 插件在这些平台上会抛 MissingPluginException', () {
      for (final platform in const [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(supportsMultiWindow, isFalse, reason: '$platform');
      }
    });
  });
}

/// 清掉 bridge 里的**进程级全局**。
///
/// 五个回调都是全局的（见 `player_window_bridge.dart` 的说明），漏清一个的表现
/// 是「前一条用例装上的回调在后一条里还活着」—— 于是后一条明明没装回调却收到了
/// 调用，或者更糟：它以为「没装回调」的路径被测过了，其实没有。
void _resetGlobals() {
  debugSetPendingPlayRequest(null);
  onPlaybackProgress = null;
  onTicketRefresh = null;
  onFetchSubtitleText = null;
  onFetchThumbnail = null;
  onSearchOnlineSubtitles = null;
  onFetchOnlineSubtitle = null;
}
