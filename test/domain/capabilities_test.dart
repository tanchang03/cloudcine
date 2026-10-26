import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// 能力声明这个值对象本身。
///
/// ## 为什么值得单独测（它一个方法都没有）
///
/// 它是一份**纯声明**，但上层拿它做的判断全是「选错了就静默出错」的那种：
///
///   - [Capabilities.canWrite] → 备份包落到哪一家（挑错了，用户点「备份」
///     只拿到一句 `unsupported`）；
///   - [Capabilities.canDelete] → 媒体库批量删除的分账（判错了，界面说
///     「已删除 12 个」而盘上还留着 12 个）；
///   - [Capabilities.canMove] → 多选工具条上「移动」该不该置灰。
///
/// 这三件事**没有一处会在判错时报错**。所以这里守的不是「getter 能返回
/// 自己存的值」，而是下面三条**结构**上的性质：
///
///   1. 三个位**互相独立** —— `copyWith` 里少写一个 `??`、或者把
///      `canMove` 写成 `canDelete ?? this.canMove`，都不会红，只会让某一家
///      网盘在某个场景下悄悄失去一个能力；
///   2. 默认值必须是 `true` —— 夸克**没有**显式声明这三个位，它靠的就是
///      默认值。谁把默认值改成 `false`，夸克的删除和移动会一起消失；
///   3. [Capabilities.toString] 必须把三个位都印出来 —— 诊断日志里靠它一眼
///      判断「这家能不能删」，漏印一位就等于那个位在日志里不可见。
void main() {
  Capabilities caps({
    bool canWrite = true,
    bool canDelete = true,
    bool canMove = true,
  }) =>
      Capabilities(
        provider: DriveProvider.baidu,
        canWrite: canWrite,
        canDelete: canDelete,
        canMove: canMove,
      );

  group('三个写能力位互相独立', () {
    test('关掉 canDelete 不会动 canWrite / canMove', () {
      final c = caps().copyWith(canDelete: false);

      expect(c.canDelete, isFalse);
      expect(c.canWrite, isTrue,
          reason: '「能删不能传」正是百度现在的形状。copyWith 里少一个 '
              '`??` 之类的笔误，就会把另外两个位一起拖走 —— 而那种错误'
              '在任何界面上都不报错，只是某个入口悄悄灰掉。');
      expect(c.canMove, isTrue);
    });

    test('关掉 canMove 不会动 canWrite / canDelete', () {
      final c = caps().copyWith(canMove: false);

      expect(c.canMove, isFalse);
      expect(c.canWrite, isTrue);
      expect(c.canDelete, isTrue,
          reason: '「能删不能移」是另一个合法组合。两个位合成一个的话，'
              '这种组合根本表达不出来 —— 那正是这次修的 bug 的根源。');
    });

    test('关掉 canWrite 不会动 canDelete / canMove', () {
      // 百度的现状：canWrite=false, canDelete=true, canMove=true。
      final c = caps().copyWith(canWrite: false);

      expect(c.canWrite, isFalse);
      expect(c.canDelete, isTrue);
      expect(c.canMove, isTrue);
    });

    test('三个位可以任意组合，互不干扰', () {
      // 穷举 8 种组合。写成表格而不是逐个 copyWith：组合一多，
      // 「哪个参数写串了」这种错只有在全覆盖时才暴露。
      for (final w in [true, false]) {
        for (final d in [true, false]) {
          for (final m in [true, false]) {
            final c = caps().copyWith(canWrite: w, canDelete: d, canMove: m);
            expect(
              [c.canWrite, c.canDelete, c.canMove],
              [w, d, m],
              reason: 'canWrite=$w, canDelete=$d, canMove=$m 的组合被改坏了',
            );
          }
        }
      }
    });

    test('不传参数时三个位原样保留', () {
      final c = caps(canWrite: false, canDelete: true, canMove: false)
          .copyWith(listQps: 9.0);

      expect([c.canWrite, c.canDelete, c.canMove], [false, true, false],
          reason: '改一个无关字段（节流）不该顺手重置能力位 —— '
              '`copyWith` 的每次调用都是这个风险。');
    });
  });

  group('默认值', () {
    test('三个写能力位默认都是 true', () {
      const c = Capabilities(provider: DriveProvider.quark);

      expect([c.canWrite, c.canDelete, c.canMove], [true, true, true],
          reason: '夸克**没有**显式声明这三个位（见 `quarkCapabilities`），'
              '它靠的就是默认值。把任何一个默认值改成 false，夸克的删除或'
              '移动会一起消失，而代码里找不到任何一处「关掉它」的痕迹。');
    });
  });

  group('copyWith 的其余字段', () {
    test('clearMaxSingleFileBytes 清空上限，而不是「保留原值」', () {
      final c = Capabilities(
        provider: DriveProvider.quark,
        maxSingleFileBytes: 1024,
      );

      expect(c.copyWith(clearMaxSingleFileBytes: true).maxSingleFileBytes,
          isNull,
          reason: '可空字段没法用 `null` 表示「清空」（那和「不改」同义），'
              '所以单独一个开关。写成 `maxSingleFileBytes ?? this.…` 的话，'
              '「解除限制」这个动作会静默无效。');
      expect(c.copyWith(listQps: 1.0).maxSingleFileBytes, 1024,
          reason: '不传开关时上限必须留着');
    });

    test('hasFileSizeLimit 跟着 maxSingleFileBytes 走', () {
      const unlimited = Capabilities(provider: DriveProvider.quark);
      final limited =
          const Capabilities(provider: DriveProvider.quark)
              .copyWith(maxSingleFileBytes: 100);

      expect(unlimited.hasFileSizeLimit, isFalse);
      expect(limited.hasFileSizeLimit, isTrue);
    });
  });

  group('toString：诊断日志里唯一的「这家能干什么」', () {
    test('三个位都印出来', () {
      final s = caps(canWrite: false, canDelete: true, canMove: false).toString();

      expect(s, contains('write=false'));
      expect(s, contains('delete=true'));
      expect(s, contains('move=false'),
          reason: '排查「为什么这个按钮是灰的」时，日志里那一行是唯一能一眼'
              '看到答案的地方。漏印一位，那个位在日志里就等于不存在 —— '
              '而人不会去读代码确认，只会怀疑界面。');
    });

    test('带上 provider id，能分清是哪一家', () {
      expect(caps().toString(), contains(DriveProvider.baidu.id));
    });
  });
}
