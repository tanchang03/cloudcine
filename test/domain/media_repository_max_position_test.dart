import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「历史最大播放位置」在仓储层的契约。
///
/// ## 它和续播点是两回事
///
///   - `resumePositionMs`（续播点）回答「**这次**从哪儿接着播」—— 会变，
///     看完会被清成 NULL；
///   - `maxPositionMs`（历史最大位置）回答「**这一集我看过没有 / 看到哪儿了**」
///     —— 只增不减、永不清除。
///
/// 详情页文件列表底下那条进度条读的是后者。用前者画的话，用户刚看完一集
/// 回来，那一行会显示 0% —— 恰好是他最想看到 100% 的时刻。
///
/// 这份契约两个实现都要满足（`InMemoryMediaRepository` 与
/// `DriftMediaRepository`），所以每一条都只写「行为」，不写实现细节。
void main() {
  final ts = DateTime(2026, 10, 3);

  MediaItem item(String fileId) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd1',
        dirPath: '/剧集/看过的剧/',
        groupKey: '看过的剧',
        kind: MediaKind.episode,
        firstSeenAt: ts,
        updatedAt: ts,
      );

  /// 建一个装着 [fileIds] 这几个条目的内存库，返回 (仓储, **主键**列表)。
  ///
  /// ⚠️ 返回的是 `MediaItem.id`（`provider:fileId`），不是传进来的 fileId ——
  /// 两者差一个前缀，混用的话这些用例会「全部通过但什么都没测到」。
  Future<(MediaRepository, List<String>)> seeded(List<String> fileIds) async {
    final items = fileIds.map(item).toList();
    final repo = InMemoryMediaRepository();
    await repo.upsertItems(items);
    return (repo, items.map((i) => i.id).toList(growable: false));
  }

  test('存了就能按 id 读回来', () async {
    final (repo, ids) = await seeded(['f1', 'f2']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 12));

    final max = await repo.maxPositions(ids);
    expect(max[ids[0]], const Duration(minutes: 12));
  });

  test('只增不减 —— 回拖 / 重看不会让进度条退回去', () async {
    final (repo, ids) = await seeded(['f1']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 40));
    // 用户回拖到 5 分钟，播放器照常上报 —— 但历史最大位置不能被它拉回去。
    await repo.saveMaxPosition(ids[0], const Duration(minutes: 5));

    final max = await repo.maxPositions(ids);
    expect(
      max[ids[0]],
      const Duration(minutes: 40),
      reason: '这一列存的是「看过的最远位置」。跟着上报位置走的话，用户回拖'
          '一次进度条就退回去一次，而那正是他想回头补看的地方 —— '
          '进度条会变成「播放头在哪」，与「看过没有」完全是两件事。',
    );
  });

  test('写一个更靠后的位置会推进它', () async {
    final (repo, ids) = await seeded(['f1']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 12));
    await repo.saveMaxPosition(ids[0], const Duration(minutes: 47));

    final max = await repo.maxPositions(ids);
    expect(max[ids[0]], const Duration(minutes: 47));
  });

  test('写 0 / 负位置是**无操作**，不会造出一条「看过」的记录', () async {
    final (repo, ids) = await seeded(['f1']);

    await repo.saveMaxPosition(ids[0], Duration.zero);
    await repo.saveMaxPosition(ids[0], const Duration(seconds: -30));

    final max = await repo.maxPositions(ids);
    expect(
      max.containsKey(ids[0]),
      isFalse,
      reason: '这一列只增不减，一旦被写成 0，那一行就再也回不到「没看过」了 —— '
          '而「刚点开就退出」本来就不该算看过。',
    );
  });

  test('0 也不会把已有的进度拉下来', () async {
    final (repo, ids) = await seeded(['f1']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 12));
    await repo.saveMaxPosition(ids[0], Duration.zero);

    final max = await repo.maxPositions(ids);
    expect(max[ids[0]], const Duration(minutes: 12));
  });

  test('从没播过的条目不出现在结果里（缺键 = 没看过）', () async {
    final (repo, ids) = await seeded(['f1', 'f2']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 12));

    final max = await repo.maxPositions(ids);
    expect(
      max.keys,
      [ids[0]],
      reason: 'UI 用「键在不在」判断画不画进度条。给没播过的条目补一条 0 会让'
          '每一行都出现一条空槽 —— 满屏噪声，且看不出哪些真看过。',
    );
  });

  test('只问其中几个 id 时不返回别人的进度', () async {
    final (repo, ids) = await seeded(['f1', 'f2']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 12));
    await repo.saveMaxPosition(ids[1], const Duration(minutes: 30));

    final max = await repo.maxPositions([ids[1]]);
    expect(max.keys, [ids[1]]);
  });

  test('空 id 列表不查库，直接返回空表', () async {
    final (repo, _) = await seeded(['f1']);
    expect(await repo.maxPositions(const []), isEmpty);
  });

  test('条目被删掉时它的历史进度跟着走（不留孤儿）', () async {
    final (repo, ids) = await seeded(['f1', 'f2']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 12));
    await repo.deleteItem(ids[0]);

    final max = await repo.maxPositions(ids);
    expect(
      max.containsKey(ids[0]),
      isFalse,
      reason: '删掉一条记录之后它的进度不该还在。留着的话，同一个 fid 以后'
          '重新入库（重扫 / 换目录）会凭空继承一段早就作废的进度。',
    );
  });

  test('续播点与历史最大位置互不影响', () async {
    final (repo, ids) = await seeded(['f1']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 40));
    // 看完了 → 续播点被清掉（这是既有语义，不能动）。
    await repo.saveResumePosition(ids[0], null);

    final resume = await repo.resumePositions(ids);
    final max = await repo.maxPositions(ids);

    expect(resume.containsKey(ids[0]), isFalse, reason: '看完清续播点');
    expect(
      max[ids[0]],
      const Duration(minutes: 40),
      reason: '但历史最大位置**不受影响** —— 这一条正是这个功能存在的理由：'
          '刚看完的一集必须稳定显示满格。',
    );
  });
}
