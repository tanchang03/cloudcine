import 'package:cloudcine/domain/services/playback_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进度条目的**合并规则**与**序列化**。
///
/// 这两件事是整个「进度独立存储 + 跨端同步」的地基，而它们错了之后的症状
/// 全都**不报错**：用户只会看到「进度条倒退了」「另一台设备的进度把我这台
/// 冲掉了」。所以下面每一条断言都对着一个具体症状。
void main() {
  group('ProgressEntry.mergedWith —— 谁赢', () {
    test('updatedAtSec 更大的一方赢，拿走续播点与已读时间', () {
      const older = ProgressEntry(
        resumeMs: 1000,
        playedAtSec: 100,
        updatedAtSec: 100,
      );
      const newer = ProgressEntry(
        resumeMs: 9000,
        playedAtSec: 200,
        updatedAtSec: 200,
      );
      expect(newer.mergedWith(older).resumeMs, 9000);
      expect(older.mergedWith(newer).resumeMs, 9000, reason: '顺序不该影响结果');
      expect(newer.mergedWith(older).playedAtSec, 200);
    });

    test('⛔ 历史最大位置取较大值，**与谁赢无关**（进度条绝不倒退）', () {
      // 这一条是最容易写错的：把 maxMs 也交给 LWW 的话，
      // 「另一台机器看得更远」会被一次较晚但位置较浅的写入抹掉。
      const laterButShallower = ProgressEntry(
        resumeMs: 60_000,
        maxMs: 60_000,
        updatedAtSec: 500,
      );
      const earlierButDeeper = ProgressEntry(
        maxMs: 1_800_000,
        updatedAtSec: 100,
      );
      final merged = laterButShallower.mergedWith(earlierButDeeper);
      expect(merged.resumeMs, 60_000, reason: '续播点归赢家');
      expect(merged.maxMs, 1_800_000, reason: '历史最远位置是并集');
      expect(merged.updatedAtSec, 500);
    });

    test('已读时间也只前进（「最近播放」排序不倒退）', () {
      const winner = ProgressEntry(playedAtSec: 100, updatedAtSec: 100);
      const loser = ProgressEntry(playedAtSec: 900, updatedAtSec: 50);
      expect(winner.mergedWith(loser).playedAtSec, 900);
    });

    test('updatedAtSec 相等时保留自己 —— 两台机器结果一致，不会来回抖', () {
      const a = ProgressEntry(resumeMs: 111, updatedAtSec: 7);
      const b = ProgressEntry(resumeMs: 222, updatedAtSec: 7);
      expect(a.mergedWith(b).resumeMs, 111);
      expect(b.mergedWith(a).resumeMs, 222);
    });

    test('看完清掉续播点之后合并：续播点为空，但历史进度留着', () {
      const finished = ProgressEntry(maxMs: 3_000_000, updatedAtSec: 900);
      const beforeFinish = ProgressEntry(
        resumeMs: 2_900_000,
        maxMs: 2_900_000,
        updatedAtSec: 800,
      );
      final merged = finished.mergedWith(beforeFinish);
      expect(merged.resumeMs, isNull, reason: '看完了就不该有可续的点');
      expect(merged.maxMs, 3_000_000);
    });
  });

  group('ProgressEntry JSON', () {
    test('空字段被省略 —— 几千条时这是几百 KB 的差别', () {
      const e = ProgressEntry(updatedAtSec: 42);
      expect(e.toJson(), {'u': 42});
      expect(e.toJson().containsKey('r'), isFalse);
    });

    test('往返一致', () {
      const e = ProgressEntry(
        resumeMs: 1234,
        maxMs: 5678,
        playedAtSec: 90,
        updatedAtSec: 91,
      );
      final back = ProgressEntry.fromJson(e.toJson())!;
      expect(back.sameAs(e), isTrue);
    });

    test('缺 u（没有合并判据）的条目被整条丢掉', () {
      expect(ProgressEntry.fromJson({'r': 1, 'm': 2}), isNull);
    });

    test('字段类型不对时只丢那一条，不抛', () {
      expect(ProgressEntry.fromJson({'u': 'not-a-number'}), isNull);
      expect(ProgressEntry.fromJson('nonsense'), isNull);
    });
  });

  group('ProgressBook', () {
    test('两台机器各看一集 → 合并之后**两条都在**（不是整份覆盖）', () {
      final local = ProgressBook({
        'quark:e1': const ProgressEntry(resumeMs: 100, updatedAtSec: 100),
      });
      final remote = ProgressBook({
        'quark:e2': const ProgressEntry(resumeMs: 200, updatedAtSec: 200),
      });
      final changed = local.mergeFrom(remote);
      expect(changed, 1);
      expect(local.length, 2);
      expect(local['quark:e1']!.resumeMs, 100);
      expect(local['quark:e2']!.resumeMs, 200);
    });

    test('内容完全一致时返回 0 —— 调用方据此**不传网盘**', () {
      final a = ProgressBook({
        'x': const ProgressEntry(resumeMs: 1, updatedAtSec: 5),
      });
      final b = ProgressBook({
        'x': const ProgressEntry(resumeMs: 1, updatedAtSec: 5),
      });
      expect(a.mergeFrom(b), 0);
    });

    test('JSON 往返', () {
      final book = ProgressBook({
        'quark:a': const ProgressEntry(
          resumeMs: 10,
          maxMs: 20,
          playedAtSec: 30,
          updatedAtSec: 31,
        ),
        'quark:b': const ProgressEntry(maxMs: 40, updatedAtSec: 41),
      });
      final back = ProgressBook.fromBytes(book.toBytes());
      expect(back.length, 2);
      expect(back['quark:a']!.maxMs, 20);
      expect(back['quark:b']!.resumeMs, isNull);
    });

    test('损坏 / 截断的文件 → 空书，**不抛**（挂在启动路径上）', () {
      expect(ProgressBook.fromJsonString('{"v":1,"items":{').isEmpty, isTrue);
      expect(ProgressBook.fromJsonString('').isEmpty, isTrue);
      expect(ProgressBook.fromJsonString('[]').isEmpty, isTrue);
    });

    test('单条非法只丢那一条，其余照收', () {
      final book = ProgressBook.fromJsonString(
        '{"v":1,"items":{"good":{"u":5,"m":7},"bad":{"r":1},"alsonot":3}}',
      );
      expect(book.length, 1);
      expect(book['good']!.maxMs, 7);
    });
  });
}
