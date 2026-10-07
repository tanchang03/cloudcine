import 'package:cloudcine/core/utils/directory_anchor.dart';
import 'package:cloudcine/core/utils/directory_title.dart';
import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// 目录锚点：**新文件该归到哪部已有剧集下**。
///
/// 这些用例守的是 2026-10-07 那三连（剧集页看不见 / 追更检查报「没有更新」/
/// 用户得自己手动归一）。判据写错的代价全是**静默**的：
///
///   - 漏锚（该锚不锚）→ 又分叉出一部作品，用户找不到那几十集；
///   - 误锚（不该锚却锚）→ 把不相干的片子揉进同一部剧，而 `media_items`
///     的 `group_key` **永不改写**，得手动归一才拆得开。
///
/// 所以三道闸（剧集 / 唯一 / 严格子目录）每一条都要有一条用例钉住。
void main() {
  /// 现场那部老剧：20 个 `01.mp4…`，文件都在 `/来自：分享/兰丨香R-故/`。
  const liveDir = '/来自：分享/兰丨香R-故/';

  /// 后来新开的那一层。
  const liveSubDir =
      '/来自：分享/兰丨香R-故/兰z.香z.如z.故  去头去尾版 (2026) 4K/';

  AnchorWork episode({
    required String key,
    required String title,
    required Set<String> dirs,
  }) =>
      AnchorWork(
        key: key,
        title: title,
        kind: MediaKind.episode,
        isAlias: false,
        dirs: dirs,
      );

  AnchorWork movie({
    required String key,
    required String title,
    required Set<String> dirs,
  }) =>
      AnchorWork(
        key: key,
        title: title,
        kind: MediaKind.movie,
        isAlias: false,
        dirs: dirs,
      );

  DirectoryAnchorIndex indexOf(List<AnchorWork> works) =>
      DirectoryAnchorIndex.of(works);

  group('现场复现：剧集目录下新开一层', () {
    test('子目录里的新集 → 锚到已有那部剧', () {
      final index = indexOf([
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {liveDir}),
      ]);

      final anchor = index.anchorFor(liveSubDir);

      expect(anchor, isNotNull, reason: '不锚的话这 47 集会另起一部作品');
      expect(anchor!.groupKey, '兰丨香r故');
      expect(anchor.title, '兰香如故');
    });

    test('末级目录名与剧名零公共字符，照样锚得上', () {
      // `去头去尾版 4K` 与《兰香如故》一个字符都不共 —— 判据**不看名字**。
      final index = indexOf([
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {liveDir}),
      ]);

      expect(index.anchorFor('$liveDir去头去尾版 4K/')?.groupKey, '兰丨香r故');
    });

    test('多层子目录同样锚（新开的那一层下面还有一层）', () {
      final index = indexOf([
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {liveDir}),
      ]);

      expect(index.anchorFor('${liveSubDir}S01/')?.groupKey, '兰丨香r故');
    });

    test('目录路径不带尾斜杠也认（口径与 MediaItem.dirPath 一致）', () {
      final index = indexOf([
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {liveDir}),
      ]);

      expect(
        index.anchorFor('/来自：分享/兰丨香R-故/兰z.香z.如z.故  去头去尾版 (2026) 4K')
            ?.groupKey,
        '兰丨香r故',
      );
    });
  });

  group('闸 3：必须是**严格**子目录（这条是整套判据的关键）', () {
    test('文件直接躺在剧集目录里 → 不锚', () {
      final index = indexOf([
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {liveDir}),
      ]);

      expect(
        index.anchorFor(liveDir),
        isNull,
        reason: '平铺目录（/电影/ 那种形状）就是 `D == A` —— '
            '不挡这一条的话，一部剧 + 一堆电影混放的目录里，'
            '新片会被吸进那部剧',
      );
    });

    test('平铺目录里只有一部剧时，新片不会被吸进去', () {
      // `/来自：分享/我的资源/` 里目前只有一部剧，用户又丢了一部电影进去。
      final index = indexOf([
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {'/来自：分享/我的资源/'}),
      ]);

      expect(index.anchorFor('/来自：分享/我的资源/'), isNull);
    });

    test('兄弟目录（不在它之下）不受影响', () {
      final index = indexOf([
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {liveDir}),
      ]);

      expect(index.anchorFor('/来自：分享/别的剧/'), isNull);
      expect(index.anchorFor('/来自：分享/'), isNull);
    });
  });

  group('闸 1：只有剧集当锚点', () {
    test('电影作品的目录不当锚点', () {
      final index = indexOf([
        movie(key: '流浪地球2#2023', title: '流浪地球2', dirs: {'/电影/'}),
      ]);

      expect(index.anchorFor('/电影/番外/'), isNull);
      expect(index.length, 0, reason: '电影根本不该被登记进索引');
    });
  });

  group('闸 2：目录下不唯一 → 不猜', () {
    test('同一个目录下有两部剧 → 放弃', () {
      final index = indexOf([
        episode(key: 'a剧', title: 'A剧', dirs: {'/来自：分享/合集/'}),
        episode(key: 'b剧', title: 'B剧', dirs: {'/来自：分享/合集/'}),
      ]);

      expect(index.anchorFor('/来自：分享/合集/新一季/'), isNull);
    });

    test('最深一级不唯一时**直接放弃**，不再往更笼统的上级找', () {
      // 父目录唯一、子目录不唯一：子目录是更贴近的证据，它说不了话就不猜。
      final index = indexOf([
        episode(key: '甲', title: '甲剧', dirs: {'/来自：分享/甲剧/'}),
        episode(key: '乙', title: '乙剧', dirs: {'/来自：分享/甲剧/混放/'}),
        episode(key: '丙', title: '丙剧', dirs: {'/来自：分享/甲剧/混放/'}),
      ]);

      expect(index.anchorFor('/来自：分享/甲剧/混放/'), isNull);
    });
  });

  group('根目录与别名行', () {
    test('文件直接在根目录下的作品不登记', () {
      final index = indexOf([
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {'/'}),
      ]);

      expect(index.length, 0);
      expect(index.anchorFor('/任何目录/'), isNull);
    });

    test('别名行（mergedInto != null）不当锚点 —— 会成链', () {
      final index = indexOf([
        AnchorWork(
          key: '兰z香z如z故去头去尾版',
          title: '兰z 香z 如z 故 去头去尾版',
          kind: MediaKind.episode,
          isAlias: true,
          dirs: {liveSubDir},
        ),
      ]);

      expect(index.length, 0);
      expect(index.anchorFor('$liveSubDir第二季/'), isNull);
    });

    test('标题为空的作品不登记', () {
      final index = indexOf([
        episode(key: 'x', title: '   ', dirs: {'/来自：分享/x/'}),
      ]);
      expect(index.length, 0);
    });

    test('一部作品都没有 → 任何目录都锚不到', () {
      final index = indexOf(const []);
      expect(index.isEmpty, isTrue);
      expect(index.anchorFor(liveSubDir), isNull);
    });
  });

  group('最深一级优先', () {
    test('父子两级各有一部剧时，取最贴近的那一级', () {
      final index = indexOf([
        episode(key: '外', title: '兰香如故', dirs: {'/来自：分享/兰香如故/'}),
        episode(key: '内', title: '兰香如故 去头去尾版', dirs: {liveSubDir}),
      ]);

      expect(index.anchorFor('$liveSubDir第2季/')?.groupKey, '内');
      // 子目录自己的文件（D == 内）不锚 —— 闸 3 先看自己那一级。
      expect(index.anchorFor(liveSubDir), isNull);
    });

    test('不越级：被夹在中间的那一层不唯一时，不会跳到更上面去认亲', () {
      // `/甲剧/混放/` 里是乙剧与丙剧；`/甲剧/` 是甲剧。
      // 混放目录里的新文件不该因为「再往上是甲剧」就归到甲剧头上。
      final index = indexOf([
        episode(key: '甲', title: '甲剧', dirs: {'/来自：分享/甲剧/'}),
        episode(key: '乙', title: '乙剧', dirs: {'/来自：分享/甲剧/混放/'}),
      ]);

      expect(index.anchorFor('/来自：分享/甲剧/混放/'), isNull);
      expect(index.anchorFor('/来自：分享/甲剧/混放/新一层/')?.groupKey, '乙');
    });
  });

  group('索引是**可变**的：扫描期登记新作品', () {
    test('register 之后，新登记的目录立刻能锚（BFS 父先子后）', () {
      // 首次扫描：库里一部剧都没有。
      final index = indexOf(const []);
      expect(index.anchorFor(liveSubDir), isNull);

      // 父目录那一批扫完、作品行落库 → 登记。
      index.register(
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {liveDir}),
      );

      expect(
        index.anchorFor(liveSubDir)?.groupKey,
        '兰丨香r故',
        reason: '不登记的话「第一次扫就分叉，得再扫一次才对」',
      );
    });

    test('同一部作品重复登记同一个目录只留一条（不会自己把自己变成「不唯一」）', () {
      final index = indexOf([
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {liveDir}),
      ]);
      index.register(
        episode(key: '兰丨香r故', title: '兰香如故', dirs: {liveDir}),
      );

      expect(index.anchorFor(liveSubDir)?.groupKey, '兰丨香r故');
    });
  });

  group('名字归一化口径（与 WorkMergeSuggester 共用一份）', () {
    test('小写、只留字母数字与汉字', () {
      // ⚠️ `丨`（U+4E28）落在 `\u4e00-\u9fff` 区间里，**会被保留** ——
      //    所以老作品真实的 key 就是 `兰丨香r故`（库里也是这个）。
      expect(normalizeWorkName('兰丨香R-故'), '兰丨香r故');
      expect(normalizeWorkName('Shōgun (2024)'), 'shgun2024');
      expect(normalizeWorkName(null), '');
    });

    test('公共字符数按字符集算，不看顺序', () {
      expect(sharedNameChars('兰丨香R-故', '兰香如故'), 3);
      expect(sharedNameChars('兰z香z如z故去头去尾版', '兰香如故'), 4);
      expect(sharedNameChars('兰亭', '兰香如故'), 1);
      expect(kMinSharedNameChars, 2);
    });
  });
}
