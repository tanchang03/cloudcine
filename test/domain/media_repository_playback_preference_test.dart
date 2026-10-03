import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/entities/playback_preference.dart';
import 'package:flutter_test/flutter_test.dart';

/// 逐文件播放偏好在仓储层的两条路径：**精确命中**与**同剧回退**。
///
/// 这一层是「下次打开还是上次那套设置」的落点，两条路径对应两种真实场景：
///
///   - 同一集重播 → 精确命中；
///   - 同剧里没播过的那一集 → 回退到最近改过的那一集（用户给第 1 集选了粤语，
///     第 2 集打开也该是粤语）。
///
/// 回退**只在同一部作品内**发生。跨作品串味是最难查的一类 bug：用户打开一部
/// 新片，字幕语言却是上一部片选的，而日志里什么都看不出来。
void main() {
  final ts = DateTime(2026, 10, 3);

  MediaItem item(String groupKey, String fileId) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd1',
        dirPath: '/剧/$groupKey/',
        groupKey: groupKey,
        kind: MediaKind.episode,
        title: fileId,
        firstSeenAt: ts,
        updatedAt: ts,
      );

  MediaWork work(String key) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: key,
        updatedAt: ts,
      );

  const audioZh =
      TrackPreference(trackId: '1', language: 'chi', title: '国语', index: 0);
  const subZh = TrackPreference(
    trackId: 'embedded#3',
    language: 'zho',
    title: '简体中文',
    index: 1,
  );

  PlaybackPreference pref({
    String? quality,
    TrackPreference? audio,
    TrackPreference? subtitle,
    bool subtitlesEnabled = true,
    String? effect,
  }) =>
      PlaybackPreference(
        qualityId: quality,
        audio: audio,
        subtitle: subtitle,
        subtitlesEnabled: subtitlesEnabled,
        audioEffect: effect,
      );

  group('playbackPreferenceFor —— 精确命中', () {
    test('存过的那一条原样读回来', () async {
      final repo = InMemoryMediaRepository();
      final a = item('剧A', 'f1');
      final saved = pref(
        quality: 'super',
        audio: audioZh,
        subtitle: subZh,
        effect: 'upmix',
      );

      await repo.savePlaybackPreference(a.id, a.groupKey, saved);

      expect(
        await repo.playbackPreferenceFor(a.id, groupKey: a.groupKey),
        saved,
        reason: '这是「下次打开还是上次那套设置」的主路径。它坏掉的表现是'
            '「设置全没记住」—— 而用户会以为播放器根本没做这个功能',
      );
    });
  });

  group('playbackPreferenceFor —— 同剧回退', () {
    test('这一集没记过 → 用同一部作品里别的那一集', () async {
      final repo = InMemoryMediaRepository();
      final ep1 = item('剧A', 'f1');
      final ep2 = item('剧A', 'f2');
      final saved = pref(quality: 'super', subtitle: subZh);

      await repo.savePlaybackPreference(ep1.id, ep1.groupKey, saved);

      expect(
        await repo.playbackPreferenceFor(ep2.id, groupKey: ep2.groupKey),
        saved,
        reason: '用户给第 1 集选了字幕，第 2 集打开也该是那一条 —— 这是需求里'
            '「同剧继承」那一半。只做精确命中等于每换一集都要重设一遍，'
            '而连播时用户根本不会去重设',
      );
    });

    test('同剧有多条时取**最近**改过的那一条', () async {
      final repo = InMemoryMediaRepository();
      final ep1 = item('剧A', 'f1');
      final ep2 = item('剧A', 'f2');
      final ep3 = item('剧A', 'f3');

      await repo.savePlaybackPreference(ep1.id, ep1.groupKey, pref(quality: 'super'));
      // 排序依据是写入时间，两次写落在同一微秒里就无法分出先后 ——
      // 等一下是**测试**的需要，不是产品行为。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.savePlaybackPreference(ep2.id, ep2.groupKey, pref(quality: 'origin'));

      expect(
        (await repo.playbackPreferenceFor(ep3.id, groupKey: ep3.groupKey))
            ?.qualityId,
        'origin',
        reason: '取最早那条会让「用户最近一次调过的设置」永远不生效 —— '
            '而他明明刚在第 2 集上改过',
      );
    });

    test('跨作品不串味', () async {
      final repo = InMemoryMediaRepository();
      final a1 = item('剧A', 'f1');
      final b1 = item('剧B', 'f9');

      await repo.savePlaybackPreference(a1.id, a1.groupKey, pref(subtitle: subZh));

      expect(
        await repo.playbackPreferenceFor(b1.id, groupKey: b1.groupKey),
        isNull,
        reason: '回退必须在同一部作品内。串味的表现是「打开一部新片，字幕却是'
            '上一部片选的」—— 用户完全无从理解，我们也完全无从复现',
      );
    });

    test('不给 groupKey 就不回退', () async {
      final repo = InMemoryMediaRepository();
      final ep1 = item('剧A', 'f1');
      final ep2 = item('剧A', 'f2');

      await repo.savePlaybackPreference(ep1.id, ep1.groupKey, pref(quality: 'super'));

      expect(
        await repo.playbackPreferenceFor(ep2.id),
        isNull,
        reason: '`groupKey` 是「这条文件属于哪一部作品」的唯一凭据。缺了它就'
            '只剩精确匹配 —— 靠猜一个作品出来比返回 null 危险得多',
      );
    });

    test('精确命中优先于同剧回退', () async {
      final repo = InMemoryMediaRepository();
      final ep1 = item('剧A', 'f1');
      final ep2 = item('剧A', 'f2');

      await repo.savePlaybackPreference(ep1.id, ep1.groupKey, pref(quality: 'super'));
      await repo.savePlaybackPreference(ep2.id, ep2.groupKey, pref(quality: 'origin'));

      expect(
        (await repo.playbackPreferenceFor(ep2.id, groupKey: ep2.groupKey))
            ?.qualityId,
        'origin',
        reason: '「这一集自己记过的」永远比「同一部作品里别的那一集」更贴切。'
            '顺序反了的话，用户在本集改过的设置会被别集**顶掉**',
      );
    });

    test('空偏好当「没记过」—— 不挡住同剧回退', () async {
      final repo = InMemoryMediaRepository();
      final ep1 = item('剧A', 'f1');
      final ep2 = item('剧A', 'f2');

      await repo.savePlaybackPreference(ep1.id, ep1.groupKey, pref(quality: 'super'));
      // 库里确实可能有这种行：`playback_prefs.prefs` 列的默认值就是 `'{}'`。
      // 那种行必须当「没记过」，否则它会**挡住**同剧回退 —— 表现为
      // 「别的集都记住了，就这一集永远回到默认」，而它偏偏是用户刚看过的那一集。
      await repo.savePlaybackPreference(ep2.id, ep2.groupKey, const PlaybackPreference());

      expect(
        (await repo.playbackPreferenceFor(ep2.id, groupKey: ep2.groupKey))
            ?.qualityId,
        'super',
      );
    });
  });

  group('savePlaybackPreference —— 整条覆盖', () {
    test('第二次保存整条替换，旧值不残留', () async {
      final repo = InMemoryMediaRepository();
      final a = item('剧A', 'f1');
      await repo.savePlaybackPreference(
        a.id,
        a.groupKey,
        pref(quality: 'super', audio: audioZh, subtitle: subZh, effect: 'upmix'),
      );

      await repo.savePlaybackPreference(a.id, a.groupKey, pref(quality: 'origin'));

      final read = await repo.playbackPreferenceFor(a.id, groupKey: a.groupKey);
      expect(read?.qualityId, 'origin');
      expect(
        read?.audio,
        isNull,
        reason: '整条覆盖（而不是逐字段合并）是刻意的：「清掉某一项」只有覆盖写'
            '才表达得出来。改成合并的话，用户清掉的音轨偏好在下一次保存时'
            '会**自己长回来**',
      );
      expect(read?.subtitle, isNull);
      expect(read?.audioEffect, isNull);
    });

    test('「主动关掉字幕」能被原样存下来，不等于「没记过」', () async {
      final repo = InMemoryMediaRepository();
      final a = item('剧A', 'f1');
      await repo.savePlaybackPreference(
        a.id,
        a.groupKey,
        pref(subtitle: null, subtitlesEnabled: false),
      );

      final read = await repo.playbackPreferenceFor(a.id, groupKey: a.groupKey);
      expect(read, isNotNull);
      expect(read!.subtitlesEnabled, isFalse);
      expect(read.subtitle, isNull);
      expect(
        read.isEmpty,
        isFalse,
        reason: '「关掉字幕」必须与「没记过」区分开。两者混同的表现是：用户在一部'
            '片里关掉字幕，下次打开又被自动挂上一条，而他明明关过 —— 这是'
            '`subtitlesEnabled` 这个字段存在的唯一理由',
      );
    });
  });

  group('删除时的孤儿清理', () {
    test('deleteItem 连带删掉这条文件的偏好', () async {
      final repo = InMemoryMediaRepository();
      final a = item('剧A', 'f1');
      await repo.upsertItems([a]);
      await repo.savePlaybackPreference(a.id, a.groupKey, pref(quality: 'super'));

      await repo.deleteItem(a.id);

      expect(
        await repo.playbackPreferenceFor(a.id, groupKey: a.groupKey),
        isNull,
        reason: '留着的话，网盘上同一个文件被重新扫进来（id 一样）会**直接套用'
            '上一个文件的设置**；而这条记录本该随文件一起消失',
      );
    });

    test('deleteWork 连带删掉整组偏好', () async {
      final repo = InMemoryMediaRepository();
      final ep1 = item('剧A', 'f1');
      final ep2 = item('剧A', 'f2');
      await repo.upsertItems([ep1, ep2]);
      await repo.upsertWorks([work('剧A')]);
      await repo.savePlaybackPreference(ep1.id, ep1.groupKey, pref(quality: 'super'));
      await repo.savePlaybackPreference(ep2.id, ep2.groupKey, pref(quality: 'origin'));

      await repo.deleteWork('剧A');

      expect(await repo.playbackPreferenceFor(ep1.id, groupKey: '剧A'), isNull);
      expect(await repo.playbackPreferenceFor(ep2.id, groupKey: '剧A'), isNull);
      expect(
        repo.playbackPrefs,
        isEmpty,
        reason: '「移除整部剧」之后还留着一堆对不上任何文件的偏好行，只会在库里'
            '越积越多 —— 而且它们**永远不会被读到**，所以谁也不会发现',
      );
    });
  });
}
