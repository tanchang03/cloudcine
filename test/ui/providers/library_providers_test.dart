import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:cloudcine/ui/providers/library_refresh_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 分类栏上「最近播放」这一栏的筛选状态。
///
/// 它和真正的分类共用一排按钮，但**不是一个分类**（见
/// `LibraryFilter.playedOnly`）。下面每一条都对应一个「用户看着不对但说不出
/// 哪里不对」的场景：两个按钮同时高亮、排序和栏目自相矛盾、空态指错方向。
void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  LibraryFilterController controller() =>
      container.read(libraryFilterProvider.notifier);
  LibraryFilter filter() => container.read(libraryFilterProvider);

  group('「最近播放」与分类互斥', () {
    test('点「最近播放」会退出当前分类', () {
      controller().setCategory(MediaCategory.anime);
      controller().setPlayedOnly();

      expect(filter().playedOnly, isTrue);
      expect(filter().category, isNull,
          reason: '分类栏是**单选组**。两个同时高亮时用户不知道列表到底在筛'
              '什么，而结果看起来又像「动漫栏少了东西」');
    });

    test('点分类会退出「最近播放」', () {
      controller().setPlayedOnly();
      controller().setCategory(MediaCategory.movie);

      expect(filter().playedOnly, isFalse);
      expect(filter().category, MediaCategory.movie);
    });

    test('点「全部」会退出「最近播放」', () {
      controller().setPlayedOnly();
      controller().setCategory(null);

      expect(filter().playedOnly, isFalse);
      expect(filter().category, isNull);
    });
  });

  group('排序', () {
    test('切到「最近播放」时顺带把排序切成按播放时间', () {
      controller().setPlayedOnly();

      expect(filter().sort, WorkSort.recentPlayed,
          reason: '一个按「最近添加」排的「最近播放」列表是自相矛盾的：'
              '用户点这一栏要看的就是「我最近看了什么」，'
              '第一条却不是最近看的那部');
    });

    test('离开「最近播放」不会偷偷改回排序', () {
      controller().setPlayedOnly();
      controller().setCategory(MediaCategory.movie);

      expect(filter().sort, WorkSort.recentPlayed,
          reason: '分不出「排序是刚被隐式设上的」还是「用户自己在排序菜单里'
              '选的」，猜错就会静默改掉用户的选择。排序菜单一直显示着当前'
              '排序，所以这不是隐藏状态 —— 用户看得见，一键就能改');
    });
  });

  group('空态与筛选条件', () {
    test('「最近播放」本身就算有筛选条件', () {
      controller().setPlayedOnly();

      expect(filter().isEmpty, isFalse,
          reason: '它为 true 时页面会给出「媒体库还是空的，去扫描」——'
              '而这一栏为空跟扫描完全无关，用户会白等一次全盘遍历');
      expect(filter().isDefault, isFalse);
    });

    test('clear() 把视图也复位', () {
      controller().setPlayedOnly();
      controller().clear();

      expect(filter(), const LibraryFilter());
    });

    test('toString 里看得出当前是「最近播放」而不是某个分类', () {
      controller().setPlayedOnly();
      expect(filter().toString(), contains('最近播放'));
    });
  });

  group('筛选面板（年代 / 类型）', () {
    test('点一下选中，再点一下取消', () {
      controller().toggleDecade(2020);
      expect(filter().decades, {2020});

      controller().toggleDecade(2020);
      expect(
        filter().decades,
        isEmpty,
        reason: '用户点错一个年代时应该只需要再点一下，而不是清掉整组条件重来',
      );
    });

    test('年代与类型两组互不影响', () {
      controller().toggleDecade(2020);
      controller().toggleGenre('动画');

      expect(filter().decades, {2020});
      expect(filter().genres, {'动画'});

      controller().toggleGenre('动画');
      expect(filter().decades, {2020},
          reason: '取消类型不该顺手把年代也清掉 —— 两组是两个独立的维度');
    });

    test('clearExtra 只清面板里的两组', () {
      controller().setCategory(MediaCategory.anime);
      controller().setQuery('魔法');
      controller().toggleDecade(2020);
      controller().toggleGenre('动画');

      controller().clearExtra();

      expect(filter().decades, isEmpty);
      expect(filter().genres, isEmpty);
      expect(filter().category, MediaCategory.anime,
          reason: '分类栏与搜索框在面板之外、各有自己的清除入口。'
              '面板上的「清空筛选」把它们一起抹掉，用户会莫名其妙地'
              '丢掉刚打的搜索词');
      expect(filter().query, '魔法');
    });

    test('hasExtra 只看这两组', () {
      expect(filter().hasExtra, isFalse);

      controller().setCategory(MediaCategory.movie);
      expect(filter().hasExtra, isFalse, reason: '分类是分类栏的事，不是面板的');

      controller().toggleDecade(2020);
      expect(filter().hasExtra, isTrue);
    });

    test('面板里的条件也算「有筛选条件」', () {
      controller().toggleGenre('动画');

      expect(filter().isEmpty, isFalse,
          reason: '它为 true 时页面会给出「媒体库还是空的，去扫描」——'
              '而筛出来的空跟扫描完全无关');
      expect(filter().isDefault, isFalse);
    });

    test('copyWith 传空集合能清空（不能像 category 那样用 null 表示不改）', () {
      controller().toggleDecade(2020);
      controller().toggleGenre('动画');

      final cleared = filter().copyWith(decades: const <int>{});

      expect(cleared.decades, isEmpty);
      expect(cleared.genres, {'动画'},
          reason: '只传了 decades 就不该动 genres');
    });

    test('相等性按集合**内容**比，不按引用', () {
      // 故意用非 const 字面量：const 会被规范化成同一个对象，
      // 那样连引用相等都能过，测不出真正想钉的东西。
      final a = LibraryFilter(decades: {2020}, genres: {'动画'});
      final b = LibraryFilter(decades: {2020}, genres: {'动画'});

      expect(a == b, isTrue,
          reason: 'Set 没重写 ==（默认是引用相等）。不比内容的话，'
              'Riverpod 会把「内容一样的新实例」当成变化，'
              '让整张海报墙白重建一次');
      expect(a.hashCode, b.hashCode);

      // 与顺序无关
      expect(
        LibraryFilter(decades: {2020, 2010}) ==
            LibraryFilter(decades: {2010, 2020}),
        isTrue,
      );
    });

    test('clear() 把面板条件也复位', () {
      controller().toggleDecade(2020);
      controller().toggleGenre('动画');
      controller().clear();

      expect(filter(), const LibraryFilter());
    });

    test('toString 里看得出筛了哪些', () {
      controller().toggleDecade(2020);
      controller().toggleGenre('动画');
      final text = filter().toString();

      expect(text, contains('2020'));
      expect(text, contains('动画'));
    });
  });

  group('播放记录变化的刷新信号', () {
    test('只有换条播放才推进版本号', () {
      final notifier = container.read(playbackLibraryLinkProvider.notifier);
      expect(container.read(playbackLibraryLinkProvider), 0);

      expect(notifier.report('quark:f1'), isTrue);
      expect(container.read(playbackLibraryLinkProvider), 1);

      // 同一部片子每 10 秒一次的进度回报：**不能**每次都刷 ——
      // 用户在主窗口看海报墙、播放窗口在另一块屏上播片时，
      // 列表会每 10 秒重建一遍。
      expect(notifier.report('quark:f1'), isFalse);
      expect(container.read(playbackLibraryLinkProvider), 1);

      expect(notifier.report('quark:f2'), isTrue,
          reason: '换了新的一条就必须刷：它得出现在「最近播放」的最前面');
      expect(container.read(playbackLibraryLinkProvider), 2);
    });
  });
}
