import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这条请求是**跨引擎**传的：它先被编码进方法通道，再由另一侧的
/// [PlayRequest.fromJson] 还原。
///
/// 所以「编解码对称」不是可选项 —— 一旦不对称，表现是「窗口起来了但什么都
/// 没播」，既不抛异常也没有日志。同理，请求头丢了的表现是夸克直链 412。
void main() {
  group('PlayRequest 编解码', () {
    test('字段能原样过一趟通道', () {
      const original = PlayRequest(
        url: 'https://cdn.example.com/a.m3u8?sign=abc',
        title: '银翼杀手',
        headers: <String, String>{
          'Cookie': 'k=v',
          'Referer': 'https://pan.quark.cn',
        },
        qualityLabel: '4k(2160p)',
        startPosition: Duration(minutes: 12, seconds: 3),
      );

      final restored = PlayRequest.fromJson(original.toJson());

      expect(restored, original);
      expect(restored!.headers['Cookie'], 'k=v');
      expect(restored.startPosition, const Duration(minutes: 12, seconds: 3));
    });

    test('请求头不能丢 —— 丢了就是夸克 412', () {
      const original = PlayRequest(
        url: 'https://cdn.example.com/a.m3u8',
        title: 'x',
        headers: <String, String>{'Cookie': 'k=v'},
      );

      expect(PlayRequest.fromJson(original.toJson())!.headers, {'Cookie': 'k=v'});
    });

    test('可选字段缺省时不崩', () {
      final restored = PlayRequest.fromJson(const <String, Object?>{
        'url': 'https://a/b.mp4',
        'title': 't',
      })!;

      expect(restored.headers, isEmpty);
      expect(restored.qualityLabel, isNull);
      expect(restored.startPosition, Duration.zero);
    });

    test('畸形输入一律返回 null，绝不抛异常', () {
      // 播放窗口拿到解不开的请求时，正确行为是安静地停在空舞台，
      // 而不是崩掉一个刚起来的窗口。
      const raws = <Object?>[
        null,
        'string',
        42,
        <String>[],
        <String, Object?>{},
        <String, Object?>{'url': ''},
        <String, Object?>{'url': 1},
      ];

      for (final raw in raws) {
        expect(() => PlayRequest.fromJson(raw), returnsNormally, reason: 'raw=$raw');
        expect(PlayRequest.fromJson(raw), isNull, reason: 'raw=$raw');
      }
    });

    test('请求头里混进非字符串值只丢那一项，不整条作废', () {
      final restored = PlayRequest.fromJson(const <String, Object?>{
        'url': 'https://a/b.mp4',
        'title': 't',
        'headers': <Object?, Object?>{'Cookie': 'k=v', 'Bad': 42},
      });

      expect(restored, isNotNull);
      expect(restored!.headers, {'Cookie': 'k=v'});
    });

    test('startPosition 为负 / 非整数时按 0 处理', () {
      for (final raw in const <Object?>[-5, 'abc', null, 1.5]) {
        final restored = PlayRequest.fromJson(<String, Object?>{
          'url': 'https://a/b.mp4',
          'title': 't',
          'startPositionMs': raw,
        })!;

        expect(restored.startPosition, Duration.zero, reason: 'raw=$raw');
      }
    });

    test('qualityId 要往返 —— 它是刷新直链时保住档位的唯一依据', () {
      const original = PlayRequest(
        url: 'https://a/b.mp4',
        title: 't',
        qualityId: '4k',
        qualityLabel: '4k(2160p)',
      );

      final restored = PlayRequest.fromJson(original.toJson())!;

      expect(restored.qualityId, '4k');
      // label 只用于显示，缺了它刷新照样能保住档位；反之不行。
      expect(restored.qualityLabel, '4k(2160p)');
    });

    test('qualityId 缺省或空串都归一成 null', () {
      for (final raw in const <Object?>[null, '', 42]) {
        final restored = PlayRequest.fromJson(<String, Object?>{
          'url': 'https://a/b.mp4',
          'title': 't',
          'qualityId': raw,
        })!;

        expect(restored.qualityId, isNull, reason: 'raw=$raw');
      }
    });

    test('档位不同就不相等 —— 否则「刷新后换了档」会被当成同一条请求', () {
      const a = PlayRequest(url: 'u', title: 't', qualityId: '4k');
      const b = PlayRequest(url: 'u', title: 't', qualityId: 'super');

      expect(a == b, isFalse);
    });
  });

  group('PlayRequest.describe', () {
    test('只出片名与档位，绝不带直链或请求头', () {
      const request = PlayRequest(
        url: 'https://cdn.example.com/a.m3u8?sign=SUPERSECRET',
        title: '银翼杀手',
        headers: <String, String>{'Cookie': 'SECRETCOOKIE'},
        qualityLabel: '4k(2160p)',
      );

      final text = request.describe();

      expect(text, contains('银翼杀手'));
      expect(text, contains('4k(2160p)'));
      // 诊断日志是给用户复制粘贴用的，不能成为泄露渠道。
      expect(text, isNot(contains('SUPERSECRET')));
      expect(text, isNot(contains('SECRETCOOKIE')));
      expect(request.toString(), isNot(contains('SUPERSECRET')));
    });

    test('没有档位标签时只出片名', () {
      const request = PlayRequest(url: 'https://a/b.mp4', title: 'x');

      expect(request.describe(), 'x');
    });
  });

  group('字幕：PlayRequest.subtitles', () {
    test('网盘字幕清单要往返 —— 丢了它播放器就只剩「内嵌轨」一种来源', () {
      const original = PlayRequest(
        url: 'https://a/b.mkv',
        title: '指环王：力量之戒 S01E01',
        subtitles: <SubtitleBrief>[
          SubtitleBrief(
            fileId: 'f1',
            label: '简体中文',
            language: 'zh',
            fileName: 'a.chs.srt',
          ),
          SubtitleBrief(fileId: 'f2', label: '英文'),
        ],
      );

      final restored = PlayRequest.fromJson(original.toJson())!;

      expect(restored.subtitles, original.subtitles);
      expect(restored.subtitles.first.fileName, 'a.chs.srt');
      expect(restored.subtitles.first.language, 'zh');
    });

    test('字幕列表里混进畸形项只丢那一项，不整条请求作废', () {
      // 与档位、剧集列表同一条规矩：一个读不懂的字幕不该让整部片播不了。
      final restored = PlayRequest.fromJson(const <String, Object?>{
        'url': 'https://a/b.mkv',
        'title': 't',
        'subtitles': <Object?>[
          <String, Object?>{'fileId': 'f1', 'label': '简体中文'},
          <String, Object?>{'label': '没有 fileId'},
          'garbage',
          <String, Object?>{'fileId': ''},
        ],
      })!;

      expect(restored.subtitles, hasLength(1));
      expect(restored.subtitles.single.fileId, 'f1');
    });

    test('字幕不同就不相等 —— 否则「换了一部片但字幕没变」会被判成同一条请求', () {
      const a = PlayRequest(
        url: 'u',
        title: 't',
        subtitles: <SubtitleBrief>[SubtitleBrief(fileId: 'f1', label: 'x')],
      );
      const b = PlayRequest(url: 'u', title: 't');

      expect(a == b, isFalse);
    });

    test('SubtitleBrief 没有名字时退回文件名、再退回 id —— 菜单上不能出现空行', () {
      expect(
        SubtitleBrief.fromJson(const <String, Object?>{'fileId': 'f9'})!.label,
        'f9',
      );
      expect(
        SubtitleBrief.fromJson(
          const <String, Object?>{'fileId': 'f9', 'fileName': 'a.srt'},
        )!.label,
        'a.srt',
      );
    });
  });

  group('OnlineSubtitleBrief', () {
    test('fileId 允许是数字字符串 —— 通道不保证把 int 原样送回来', () {
      final brief = OnlineSubtitleBrief.fromJson(const <String, Object?>{
        'fileId': '12345',
        'fileName': 'Movie.chs.srt',
        'language': 'zh-cn',
        'title': '银翼杀手',
        'downloadCount': 42,
      })!;

      expect(brief.fileId, 12345);
      expect(brief.downloadCount, 42);
      expect(brief.language, 'zh-cn');
    });

    test('缺 fileId 就是解不开 —— 没有它连下载地址都换不到', () {
      for (final raw in const <Object?>[
        null,
        'x',
        42,
        <String, Object?>{},
        <String, Object?>{'fileId': 'abc'},
      ]) {
        expect(OnlineSubtitleBrief.fromJson(raw), isNull, reason: 'raw=$raw');
      }
    });

    test('没有文件名时给一个能看的兜底，不能是空行', () {
      final brief = OnlineSubtitleBrief.fromJson(const <String, Object?>{
        'fileId': 7,
      })!;

      expect(brief.fileName, isNotEmpty);
    });
  });

  group('SubtitleSearchRequest', () {
    test('itemId 与兜底片名都要往返', () {
      const original = SubtitleSearchRequest(itemId: '102', fallbackQuery: '指环王');
      final restored = SubtitleSearchRequest.fromJson(original.toJson());

      expect(restored.itemId, '102');
      expect(restored.fallbackQuery, '指环王');
      expect(restored.isEmpty, isFalse);
    });

    test('解不开时是**空请求**而不是 null —— 少一个 null 分支就少一处漏判', () {
      for (final raw in const <Object?>[null, 'x', 42, <String>[]]) {
        expect(SubtitleSearchRequest.fromJson(raw).isEmpty, isTrue, reason: 'raw=$raw');
      }
    });

    test('只有空白也算空 —— 否则会拿一个空串去搜，白烧一次额度', () {
      expect(const SubtitleSearchRequest(fallbackQuery: '   ').isEmpty, isTrue);
      expect(const SubtitleSearchRequest(fallbackQuery: '\n\t').isEmpty, isTrue);
      // 只要有一边有内容就不算空。
      expect(const SubtitleSearchRequest(itemId: '102').isEmpty, isFalse);
      expect(const SubtitleSearchRequest(fallbackQuery: 'x').isEmpty, isFalse);
    });

    test('toString 只出条目 id 与片名，不带任何凭证（本来也没有）', () {
      const r = SubtitleSearchRequest(itemId: '102', fallbackQuery: '银翼杀手');

      expect(r.toString(), contains('102'));
      expect(r.toString(), contains('银翼杀手'));
    });
  });

  group('PlayRequest 值语义', () {
    test('字段相同即相等，请求头的键序不影响', () {
      const a = PlayRequest(
        url: 'u',
        title: 't',
        headers: <String, String>{'A': '1', 'B': '2'},
      );
      const b = PlayRequest(
        url: 'u',
        title: 't',
        headers: <String, String>{'B': '2', 'A': '1'},
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('请求头不同就不相等 —— 否则「带没带 Cookie」会被判成同一个请求', () {
      const a = PlayRequest(
        url: 'u',
        title: 't',
        headers: <String, String>{'Cookie': '1'},
      );
      const b = PlayRequest(
        url: 'u',
        title: 't',
        headers: <String, String>{'Cookie': '2'},
      );

      expect(a == b, isFalse);
    });
  });

  // ------------------------------------------------------------------ 剧集列表

  /// 面板上那一行显示什么，全由这两个 getter 决定（`EpisodeTile` 只负责画）。
  /// 它们错了不会抛异常，只会「看起来就是这样设计的」。
  group('PlaylistEntry 面板文案', () {
    PlaylistEntry entry({
      String title = '第 3 集',
      String fileName = '',
      String subtitle = '',
      Duration resume = Duration.zero,
      Duration duration = Duration.zero,
    }) =>
        PlaylistEntry(
          itemId: 'q:1',
          title: title,
          fileName: fileName,
          subtitle: subtitle,
          resumePosition: resume,
          duration: duration,
        );

    test('主标题是文件名，不是集号', () {
      // 用户扫这个列表是为了找「网盘上那个文件」。显示集号的话，同一集的
      // 国语版 / 粤语版、2160p / 1080p 两个压制会长得一模一样。
      expect(
        entry(title: '第 3 集', fileName: 'The.Glory.S01E03.2160p-老K.mkv')
            .rowTitle,
        'The.Glory.S01E03.2160p-老K.mkv',
      );
    });

    test('上游没给文件名时退回集号（老版本请求里没有这个字段）', () {
      expect(entry(title: '第 3 集').rowTitle, '第 3 集');
    });

    test('副标题里集号排在最前 —— 被省略号吃掉的只能是后面的码率', () {
      final e = entry(
        title: '第 3 集',
        fileName: 'a.S01E03.mkv',
        subtitle: '2160P · MKV · H.265 · 12.3 GB',
      );
      expect(e.rowSubtitle, '第 3 集 · 2160P · MKV · H.265 · 12.3 GB');
    });

    test('标题与文件名说的是同一件事时不重复显示', () {
      // 提不出集号的条目，title 本身就是 `剧名-文件名`（见
      // `MediaItem._fileRowLabel`）。再往副标题里放一遍就是同一句话出现两次，
      // 而这一行只有约 190px 宽。
      final e = entry(
        title: 'F飞CC日 志2-01.国语',
        fileName: '01.国语.mp4',
        subtitle: '1080P · MP4',
      );
      expect(e.rowSubtitle, '1080P · MP4');
    });

    test('撞名退让出来的 `剧名 S01E03`，片名与文件名同文时同样不重复', () {
      // 退让到第二级（`RowLabelStyle.withTitle`）时，标题是
      // `剧名 S01E03`。刮削到的是英文剧名、文件名也是英文时两者同源，
      // 主标题里已经写着 `The.Glory.S01E03`，副标题再写一遍是纯噪音。
      final e = entry(
        title: 'The Glory S01E03',
        fileName: 'The.Glory.S01E03.2160p.mkv',
        subtitle: '2160P',
      );
      expect(e.rowSubtitle, '2160P');
    });

    test('中文剧名对英文文件名不算重复 —— 那一行反而是有用的', () {
      // 同一支退让，但刮削回来的是中文剧名（`黑暗荣耀`）而网盘文件是英文名
      // （`The.Glory...`）。折叠后一个是 `黑暗荣耀s01e03`、一个是
      // `theglorys01e03…`，互不包含。
      //
      // 这里**不该**去重：主标题是英文文件名，副标题里的中文 `黑暗荣耀 S01E03`
      // 是用户唯一能看到「这是第几集」的地方。若为了「像重复」把它删掉，
      // 副标题就只剩码率，用户反而认不出这一行是第几集。
      final e = entry(
        title: '黑暗荣耀 S01E03',
        fileName: 'The.Glory.S01E03.2160p.mkv',
        subtitle: '2160P',
      );
      expect(e.rowSubtitle, '黑暗荣耀 S01E03 · 2160P');
    });

    test('副标题为空时不留一个孤零零的分隔符', () {
      expect(entry(title: '第 1 集', fileName: 'a.mkv').rowSubtitle, '第 1 集');
      expect(entry(title: '第 1 集', fileName: 'a.mkv', subtitle: '')
          .rowSubtitle, '第 1 集');
    });

    test('fileName 能原样过一趟跨引擎通道', () {
      // 漏了序列化的话，播放窗口收到的 fileName 永远是空串 ——
      // 表现是「面板上又只剩下集号了」，而没有任何报错。
      const original = PlaylistEntry(
        itemId: 'q:9',
        title: '第 3 集',
        fileName: 'The.Glory.S01E03.2160p-老K.mkv',
        subtitle: '2160P · MKV',
        resumePosition: Duration(minutes: 3),
        duration: Duration(minutes: 60),
      );

      final restored = PlaylistEntry.fromJson(original.toJson());

      expect(restored, original);
      expect(restored!.fileName, 'The.Glory.S01E03.2160p-老K.mkv');
      expect(restored.rowTitle, 'The.Glory.S01E03.2160p-老K.mkv');
    });

    test('缺 fileName 的旧请求还原成空串，不是 itemId', () {
      // 回落到 itemId 会显示成 `provider:fileId` 那种机器串 ——
      // 比没有人话标题更糟。
      final restored = PlaylistEntry.fromJson(const <String, Object?>{
        'itemId': 'q:1',
        'title': '第 1 集',
      })!;

      expect(restored.fileName, isEmpty);
      expect(restored.rowTitle, '第 1 集');
    });

    test('fileName 变了就不相等 —— 否则面板不会重绘', () {
      const a = PlaylistEntry(itemId: 'q:1', title: 't', fileName: 'a.mkv');
      const b = PlaylistEntry(itemId: 'q:1', title: 't', fileName: 'b.mkv');
      expect(a == b, isFalse);
    });
  });
}
