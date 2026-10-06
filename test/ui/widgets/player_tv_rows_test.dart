import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/subtitle_formats.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/quality_option.dart';
import 'package:cloudcine/domain/entities/subtitle_track.dart';
import 'package:cloudcine/ui/widgets/player_tv_panel.dart';
import 'package:cloudcine/ui/widgets/player_tv_rows.dart';

MediaItem _item({String id = 'f1', int? episode}) => MediaItem(
      provider: DriveProvider.quark,
      fileId: id,
      name: 'A.S01E01.mkv',
      dirId: 'd1',
      dirPath: '/剧集/A/',
      groupKey: 'A',
      kind: MediaKind.episode,
      title: 'A',
      episode: episode,
      firstSeenAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

QualityOption _quality(String id, {bool available = true}) => QualityOption(
      id: id,
      label: id,
      url: available ? Uri.parse('http://example.invalid/$id') : null,
    );

SubtitleTrack _sub(String id) => SubtitleTrack(
      id: id,
      origin: SubtitleOrigin.embedded,
      label: id,
      format: SubtitleFormat.srt,
    );

/// 只记账的动作表 —— 断言「哪一行落到了哪个回调上」。
class _Spy {
  final List<String> picked = <String>[];
  bool closed = false;

  TvOsdActionTarget get target => TvOsdActionTarget(
        onPickQuality: (id) async => picked.add('quality:$id'),
        onPickSubtitle: (t) async => picked.add('subtitle:${t?.id ?? 'off'}'),
        onPickAudioTrack: (t, i) => picked.add('audio:${t.id}@$i'),
        onPickAudioEffect: (p) async => picked.add('effect:$p'),
        onPickRate: (r) async => picked.add('rate:$r'),
        // 记 `fileId` 而不是 `id`：`MediaItem.id` 带 provider 前缀
        // （`quark:f1`），断言里写它会让「换源前缀」这种无关改动把测试搞红。
        onPickEpisode: (i) async => picked.add('episode:${i.fileId}'),
        onJumpIntro: () async => picked.add('intro'),
        onClose: () => closed = true,
      );
}

/// 跑一条「按了 OK」并返回记账结果。
_Spy _activate(
  PlayerTvRow row,
  int chip, {
  List<MediaItem> siblings = const [],
  List<QualityOption> qualities = const [],
  List<SubtitleTrack> subtitles = const [],
  List<mk.AudioTrack> audioTracks = const [],
}) {
  final spy = _Spy();
  applyPlayerTvRowAction(
    row: row,
    optionIndex: chip,
    siblings: siblings,
    qualities: qualities,
    subtitles: subtitles,
    audioTracks: audioTracks,
    target: spy.target,
  );
  return spy;
}

void main() {
  // -------------------------------------------------------------------
  // 喂给原生 OSD 的 JSON
  //
  // 这条契约**写错不会报错**：原生侧拿到空 options 就画一条空菜单，
  // 拿到短一截的 enabled 就把灰掉的档位当成可选。所以形状必须钉死。
  // -------------------------------------------------------------------
  group('encodeTvOsdPayload', () {
    test('把行编成原生 OSD 直接能吃的形状', () {
      final payload = encodeTvOsdPayload(
        const [
          PlayerTvRowValue(
            row: PlayerTvRow.episode,
            value: '第 3 集',
            options: [PlayerTvOption('E01'), PlayerTvOption('E02')],
            vertical: true,
            selectedOption: 1,
          ),
          PlayerTvRowValue(
            row: PlayerTvRow.quality,
            value: '原画',
            options: [
              PlayerTvOption('原画'),
              PlayerTvOption('4K', enabled: false),
            ],
          ),
        ],
        selectedRow: 1,
      );

      expect(payload['selectedRow'], 1);
      final rows = payload['rows']! as List<Object?>;
      expect(rows.length, 2);

      final ep = rows[0]! as Map<Object?, Object?>;
      // 行名走 `PlayerTvRow.label`，不是调用方另写一份。
      expect(ep['label'], '选集');
      expect(ep['value'], '第 3 集');
      expect(ep['options'], <String>['E01', 'E02']);
      expect(ep['enabled'], <bool>[true, true]);
      expect(ep['vertical'], true);
      // 光标起点：原生那边换到这一行时会用它。
      expect(ep['selected'], 1);
      expect(ep['hint'], isNull);

      final q = rows[1]! as Map<Object?, Object?>;
      expect(q['label'], '画质');
      // ⛔ enabled 必须与 options **等长** —— 原生那边按下标取，
      //    短了会静默退回「可选」，灰掉的档位就又按得动了。
      expect(
        (q['enabled']! as List<Object?>).length,
        (q['options']! as List<Object?>).length,
      );
      expect(q['enabled'], <bool>[true, false]);
      expect(q['vertical'], false);
      expect(q['selected'], 0);
    });

    test('没有选项条的行：options/enabled 是空表，hint 带出去', () {
      final payload = encodeTvOsdPayload(
        const [
          PlayerTvRowValue(
            row: PlayerTvRow.intro,
            value: '跳到 01:30',
            adjustable: false,
            hint: '按 OK 跳到 01:30',
          ),
        ],
      );

      final row =
          (payload['rows']! as List<Object?>)[0]! as Map<Object?, Object?>;
      expect(row['options'], isEmpty);
      expect(row['enabled'], isEmpty);
      expect(row['hint'], '按 OK 跳到 01:30');
    });
  });

  // -------------------------------------------------------------------
  // 「按了 OK」→ 播放页动作
  //
  // Flutter 版菜单与原生版菜单共用这一份。指错一行不会有任何报错，
  // 只会在真机上静默做错事（例如选「音效」却换了音轨）。
  // -------------------------------------------------------------------
  group('applyPlayerTvRowAction', () {
    test('选集：交出第 N 条，并收起菜单', () {
      final spy = _activate(
        PlayerTvRow.episode,
        2,
        siblings: [_item(id: 'f1'), _item(id: 'f2'), _item(id: 'f3')],
      );
      expect(spy.picked, ['episode:f3']);
      expect(spy.closed, isTrue);
    });

    test('选集越界：什么都不做，而且**不**收菜单', () {
      final spy = _activate(PlayerTvRow.episode, -1, siblings: [_item()]);
      expect(spy.picked, isEmpty);
      expect(spy.closed, isFalse);
    });

    test('画质：可用档位照切，不可用档位挡掉（但菜单照样收）', () {
      final qualities = [
        _quality('origin'),
        _quality('4k', available: false),
      ];

      final ok = _activate(PlayerTvRow.quality, 0, qualities: qualities);
      expect(ok.picked, ['quality:origin']);
      expect(ok.closed, isTrue);

      // 灰掉那一颗：鼠标点得到它，所以这里必须再挡一次。
      final grey = _activate(PlayerTvRow.quality, 1, qualities: qualities);
      expect(grey.picked, isEmpty);
      expect(grey.closed, isTrue);
    });

    test('字幕：第 0 颗是「关闭」，第 N 颗是第 N-1 条轨', () {
      final subs = [_sub('s1'), _sub('s2')];

      final off = _activate(PlayerTvRow.subtitle, 0, subtitles: subs);
      expect(off.picked, ['subtitle:off']);

      final second = _activate(PlayerTvRow.subtitle, 2, subtitles: subs);
      expect(second.picked, ['subtitle:s2']);
    });

    test('音轨：把轨和它的下标一起交出去（下标要落库）', () {
      final tracks = [
        mk.AudioTrack('a1', '国语', 'chi'),
        mk.AudioTrack('a2', '粤语', 'yue'),
      ];
      final spy = _activate(PlayerTvRow.audioTrack, 1, audioTracks: tracks);
      expect(spy.picked, ['audio:a2@1']);
    });

    test('倍速：第 N 颗 chip 对应 kPlaybackRates[N]', () {
      final spy = _activate(PlayerTvRow.rate, 3);
      expect(kPlaybackRates[3], 1.25);
      expect(spy.picked, ['rate:1.25']);
    });

    test('片头：只跳，不依赖选项条', () {
      final spy = _activate(PlayerTvRow.intro, -1);
      expect(spy.picked, ['intro']);
      expect(spy.closed, isTrue);
    });
  });

  // -------------------------------------------------------------------
  // 与原生 OSD 的行序约定
  // -------------------------------------------------------------------
  group('行序约定', () {
    test('PlayerTvRow 的声明顺序就是原生菜单回传的下标顺序', () {
      // ⛔ 原生侧只回传下标（`{"row": 3}`），播放页用
      //    `PlayerTvRow.values[row]` 还原。这个顺序一变，
      //    「按 OK 选音轨」会静默变成「选字幕」—— 而两边都不会报错。
      expect(
        PlayerTvRow.values.map((r) => r.name).toList(),
        [
          'episode',
          'quality',
          'subtitle',
          'audioTrack',
          'audioEffect',
          'rate',
          'intro',
        ],
      );
    });
  });
}
