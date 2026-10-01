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
