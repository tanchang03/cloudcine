import 'dart:async';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/scraper.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个可编程的假刮削器。
class _Fake implements MetadataScraper {
  _Fake(
    this.id, {
    this.enabled = true,
    required this.run,
    this.onSearch,
    this.onResolve,
  });

  @override
  final String id;

  final bool enabled;
  final Future<ScrapedMetadata?> Function(ScrapeQuery query) run;

  /// 手动通道：不传就是「这个源给不出候选」。
  final Future<List<ScrapeCandidate>> Function(ScrapeQuery query)? onSearch;
  final Future<ScrapedMetadata?> Function(ScrapeCandidate candidate)? onResolve;

  int calls = 0;
  int searchCalls = 0;
  int resolveCalls = 0;

  @override
  String get displayName => id;

  @override
  bool get isEnabled => enabled;

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) {
    calls++;
    return run(query);
  }

  @override
  Future<List<ScrapeCandidate>> search(ScrapeQuery query) {
    searchCalls++;
    return onSearch?.call(query) ?? Future.value(const []);
  }

  @override
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) {
    resolveCalls++;
    return onResolve?.call(candidate) ?? Future.value(null);
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

  group('ScraperPipeline.search（手动挑选用的候选）', () {
    test('按优先级拼接**所有**源的候选，一个都不丢', () async {
      // 与 scrape 的跑法刻意不同：那个是「并发起跑、取第一个成功的」，
      // 因为自动刮削只要一个答案；这里是用户要自己挑，所以每个源的
      // 候选都必须给出来。
      final pipeline = ScraperPipeline([
        _Fake(
          'tmdb',
          run: (_) async => null,
          onSearch: (_) async => const [
            ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '甲'),
          ],
        ),
        _Fake(
          'douban',
          run: (_) async => null,
          onSearch: (_) async => const [
            ScrapeCandidate(source: 'douban', sourceId: '2', title: '乙'),
          ],
        ),
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final found = await pipeline.search(_q);

      expect(found.map((c) => c.title), ['甲', '乙']);
    });

    test('一个源搜挂了，其他源的候选照常返回', () async {
      final pipeline = ScraperPipeline([
        _Fake(
          'boom',
          run: (_) async => null,
          onSearch: (_) async => throw StateError('网络库没兜住'),
        ),
        _Fake(
          'douban',
          run: (_) async => null,
          onSearch: (_) async => const [
            ScrapeCandidate(source: 'douban', sourceId: '2', title: '乙'),
          ],
        ),
      ]);

      expect(
        (await pipeline.search(_q)).map((c) => c.title),
        ['乙'],
        reason: '让对话框整个空掉比少一个源糟糕得多 —— 用户会以为'
            '「这个词在哪儿都搜不到」。',
      );
    });

    test('未启用的源不参与搜索', () async {
      final disabled = _Fake(
        'off',
        enabled: false,
        run: (_) async => null,
        onSearch: (_) async => const [
          ScrapeCandidate(source: 'off', sourceId: '1', title: '甲'),
        ],
      );
      final pipeline = ScraperPipeline([
        disabled,
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      expect(await pipeline.search(_q), isEmpty);
      expect(disabled.searchCalls, 0);
    });

    test('本地兜底源也给不出候选（它没有 search 能力）', () async {
      final pipeline = ScraperPipeline([
        _Fake('tmdb', run: (_) async => null),
        const LocalFilenameScraper(),
      ]);

      expect(await pipeline.search(_q), isEmpty);
    });

    test('指定 sourceId → 只搜那一个源，别的源一次都不发', () async {
      final tmdb = _Fake(
        'tmdb',
        run: (_) async => null,
        onSearch: (_) async => const [
          ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '甲'),
        ],
      );
      final douban = _Fake(
        'douban',
        run: (_) async => null,
        onSearch: (_) async => const [
          ScrapeCandidate(source: 'douban', sourceId: '2', title: '乙'),
        ],
      );
      final pipeline = ScraperPipeline([tmdb, douban]);

      final found = await pipeline.search(_q, sourceId: 'douban');

      expect(found.map((c) => c.title), ['乙']);
      expect(
        tmdb.searchCalls,
        0,
        reason: '用户选了「只在豆瓣搜」时，TMDB 的额度没必要花 —— '
            '而这正是这个筛选存在的全部意义。',
      );
      expect(douban.searchCalls, 1);
    });

    test('sourceId 为 null → 照旧搜全部（不改变原行为）', () async {
      final pipeline = ScraperPipeline([
        _Fake(
          'tmdb',
          run: (_) async => null,
          onSearch: (_) async => const [
            ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '甲'),
          ],
        ),
        _Fake(
          'douban',
          run: (_) async => null,
          onSearch: (_) async => const [
            ScrapeCandidate(source: 'douban', sourceId: '2', title: '乙'),
          ],
        ),
      ]);

      expect((await pipeline.search(_q)).map((c) => c.title), ['甲', '乙']);
    });

    test('sourceId 指向不在流水线里的源 → 空列表，不退回「搜全部」', () async {
      final tmdb = _Fake(
        'tmdb',
        run: (_) async => null,
        onSearch: (_) async => const [
          ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '甲'),
        ],
      );
      final pipeline = ScraperPipeline([tmdb]);

      expect(
        await pipeline.search(_q, sourceId: 'douban'),
        isEmpty,
        reason: '用户选了一个当前没配好的源（比如 Cookie 被清空了）。'
            '这时退回「搜全部」会把 TMDB 的候选冒充成他要找的那一家 —— '
            '宁可空，也不能给错来源的结果。',
      );
      expect(tmdb.searchCalls, 0);
    });
  });

  group('ScraperPipeline.availableSources / displayNameOf（给 UI 用）', () {
    test('availableSources 只列已启用且能出候选的源，排除本地兜底', () {
      final pipeline = ScraperPipeline([
        _Fake('tmdb', run: (_) async => null),
        _Fake('douban', enabled: false, run: (_) async => null),
        const LocalFilenameScraper(),
      ]);

      final sources = pipeline.availableSources;

      expect(sources.map((s) => s.id), ['tmdb']);
      expect(
        sources.map((s) => s.displayName),
        ['tmdb'],
        reason: '本地文件名解析永远返回空候选，把它列进「来源筛选」'
            '只会给用户一个点了没反应的选项。',
      );
    });

    test('displayNameOf 按 id 查展示名；查不到返回 null', () {
      final pipeline = ScraperPipeline([
        _Fake('tmdb', run: (_) async => null),
        const LocalFilenameScraper(),
      ]);

      expect(pipeline.displayNameOf('tmdb'), 'tmdb');
      expect(pipeline.displayNameOf('local'), '文件名解析');
      expect(
        pipeline.displayNameOf('nope'),
        isNull,
        reason: '查不到时返回 null，让调用方决定怎么兜底 —— 而不是'
            '把原始 id 直接贴进用户可见的文案里。',
      );
    });
  });

  group('ScraperPipeline.resolve（用户选中之后）', () {
    test('按候选的 source 找回对应刮削器', () async {
      final tmdb = _Fake(
        'tmdb',
        run: (_) async => null,
        onResolve: (c) async => _meta('TMDB:${c.sourceId}'),
      );
      final douban = _Fake(
        'douban',
        run: (_) async => null,
        onResolve: (c) async => _meta('DOUBAN:${c.sourceId}'),
      );
      final pipeline = ScraperPipeline([tmdb, douban]);

      final r = await pipeline.resolve(
        const ScrapeCandidate(source: 'douban', sourceId: '2', title: '乙'),
      );

      expect(r!.title, 'DOUBAN:2');
      expect(douban.resolveCalls, 1);
      expect(tmdb.resolveCalls, 0, reason: '不能拿别的源去解析这个候选。');
    });

    test('候选来源不在流水线里 → null（不猜、也不退回兜底）', () async {
      final pipeline = ScraperPipeline([
        _Fake('tmdb', run: (_) async => null),
        const LocalFilenameScraper(),
      ]);

      expect(
        await pipeline.resolve(
          const ScrapeCandidate(source: 'douban', sourceId: '2', title: '乙'),
        ),
        isNull,
        reason: '用户换掉了设置（比如把豆瓣 Cookie 清空了），流水线重建后'
            '对话框里那份候选就成了孤儿 —— 这时宁可说「找不到来源」，'
            '也不能拿别的源的结果顶上。',
      );
    });

    test('空流水线 → null，不抛', () async {
      expect(
        await ScraperPipeline(const []).resolve(
          const ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '甲'),
        ),
        isNull,
      );
    });
  });

  group('候选链：文件名 → 目录名（2026-10-03）', () {
    // 现场：`/来自：分享/仙逆/126 纯享-仙踪-[4K][HEVC][2026-02-01].mp4`。
    // 文件名里没有作品名，`仙逆` 只写在目录上。
    const chain = ScrapeQuery(
      title: '126 纯享-仙踪',
      kind: MediaKind.movie,
      year: 2026,
      fallbacks: [
        ScrapeQuery(
          title: '仙逆',
          kind: MediaKind.episode,
          requireExactTitle: true,
        ),
      ],
    );

    test('主查询落空 → 换兜底词再搜一次，命中就用它', () async {
      final seen = <String>[];
      final online = _Fake('tmdb', run: (q) async {
        seen.add(q.title);
        return q.title == '仙逆' ? _meta('仙逆') : null;
      });
      final pipeline = ScraperPipeline([
        online,
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final r = await pipeline.scrape(chain);

      expect(r!.title, '仙逆');
      expect(seen, ['126 纯享-仙踪', '仙逆'],
          reason: '兜底是「前面全落空才试」，不是「每条都试」—— 并发起跑会把 '
              '3 条候选的额度一次全花掉，而豆瓣匿名额度只有约 10 个搜索词');
    });

    test('主查询命中 → 兜底一次请求都不发', () async {
      final seen = <String>[];
      final online = _Fake('tmdb', run: (q) async {
        seen.add(q.title);
        return _meta('HIT:${q.title}');
      });
      final pipeline = ScraperPipeline([
        online,
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final r = await pipeline.scrape(chain);

      expect(r!.title, 'HIT:126 纯享-仙踪');
      expect(seen, ['126 纯享-仙踪']);
    });

    test('⚠️ 整条链都落空 → 本地兜底仍然只用**主查询**', () async {
      final local = _Fake('local', run: (q) async => _meta('LOCAL:${q.title}'));
      final pipeline = ScraperPipeline([
        _Fake('tmdb', run: (_) async => null),
        local,
      ]);

      final r = await pipeline.scrape(chain);

      expect(
        r!.title,
        'LOCAL:126 纯享-仙踪',
        reason: '本地兜底是「文件名解析」。拿目录名去兜会把作品改名成「仙逆」，'
            '而那是**没海报也没简介**的一次改名 —— 用户只会觉得'
            '「刮了一次，名字反而变了」',
      );
      expect(local.calls, 1, reason: '兜底只跑一次，不是每条候选后面都跑一遍');
    });

    test('没有兜底时行为一字不变', () async {
      final seen = <String>[];
      final pipeline = ScraperPipeline([
        _Fake('tmdb', run: (q) async {
          seen.add(q.title);
          return null;
        }),
        _Fake('local', run: (q) async => _meta('LOCAL:${q.title}')),
      ]);

      final r = await pipeline.scrape(_q);

      expect(seen, ['某片']);
      expect(r!.title, 'LOCAL:某片');
    });

    test('兜底词也走同一条优先级规则（不是「谁先返回算谁」）', () async {
      final high = _Fake(
        'high',
        run: (q) async => q.title == '仙逆' ? _meta('HIGH:仙逆') : null,
      );
      final low = _Fake(
        'low',
        run: (q) async => q.title == '仙逆' ? _meta('LOW:仙逆') : null,
      );
      final pipeline = ScraperPipeline([
        high,
        low,
        _Fake('local', run: (_) async => _meta('LOCAL')),
      ]);

      final r = await pipeline.scrape(chain);

      expect(r!.title, 'HIGH:仙逆',
          reason: '候选链只改「用哪个词」，不改「按优先级取第一个成功的」');
    });
  });
}
