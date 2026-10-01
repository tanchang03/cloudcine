import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/ui/pages/library_page.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// 列表为空时，那句提示与那个按钮。
///
/// ## 为什么值得一个文件
///
/// 原先这里的分支是「提示语按条件分两种，按钮一律 `clear()`」，而 `clear()`
/// 是**全部复位** —— 只打了搜索词的用户点「清空筛选」，连分类栏选的位置
/// 和排序都一起丢掉。这类 bug 不报错、不在日志里留痕，只表现为「用户莫名
/// 其妙地回到了全部」，而且他不会把这两件事联系起来。
///
/// 第二条断言（按钮清的范围）是重点：**按钮的用途是让用户重新看到内容**，
/// 所以它必须清掉全部在用的条件。同时设了搜索词与年代却只清一个，列表
/// 很可能还是空的 —— 用户会认为这个按钮坏了。
void main() {
  const plain = LibraryFilter();

  test('两组都在用 → 两个都清，且保留分类', () {
    const filter = LibraryFilter(
      category: MediaCategory.movie,
      query: '魔法',
      decades: {2020},
      genres: {'动画'},
    );

    final hint = libraryEmptyHint(filter);

    expect(hint.action, LibraryEmptyAction.clearExtraAndQuery);
    expect(
      hint.action,
      isNot(LibraryEmptyAction.clearAll),
      reason: '只清掉一个的话列表很可能还是空的（另一个条件仍然在收窄），'
          '用户会认为按钮坏了。',
    );
    expect(
      hint.body,
      contains('魔法'),
      reason: '提示语要带上用户自己打的词 —— 「没有匹配的作品」不带词的话，'
          '用户没法确认列表筛的到底是不是他想要的那个词。',
    );
  });

  test('只有年代 / 类型 → 清那两组，保留分类与搜索词', () {
    const filter = LibraryFilter(
      category: MediaCategory.anime,
      decades: {1990},
    );

    final hint = libraryEmptyHint(filter);

    expect(hint.action, LibraryEmptyAction.clearExtra);
    expect(hint.actionLabel, '清空筛选');
    expect(
      hint.body,
      contains('年代'),
      reason: '提示语要说出清的是哪一类条件，否则用户点完不知道刚才是什么在拦着。',
    );
  });

  test('只有搜索词 → 只清搜索词，分类栏不动', () {
    const filter = LibraryFilter(
      category: MediaCategory.series,
      query: '某个不存在的片名',
    );

    final hint = libraryEmptyHint(filter);

    expect(
      hint.action,
      LibraryEmptyAction.clearQuery,
      reason: '`clear()` 会把分类栏选的位置一起复位。用户点的是「清空搜索」，'
          '不该连栏目都丢掉。',
    );
    expect(hint.actionLabel, '清空搜索');
    expect(hint.body, contains('某个不存在的片名'));
  });

  test('什么条件都没有（只切了分类）→ 回到全部', () {
    const filter = LibraryFilter(category: MediaCategory.documentary);

    final hint = libraryEmptyHint(filter);

    expect(hint.action, LibraryEmptyAction.clearAll);
    expect(hint.actionLabel, '回到全部');
    expect(
      hint.body,
      contains('换个分类'),
      reason: '这一栏本来就空，跟「筛选没筛到」是两件事。让用户去「重新扫描」'
          '比让他换分类更没用。',
    );
  });

  test('搜索词只有空白字符 → 不算条件', () {
    const filter = LibraryFilter(category: MediaCategory.movie, query: '   ');

    expect(
      libraryEmptyHint(filter).action,
      LibraryEmptyAction.clearAll,
      reason: '判据必须与 `LibraryFilter.isEmpty` / `workListProvider` 一致：'
          '那两处都是 `query.trim()`。只判 `isNotEmpty` 的话，用户打了几个'
          '空格再删干净，这里会让他去「清空搜索」—— 而搜索框已经是空的了。',
    );
  });

  test('未设任何条件时不会误判成「有筛选」', () {
    expect(libraryEmptyHint(plain).action, LibraryEmptyAction.clearAll);
  });
}
