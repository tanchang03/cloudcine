import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/services/drive_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批量删除的**计划与文案**。
///
/// ## 为什么值得给一个「只有几个 getter」的类写测试
///
/// 它守着三条**错了不会报错、只会让用户丢东西或白担心**的判据：
///
///   1. 分块不能丢条目、不能重复 —— 漏一条就是「我明明勾了它，删完还在」；
///   2. 目录体积网盘常常不给，那时只能说「至少释放」/「未知」，**绝不能**
///      写成 `0 B`（会被读成「删了也没用」，用户就不删了）；
///   3. 部分失败时必须把失败数说出来 —— 说成「已删除」会让用户以为删干净了，
///      而列表里那些还在，他只会以为界面没刷新。
void main() {
  DriveEntry file(String id, {int? size}) => DriveEntry(
        id: id,
        name: '$id.mkv',
        isDirectory: false,
        sizeBytes: size,
      );

  DriveEntry dir(String id, {int? size}) => DriveEntry(
        id: id,
        name: id,
        isDirectory: true,
        sizeBytes: size,
      );

  const gb = 1024 * 1024 * 1024;

  group('分块', () {
    test('不超过上限时只有一批', () {
      final plan = DriveDeletePlan(
        entries: [for (var i = 0; i < 10; i++) file('f$i')],
      );
      expect(plan.idChunks().length, 1);
      expect(plan.idChunks().single.length, 10);
    });

    test('刚好等于上限时也只有一批（边界不是 off-by-one）', () {
      final n = DriveDeletePlan.maxIdsPerRequest;
      final plan = DriveDeletePlan(entries: [for (var i = 0; i < n; i++) file('f$i')]);
      expect(plan.idChunks().length, 1,
          reason: '刚好 100 个却切成 2 批的话，第 2 批是空的 —— 一次白打的请求，'
              '而夸克那条限流线本来就很紧。');
    });

    test('超出一批时切多批，且一条不丢、一条不重', () {
      final n = DriveDeletePlan.maxIdsPerRequest;
      final plan = DriveDeletePlan(entries: [for (var i = 0; i < n + 3; i++) file('f$i')]);

      final chunks = plan.idChunks();
      expect(chunks.length, 2);
      expect(chunks.first.length, n);
      expect(chunks.last.length, 3);

      final flat = [for (final c in chunks) ...c];
      expect(flat.length, plan.count,
          reason: '丢一条 = 用户勾了它却没删掉，而他不会知道是哪一条。');
      expect(flat.toSet().length, flat.length,
          reason: '重复一条 = 对同一个 fid 发两次删除，第二次必然报错，'
              '然后失败计数里多出一个假的失败。');
    });

    test('空计划不产生任何批次（不发请求）', () {
      expect(const DriveDeletePlan(entries: []).idChunks(), isEmpty);
    });
  });

  group('释放空间的说法', () {
    test('全是已知体积的文件 → 可以说「约」', () {
      final plan = DriveDeletePlan(entries: [file('a', size: gb), file('b', size: gb)]);
      expect(plan.freedIsLowerBound, isFalse);
      expect(plan.freedLabel, '释放约 2.0 GB');
    });

    test('勾了目录 → 只能说「至少」（目录体积网盘通常不给）', () {
      final plan = DriveDeletePlan(entries: [file('a', size: gb), dir('d1')]);
      expect(plan.freedIsLowerBound, isTrue,
          reason: '目录的体积拿不到，总和就只是下界。说成准确的「释放 1.0 GB」'
              '会明显少报 —— 用户删完看到容量掉了一大截，会觉得预估是错的。');
      expect(plan.freedLabel, '至少释放 1.0 GB');
    });

    test('一个体积都拿不到 → 说「未知」，绝不写成 0 B', () {
      final plan = DriveDeletePlan(entries: [dir('d1'), dir('d2')]);
      expect(plan.knownBytes, 0);
      expect(plan.freedLabel, contains('未知'));
      expect(plan.freedLabel, isNot(contains('0 B')),
          reason: '「释放 0 B」会被读成「删了也腾不出空间」，用户就不删了 —— '
              '而事实正好相反。');
    });
  });

  group('文案', () {
    test('目录警告只在勾了目录时出现，且要说清「连里面的文件一起删」', () {
      expect(DriveDeletePlan(entries: [file('a')]).folderWarning, isNull);

      final warn = DriveDeletePlan(entries: [file('a'), dir('d1'), dir('d2')])
          .folderWarning;
      expect(warn, isNotNull);
      expect(warn, contains('2 个目录'));
      expect(warn, contains('全部文件'),
          reason: '列表里那一行只写着一个目录名，看不出里面还有几百 GB —— '
              '不说这一句，用户以为自己在删一个空文件夹。');
    });

    test('不可逆警告必须明说无法恢复', () {
      final plan = DriveDeletePlan(entries: [file('a')]);
      expect(plan.irreversibleWarning, contains('不可撤销'));
      expect(plan.irreversibleWarning, contains('无法恢复'),
          reason: '用户对「删除」的预期常常是「进回收站还能捞回来」。'
              '只写「请确认」读起来像一句客套话。');
    });

    test('确认按钮带数量（最后一次核对机会）', () {
      final plan = DriveDeletePlan(entries: [file('a'), file('b')]);
      expect(plan.confirmLabel, '删除 2 项');
    });

    test('标题是问句，与按钮文案不重样', () {
      final plan = DriveDeletePlan(entries: [file('a'), file('b')]);
      expect(plan.title, isNot(plan.confirmLabel),
          reason: '两处文案一样的话，弹窗上会重复印同一句话，'
              '而测试里的 find.text 也会同时命中标题和按钮 —— 那种含糊'
              '正是「用户以为自己点的是标题」的来源。');
      expect(plan.title, contains('2 项'));
    });

    test('全部成功：说「已删除 N 项」', () {
      final plan = DriveDeletePlan(entries: [file('a'), file('b')]);
      expect(plan.deletedMessage(deleted: 2, failed: 0), contains('已删除 2 项'));
    });

    test('部分失败：必须把失败数说出来', () {
      final plan = DriveDeletePlan(entries: [for (var i = 0; i < 5; i++) file('f$i')]);
      final msg = plan.deletedMessage(deleted: 3, failed: 2);
      expect(msg, contains('已删除 3 项'));
      expect(msg, contains('2 项失败'),
          reason: '只说「已删除 3 项」会让用户以为删干净了，而剩下那 2 项'
              '在列表里还好好待着 —— 他会以为界面没刷新，然后再点一次删除。');
    });

    test('全部失败：不能说「已删除」', () {
      final plan = DriveDeletePlan(entries: [file('a'), file('b')]);
      final msg = plan.deletedMessage(deleted: 0, failed: 2);
      expect(msg, isNot(contains('已删除')));
      expect(msg, contains('2 项'));
    });
  });
}
