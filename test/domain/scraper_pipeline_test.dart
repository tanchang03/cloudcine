import 'dart:async';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/scraper.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个可编程的假刮削器。
class _Fake implements MetadataScraper {
  _Fake(this.id, {this.enabled = true, required this.run});

  @override
  final String id;

  final bool enabled;
  final Future<ScrapedMetadata?> Function(ScrapeQuery query) run;

  int calls = 0;

  @override
  String get displayName => id;

  @override
  bool get isEnabled => enabled;

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) {
    calls++;
    return run(query);
  }
}

ScrapedMetadata _meta(String title) => ScrapedMetadata(
      title: title,
      source: ScrapeSource.online,
    );

const _q = ScrapeQuery(title: '某片', kind: MediaKind.movie);

void main() {
  group('ScraperPipeline 并发与优先级', () {
    test('所有竞速者同时起跑，不是串行等', () async {
      final gate = Completer<void>();
      var secondStarted = false;

      final first = _Fake('first', run: (_) async {
        await gate.future;
        return null;
      });
      final second = _Fake('second', run: (_) async {
        secondStarted = true;
        return _meta('SECOND');
      });

      final pipeline = ScraperPipeline([
        first,
        second,
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final pending = pipeline.scrape(_q);
      await pumpEventQueue();

      expect(
        secondStarted,
        isTrue,
        reason: '第二个源必须在第一个还没返回时就已经发出请求。'
            '写成 `for (s in scrapers) await s.scrape()` 会让总耗时变成'
            '「所有源的和」，而它们本来是完全独立的。',
      );

      gate.complete();
      final r = await pending;
      expect(r!.title, 'SECOND');
    });

    test('低优先级先返回也不算数：优先级高的成功者胜出', () async {
      final gate = Completer<void>();
      var lowReturned = false;

      final high = _Fake('high', run: (_) async {
        await gate.future;
        return _meta('HIGH');
      });
      final low = _Fake('low', run: (_) async {
        lowReturned = true;
        return _meta('LOW');
      });

      final pipeline = ScraperPipeline([
        high,
        low,
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final pending = pipeline.scrape(_q);
      await pumpEventQueue();
      expect(lowReturned, isTrue, reason: '低优先级那个确实已经先返回了');

      gate.complete();
      final r = await pending;

      expect(
        r!.title,
        'HIGH',
        reason: '「按优先级并发」的意思就是：低优先级的先回来也不作数，'
            '只要高优先级的成功就用高优先级的。谁先返回就用谁的话，'
            '优先级这个设置就完全没有意义了。',
      );
    });

    test('兜底不参与竞速：本地再快也不能赢过在线源', () async {
      final gate = Completer<void>();
      var localCalled = false;

      final online = _Fake('online', run: (_) async {
        await gate.future;
        return _meta('ONLINE');
      });
      final local = _Fake('local', run: (_) async {
        localCalled = true;
        return _meta('LOCAL');
      });

      final pipeline = ScraperPipeline([online, local]);

      final pending = pipeline.scrape(_q);
      await pumpEventQueue();

      expect(
        localCalled,
        isFalse,
        reason: '本地文件名解析永远成功、而且几乎瞬时返回。让它参赛它就会'
            '永远赢，在线源一次机会都没有 —— 媒体库里会全是'
            '「只有标题和年份」的条目。',
      );

      gate.complete();
      final r = await pending;
      expect(r!.title, 'ONLINE');
      expect(localCalled, isFalse);
    });

    test('高优先级失败 → 用低优先级的结果', () async {
      final pipeline = ScraperPipeline([
        _Fake('high', run: (_) async => null),
        _Fake('low', run: (_) async => _meta('LOW')),
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final r = await pipeline.scrape(_q);
      expect(r!.title, 'LOW');
    });

    test('竞速者全失败 → 才用兜底', () async {
      final local = _Fake('local', run: (_) async => _meta('LOCAL'));
      final pipeline = ScraperPipeline([
        _Fake('high', run: (_) async => null),
        _Fake('low', run: (_) async => null),
        local,
      ]);

      final r = await pipeline.scrape(_q);
      expect(r!.title, 'LOCAL');
      expect(local.calls, 1);
    });

    test('只有一个刮削器时它当兜底，不当竞速者', () async {
      final only = _Fake('local', run: (_) async => _meta('LOCAL'));
      final r = await ScraperPipeline([only]).scrape(_q);
      expect(r!.title, 'LOCAL');
      expect(only.calls, 1);
    });

    test('未启用的竞速者不发请求', () async {
      final disabled = _Fake('off', enabled: false, run: (_) async {
        throw StateError('不该被调用');
      });
      final pipeline = ScraperPipeline([
        disabled,
        _Fake('on', run: (_) async => _meta('ON')),
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final r = await pipeline.scrape(_q);
      expect(r!.title, 'ON');
      expect(disabled.calls, 0);
    });

    test('竞速者抛异常按未命中处理，不中断流水线', () async {
      final pipeline = ScraperPipeline([
        _Fake('boom', run: (_) async => throw StateError('网络库没兜住')),
        _Fake('ok', run: (_) async => _meta('OK')),
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final r = await pipeline.scrape(_q);
      expect(r!.title, 'OK');
    });

    test('高优先级已返回后，低优先级的异常不会漏成未处理的异步错误', () async {
      final high = _Fake('high', run: (_) async => _meta('HIGH'));
      final slowBoom = _Fake('slow', run: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw StateError('迟到的失败');
      });
      final pipeline = ScraperPipeline([
        high,
        slowBoom,
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final r = await pipeline.scrape(_q);
      expect(r!.title, 'HIGH');

      // 竞速者是一起起跑的，高优先级成功后我们就 return 了，
      // 剩下没被 await 的 future 若抛异常就会变成未处理的异步错误
      // （在 Flutter 里直接打到 zone 的错误回调上）。这里等它们全部落地。
      await pumpEventQueue();
    });

    test('全部未命中且兜底也没有 → null，不抛', () async {
      final pipeline = ScraperPipeline([
        _Fake('high', run: (_) async => null),
        _Fake('local', run: (_) async => null),
      ]);

      expect(await pipeline.scrape(_q), isNull);
    });

    test('空列表 → null，不抛', () async {
      expect(await ScraperPipeline(const []).scrape(_q), isNull);
    });

    test('顺序即契约：本地放最后才对', () async {
      final tmdb = _Fake('tmdb', run: (_) async => _meta('TMDB'));
      final local = _Fake('local', run: (_) async => _meta('LOCAL'));

      final good = await ScraperPipeline([tmdb, local]).scrape(_q);
      expect(good!.title, 'TMDB');

      // 反过来放：本地成了竞速者、tmdb 成了兜底 —— 本地永远赢。
      // 这条断言是把那个「顺序反了也不报错、只是结果全变成本地解析」
      // 的坑钉在测试里。
      final tmdb2 = _Fake('tmdb', run: (_) async => _meta('TMDB'));
      final local2 = _Fake('local', run: (_) async => _meta('LOCAL'));
      final bad = await ScraperPipeline([local2, tmdb2]).scrape(_q);
      expect(bad!.title, 'LOCAL');
      expect(tmdb2.calls, 0);
    });
  });
}
