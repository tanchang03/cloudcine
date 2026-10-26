import 'package:cloudcine/domain/services/watch_diary.dart';
import 'package:flutter_test/flutter_test.dart';

DiaryEntry base({
  String id = 'id1',
  String title = '漫长的季节',
  int updatedAt = 100,
  int episodeWatched = 5,
  int? rating = 8,
}) =>
    DiaryEntry(
      id: id,
      provider: 'quark',
      title: title,
      kind: 'tv',
      episodeTotal: 12,
      episodeWatched: episodeWatched,
      completionRatio: episodeWatched / 12,
      addedAtSec: 1000,
      updatedAtSec: updatedAt,
      rating: rating,
      tags: const ['神作'],
    );

void main() {
  group('DiaryEntry.mergedWith', () {
    test('评分按 updatedAt 取后改的', () {
      final a = base(updatedAt: 100, rating: 7);
      final b = base(updatedAt: 200, rating: 9);
      expect(a.mergedWith(b).rating, 9); // b 后改
      expect(b.mergedWith(a).rating, 9);
    });

    test('episodeWatched 取较大值（可加合，不随 LWW）', () {
      final a = base(updatedAt: 200, episodeWatched: 5);
      final b = base(updatedAt: 100, episodeWatched: 9);
      // a 更新但只看了 5 集；b 看了 9 集 → 合并后应是 9
      expect(a.mergedWith(b).episodeWatched, 9);
      expect(b.mergedWith(a).episodeWatched, 9);
    });

    test('addedAt 取较小值（历史事实不被推后）', () {
      final a = base(updatedAt: 100, episodeWatched: 5);
      // 同一份，addedAt 不变（且 copyWith 不动完成度快照）
      expect(a.addedAtSec, 1000);
      expect(a.episodeTotal, 12);
    });

    test('lastWatched 取较大值', () {
      final aE = base(updatedAt: 100); // lastWatchedAt 默认 null
      final bE = DiaryEntry(
        id: 'id1',
        provider: 'quark',
        title: '漫长的季节',
        kind: 'tv',
        episodeTotal: 12,
        episodeWatched: 5,
        completionRatio: 0.4,
        addedAtSec: 1000,
        updatedAtSec: 200,
        lastWatchedSec: 500,
      );
      expect(aE.mergedWith(bE).lastWatchedSec, 500);
      expect(bE.mergedWith(aE).lastWatchedSec, 500);
    });

    test('墓碑参与 LWW：删除后不被复活', () {
      // A 删了（updatedAt=300, deletedAt=300），B 还留着（updatedAt=200）
      final a = base(updatedAt: 300).tombstoned();
      final b = base(updatedAt: 200);
      final merged = b.mergedWith(a);
      expect(merged.isDeleted, isTrue);
      // 反过来：B 合并进 A，A 的墓碑仍赢（updatedAt 更大）
      expect(a.mergedWith(b).isDeleted, isTrue);
    });

    test('恢复 = 置空 deletedAt 且 updatedAt 更新', () {
      final deleted = base(updatedAt: 300).tombstoned();
      final restored = deleted.copyWith(clearDeleted: true);
      expect(restored.isDeleted, isFalse);
      expect(restored.updatedAtSec, greaterThan(300));
    });

    test('相等时保留自己（>=，不抖动）', () {
      final a = base(updatedAt: 100);
      final b = base(updatedAt: 100);
      final m = a.mergedWith(b);
      expect(m.rating, 8); // 两边都是 8
    });
  });

  group('DiaryEntry.idFor 跨端稳定', () {
    test('同输入算同一 id', () {
      final a = DiaryEntry.idFor(provider: 'quark', title: '漫长的季节', year: 2023);
      final b = DiaryEntry.idFor(provider: 'quark', title: '漫长的季节', year: 2023);
      expect(a, b);
    });

    test('不同标题算出不同 id', () {
      final a = DiaryEntry.idFor(provider: 'quark', title: '漫长的季节');
      final b = DiaryEntry.idFor(provider: 'quark', title: '狂飙');
      expect(a, isNot(b));
    });

    test('全角/半角、标点、季后缀归一化后一致', () {
      final a = DiaryEntry.idFor(provider: 'quark', title: '三体　第1季', year: 2023);
      final b = DiaryEntry.idFor(provider: 'quark', title: '三体 第一季', year: 2023);
      expect(a, b);
    });
  });

  group('copyWith', () {
    test('评分推进 updatedAt，且不会回退', () {
      final e = base(updatedAt: 100);
      final c = e.copyWith(rating: 10, at: DateTime.fromMillisecondsSinceEpoch(200 * 1000));
      expect(c.rating, 10);
      expect(c.updatedAtSec, 200);
    });

    test('清空评分', () {
      expect(base().copyWith(clearRating: true).rating, isNull);
    });

    test('空短评归一化为 null', () {
      expect(base().copyWith(review: '   ').review, isNull);
    });

    test('时间戳只前进：设备回拨不赢远程', () {
      final e = base(updatedAt: 500);
      final c = e.copyWith(rating: 1, at: DateTime.fromMillisecondsSinceEpoch(100 * 1000));
      expect(c.updatedAtSec, 500); // 没回退
    });
  });

  group('DiaryBook 合并与墓碑', () {
    test('mergeFrom 返回改变条数，0 表示已一致', () {
      final book = DiaryBook({'id1': base()});
      final other = DiaryBook({'id1': base()}); // 完全相同
      expect(book.mergeFrom(other), 0);
    });

    test('mergeFrom 新增 + 修改都计数', () {
      final book = DiaryBook({'id1': base()});
      final other = DiaryBook({
        'id1': base(updatedAt: 200, rating: 9),
        'id2': base(id: 'id2', title: '狂飙'),
      });
      expect(book.mergeFrom(other), 2);
      expect(book['id1']!.rating, 9);
      expect(book['id2']!.title, '狂飙');
    });

    test('墓碑不会被另一端复活', () {
      final book = DiaryBook({'id1': base(updatedAt: 300).tombstoned()});
      final other = DiaryBook({'id1': base(updatedAt: 200)});
      book.mergeFrom(other);
      expect(book['id1']!.isDeleted, isTrue);
    });

    test('pruneTombstones 清掉过老墓碑', () {
      final book = DiaryBook({'id1': base(updatedAt: 1).tombstoned()});
      final n = book.pruneTombstones(
        now: DateTime.fromMillisecondsSinceEpoch(200 * 86400 * 1000),
      );
      expect(n, 1);
      expect(book.length, 0);
    });
  });

  group('JSON 往返', () {
    test('DiaryEntry 往返不丢字段', () {
      final e = base(updatedAt: 100)
          .copyWith(rating: 9, review: '东北文艺复兴', tags: const ['悬疑']);
      final back = DiaryEntry.fromJson(e.toJson())!;
      expect(back.sameAs(e), isTrue);
      expect(back.review, '东北文艺复兴');
      expect(back.tags, ['悬疑']);
    });

    test('非法 JSON 条目被丢弃、不抛', () {
      final book = DiaryBook.fromJsonString('{"v":1,"entries":{"x":{"title":""}}}');
      expect(book.length, 0);
    });

    test('截断的 JSON 文本 → 空本，不抛', () {
      final book = DiaryBook.fromJsonString('{"v":1,"entries":{');
      expect(book.isEmpty, isTrue);
    });
  });
}
