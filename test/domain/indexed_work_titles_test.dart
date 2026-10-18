import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/indexed_work_titles.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「已入库文件 → 它在媒体库里属于哪部作品」。
///
/// 这份映射唯一的用途是让目录视图的「已在库」标签后面带上作品名，所以这里
/// 每条断言都对应一个**界面上看得见、但不报错**的症状：标签写了错的作品、
/// 归一过的文件显示成「查不到作品」、或者本该在库的文件被标成没入库。
void main() {
  final now = DateTime(2026, 10, 17);

  MediaItem item(String fileId, String groupKey) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd',
        dirPath: '/来自：分享/仙逆/弑仙之战/',
        groupKey: groupKey,
        kind: MediaKind.episode,
        firstSeenAt: now,
        updatedAt: now,
      );

  MediaWork work(
    String key,
    String title, {
    String? mergedInto,
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: title,
        mergedInto: mergedInto,
        updatedAt: now,
      );

  group('归属作品', () {
    test('同一 group_key 的文件报同一部作品的标题', () {
      final out = indexedWorkTitles(
        items: [item('a', '仙逆'), item('b', '仙逆')],
        works: [work('仙逆', '仙逆')],
      );

      expect(out, {'quark:a': '仙逆', 'quark:b': '仙逆'});
    });

    test('别名行报**归一目标**的标题，不是别名自己的', () {
      // 现场口径：`group_key` 可能是已被折叠走的源作品（`mergedInto` 非空），
      // 而海报墙上显示的是目标那一部 —— 报别名会让用户去墙上找一部
      // 根本不存在的作品。
      final out = indexedWorkTitles(
        items: [item('a', 'renegadeimmortal')],
        works: [
          work('仙逆', '仙逆'),
          work('renegadeimmortal', 'Renegade Immortal', mergedInto: '仙逆'),
        ],
      );

      expect(out['quark:a'], '仙逆');
    });

    test('查不到作品行 → 键**照样在**，值为空串', () {
      // 「在不在库」与「在哪一部下面」必须分开：丢掉这个键会把一条明明在
      // 索引里的文件显示成「未入库」，用户于是去点「加入媒体库」。
      final out = indexedWorkTitles(
        items: [item('a', '不存在的工作')],
        works: const <MediaWork>[],
      );

      expect(out.containsKey('quark:a'), isTrue);
      expect(out['quark:a'], '');
    });

    test('目标行缺失时退回别名自己的标题（不留空）', () {
      final out = indexedWorkTitles(
        items: [item('a', 'src')],
        works: [work('src', '源作品', mergedInto: '已被删掉的目标')],
      );

      expect(out['quark:a'], '源作品');
    });

    test('标题两端空白被清掉（标签靠它拼字）', () {
      final out = indexedWorkTitles(
        items: [item('a', 'k')],
        works: [work('k', '  仙逆  ')],
      );

      expect(out['quark:a'], '仙逆');
    });

    test('没有文件 → 空映射', () {
      expect(
        indexedWorkTitles(items: const [], works: [work('k', 't')]),
        isEmpty,
      );
    });
  });
}
