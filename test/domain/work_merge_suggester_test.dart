import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/work_merge_suggester.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一部作品行。只填建议器真正看的那几列 —— 其余列与判断无关，
/// 填得越少，测试越能说明「哪些列是判据」。
MediaWork _w({
  required String key,
  required String title,
  MediaKind kind = MediaKind.episode,
  int itemCount = 0,
  String? mergedInto,
}) =>
    MediaWork(
      key: key,
      provider: DriveProvider.quark,
      kind: kind,
      title: title,
      itemCount: itemCount,
      mergedInto: mergedInto,
      updatedAt: DateTime(2026, 10, 7),
    );

void main() {
  /// 2026-10-07 的现场，逐字照抄库里的键与目录。
  ///
  /// 左边那部是老作品（20 集 `01.mp4`…`20.mp4`，片名靠目录名兜底）；
  /// 右边那部是刚发现的新子目录（47 集 `S01E01…`，片名取自子目录名）。
  /// 两个 `groupKey` 天然不同 —— 这正是「提示发现了新文件、用户却在
  /// 《兰香如故》里看不到」的全部原因。
  const oldKey = '兰丨香r故';
  const oldDir = '/来自：分享/兰丨香R-故/';
  const newKey = '兰z香z如z故去头去尾版';
  const newDir = '/来自：分享/兰丨香R-故/兰z.香z.如z.故  去头去尾版 (2026) 4K/';

  group('现场复现：子目录里的新作品 → 问一句要不要并入', () {
    test('新作品落在老作品目录之下、名字沾边 → 一条建议', () {
      final suggestions = WorkMergeSuggester.suggest(
        works: [
          _w(key: oldKey, title: '兰香如故', itemCount: 20),
          _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版', itemCount: 47),
        ],
        dirsByWork: {
          oldKey: [oldDir],
          newKey: [newDir],
        },
        touchedKeys: {newKey},
      );

      expect(suggestions, hasLength(1));
      final s = suggestions.single;
      expect(s.sourceKey, newKey, reason: '被并走的是刚发现的那部');
      expect(s.targetKey, oldKey, reason: '留下的是已有的那部');
      expect(s.sourceDir, newDir);
      expect(s.targetDir, oldDir);
      expect(s.mergedItemCount, 67, reason: '20 + 47');
    });

    test('老作品是「刚被碰过」的那个也不反着合 —— 方向恒为「新 → 旧」的目录层级', () {
      // touched 给老作品：它的目录是 newDir 的**上级**，不是子目录，
      // 所以两条 `_nestedPair` 都配不出「子 → 父」，没有建议。
      final suggestions = WorkMergeSuggester.suggest(
        works: [
          _w(key: oldKey, title: '兰香如故', itemCount: 20),
          _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版', itemCount: 47),
        ],
        dirsByWork: {
          oldKey: [oldDir],
          newKey: [newDir],
        },
        touchedKeys: {oldKey},
      );

      expect(
        suggestions,
        isEmpty,
        reason: '把上级并进子目录会把 20 集塞进 47 集那部里，方向是错的',
      );
    });
  });

  group('不打扰：这些情况一条建议都不该出', () {
    test('这次没有新入库的文件（touchedKeys 为空）', () {
      expect(
        WorkMergeSuggester.suggest(
          works: [
            _w(key: oldKey, title: '兰香如故'),
            _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版'),
          ],
          dirsByWork: {
            oldKey: [oldDir],
            newKey: [newDir],
          },
          touchedKeys: const {},
        ),
        isEmpty,
        reason: '重跑一次发现不该被追问同一件事',
      );
    });

    test('目录不嵌套（各占一个目录）', () {
      expect(
        WorkMergeSuggester.suggest(
          works: [
            _w(key: 'a', title: '流浪地球2'),
            _w(key: 'b', title: '流浪地球2 加长版'),
          ],
          dirsByWork: {
            'a': ['/电影/流浪地球2 (2023)/'],
            'b': ['/电影/流浪地球2 加长版 (2023)/'],
          },
          touchedKeys: {'b'},
        ),
        isEmpty,
        reason: '跨目录的同名片子该由「合并到…」或自动归一处理，'
            '目录包含这条判据在这里不成立',
      );
    });

    test('同一目录下但名字毫不相干（0 个公共字符）', () {
      expect(
        WorkMergeSuggester.suggest(
          works: [
            _w(key: 'a', title: '流浪地球2'),
            _w(key: 'b', title: '满江红'),
          ],
          dirsByWork: {
            'a': ['/电影/收藏/'],
            'b': ['/电影/收藏/'],
          },
          touchedKeys: {'b'},
        ),
        isEmpty,
        reason: '一个收藏夹里塞着好几部自成一体的片子，不能因为同目录就合',
      );
    });

    test('名字只共 1 个字符（门槛之下）', () {
      expect(
        WorkMergeSuggester.suggest(
          works: [
            _w(key: 'a', title: '兰香如故'),
            _w(key: 'b', title: '兰亭'),
          ],
          dirsByWork: {
            'a': [oldDir],
            'b': ['$oldDir兰亭/'],
          },
          touchedKeys: {'b'},
        ),
        isEmpty,
      );
    });

    test('源已经是别名行（被折走过）', () {
      expect(
        WorkMergeSuggester.suggest(
          works: [
            _w(key: oldKey, title: '兰香如故'),
            _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版', mergedInto: '别的'),
          ],
          dirsByWork: {
            oldKey: [oldDir],
            newKey: [newDir],
          },
          touchedKeys: {newKey},
        ),
        isEmpty,
      );
    });

    test('目标是别名行（不能当目标，会成链）', () {
      expect(
        WorkMergeSuggester.suggest(
          works: [
            _w(key: oldKey, title: '兰香如故', mergedInto: '更上面的一部'),
            _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版'),
          ],
          dirsByWork: {
            oldKey: [oldDir],
            newKey: [newDir],
          },
          touchedKeys: {newKey},
        ),
        isEmpty,
      );
    });

    test('源自己已经折进了别的作品（manualBlocker 拦得住，建议也该拦）', () {
      expect(
        WorkMergeSuggester.suggest(
          works: [
            _w(key: oldKey, title: '兰香如故'),
            _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版'),
            _w(key: '别的', title: '兰z 香z 如z 故 花絮', mergedInto: newKey),
          ],
          dirsByWork: {
            oldKey: [oldDir],
            newKey: [newDir],
            '别的': ['$newDir花絮/'],
          },
          touchedKeys: {newKey},
        ),
        isEmpty,
        reason: '对话框会亮着按钮却合不动，那种「点了没反应」最像应用坏了',
      );
    });

    test('根目录不当父目录 —— 否则一条建议会退化成「全库任意两行」', () {
      expect(
        WorkMergeSuggester.suggest(
          works: [
            _w(key: 'root', title: '兰香如故'),
            _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版'),
          ],
          dirsByWork: {
            'root': ['/'],
            newKey: [newDir],
          },
          touchedKeys: {newKey},
        ),
        isEmpty,
      );
    });
  });

  group('该出的建议：边界与挑选规则', () {
    test('名字恰好共 2 个字符 → 出建议（门槛本身）', () {
      final suggestions = WorkMergeSuggester.suggest(
        works: [
          _w(key: 'a', title: '遮天'),
          _w(key: 'b', title: '遮天 特别篇'),
        ],
        dirsByWork: {
          'a': ['/动漫/遮天/'],
          'b': ['/动漫/遮天/特别篇/'],
        },
        touchedKeys: {'b'},
      );

      expect(suggestions, hasLength(1));
      expect(suggestions.single.targetKey, 'a');
    });

    test('同一目录里的两部作品也算（目录相等 → 嵌套成立）', () {
      final suggestions = WorkMergeSuggester.suggest(
        works: [
          _w(key: 'a', title: '流浪地球2', itemCount: 1),
          _w(key: 'b', title: '流浪地球2 加长版', itemCount: 1),
        ],
        dirsByWork: {
          'a': ['/电影/收藏/'],
          'b': ['/电影/收藏/'],
        },
        touchedKeys: {'b'},
      );

      expect(suggestions, hasLength(1));
      expect(suggestions.single.sourceDir, '/电影/收藏/');
      expect(suggestions.single.targetDir, '/电影/收藏/');
    });

    test('多个候选目标 → 取目录最贴近（最深）的那一级', () {
      final suggestions = WorkMergeSuggester.suggest(
        works: [
          _w(key: 'top', title: '兰香如故', itemCount: 100),
          _w(key: 'mid', title: '兰香如故', itemCount: 20),
          _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版', itemCount: 47),
        ],
        dirsByWork: {
          'top': ['/来自：分享/'],
          'mid': [oldDir],
          newKey: [newDir],
        },
        touchedKeys: {newKey},
      );

      expect(suggestions, hasLength(1));
      expect(
        suggestions.single.targetKey,
        'mid',
        reason: '最贴近的那一级才是用户心里的「这一部」；'
            '按文件数会挑到 100 集的 top，那是另一回事',
      );
    });

    test('深度并列时取文件更多的目标', () {
      final suggestions = WorkMergeSuggester.suggest(
        works: [
          _w(key: 'few', title: '兰香如故', itemCount: 2),
          _w(key: 'many', title: '兰香如故', itemCount: 20),
          _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版', itemCount: 47),
        ],
        dirsByWork: {
          'few': [oldDir],
          'many': [oldDir],
          newKey: [newDir],
        },
        touchedKeys: {newKey},
      );

      expect(suggestions.single.targetKey, 'many');
    });

    test('一个源只出一条建议，且多个源按 sourceKey 升序', () {
      final suggestions = WorkMergeSuggester.suggest(
        works: [
          _w(key: 'z源', title: '兰香如故 第二版'),
          _w(key: 'a源', title: '兰香如故 第一版'),
          _w(key: oldKey, title: '兰香如故', itemCount: 20),
        ],
        dirsByWork: {
          oldKey: [oldDir],
          'z源': ['$oldDir第二版/'],
          'a源': ['$oldDir第一版/'],
        },
        touchedKeys: {'z源', 'a源'},
      );

      expect(suggestions.map((s) => s.sourceKey).toList(), ['a源', 'z源']);
      expect(suggestions.map((s) => s.targetKey).toSet(), {oldKey});
    });

    test('输出与输入顺序无关（纯函数：同样的输入永远同样的输出）', () {
      final works = [
        _w(key: oldKey, title: '兰香如故', itemCount: 20),
        _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版', itemCount: 47),
      ];
      final dirs = {
        oldKey: [oldDir],
        newKey: [newDir],
      };

      final a = WorkMergeSuggester.suggest(
        works: works,
        dirsByWork: dirs,
        touchedKeys: {newKey},
      );
      final b = WorkMergeSuggester.suggest(
        works: works.reversed.toList(),
        dirsByWork: dirs,
        touchedKeys: {newKey},
      );

      expect(b.map((s) => s.toString()), a.map((s) => s.toString()));
    });

    test('源没有媒体项（查不到目录）→ 跳过，不抛异常', () {
      expect(
        WorkMergeSuggester.suggest(
          works: [
            _w(key: oldKey, title: '兰香如故'),
            _w(key: newKey, title: '兰z 香z 如z 故 去头去尾版'),
          ],
          dirsByWork: {oldKey: [oldDir]},
          touchedKeys: {newKey},
        ),
        isEmpty,
      );
    });
  });
}
