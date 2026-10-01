// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $MediaItemsTable extends MediaItems
    with TableInfo<$MediaItemsTable, MediaItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _providerMeta = const VerificationMeta(
    'provider',
  );
  @override
  late final GeneratedColumn<String> provider = GeneratedColumn<String>(
    'provider',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileIdMeta = const VerificationMeta('fileId');
  @override
  late final GeneratedColumn<String> fileId = GeneratedColumn<String>(
    'file_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dirIdMeta = const VerificationMeta('dirId');
  @override
  late final GeneratedColumn<String> dirId = GeneratedColumn<String>(
    'dir_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _dirPathMeta = const VerificationMeta(
    'dirPath',
  );
  @override
  late final GeneratedColumn<String> dirPath = GeneratedColumn<String>(
    'dir_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('/'),
  );
  static const VerificationMeta _groupKeyMeta = const VerificationMeta(
    'groupKey',
  );
  @override
  late final GeneratedColumn<String> groupKey = GeneratedColumn<String>(
    'group_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _seasonMeta = const VerificationMeta('season');
  @override
  late final GeneratedColumn<int> season = GeneratedColumn<int>(
    'season',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _episodeMeta = const VerificationMeta(
    'episode',
  );
  @override
  late final GeneratedColumn<int> episode = GeneratedColumn<int>(
    'episode',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _episodeEndMeta = const VerificationMeta(
    'episodeEnd',
  );
  @override
  late final GeneratedColumn<int> episodeEnd = GeneratedColumn<int>(
    'episode_end',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _containerMeta = const VerificationMeta(
    'container',
  );
  @override
  late final GeneratedColumn<String> container = GeneratedColumn<String>(
    'container',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('other'),
  );
  static const VerificationMeta _resolutionMeta = const VerificationMeta(
    'resolution',
  );
  @override
  late final GeneratedColumn<String> resolution = GeneratedColumn<String>(
    'resolution',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _modifiedAtMeta = const VerificationMeta(
    'modifiedAt',
  );
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
    'modified_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _videoCodecMeta = const VerificationMeta(
    'videoCodec',
  );
  @override
  late final GeneratedColumn<String> videoCodec = GeneratedColumn<String>(
    'video_codec',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _audioCodecMeta = const VerificationMeta(
    'audioCodec',
  );
  @override
  late final GeneratedColumn<String> audioCodec = GeneratedColumn<String>(
    'audio_codec',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _flagsMeta = const VerificationMeta('flags');
  @override
  late final GeneratedColumn<String> flags = GeneratedColumn<String>(
    'flags',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _releaseGroupMeta = const VerificationMeta(
    'releaseGroup',
  );
  @override
  late final GeneratedColumn<String> releaseGroup = GeneratedColumn<String>(
    'release_group',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isSampleOrExtraMeta = const VerificationMeta(
    'isSampleOrExtra',
  );
  @override
  late final GeneratedColumn<bool> isSampleOrExtra = GeneratedColumn<bool>(
    'is_sample_or_extra',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_sample_or_extra" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _firstSeenAtMeta = const VerificationMeta(
    'firstSeenAt',
  );
  @override
  late final GeneratedColumn<DateTime> firstSeenAt = GeneratedColumn<DateTime>(
    'first_seen_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastPlayedAtMeta = const VerificationMeta(
    'lastPlayedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastPlayedAt = GeneratedColumn<DateTime>(
    'last_played_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resumePositionMsMeta = const VerificationMeta(
    'resumePositionMs',
  );
  @override
  late final GeneratedColumn<int> resumePositionMs = GeneratedColumn<int>(
    'resume_position_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _thumbUrlMeta = const VerificationMeta(
    'thumbUrl',
  );
  @override
  late final GeneratedColumn<String> thumbUrl = GeneratedColumn<String>(
    'thumb_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _videoWidthMeta = const VerificationMeta(
    'videoWidth',
  );
  @override
  late final GeneratedColumn<int> videoWidth = GeneratedColumn<int>(
    'video_width',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _videoHeightMeta = const VerificationMeta(
    'videoHeight',
  );
  @override
  late final GeneratedColumn<int> videoHeight = GeneratedColumn<int>(
    'video_height',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    provider,
    fileId,
    name,
    dirId,
    dirPath,
    groupKey,
    kind,
    title,
    year,
    season,
    episode,
    episodeEnd,
    container,
    resolution,
    sizeBytes,
    modifiedAt,
    durationMs,
    source,
    videoCodec,
    audioCodec,
    flags,
    releaseGroup,
    isSampleOrExtra,
    firstSeenAt,
    updatedAt,
    lastPlayedAt,
    resumePositionMs,
    thumbUrl,
    videoWidth,
    videoHeight,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<MediaItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('provider')) {
      context.handle(
        _providerMeta,
        provider.isAcceptableOrUnknown(data['provider']!, _providerMeta),
      );
    } else if (isInserting) {
      context.missing(_providerMeta);
    }
    if (data.containsKey('file_id')) {
      context.handle(
        _fileIdMeta,
        fileId.isAcceptableOrUnknown(data['file_id']!, _fileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_fileIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('dir_id')) {
      context.handle(
        _dirIdMeta,
        dirId.isAcceptableOrUnknown(data['dir_id']!, _dirIdMeta),
      );
    }
    if (data.containsKey('dir_path')) {
      context.handle(
        _dirPathMeta,
        dirPath.isAcceptableOrUnknown(data['dir_path']!, _dirPathMeta),
      );
    }
    if (data.containsKey('group_key')) {
      context.handle(
        _groupKeyMeta,
        groupKey.isAcceptableOrUnknown(data['group_key']!, _groupKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_groupKeyMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('year')) {
      context.handle(
        _yearMeta,
        year.isAcceptableOrUnknown(data['year']!, _yearMeta),
      );
    }
    if (data.containsKey('season')) {
      context.handle(
        _seasonMeta,
        season.isAcceptableOrUnknown(data['season']!, _seasonMeta),
      );
    }
    if (data.containsKey('episode')) {
      context.handle(
        _episodeMeta,
        episode.isAcceptableOrUnknown(data['episode']!, _episodeMeta),
      );
    }
    if (data.containsKey('episode_end')) {
      context.handle(
        _episodeEndMeta,
        episodeEnd.isAcceptableOrUnknown(data['episode_end']!, _episodeEndMeta),
      );
    }
    if (data.containsKey('container')) {
      context.handle(
        _containerMeta,
        container.isAcceptableOrUnknown(data['container']!, _containerMeta),
      );
    }
    if (data.containsKey('resolution')) {
      context.handle(
        _resolutionMeta,
        resolution.isAcceptableOrUnknown(data['resolution']!, _resolutionMeta),
      );
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    }
    if (data.containsKey('modified_at')) {
      context.handle(
        _modifiedAtMeta,
        modifiedAt.isAcceptableOrUnknown(data['modified_at']!, _modifiedAtMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('video_codec')) {
      context.handle(
        _videoCodecMeta,
        videoCodec.isAcceptableOrUnknown(data['video_codec']!, _videoCodecMeta),
      );
    }
    if (data.containsKey('audio_codec')) {
      context.handle(
        _audioCodecMeta,
        audioCodec.isAcceptableOrUnknown(data['audio_codec']!, _audioCodecMeta),
      );
    }
    if (data.containsKey('flags')) {
      context.handle(
        _flagsMeta,
        flags.isAcceptableOrUnknown(data['flags']!, _flagsMeta),
      );
    }
    if (data.containsKey('release_group')) {
      context.handle(
        _releaseGroupMeta,
        releaseGroup.isAcceptableOrUnknown(
          data['release_group']!,
          _releaseGroupMeta,
        ),
      );
    }
    if (data.containsKey('is_sample_or_extra')) {
      context.handle(
        _isSampleOrExtraMeta,
        isSampleOrExtra.isAcceptableOrUnknown(
          data['is_sample_or_extra']!,
          _isSampleOrExtraMeta,
        ),
      );
    }
    if (data.containsKey('first_seen_at')) {
      context.handle(
        _firstSeenAtMeta,
        firstSeenAt.isAcceptableOrUnknown(
          data['first_seen_at']!,
          _firstSeenAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_firstSeenAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('last_played_at')) {
      context.handle(
        _lastPlayedAtMeta,
        lastPlayedAt.isAcceptableOrUnknown(
          data['last_played_at']!,
          _lastPlayedAtMeta,
        ),
      );
    }
    if (data.containsKey('resume_position_ms')) {
      context.handle(
        _resumePositionMsMeta,
        resumePositionMs.isAcceptableOrUnknown(
          data['resume_position_ms']!,
          _resumePositionMsMeta,
        ),
      );
    }
    if (data.containsKey('thumb_url')) {
      context.handle(
        _thumbUrlMeta,
        thumbUrl.isAcceptableOrUnknown(data['thumb_url']!, _thumbUrlMeta),
      );
    }
    if (data.containsKey('video_width')) {
      context.handle(
        _videoWidthMeta,
        videoWidth.isAcceptableOrUnknown(data['video_width']!, _videoWidthMeta),
      );
    }
    if (data.containsKey('video_height')) {
      context.handle(
        _videoHeightMeta,
        videoHeight.isAcceptableOrUnknown(
          data['video_height']!,
          _videoHeightMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MediaItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaItemRow(
      id:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}id'],
          )!,
      provider:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}provider'],
          )!,
      fileId:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}file_id'],
          )!,
      name:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}name'],
          )!,
      dirId:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}dir_id'],
          )!,
      dirPath:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}dir_path'],
          )!,
      groupKey:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}group_key'],
          )!,
      kind:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}kind'],
          )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      ),
      year: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}year'],
      ),
      season: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}season'],
      ),
      episode: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}episode'],
      ),
      episodeEnd: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}episode_end'],
      ),
      container:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}container'],
          )!,
      resolution: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resolution'],
      ),
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      ),
      modifiedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}modified_at'],
      ),
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      ),
      videoCodec: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}video_codec'],
      ),
      audioCodec: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}audio_codec'],
      ),
      flags:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}flags'],
          )!,
      releaseGroup: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}release_group'],
      ),
      isSampleOrExtra:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}is_sample_or_extra'],
          )!,
      firstSeenAt:
          attachedDatabase.typeMapping.read(
            DriftSqlType.dateTime,
            data['${effectivePrefix}first_seen_at'],
          )!,
      updatedAt:
          attachedDatabase.typeMapping.read(
            DriftSqlType.dateTime,
            data['${effectivePrefix}updated_at'],
          )!,
      lastPlayedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_played_at'],
      ),
      resumePositionMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}resume_position_ms'],
      ),
      thumbUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumb_url'],
      ),
      videoWidth: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}video_width'],
      ),
      videoHeight: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}video_height'],
      ),
    );
  }

  @override
  $MediaItemsTable createAlias(String alias) {
    return $MediaItemsTable(attachedDatabase, alias);
  }
}

class MediaItemRow extends DataClass implements Insertable<MediaItemRow> {
  /// 主键：`provider:fileId`（见 `MediaItem.id`）
  final String id;
  final String provider;
  final String fileId;
  final String name;
  final String dirId;
  final String dirPath;

  /// 归组键 —— 作品表的关联字段。
  ///
  /// 刻意**不加外键约束**：作品行是在遍历结束后才统一写的，中途被杀时
  /// 会存在「有媒体项、没作品行」的中间态。外键会让那个中间态无法写入，
  /// 而它恰恰是「续扫」这个功能的正常状态。
  final String groupKey;
  final String kind;
  final String? title;
  final int? year;
  final int? season;
  final int? episode;
  final int? episodeEnd;

  /// 容器标识（`VideoContainer.name`）
  final String container;

  /// 分辨率档位标识（`VideoResolution.label`，如 `1080P`）。
  ///
  /// 存 label 而不是枚举 index：枚举顺序一旦调整（比如插一档 8K 到中间），
  /// index 会整体错位，而旧数据会**静默**变成另一档分辨率。
  final String? resolution;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final int? durationMs;
  final String? source;
  final String? videoCodec;
  final String? audioCodec;

  /// 标记集合，存 JSON 数组字符串（`["HDR","10bit"]`）。
  final String flags;
  final String? releaseGroup;
  final bool isSampleOrExtra;

  /// 入库时间。**决定「最近添加」排序**，因此 upsert 时必须保留旧值。
  final DateTime firstSeenAt;
  final DateTime updatedAt;

  /// 最近播放时间。`null` 表示没播过。
  final DateTime? lastPlayedAt;

  /// 续播位置（毫秒）。`null` = 没有可续的点（没播过 / 已看完 / 用户关了
  /// 「记住播放进度」）。
  ///
  /// ## 为什么是单独一列而不是复用 [lastPlayedAt]
  ///
  /// 两者**语义不同、更新频率差两个数量级**：`lastPlayedAt` 是「什么时候看的」
  /// （决定「最近播放」排序），每 10 秒一次进度回报都会刷新它；而这一列是
  /// 「看到哪儿了」，也每 10 秒写一次。合成一列就得塞 JSON，而那会让
  /// 「最近播放」的排序查询变成字符串解析。
  ///
  /// ## 为什么存毫秒而不是秒
  ///
  /// 时长本身就是毫秒（[MediaItems.durationMs]），统一单位省掉一处换算；
  /// 而换算正是这类字段最容易出错的地方（`inSeconds` 截断 vs 四舍五入）。
  final int? resumePositionMs;

  /// 网盘服务端生成的视频预览图地址（夸克 `preview_url` / `thumbnail`）。
  ///
  /// **只存地址，不存图片** —— 图片由 `PosterCache` 按需下载并落盘。
  /// 扫描期下载几千张图会让一次扫描多出几千次请求（夸克有 QPS 限制），
  /// 而用户可能根本不会翻到那些片子。
  ///
  /// 地址**不含 Cookie**（Cookie 在每次响应里轮换，冻进地址第二天就 401），
  /// 取图时必须由适配器现给请求头。
  final String? thumbUrl;

  /// 网盘给出的**实测**视频像素尺寸（夸克 `video_width` / `video_height`）。
  ///
  /// 2026-10-01 实测：递归遍历 44 个目录、427 个视频，这两个字段覆盖率
  /// **100%**，且没有 0 值。它们比文件名可靠，所以 [resolution] 那一列在
  /// 它们存在时是**由它们归挡出来的**，而不是从文件名猜的。
  ///
  /// ## 为什么存原始像素，而不只存归挡结果
  ///
  /// 归挡规则将来可能调整（加档、改长边阈值），届时可以从原始值**重算**；
  /// 只存档位就只能重扫全盘。两者代价差一个数量级。
  final int? videoWidth;
  final int? videoHeight;
  const MediaItemRow({
    required this.id,
    required this.provider,
    required this.fileId,
    required this.name,
    required this.dirId,
    required this.dirPath,
    required this.groupKey,
    required this.kind,
    this.title,
    this.year,
    this.season,
    this.episode,
    this.episodeEnd,
    required this.container,
    this.resolution,
    this.sizeBytes,
    this.modifiedAt,
    this.durationMs,
    this.source,
    this.videoCodec,
    this.audioCodec,
    required this.flags,
    this.releaseGroup,
    required this.isSampleOrExtra,
    required this.firstSeenAt,
    required this.updatedAt,
    this.lastPlayedAt,
    this.resumePositionMs,
    this.thumbUrl,
    this.videoWidth,
    this.videoHeight,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['provider'] = Variable<String>(provider);
    map['file_id'] = Variable<String>(fileId);
    map['name'] = Variable<String>(name);
    map['dir_id'] = Variable<String>(dirId);
    map['dir_path'] = Variable<String>(dirPath);
    map['group_key'] = Variable<String>(groupKey);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || title != null) {
      map['title'] = Variable<String>(title);
    }
    if (!nullToAbsent || year != null) {
      map['year'] = Variable<int>(year);
    }
    if (!nullToAbsent || season != null) {
      map['season'] = Variable<int>(season);
    }
    if (!nullToAbsent || episode != null) {
      map['episode'] = Variable<int>(episode);
    }
    if (!nullToAbsent || episodeEnd != null) {
      map['episode_end'] = Variable<int>(episodeEnd);
    }
    map['container'] = Variable<String>(container);
    if (!nullToAbsent || resolution != null) {
      map['resolution'] = Variable<String>(resolution);
    }
    if (!nullToAbsent || sizeBytes != null) {
      map['size_bytes'] = Variable<int>(sizeBytes);
    }
    if (!nullToAbsent || modifiedAt != null) {
      map['modified_at'] = Variable<DateTime>(modifiedAt);
    }
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    if (!nullToAbsent || source != null) {
      map['source'] = Variable<String>(source);
    }
    if (!nullToAbsent || videoCodec != null) {
      map['video_codec'] = Variable<String>(videoCodec);
    }
    if (!nullToAbsent || audioCodec != null) {
      map['audio_codec'] = Variable<String>(audioCodec);
    }
    map['flags'] = Variable<String>(flags);
    if (!nullToAbsent || releaseGroup != null) {
      map['release_group'] = Variable<String>(releaseGroup);
    }
    map['is_sample_or_extra'] = Variable<bool>(isSampleOrExtra);
    map['first_seen_at'] = Variable<DateTime>(firstSeenAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || lastPlayedAt != null) {
      map['last_played_at'] = Variable<DateTime>(lastPlayedAt);
    }
    if (!nullToAbsent || resumePositionMs != null) {
      map['resume_position_ms'] = Variable<int>(resumePositionMs);
    }
    if (!nullToAbsent || thumbUrl != null) {
      map['thumb_url'] = Variable<String>(thumbUrl);
    }
    if (!nullToAbsent || videoWidth != null) {
      map['video_width'] = Variable<int>(videoWidth);
    }
    if (!nullToAbsent || videoHeight != null) {
      map['video_height'] = Variable<int>(videoHeight);
    }
    return map;
  }

  MediaItemsCompanion toCompanion(bool nullToAbsent) {
    return MediaItemsCompanion(
      id: Value(id),
      provider: Value(provider),
      fileId: Value(fileId),
      name: Value(name),
      dirId: Value(dirId),
      dirPath: Value(dirPath),
      groupKey: Value(groupKey),
      kind: Value(kind),
      title:
          title == null && nullToAbsent ? const Value.absent() : Value(title),
      year: year == null && nullToAbsent ? const Value.absent() : Value(year),
      season:
          season == null && nullToAbsent ? const Value.absent() : Value(season),
      episode:
          episode == null && nullToAbsent
              ? const Value.absent()
              : Value(episode),
      episodeEnd:
          episodeEnd == null && nullToAbsent
              ? const Value.absent()
              : Value(episodeEnd),
      container: Value(container),
      resolution:
          resolution == null && nullToAbsent
              ? const Value.absent()
              : Value(resolution),
      sizeBytes:
          sizeBytes == null && nullToAbsent
              ? const Value.absent()
              : Value(sizeBytes),
      modifiedAt:
          modifiedAt == null && nullToAbsent
              ? const Value.absent()
              : Value(modifiedAt),
      durationMs:
          durationMs == null && nullToAbsent
              ? const Value.absent()
              : Value(durationMs),
      source:
          source == null && nullToAbsent ? const Value.absent() : Value(source),
      videoCodec:
          videoCodec == null && nullToAbsent
              ? const Value.absent()
              : Value(videoCodec),
      audioCodec:
          audioCodec == null && nullToAbsent
              ? const Value.absent()
              : Value(audioCodec),
      flags: Value(flags),
      releaseGroup:
          releaseGroup == null && nullToAbsent
              ? const Value.absent()
              : Value(releaseGroup),
      isSampleOrExtra: Value(isSampleOrExtra),
      firstSeenAt: Value(firstSeenAt),
      updatedAt: Value(updatedAt),
      lastPlayedAt:
          lastPlayedAt == null && nullToAbsent
              ? const Value.absent()
              : Value(lastPlayedAt),
      resumePositionMs:
          resumePositionMs == null && nullToAbsent
              ? const Value.absent()
              : Value(resumePositionMs),
      thumbUrl:
          thumbUrl == null && nullToAbsent
              ? const Value.absent()
              : Value(thumbUrl),
      videoWidth:
          videoWidth == null && nullToAbsent
              ? const Value.absent()
              : Value(videoWidth),
      videoHeight:
          videoHeight == null && nullToAbsent
              ? const Value.absent()
              : Value(videoHeight),
    );
  }

  factory MediaItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaItemRow(
      id: serializer.fromJson<String>(json['id']),
      provider: serializer.fromJson<String>(json['provider']),
      fileId: serializer.fromJson<String>(json['fileId']),
      name: serializer.fromJson<String>(json['name']),
      dirId: serializer.fromJson<String>(json['dirId']),
      dirPath: serializer.fromJson<String>(json['dirPath']),
      groupKey: serializer.fromJson<String>(json['groupKey']),
      kind: serializer.fromJson<String>(json['kind']),
      title: serializer.fromJson<String?>(json['title']),
      year: serializer.fromJson<int?>(json['year']),
      season: serializer.fromJson<int?>(json['season']),
      episode: serializer.fromJson<int?>(json['episode']),
      episodeEnd: serializer.fromJson<int?>(json['episodeEnd']),
      container: serializer.fromJson<String>(json['container']),
      resolution: serializer.fromJson<String?>(json['resolution']),
      sizeBytes: serializer.fromJson<int?>(json['sizeBytes']),
      modifiedAt: serializer.fromJson<DateTime?>(json['modifiedAt']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      source: serializer.fromJson<String?>(json['source']),
      videoCodec: serializer.fromJson<String?>(json['videoCodec']),
      audioCodec: serializer.fromJson<String?>(json['audioCodec']),
      flags: serializer.fromJson<String>(json['flags']),
      releaseGroup: serializer.fromJson<String?>(json['releaseGroup']),
      isSampleOrExtra: serializer.fromJson<bool>(json['isSampleOrExtra']),
      firstSeenAt: serializer.fromJson<DateTime>(json['firstSeenAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      lastPlayedAt: serializer.fromJson<DateTime?>(json['lastPlayedAt']),
      resumePositionMs: serializer.fromJson<int?>(json['resumePositionMs']),
      thumbUrl: serializer.fromJson<String?>(json['thumbUrl']),
      videoWidth: serializer.fromJson<int?>(json['videoWidth']),
      videoHeight: serializer.fromJson<int?>(json['videoHeight']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'provider': serializer.toJson<String>(provider),
      'fileId': serializer.toJson<String>(fileId),
      'name': serializer.toJson<String>(name),
      'dirId': serializer.toJson<String>(dirId),
      'dirPath': serializer.toJson<String>(dirPath),
      'groupKey': serializer.toJson<String>(groupKey),
      'kind': serializer.toJson<String>(kind),
      'title': serializer.toJson<String?>(title),
      'year': serializer.toJson<int?>(year),
      'season': serializer.toJson<int?>(season),
      'episode': serializer.toJson<int?>(episode),
      'episodeEnd': serializer.toJson<int?>(episodeEnd),
      'container': serializer.toJson<String>(container),
      'resolution': serializer.toJson<String?>(resolution),
      'sizeBytes': serializer.toJson<int?>(sizeBytes),
      'modifiedAt': serializer.toJson<DateTime?>(modifiedAt),
      'durationMs': serializer.toJson<int?>(durationMs),
      'source': serializer.toJson<String?>(source),
      'videoCodec': serializer.toJson<String?>(videoCodec),
      'audioCodec': serializer.toJson<String?>(audioCodec),
      'flags': serializer.toJson<String>(flags),
      'releaseGroup': serializer.toJson<String?>(releaseGroup),
      'isSampleOrExtra': serializer.toJson<bool>(isSampleOrExtra),
      'firstSeenAt': serializer.toJson<DateTime>(firstSeenAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'lastPlayedAt': serializer.toJson<DateTime?>(lastPlayedAt),
      'resumePositionMs': serializer.toJson<int?>(resumePositionMs),
      'thumbUrl': serializer.toJson<String?>(thumbUrl),
      'videoWidth': serializer.toJson<int?>(videoWidth),
      'videoHeight': serializer.toJson<int?>(videoHeight),
    };
  }

  MediaItemRow copyWith({
    String? id,
    String? provider,
    String? fileId,
    String? name,
    String? dirId,
    String? dirPath,
    String? groupKey,
    String? kind,
    Value<String?> title = const Value.absent(),
    Value<int?> year = const Value.absent(),
    Value<int?> season = const Value.absent(),
    Value<int?> episode = const Value.absent(),
    Value<int?> episodeEnd = const Value.absent(),
    String? container,
    Value<String?> resolution = const Value.absent(),
    Value<int?> sizeBytes = const Value.absent(),
    Value<DateTime?> modifiedAt = const Value.absent(),
    Value<int?> durationMs = const Value.absent(),
    Value<String?> source = const Value.absent(),
    Value<String?> videoCodec = const Value.absent(),
    Value<String?> audioCodec = const Value.absent(),
    String? flags,
    Value<String?> releaseGroup = const Value.absent(),
    bool? isSampleOrExtra,
    DateTime? firstSeenAt,
    DateTime? updatedAt,
    Value<DateTime?> lastPlayedAt = const Value.absent(),
    Value<int?> resumePositionMs = const Value.absent(),
    Value<String?> thumbUrl = const Value.absent(),
    Value<int?> videoWidth = const Value.absent(),
    Value<int?> videoHeight = const Value.absent(),
  }) => MediaItemRow(
    id: id ?? this.id,
    provider: provider ?? this.provider,
    fileId: fileId ?? this.fileId,
    name: name ?? this.name,
    dirId: dirId ?? this.dirId,
    dirPath: dirPath ?? this.dirPath,
    groupKey: groupKey ?? this.groupKey,
    kind: kind ?? this.kind,
    title: title.present ? title.value : this.title,
    year: year.present ? year.value : this.year,
    season: season.present ? season.value : this.season,
    episode: episode.present ? episode.value : this.episode,
    episodeEnd: episodeEnd.present ? episodeEnd.value : this.episodeEnd,
    container: container ?? this.container,
    resolution: resolution.present ? resolution.value : this.resolution,
    sizeBytes: sizeBytes.present ? sizeBytes.value : this.sizeBytes,
    modifiedAt: modifiedAt.present ? modifiedAt.value : this.modifiedAt,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    source: source.present ? source.value : this.source,
    videoCodec: videoCodec.present ? videoCodec.value : this.videoCodec,
    audioCodec: audioCodec.present ? audioCodec.value : this.audioCodec,
    flags: flags ?? this.flags,
    releaseGroup: releaseGroup.present ? releaseGroup.value : this.releaseGroup,
    isSampleOrExtra: isSampleOrExtra ?? this.isSampleOrExtra,
    firstSeenAt: firstSeenAt ?? this.firstSeenAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastPlayedAt: lastPlayedAt.present ? lastPlayedAt.value : this.lastPlayedAt,
    resumePositionMs:
        resumePositionMs.present
            ? resumePositionMs.value
            : this.resumePositionMs,
    thumbUrl: thumbUrl.present ? thumbUrl.value : this.thumbUrl,
    videoWidth: videoWidth.present ? videoWidth.value : this.videoWidth,
    videoHeight: videoHeight.present ? videoHeight.value : this.videoHeight,
  );
  MediaItemRow copyWithCompanion(MediaItemsCompanion data) {
    return MediaItemRow(
      id: data.id.present ? data.id.value : this.id,
      provider: data.provider.present ? data.provider.value : this.provider,
      fileId: data.fileId.present ? data.fileId.value : this.fileId,
      name: data.name.present ? data.name.value : this.name,
      dirId: data.dirId.present ? data.dirId.value : this.dirId,
      dirPath: data.dirPath.present ? data.dirPath.value : this.dirPath,
      groupKey: data.groupKey.present ? data.groupKey.value : this.groupKey,
      kind: data.kind.present ? data.kind.value : this.kind,
      title: data.title.present ? data.title.value : this.title,
      year: data.year.present ? data.year.value : this.year,
      season: data.season.present ? data.season.value : this.season,
      episode: data.episode.present ? data.episode.value : this.episode,
      episodeEnd:
          data.episodeEnd.present ? data.episodeEnd.value : this.episodeEnd,
      container: data.container.present ? data.container.value : this.container,
      resolution:
          data.resolution.present ? data.resolution.value : this.resolution,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      durationMs:
          data.durationMs.present ? data.durationMs.value : this.durationMs,
      source: data.source.present ? data.source.value : this.source,
      videoCodec:
          data.videoCodec.present ? data.videoCodec.value : this.videoCodec,
      audioCodec:
          data.audioCodec.present ? data.audioCodec.value : this.audioCodec,
      flags: data.flags.present ? data.flags.value : this.flags,
      releaseGroup:
          data.releaseGroup.present
              ? data.releaseGroup.value
              : this.releaseGroup,
      isSampleOrExtra:
          data.isSampleOrExtra.present
              ? data.isSampleOrExtra.value
              : this.isSampleOrExtra,
      firstSeenAt:
          data.firstSeenAt.present ? data.firstSeenAt.value : this.firstSeenAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      lastPlayedAt:
          data.lastPlayedAt.present
              ? data.lastPlayedAt.value
              : this.lastPlayedAt,
      resumePositionMs:
          data.resumePositionMs.present
              ? data.resumePositionMs.value
              : this.resumePositionMs,
      thumbUrl: data.thumbUrl.present ? data.thumbUrl.value : this.thumbUrl,
      videoWidth:
          data.videoWidth.present ? data.videoWidth.value : this.videoWidth,
      videoHeight:
          data.videoHeight.present ? data.videoHeight.value : this.videoHeight,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaItemRow(')
          ..write('id: $id, ')
          ..write('provider: $provider, ')
          ..write('fileId: $fileId, ')
          ..write('name: $name, ')
          ..write('dirId: $dirId, ')
          ..write('dirPath: $dirPath, ')
          ..write('groupKey: $groupKey, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('year: $year, ')
          ..write('season: $season, ')
          ..write('episode: $episode, ')
          ..write('episodeEnd: $episodeEnd, ')
          ..write('container: $container, ')
          ..write('resolution: $resolution, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('source: $source, ')
          ..write('videoCodec: $videoCodec, ')
          ..write('audioCodec: $audioCodec, ')
          ..write('flags: $flags, ')
          ..write('releaseGroup: $releaseGroup, ')
          ..write('isSampleOrExtra: $isSampleOrExtra, ')
          ..write('firstSeenAt: $firstSeenAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('resumePositionMs: $resumePositionMs, ')
          ..write('thumbUrl: $thumbUrl, ')
          ..write('videoWidth: $videoWidth, ')
          ..write('videoHeight: $videoHeight')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    provider,
    fileId,
    name,
    dirId,
    dirPath,
    groupKey,
    kind,
    title,
    year,
    season,
    episode,
    episodeEnd,
    container,
    resolution,
    sizeBytes,
    modifiedAt,
    durationMs,
    source,
    videoCodec,
    audioCodec,
    flags,
    releaseGroup,
    isSampleOrExtra,
    firstSeenAt,
    updatedAt,
    lastPlayedAt,
    resumePositionMs,
    thumbUrl,
    videoWidth,
    videoHeight,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaItemRow &&
          other.id == this.id &&
          other.provider == this.provider &&
          other.fileId == this.fileId &&
          other.name == this.name &&
          other.dirId == this.dirId &&
          other.dirPath == this.dirPath &&
          other.groupKey == this.groupKey &&
          other.kind == this.kind &&
          other.title == this.title &&
          other.year == this.year &&
          other.season == this.season &&
          other.episode == this.episode &&
          other.episodeEnd == this.episodeEnd &&
          other.container == this.container &&
          other.resolution == this.resolution &&
          other.sizeBytes == this.sizeBytes &&
          other.modifiedAt == this.modifiedAt &&
          other.durationMs == this.durationMs &&
          other.source == this.source &&
          other.videoCodec == this.videoCodec &&
          other.audioCodec == this.audioCodec &&
          other.flags == this.flags &&
          other.releaseGroup == this.releaseGroup &&
          other.isSampleOrExtra == this.isSampleOrExtra &&
          other.firstSeenAt == this.firstSeenAt &&
          other.updatedAt == this.updatedAt &&
          other.lastPlayedAt == this.lastPlayedAt &&
          other.resumePositionMs == this.resumePositionMs &&
          other.thumbUrl == this.thumbUrl &&
          other.videoWidth == this.videoWidth &&
          other.videoHeight == this.videoHeight);
}

class MediaItemsCompanion extends UpdateCompanion<MediaItemRow> {
  final Value<String> id;
  final Value<String> provider;
  final Value<String> fileId;
  final Value<String> name;
  final Value<String> dirId;
  final Value<String> dirPath;
  final Value<String> groupKey;
  final Value<String> kind;
  final Value<String?> title;
  final Value<int?> year;
  final Value<int?> season;
  final Value<int?> episode;
  final Value<int?> episodeEnd;
  final Value<String> container;
  final Value<String?> resolution;
  final Value<int?> sizeBytes;
  final Value<DateTime?> modifiedAt;
  final Value<int?> durationMs;
  final Value<String?> source;
  final Value<String?> videoCodec;
  final Value<String?> audioCodec;
  final Value<String> flags;
  final Value<String?> releaseGroup;
  final Value<bool> isSampleOrExtra;
  final Value<DateTime> firstSeenAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> lastPlayedAt;
  final Value<int?> resumePositionMs;
  final Value<String?> thumbUrl;
  final Value<int?> videoWidth;
  final Value<int?> videoHeight;
  final Value<int> rowid;
  const MediaItemsCompanion({
    this.id = const Value.absent(),
    this.provider = const Value.absent(),
    this.fileId = const Value.absent(),
    this.name = const Value.absent(),
    this.dirId = const Value.absent(),
    this.dirPath = const Value.absent(),
    this.groupKey = const Value.absent(),
    this.kind = const Value.absent(),
    this.title = const Value.absent(),
    this.year = const Value.absent(),
    this.season = const Value.absent(),
    this.episode = const Value.absent(),
    this.episodeEnd = const Value.absent(),
    this.container = const Value.absent(),
    this.resolution = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.source = const Value.absent(),
    this.videoCodec = const Value.absent(),
    this.audioCodec = const Value.absent(),
    this.flags = const Value.absent(),
    this.releaseGroup = const Value.absent(),
    this.isSampleOrExtra = const Value.absent(),
    this.firstSeenAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.lastPlayedAt = const Value.absent(),
    this.resumePositionMs = const Value.absent(),
    this.thumbUrl = const Value.absent(),
    this.videoWidth = const Value.absent(),
    this.videoHeight = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaItemsCompanion.insert({
    required String id,
    required String provider,
    required String fileId,
    required String name,
    this.dirId = const Value.absent(),
    this.dirPath = const Value.absent(),
    required String groupKey,
    required String kind,
    this.title = const Value.absent(),
    this.year = const Value.absent(),
    this.season = const Value.absent(),
    this.episode = const Value.absent(),
    this.episodeEnd = const Value.absent(),
    this.container = const Value.absent(),
    this.resolution = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.source = const Value.absent(),
    this.videoCodec = const Value.absent(),
    this.audioCodec = const Value.absent(),
    this.flags = const Value.absent(),
    this.releaseGroup = const Value.absent(),
    this.isSampleOrExtra = const Value.absent(),
    required DateTime firstSeenAt,
    required DateTime updatedAt,
    this.lastPlayedAt = const Value.absent(),
    this.resumePositionMs = const Value.absent(),
    this.thumbUrl = const Value.absent(),
    this.videoWidth = const Value.absent(),
    this.videoHeight = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       provider = Value(provider),
       fileId = Value(fileId),
       name = Value(name),
       groupKey = Value(groupKey),
       kind = Value(kind),
       firstSeenAt = Value(firstSeenAt),
       updatedAt = Value(updatedAt);
  static Insertable<MediaItemRow> custom({
    Expression<String>? id,
    Expression<String>? provider,
    Expression<String>? fileId,
    Expression<String>? name,
    Expression<String>? dirId,
    Expression<String>? dirPath,
    Expression<String>? groupKey,
    Expression<String>? kind,
    Expression<String>? title,
    Expression<int>? year,
    Expression<int>? season,
    Expression<int>? episode,
    Expression<int>? episodeEnd,
    Expression<String>? container,
    Expression<String>? resolution,
    Expression<int>? sizeBytes,
    Expression<DateTime>? modifiedAt,
    Expression<int>? durationMs,
    Expression<String>? source,
    Expression<String>? videoCodec,
    Expression<String>? audioCodec,
    Expression<String>? flags,
    Expression<String>? releaseGroup,
    Expression<bool>? isSampleOrExtra,
    Expression<DateTime>? firstSeenAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? lastPlayedAt,
    Expression<int>? resumePositionMs,
    Expression<String>? thumbUrl,
    Expression<int>? videoWidth,
    Expression<int>? videoHeight,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (provider != null) 'provider': provider,
      if (fileId != null) 'file_id': fileId,
      if (name != null) 'name': name,
      if (dirId != null) 'dir_id': dirId,
      if (dirPath != null) 'dir_path': dirPath,
      if (groupKey != null) 'group_key': groupKey,
      if (kind != null) 'kind': kind,
      if (title != null) 'title': title,
      if (year != null) 'year': year,
      if (season != null) 'season': season,
      if (episode != null) 'episode': episode,
      if (episodeEnd != null) 'episode_end': episodeEnd,
      if (container != null) 'container': container,
      if (resolution != null) 'resolution': resolution,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (durationMs != null) 'duration_ms': durationMs,
      if (source != null) 'source': source,
      if (videoCodec != null) 'video_codec': videoCodec,
      if (audioCodec != null) 'audio_codec': audioCodec,
      if (flags != null) 'flags': flags,
      if (releaseGroup != null) 'release_group': releaseGroup,
      if (isSampleOrExtra != null) 'is_sample_or_extra': isSampleOrExtra,
      if (firstSeenAt != null) 'first_seen_at': firstSeenAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (lastPlayedAt != null) 'last_played_at': lastPlayedAt,
      if (resumePositionMs != null) 'resume_position_ms': resumePositionMs,
      if (thumbUrl != null) 'thumb_url': thumbUrl,
      if (videoWidth != null) 'video_width': videoWidth,
      if (videoHeight != null) 'video_height': videoHeight,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaItemsCompanion copyWith({
    Value<String>? id,
    Value<String>? provider,
    Value<String>? fileId,
    Value<String>? name,
    Value<String>? dirId,
    Value<String>? dirPath,
    Value<String>? groupKey,
    Value<String>? kind,
    Value<String?>? title,
    Value<int?>? year,
    Value<int?>? season,
    Value<int?>? episode,
    Value<int?>? episodeEnd,
    Value<String>? container,
    Value<String?>? resolution,
    Value<int?>? sizeBytes,
    Value<DateTime?>? modifiedAt,
    Value<int?>? durationMs,
    Value<String?>? source,
    Value<String?>? videoCodec,
    Value<String?>? audioCodec,
    Value<String>? flags,
    Value<String?>? releaseGroup,
    Value<bool>? isSampleOrExtra,
    Value<DateTime>? firstSeenAt,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? lastPlayedAt,
    Value<int?>? resumePositionMs,
    Value<String?>? thumbUrl,
    Value<int?>? videoWidth,
    Value<int?>? videoHeight,
    Value<int>? rowid,
  }) {
    return MediaItemsCompanion(
      id: id ?? this.id,
      provider: provider ?? this.provider,
      fileId: fileId ?? this.fileId,
      name: name ?? this.name,
      dirId: dirId ?? this.dirId,
      dirPath: dirPath ?? this.dirPath,
      groupKey: groupKey ?? this.groupKey,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      year: year ?? this.year,
      season: season ?? this.season,
      episode: episode ?? this.episode,
      episodeEnd: episodeEnd ?? this.episodeEnd,
      container: container ?? this.container,
      resolution: resolution ?? this.resolution,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      durationMs: durationMs ?? this.durationMs,
      source: source ?? this.source,
      videoCodec: videoCodec ?? this.videoCodec,
      audioCodec: audioCodec ?? this.audioCodec,
      flags: flags ?? this.flags,
      releaseGroup: releaseGroup ?? this.releaseGroup,
      isSampleOrExtra: isSampleOrExtra ?? this.isSampleOrExtra,
      firstSeenAt: firstSeenAt ?? this.firstSeenAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      resumePositionMs: resumePositionMs ?? this.resumePositionMs,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (provider.present) {
      map['provider'] = Variable<String>(provider.value);
    }
    if (fileId.present) {
      map['file_id'] = Variable<String>(fileId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (dirId.present) {
      map['dir_id'] = Variable<String>(dirId.value);
    }
    if (dirPath.present) {
      map['dir_path'] = Variable<String>(dirPath.value);
    }
    if (groupKey.present) {
      map['group_key'] = Variable<String>(groupKey.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (season.present) {
      map['season'] = Variable<int>(season.value);
    }
    if (episode.present) {
      map['episode'] = Variable<int>(episode.value);
    }
    if (episodeEnd.present) {
      map['episode_end'] = Variable<int>(episodeEnd.value);
    }
    if (container.present) {
      map['container'] = Variable<String>(container.value);
    }
    if (resolution.present) {
      map['resolution'] = Variable<String>(resolution.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (videoCodec.present) {
      map['video_codec'] = Variable<String>(videoCodec.value);
    }
    if (audioCodec.present) {
      map['audio_codec'] = Variable<String>(audioCodec.value);
    }
    if (flags.present) {
      map['flags'] = Variable<String>(flags.value);
    }
    if (releaseGroup.present) {
      map['release_group'] = Variable<String>(releaseGroup.value);
    }
    if (isSampleOrExtra.present) {
      map['is_sample_or_extra'] = Variable<bool>(isSampleOrExtra.value);
    }
    if (firstSeenAt.present) {
      map['first_seen_at'] = Variable<DateTime>(firstSeenAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (lastPlayedAt.present) {
      map['last_played_at'] = Variable<DateTime>(lastPlayedAt.value);
    }
    if (resumePositionMs.present) {
      map['resume_position_ms'] = Variable<int>(resumePositionMs.value);
    }
    if (thumbUrl.present) {
      map['thumb_url'] = Variable<String>(thumbUrl.value);
    }
    if (videoWidth.present) {
      map['video_width'] = Variable<int>(videoWidth.value);
    }
    if (videoHeight.present) {
      map['video_height'] = Variable<int>(videoHeight.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaItemsCompanion(')
          ..write('id: $id, ')
          ..write('provider: $provider, ')
          ..write('fileId: $fileId, ')
          ..write('name: $name, ')
          ..write('dirId: $dirId, ')
          ..write('dirPath: $dirPath, ')
          ..write('groupKey: $groupKey, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('year: $year, ')
          ..write('season: $season, ')
          ..write('episode: $episode, ')
          ..write('episodeEnd: $episodeEnd, ')
          ..write('container: $container, ')
          ..write('resolution: $resolution, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('source: $source, ')
          ..write('videoCodec: $videoCodec, ')
          ..write('audioCodec: $audioCodec, ')
          ..write('flags: $flags, ')
          ..write('releaseGroup: $releaseGroup, ')
          ..write('isSampleOrExtra: $isSampleOrExtra, ')
          ..write('firstSeenAt: $firstSeenAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('resumePositionMs: $resumePositionMs, ')
          ..write('thumbUrl: $thumbUrl, ')
          ..write('videoWidth: $videoWidth, ')
          ..write('videoHeight: $videoHeight, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MediaWorksTable extends MediaWorks
    with TableInfo<$MediaWorksTable, MediaWorkRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaWorksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _providerMeta = const VerificationMeta(
    'provider',
  );
  @override
  late final GeneratedColumn<String> provider = GeneratedColumn<String>(
    'provider',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originalTitleMeta = const VerificationMeta(
    'originalTitle',
  );
  @override
  late final GeneratedColumn<String> originalTitle = GeneratedColumn<String>(
    'original_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _overviewMeta = const VerificationMeta(
    'overview',
  );
  @override
  late final GeneratedColumn<String> overview = GeneratedColumn<String>(
    'overview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _posterUrlMeta = const VerificationMeta(
    'posterUrl',
  );
  @override
  late final GeneratedColumn<String> posterUrl = GeneratedColumn<String>(
    'poster_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _posterFileMeta = const VerificationMeta(
    'posterFile',
  );
  @override
  late final GeneratedColumn<String> posterFile = GeneratedColumn<String>(
    'poster_file',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _posterFaceXMeta = const VerificationMeta(
    'posterFaceX',
  );
  @override
  late final GeneratedColumn<double> posterFaceX = GeneratedColumn<double>(
    'poster_face_x',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _backdropUrlMeta = const VerificationMeta(
    'backdropUrl',
  );
  @override
  late final GeneratedColumn<String> backdropUrl = GeneratedColumn<String>(
    'backdrop_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _backdropFileMeta = const VerificationMeta(
    'backdropFile',
  );
  @override
  late final GeneratedColumn<String> backdropFile = GeneratedColumn<String>(
    'backdrop_file',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ratingMeta = const VerificationMeta('rating');
  @override
  late final GeneratedColumn<double> rating = GeneratedColumn<double>(
    'rating',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _genresMeta = const VerificationMeta('genres');
  @override
  late final GeneratedColumn<String> genres = GeneratedColumn<String>(
    'genres',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _onlineIdMeta = const VerificationMeta(
    'onlineId',
  );
  @override
  late final GeneratedColumn<String> onlineId = GeneratedColumn<String>(
    'online_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scrapedAtMeta = const VerificationMeta(
    'scrapedAt',
  );
  @override
  late final GeneratedColumn<DateTime> scrapedAt = GeneratedColumn<DateTime>(
    'scraped_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _itemCountMeta = const VerificationMeta(
    'itemCount',
  );
  @override
  late final GeneratedColumn<int> itemCount = GeneratedColumn<int>(
    'item_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalBytesMeta = const VerificationMeta(
    'totalBytes',
  );
  @override
  late final GeneratedColumn<int> totalBytes = GeneratedColumn<int>(
    'total_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastModifiedAtMeta = const VerificationMeta(
    'lastModifiedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastModifiedAt =
      GeneratedColumn<DateTime>(
        'last_modified_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _lastPlayedAtMeta = const VerificationMeta(
    'lastPlayedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastPlayedAt = GeneratedColumn<DateTime>(
    'last_played_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    key,
    provider,
    kind,
    category,
    title,
    originalTitle,
    year,
    overview,
    posterUrl,
    posterFile,
    posterFaceX,
    backdropUrl,
    backdropFile,
    rating,
    genres,
    onlineId,
    source,
    scrapedAt,
    itemCount,
    totalBytes,
    lastModifiedAt,
    lastPlayedAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_works';
  @override
  VerificationContext validateIntegrity(
    Insertable<MediaWorkRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('provider')) {
      context.handle(
        _providerMeta,
        provider.isAcceptableOrUnknown(data['provider']!, _providerMeta),
      );
    } else if (isInserting) {
      context.missing(_providerMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('original_title')) {
      context.handle(
        _originalTitleMeta,
        originalTitle.isAcceptableOrUnknown(
          data['original_title']!,
          _originalTitleMeta,
        ),
      );
    }
    if (data.containsKey('year')) {
      context.handle(
        _yearMeta,
        year.isAcceptableOrUnknown(data['year']!, _yearMeta),
      );
    }
    if (data.containsKey('overview')) {
      context.handle(
        _overviewMeta,
        overview.isAcceptableOrUnknown(data['overview']!, _overviewMeta),
      );
    }
    if (data.containsKey('poster_url')) {
      context.handle(
        _posterUrlMeta,
        posterUrl.isAcceptableOrUnknown(data['poster_url']!, _posterUrlMeta),
      );
    }
    if (data.containsKey('poster_file')) {
      context.handle(
        _posterFileMeta,
        posterFile.isAcceptableOrUnknown(data['poster_file']!, _posterFileMeta),
      );
    }
    if (data.containsKey('poster_face_x')) {
      context.handle(
        _posterFaceXMeta,
        posterFaceX.isAcceptableOrUnknown(
          data['poster_face_x']!,
          _posterFaceXMeta,
        ),
      );
    }
    if (data.containsKey('backdrop_url')) {
      context.handle(
        _backdropUrlMeta,
        backdropUrl.isAcceptableOrUnknown(
          data['backdrop_url']!,
          _backdropUrlMeta,
        ),
      );
    }
    if (data.containsKey('backdrop_file')) {
      context.handle(
        _backdropFileMeta,
        backdropFile.isAcceptableOrUnknown(
          data['backdrop_file']!,
          _backdropFileMeta,
        ),
      );
    }
    if (data.containsKey('rating')) {
      context.handle(
        _ratingMeta,
        rating.isAcceptableOrUnknown(data['rating']!, _ratingMeta),
      );
    }
    if (data.containsKey('genres')) {
      context.handle(
        _genresMeta,
        genres.isAcceptableOrUnknown(data['genres']!, _genresMeta),
      );
    }
    if (data.containsKey('online_id')) {
      context.handle(
        _onlineIdMeta,
        onlineId.isAcceptableOrUnknown(data['online_id']!, _onlineIdMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('scraped_at')) {
      context.handle(
        _scrapedAtMeta,
        scrapedAt.isAcceptableOrUnknown(data['scraped_at']!, _scrapedAtMeta),
      );
    }
    if (data.containsKey('item_count')) {
      context.handle(
        _itemCountMeta,
        itemCount.isAcceptableOrUnknown(data['item_count']!, _itemCountMeta),
      );
    }
    if (data.containsKey('total_bytes')) {
      context.handle(
        _totalBytesMeta,
        totalBytes.isAcceptableOrUnknown(data['total_bytes']!, _totalBytesMeta),
      );
    }
    if (data.containsKey('last_modified_at')) {
      context.handle(
        _lastModifiedAtMeta,
        lastModifiedAt.isAcceptableOrUnknown(
          data['last_modified_at']!,
          _lastModifiedAtMeta,
        ),
      );
    }
    if (data.containsKey('last_played_at')) {
      context.handle(
        _lastPlayedAtMeta,
        lastPlayedAt.isAcceptableOrUnknown(
          data['last_played_at']!,
          _lastPlayedAtMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  MediaWorkRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaWorkRow(
      key:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}key'],
          )!,
      provider:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}provider'],
          )!,
      kind:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}kind'],
          )!,
      category:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}category'],
          )!,
      title:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}title'],
          )!,
      originalTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}original_title'],
      ),
      year: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}year'],
      ),
      overview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}overview'],
      ),
      posterUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poster_url'],
      ),
      posterFile: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poster_file'],
      ),
      posterFaceX: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}poster_face_x'],
      ),
      backdropUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}backdrop_url'],
      ),
      backdropFile: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}backdrop_file'],
      ),
      rating: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}rating'],
      ),
      genres:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}genres'],
          )!,
      onlineId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}online_id'],
      ),
      source:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}source'],
          )!,
      scrapedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}scraped_at'],
      ),
      itemCount:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}item_count'],
          )!,
      totalBytes:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}total_bytes'],
          )!,
      lastModifiedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_modified_at'],
      ),
      lastPlayedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_played_at'],
      ),
      updatedAt:
          attachedDatabase.typeMapping.read(
            DriftSqlType.dateTime,
            data['${effectivePrefix}updated_at'],
          )!,
    );
  }

  @override
  $MediaWorksTable createAlias(String alias) {
    return $MediaWorksTable(attachedDatabase, alias);
  }
}

class MediaWorkRow extends DataClass implements Insertable<MediaWorkRow> {
  /// 主键：归组键
  final String key;
  final String provider;
  final String kind;

  /// 媒体库一级分类（`MediaCategory.name`）。
  ///
  /// 默认空串而不是 `other`：空串表示**这一行还没被判定过**，需要回填；
  /// 而 `other` 是一个**判定结果**（「判过了，就是认不出来」）。
  /// 两者混在一起的话，回填逻辑会反复把 `other` 当成待判定的行重算，
  /// 而真正的「其他」作品永远修不好（因为它本来就该是 other）。
  final String category;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? overview;
  final String? posterUrl;
  final String? posterFile;

  /// 封面里**人物所在的水平位置**（归一化 0~1），来自夸克的人脸框。
  ///
  /// 只有封面来自夸克的**视频帧**（16:9）时才有值：那时封面会被裁成竖版，
  /// 需要锚住人物，而不是裁到画面正中（双人对谈镜头的中点是两人之间的空隙）。
  /// 来自 TMDB 的海报本身就是 2:3，不需要锚点，此列为 `NULL`。
  ///
  /// 存**锚点**而不是「裁切偏移」：偏移量取决于卡片比例，换算放在渲染时
  /// （`FaceAnchor.alignmentX`），这样调整卡片比例不需要重新扫描。
  ///
  /// 与 `posterUrl` 是**成对**的 —— 换封面来源必须同时换锚点。
  final double? posterFaceX;
  final String? backdropUrl;
  final String? backdropFile;
  final double? rating;

  /// 类型列表，存 JSON 数组字符串。
  final String genres;
  final String? onlineId;

  /// 元数据来源（`ScrapeSource.name`）。
  ///
  /// 这一列是**刮削的幂等依据**：扫描器只对 `source != online` 的作品
  /// 重新走在线刮削，否则每次扫描都会把整库的 TMDB 配额重烧一遍。
  final String source;
  final DateTime? scrapedAt;

  /// 冗余计数，避免列表页为每个作品做一次 count 查询（N+1）。
  final int itemCount;
  final int totalBytes;

  /// 作品下所有文件的**网盘修改时间**最大值（`MediaItem.modifiedAt`）。
  ///
  /// 取最大值是因为一部剧有多集：新增一集时这个值会变大，
  /// 整个作品在「最近修改」排序里就会浮到前面。
  final DateTime? lastModifiedAt;
  final DateTime? lastPlayedAt;
  final DateTime updatedAt;
  const MediaWorkRow({
    required this.key,
    required this.provider,
    required this.kind,
    required this.category,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterUrl,
    this.posterFile,
    this.posterFaceX,
    this.backdropUrl,
    this.backdropFile,
    this.rating,
    required this.genres,
    this.onlineId,
    required this.source,
    this.scrapedAt,
    required this.itemCount,
    required this.totalBytes,
    this.lastModifiedAt,
    this.lastPlayedAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['provider'] = Variable<String>(provider);
    map['kind'] = Variable<String>(kind);
    map['category'] = Variable<String>(category);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || originalTitle != null) {
      map['original_title'] = Variable<String>(originalTitle);
    }
    if (!nullToAbsent || year != null) {
      map['year'] = Variable<int>(year);
    }
    if (!nullToAbsent || overview != null) {
      map['overview'] = Variable<String>(overview);
    }
    if (!nullToAbsent || posterUrl != null) {
      map['poster_url'] = Variable<String>(posterUrl);
    }
    if (!nullToAbsent || posterFile != null) {
      map['poster_file'] = Variable<String>(posterFile);
    }
    if (!nullToAbsent || posterFaceX != null) {
      map['poster_face_x'] = Variable<double>(posterFaceX);
    }
    if (!nullToAbsent || backdropUrl != null) {
      map['backdrop_url'] = Variable<String>(backdropUrl);
    }
    if (!nullToAbsent || backdropFile != null) {
      map['backdrop_file'] = Variable<String>(backdropFile);
    }
    if (!nullToAbsent || rating != null) {
      map['rating'] = Variable<double>(rating);
    }
    map['genres'] = Variable<String>(genres);
    if (!nullToAbsent || onlineId != null) {
      map['online_id'] = Variable<String>(onlineId);
    }
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || scrapedAt != null) {
      map['scraped_at'] = Variable<DateTime>(scrapedAt);
    }
    map['item_count'] = Variable<int>(itemCount);
    map['total_bytes'] = Variable<int>(totalBytes);
    if (!nullToAbsent || lastModifiedAt != null) {
      map['last_modified_at'] = Variable<DateTime>(lastModifiedAt);
    }
    if (!nullToAbsent || lastPlayedAt != null) {
      map['last_played_at'] = Variable<DateTime>(lastPlayedAt);
    }
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  MediaWorksCompanion toCompanion(bool nullToAbsent) {
    return MediaWorksCompanion(
      key: Value(key),
      provider: Value(provider),
      kind: Value(kind),
      category: Value(category),
      title: Value(title),
      originalTitle:
          originalTitle == null && nullToAbsent
              ? const Value.absent()
              : Value(originalTitle),
      year: year == null && nullToAbsent ? const Value.absent() : Value(year),
      overview:
          overview == null && nullToAbsent
              ? const Value.absent()
              : Value(overview),
      posterUrl:
          posterUrl == null && nullToAbsent
              ? const Value.absent()
              : Value(posterUrl),
      posterFile:
          posterFile == null && nullToAbsent
              ? const Value.absent()
              : Value(posterFile),
      posterFaceX:
          posterFaceX == null && nullToAbsent
              ? const Value.absent()
              : Value(posterFaceX),
      backdropUrl:
          backdropUrl == null && nullToAbsent
              ? const Value.absent()
              : Value(backdropUrl),
      backdropFile:
          backdropFile == null && nullToAbsent
              ? const Value.absent()
              : Value(backdropFile),
      rating:
          rating == null && nullToAbsent ? const Value.absent() : Value(rating),
      genres: Value(genres),
      onlineId:
          onlineId == null && nullToAbsent
              ? const Value.absent()
              : Value(onlineId),
      source: Value(source),
      scrapedAt:
          scrapedAt == null && nullToAbsent
              ? const Value.absent()
              : Value(scrapedAt),
      itemCount: Value(itemCount),
      totalBytes: Value(totalBytes),
      lastModifiedAt:
          lastModifiedAt == null && nullToAbsent
              ? const Value.absent()
              : Value(lastModifiedAt),
      lastPlayedAt:
          lastPlayedAt == null && nullToAbsent
              ? const Value.absent()
              : Value(lastPlayedAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory MediaWorkRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaWorkRow(
      key: serializer.fromJson<String>(json['key']),
      provider: serializer.fromJson<String>(json['provider']),
      kind: serializer.fromJson<String>(json['kind']),
      category: serializer.fromJson<String>(json['category']),
      title: serializer.fromJson<String>(json['title']),
      originalTitle: serializer.fromJson<String?>(json['originalTitle']),
      year: serializer.fromJson<int?>(json['year']),
      overview: serializer.fromJson<String?>(json['overview']),
      posterUrl: serializer.fromJson<String?>(json['posterUrl']),
      posterFile: serializer.fromJson<String?>(json['posterFile']),
      posterFaceX: serializer.fromJson<double?>(json['posterFaceX']),
      backdropUrl: serializer.fromJson<String?>(json['backdropUrl']),
      backdropFile: serializer.fromJson<String?>(json['backdropFile']),
      rating: serializer.fromJson<double?>(json['rating']),
      genres: serializer.fromJson<String>(json['genres']),
      onlineId: serializer.fromJson<String?>(json['onlineId']),
      source: serializer.fromJson<String>(json['source']),
      scrapedAt: serializer.fromJson<DateTime?>(json['scrapedAt']),
      itemCount: serializer.fromJson<int>(json['itemCount']),
      totalBytes: serializer.fromJson<int>(json['totalBytes']),
      lastModifiedAt: serializer.fromJson<DateTime?>(json['lastModifiedAt']),
      lastPlayedAt: serializer.fromJson<DateTime?>(json['lastPlayedAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'provider': serializer.toJson<String>(provider),
      'kind': serializer.toJson<String>(kind),
      'category': serializer.toJson<String>(category),
      'title': serializer.toJson<String>(title),
      'originalTitle': serializer.toJson<String?>(originalTitle),
      'year': serializer.toJson<int?>(year),
      'overview': serializer.toJson<String?>(overview),
      'posterUrl': serializer.toJson<String?>(posterUrl),
      'posterFile': serializer.toJson<String?>(posterFile),
      'posterFaceX': serializer.toJson<double?>(posterFaceX),
      'backdropUrl': serializer.toJson<String?>(backdropUrl),
      'backdropFile': serializer.toJson<String?>(backdropFile),
      'rating': serializer.toJson<double?>(rating),
      'genres': serializer.toJson<String>(genres),
      'onlineId': serializer.toJson<String?>(onlineId),
      'source': serializer.toJson<String>(source),
      'scrapedAt': serializer.toJson<DateTime?>(scrapedAt),
      'itemCount': serializer.toJson<int>(itemCount),
      'totalBytes': serializer.toJson<int>(totalBytes),
      'lastModifiedAt': serializer.toJson<DateTime?>(lastModifiedAt),
      'lastPlayedAt': serializer.toJson<DateTime?>(lastPlayedAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  MediaWorkRow copyWith({
    String? key,
    String? provider,
    String? kind,
    String? category,
    String? title,
    Value<String?> originalTitle = const Value.absent(),
    Value<int?> year = const Value.absent(),
    Value<String?> overview = const Value.absent(),
    Value<String?> posterUrl = const Value.absent(),
    Value<String?> posterFile = const Value.absent(),
    Value<double?> posterFaceX = const Value.absent(),
    Value<String?> backdropUrl = const Value.absent(),
    Value<String?> backdropFile = const Value.absent(),
    Value<double?> rating = const Value.absent(),
    String? genres,
    Value<String?> onlineId = const Value.absent(),
    String? source,
    Value<DateTime?> scrapedAt = const Value.absent(),
    int? itemCount,
    int? totalBytes,
    Value<DateTime?> lastModifiedAt = const Value.absent(),
    Value<DateTime?> lastPlayedAt = const Value.absent(),
    DateTime? updatedAt,
  }) => MediaWorkRow(
    key: key ?? this.key,
    provider: provider ?? this.provider,
    kind: kind ?? this.kind,
    category: category ?? this.category,
    title: title ?? this.title,
    originalTitle:
        originalTitle.present ? originalTitle.value : this.originalTitle,
    year: year.present ? year.value : this.year,
    overview: overview.present ? overview.value : this.overview,
    posterUrl: posterUrl.present ? posterUrl.value : this.posterUrl,
    posterFile: posterFile.present ? posterFile.value : this.posterFile,
    posterFaceX: posterFaceX.present ? posterFaceX.value : this.posterFaceX,
    backdropUrl: backdropUrl.present ? backdropUrl.value : this.backdropUrl,
    backdropFile: backdropFile.present ? backdropFile.value : this.backdropFile,
    rating: rating.present ? rating.value : this.rating,
    genres: genres ?? this.genres,
    onlineId: onlineId.present ? onlineId.value : this.onlineId,
    source: source ?? this.source,
    scrapedAt: scrapedAt.present ? scrapedAt.value : this.scrapedAt,
    itemCount: itemCount ?? this.itemCount,
    totalBytes: totalBytes ?? this.totalBytes,
    lastModifiedAt:
        lastModifiedAt.present ? lastModifiedAt.value : this.lastModifiedAt,
    lastPlayedAt: lastPlayedAt.present ? lastPlayedAt.value : this.lastPlayedAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  MediaWorkRow copyWithCompanion(MediaWorksCompanion data) {
    return MediaWorkRow(
      key: data.key.present ? data.key.value : this.key,
      provider: data.provider.present ? data.provider.value : this.provider,
      kind: data.kind.present ? data.kind.value : this.kind,
      category: data.category.present ? data.category.value : this.category,
      title: data.title.present ? data.title.value : this.title,
      originalTitle:
          data.originalTitle.present
              ? data.originalTitle.value
              : this.originalTitle,
      year: data.year.present ? data.year.value : this.year,
      overview: data.overview.present ? data.overview.value : this.overview,
      posterUrl: data.posterUrl.present ? data.posterUrl.value : this.posterUrl,
      posterFile:
          data.posterFile.present ? data.posterFile.value : this.posterFile,
      posterFaceX:
          data.posterFaceX.present ? data.posterFaceX.value : this.posterFaceX,
      backdropUrl:
          data.backdropUrl.present ? data.backdropUrl.value : this.backdropUrl,
      backdropFile:
          data.backdropFile.present
              ? data.backdropFile.value
              : this.backdropFile,
      rating: data.rating.present ? data.rating.value : this.rating,
      genres: data.genres.present ? data.genres.value : this.genres,
      onlineId: data.onlineId.present ? data.onlineId.value : this.onlineId,
      source: data.source.present ? data.source.value : this.source,
      scrapedAt: data.scrapedAt.present ? data.scrapedAt.value : this.scrapedAt,
      itemCount: data.itemCount.present ? data.itemCount.value : this.itemCount,
      totalBytes:
          data.totalBytes.present ? data.totalBytes.value : this.totalBytes,
      lastModifiedAt:
          data.lastModifiedAt.present
              ? data.lastModifiedAt.value
              : this.lastModifiedAt,
      lastPlayedAt:
          data.lastPlayedAt.present
              ? data.lastPlayedAt.value
              : this.lastPlayedAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaWorkRow(')
          ..write('key: $key, ')
          ..write('provider: $provider, ')
          ..write('kind: $kind, ')
          ..write('category: $category, ')
          ..write('title: $title, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('year: $year, ')
          ..write('overview: $overview, ')
          ..write('posterUrl: $posterUrl, ')
          ..write('posterFile: $posterFile, ')
          ..write('posterFaceX: $posterFaceX, ')
          ..write('backdropUrl: $backdropUrl, ')
          ..write('backdropFile: $backdropFile, ')
          ..write('rating: $rating, ')
          ..write('genres: $genres, ')
          ..write('onlineId: $onlineId, ')
          ..write('source: $source, ')
          ..write('scrapedAt: $scrapedAt, ')
          ..write('itemCount: $itemCount, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('lastModifiedAt: $lastModifiedAt, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    key,
    provider,
    kind,
    category,
    title,
    originalTitle,
    year,
    overview,
    posterUrl,
    posterFile,
    posterFaceX,
    backdropUrl,
    backdropFile,
    rating,
    genres,
    onlineId,
    source,
    scrapedAt,
    itemCount,
    totalBytes,
    lastModifiedAt,
    lastPlayedAt,
    updatedAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaWorkRow &&
          other.key == this.key &&
          other.provider == this.provider &&
          other.kind == this.kind &&
          other.category == this.category &&
          other.title == this.title &&
          other.originalTitle == this.originalTitle &&
          other.year == this.year &&
          other.overview == this.overview &&
          other.posterUrl == this.posterUrl &&
          other.posterFile == this.posterFile &&
          other.posterFaceX == this.posterFaceX &&
          other.backdropUrl == this.backdropUrl &&
          other.backdropFile == this.backdropFile &&
          other.rating == this.rating &&
          other.genres == this.genres &&
          other.onlineId == this.onlineId &&
          other.source == this.source &&
          other.scrapedAt == this.scrapedAt &&
          other.itemCount == this.itemCount &&
          other.totalBytes == this.totalBytes &&
          other.lastModifiedAt == this.lastModifiedAt &&
          other.lastPlayedAt == this.lastPlayedAt &&
          other.updatedAt == this.updatedAt);
}

class MediaWorksCompanion extends UpdateCompanion<MediaWorkRow> {
  final Value<String> key;
  final Value<String> provider;
  final Value<String> kind;
  final Value<String> category;
  final Value<String> title;
  final Value<String?> originalTitle;
  final Value<int?> year;
  final Value<String?> overview;
  final Value<String?> posterUrl;
  final Value<String?> posterFile;
  final Value<double?> posterFaceX;
  final Value<String?> backdropUrl;
  final Value<String?> backdropFile;
  final Value<double?> rating;
  final Value<String> genres;
  final Value<String?> onlineId;
  final Value<String> source;
  final Value<DateTime?> scrapedAt;
  final Value<int> itemCount;
  final Value<int> totalBytes;
  final Value<DateTime?> lastModifiedAt;
  final Value<DateTime?> lastPlayedAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const MediaWorksCompanion({
    this.key = const Value.absent(),
    this.provider = const Value.absent(),
    this.kind = const Value.absent(),
    this.category = const Value.absent(),
    this.title = const Value.absent(),
    this.originalTitle = const Value.absent(),
    this.year = const Value.absent(),
    this.overview = const Value.absent(),
    this.posterUrl = const Value.absent(),
    this.posterFile = const Value.absent(),
    this.posterFaceX = const Value.absent(),
    this.backdropUrl = const Value.absent(),
    this.backdropFile = const Value.absent(),
    this.rating = const Value.absent(),
    this.genres = const Value.absent(),
    this.onlineId = const Value.absent(),
    this.source = const Value.absent(),
    this.scrapedAt = const Value.absent(),
    this.itemCount = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.lastModifiedAt = const Value.absent(),
    this.lastPlayedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaWorksCompanion.insert({
    required String key,
    required String provider,
    required String kind,
    this.category = const Value.absent(),
    required String title,
    this.originalTitle = const Value.absent(),
    this.year = const Value.absent(),
    this.overview = const Value.absent(),
    this.posterUrl = const Value.absent(),
    this.posterFile = const Value.absent(),
    this.posterFaceX = const Value.absent(),
    this.backdropUrl = const Value.absent(),
    this.backdropFile = const Value.absent(),
    this.rating = const Value.absent(),
    this.genres = const Value.absent(),
    this.onlineId = const Value.absent(),
    required String source,
    this.scrapedAt = const Value.absent(),
    this.itemCount = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.lastModifiedAt = const Value.absent(),
    this.lastPlayedAt = const Value.absent(),
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       provider = Value(provider),
       kind = Value(kind),
       title = Value(title),
       source = Value(source),
       updatedAt = Value(updatedAt);
  static Insertable<MediaWorkRow> custom({
    Expression<String>? key,
    Expression<String>? provider,
    Expression<String>? kind,
    Expression<String>? category,
    Expression<String>? title,
    Expression<String>? originalTitle,
    Expression<int>? year,
    Expression<String>? overview,
    Expression<String>? posterUrl,
    Expression<String>? posterFile,
    Expression<double>? posterFaceX,
    Expression<String>? backdropUrl,
    Expression<String>? backdropFile,
    Expression<double>? rating,
    Expression<String>? genres,
    Expression<String>? onlineId,
    Expression<String>? source,
    Expression<DateTime>? scrapedAt,
    Expression<int>? itemCount,
    Expression<int>? totalBytes,
    Expression<DateTime>? lastModifiedAt,
    Expression<DateTime>? lastPlayedAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (provider != null) 'provider': provider,
      if (kind != null) 'kind': kind,
      if (category != null) 'category': category,
      if (title != null) 'title': title,
      if (originalTitle != null) 'original_title': originalTitle,
      if (year != null) 'year': year,
      if (overview != null) 'overview': overview,
      if (posterUrl != null) 'poster_url': posterUrl,
      if (posterFile != null) 'poster_file': posterFile,
      if (posterFaceX != null) 'poster_face_x': posterFaceX,
      if (backdropUrl != null) 'backdrop_url': backdropUrl,
      if (backdropFile != null) 'backdrop_file': backdropFile,
      if (rating != null) 'rating': rating,
      if (genres != null) 'genres': genres,
      if (onlineId != null) 'online_id': onlineId,
      if (source != null) 'source': source,
      if (scrapedAt != null) 'scraped_at': scrapedAt,
      if (itemCount != null) 'item_count': itemCount,
      if (totalBytes != null) 'total_bytes': totalBytes,
      if (lastModifiedAt != null) 'last_modified_at': lastModifiedAt,
      if (lastPlayedAt != null) 'last_played_at': lastPlayedAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaWorksCompanion copyWith({
    Value<String>? key,
    Value<String>? provider,
    Value<String>? kind,
    Value<String>? category,
    Value<String>? title,
    Value<String?>? originalTitle,
    Value<int?>? year,
    Value<String?>? overview,
    Value<String?>? posterUrl,
    Value<String?>? posterFile,
    Value<double?>? posterFaceX,
    Value<String?>? backdropUrl,
    Value<String?>? backdropFile,
    Value<double?>? rating,
    Value<String>? genres,
    Value<String?>? onlineId,
    Value<String>? source,
    Value<DateTime?>? scrapedAt,
    Value<int>? itemCount,
    Value<int>? totalBytes,
    Value<DateTime?>? lastModifiedAt,
    Value<DateTime?>? lastPlayedAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return MediaWorksCompanion(
      key: key ?? this.key,
      provider: provider ?? this.provider,
      kind: kind ?? this.kind,
      category: category ?? this.category,
      title: title ?? this.title,
      originalTitle: originalTitle ?? this.originalTitle,
      year: year ?? this.year,
      overview: overview ?? this.overview,
      posterUrl: posterUrl ?? this.posterUrl,
      posterFile: posterFile ?? this.posterFile,
      posterFaceX: posterFaceX ?? this.posterFaceX,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      backdropFile: backdropFile ?? this.backdropFile,
      rating: rating ?? this.rating,
      genres: genres ?? this.genres,
      onlineId: onlineId ?? this.onlineId,
      source: source ?? this.source,
      scrapedAt: scrapedAt ?? this.scrapedAt,
      itemCount: itemCount ?? this.itemCount,
      totalBytes: totalBytes ?? this.totalBytes,
      lastModifiedAt: lastModifiedAt ?? this.lastModifiedAt,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (provider.present) {
      map['provider'] = Variable<String>(provider.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (originalTitle.present) {
      map['original_title'] = Variable<String>(originalTitle.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (overview.present) {
      map['overview'] = Variable<String>(overview.value);
    }
    if (posterUrl.present) {
      map['poster_url'] = Variable<String>(posterUrl.value);
    }
    if (posterFile.present) {
      map['poster_file'] = Variable<String>(posterFile.value);
    }
    if (posterFaceX.present) {
      map['poster_face_x'] = Variable<double>(posterFaceX.value);
    }
    if (backdropUrl.present) {
      map['backdrop_url'] = Variable<String>(backdropUrl.value);
    }
    if (backdropFile.present) {
      map['backdrop_file'] = Variable<String>(backdropFile.value);
    }
    if (rating.present) {
      map['rating'] = Variable<double>(rating.value);
    }
    if (genres.present) {
      map['genres'] = Variable<String>(genres.value);
    }
    if (onlineId.present) {
      map['online_id'] = Variable<String>(onlineId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (scrapedAt.present) {
      map['scraped_at'] = Variable<DateTime>(scrapedAt.value);
    }
    if (itemCount.present) {
      map['item_count'] = Variable<int>(itemCount.value);
    }
    if (totalBytes.present) {
      map['total_bytes'] = Variable<int>(totalBytes.value);
    }
    if (lastModifiedAt.present) {
      map['last_modified_at'] = Variable<DateTime>(lastModifiedAt.value);
    }
    if (lastPlayedAt.present) {
      map['last_played_at'] = Variable<DateTime>(lastPlayedAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaWorksCompanion(')
          ..write('key: $key, ')
          ..write('provider: $provider, ')
          ..write('kind: $kind, ')
          ..write('category: $category, ')
          ..write('title: $title, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('year: $year, ')
          ..write('overview: $overview, ')
          ..write('posterUrl: $posterUrl, ')
          ..write('posterFile: $posterFile, ')
          ..write('posterFaceX: $posterFaceX, ')
          ..write('backdropUrl: $backdropUrl, ')
          ..write('backdropFile: $backdropFile, ')
          ..write('rating: $rating, ')
          ..write('genres: $genres, ')
          ..write('onlineId: $onlineId, ')
          ..write('source: $source, ')
          ..write('scrapedAt: $scrapedAt, ')
          ..write('itemCount: $itemCount, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('lastModifiedAt: $lastModifiedAt, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SubtitleRefsTable extends SubtitleRefs
    with TableInfo<$SubtitleRefsTable, SubtitleRefRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SubtitleRefsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _itemIdMeta = const VerificationMeta('itemId');
  @override
  late final GeneratedColumn<String> itemId = GeneratedColumn<String>(
    'item_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originMeta = const VerificationMeta('origin');
  @override
  late final GeneratedColumn<String> origin = GeneratedColumn<String>(
    'origin',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
    'label',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
    'format',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _languageCodeMeta = const VerificationMeta(
    'languageCode',
  );
  @override
  late final GeneratedColumn<String> languageCode = GeneratedColumn<String>(
    'language_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _languageLabelMeta = const VerificationMeta(
    'languageLabel',
  );
  @override
  late final GeneratedColumn<String> languageLabel = GeneratedColumn<String>(
    'language_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fileIdMeta = const VerificationMeta('fileId');
  @override
  late final GeneratedColumn<String> fileId = GeneratedColumn<String>(
    'file_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _embeddedTrackIdMeta = const VerificationMeta(
    'embeddedTrackId',
  );
  @override
  late final GeneratedColumn<int> embeddedTrackId = GeneratedColumn<int>(
    'embedded_track_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isForcedMeta = const VerificationMeta(
    'isForced',
  );
  @override
  late final GeneratedColumn<bool> isForced = GeneratedColumn<bool>(
    'is_forced',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_forced" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isSdhMeta = const VerificationMeta('isSdh');
  @override
  late final GeneratedColumn<bool> isSdh = GeneratedColumn<bool>(
    'is_sdh',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_sdh" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isDefaultMeta = const VerificationMeta(
    'isDefault',
  );
  @override
  late final GeneratedColumn<bool> isDefault = GeneratedColumn<bool>(
    'is_default',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_default" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    itemId,
    origin,
    label,
    format,
    languageCode,
    languageLabel,
    fileId,
    fileName,
    localPath,
    embeddedTrackId,
    isForced,
    isSdh,
    isDefault,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'subtitle_refs';
  @override
  VerificationContext validateIntegrity(
    Insertable<SubtitleRefRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('item_id')) {
      context.handle(
        _itemIdMeta,
        itemId.isAcceptableOrUnknown(data['item_id']!, _itemIdMeta),
      );
    } else if (isInserting) {
      context.missing(_itemIdMeta);
    }
    if (data.containsKey('origin')) {
      context.handle(
        _originMeta,
        origin.isAcceptableOrUnknown(data['origin']!, _originMeta),
      );
    } else if (isInserting) {
      context.missing(_originMeta);
    }
    if (data.containsKey('label')) {
      context.handle(
        _labelMeta,
        label.isAcceptableOrUnknown(data['label']!, _labelMeta),
      );
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    } else if (isInserting) {
      context.missing(_formatMeta);
    }
    if (data.containsKey('language_code')) {
      context.handle(
        _languageCodeMeta,
        languageCode.isAcceptableOrUnknown(
          data['language_code']!,
          _languageCodeMeta,
        ),
      );
    }
    if (data.containsKey('language_label')) {
      context.handle(
        _languageLabelMeta,
        languageLabel.isAcceptableOrUnknown(
          data['language_label']!,
          _languageLabelMeta,
        ),
      );
    }
    if (data.containsKey('file_id')) {
      context.handle(
        _fileIdMeta,
        fileId.isAcceptableOrUnknown(data['file_id']!, _fileIdMeta),
      );
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    }
    if (data.containsKey('embedded_track_id')) {
      context.handle(
        _embeddedTrackIdMeta,
        embeddedTrackId.isAcceptableOrUnknown(
          data['embedded_track_id']!,
          _embeddedTrackIdMeta,
        ),
      );
    }
    if (data.containsKey('is_forced')) {
      context.handle(
        _isForcedMeta,
        isForced.isAcceptableOrUnknown(data['is_forced']!, _isForcedMeta),
      );
    }
    if (data.containsKey('is_sdh')) {
      context.handle(
        _isSdhMeta,
        isSdh.isAcceptableOrUnknown(data['is_sdh']!, _isSdhMeta),
      );
    }
    if (data.containsKey('is_default')) {
      context.handle(
        _isDefaultMeta,
        isDefault.isAcceptableOrUnknown(data['is_default']!, _isDefaultMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SubtitleRefRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SubtitleRefRow(
      id:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}id'],
          )!,
      itemId:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}item_id'],
          )!,
      origin:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}origin'],
          )!,
      label:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}label'],
          )!,
      format:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}format'],
          )!,
      languageCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}language_code'],
      ),
      languageLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}language_label'],
      ),
      fileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_id'],
      ),
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      ),
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      ),
      embeddedTrackId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}embedded_track_id'],
      ),
      isForced:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}is_forced'],
          )!,
      isSdh:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}is_sdh'],
          )!,
      isDefault:
          attachedDatabase.typeMapping.read(
            DriftSqlType.bool,
            data['${effectivePrefix}is_default'],
          )!,
    );
  }

  @override
  $SubtitleRefsTable createAlias(String alias) {
    return $SubtitleRefsTable(attachedDatabase, alias);
  }
}

class SubtitleRefRow extends DataClass implements Insertable<SubtitleRefRow> {
  /// 主键：`itemId#fileId`（见 `SubtitleTrack.id`）
  final String id;

  /// 所属媒体项 id
  final String itemId;

  /// 来源（`SubtitleOrigin.name`）
  final String origin;
  final String label;
  final String format;
  final String? languageCode;
  final String? languageLabel;
  final String? fileId;
  final String? fileName;
  final String? localPath;
  final int? embeddedTrackId;
  final bool isForced;
  final bool isSdh;
  final bool isDefault;
  const SubtitleRefRow({
    required this.id,
    required this.itemId,
    required this.origin,
    required this.label,
    required this.format,
    this.languageCode,
    this.languageLabel,
    this.fileId,
    this.fileName,
    this.localPath,
    this.embeddedTrackId,
    required this.isForced,
    required this.isSdh,
    required this.isDefault,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['item_id'] = Variable<String>(itemId);
    map['origin'] = Variable<String>(origin);
    map['label'] = Variable<String>(label);
    map['format'] = Variable<String>(format);
    if (!nullToAbsent || languageCode != null) {
      map['language_code'] = Variable<String>(languageCode);
    }
    if (!nullToAbsent || languageLabel != null) {
      map['language_label'] = Variable<String>(languageLabel);
    }
    if (!nullToAbsent || fileId != null) {
      map['file_id'] = Variable<String>(fileId);
    }
    if (!nullToAbsent || fileName != null) {
      map['file_name'] = Variable<String>(fileName);
    }
    if (!nullToAbsent || localPath != null) {
      map['local_path'] = Variable<String>(localPath);
    }
    if (!nullToAbsent || embeddedTrackId != null) {
      map['embedded_track_id'] = Variable<int>(embeddedTrackId);
    }
    map['is_forced'] = Variable<bool>(isForced);
    map['is_sdh'] = Variable<bool>(isSdh);
    map['is_default'] = Variable<bool>(isDefault);
    return map;
  }

  SubtitleRefsCompanion toCompanion(bool nullToAbsent) {
    return SubtitleRefsCompanion(
      id: Value(id),
      itemId: Value(itemId),
      origin: Value(origin),
      label: Value(label),
      format: Value(format),
      languageCode:
          languageCode == null && nullToAbsent
              ? const Value.absent()
              : Value(languageCode),
      languageLabel:
          languageLabel == null && nullToAbsent
              ? const Value.absent()
              : Value(languageLabel),
      fileId:
          fileId == null && nullToAbsent ? const Value.absent() : Value(fileId),
      fileName:
          fileName == null && nullToAbsent
              ? const Value.absent()
              : Value(fileName),
      localPath:
          localPath == null && nullToAbsent
              ? const Value.absent()
              : Value(localPath),
      embeddedTrackId:
          embeddedTrackId == null && nullToAbsent
              ? const Value.absent()
              : Value(embeddedTrackId),
      isForced: Value(isForced),
      isSdh: Value(isSdh),
      isDefault: Value(isDefault),
    );
  }

  factory SubtitleRefRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SubtitleRefRow(
      id: serializer.fromJson<String>(json['id']),
      itemId: serializer.fromJson<String>(json['itemId']),
      origin: serializer.fromJson<String>(json['origin']),
      label: serializer.fromJson<String>(json['label']),
      format: serializer.fromJson<String>(json['format']),
      languageCode: serializer.fromJson<String?>(json['languageCode']),
      languageLabel: serializer.fromJson<String?>(json['languageLabel']),
      fileId: serializer.fromJson<String?>(json['fileId']),
      fileName: serializer.fromJson<String?>(json['fileName']),
      localPath: serializer.fromJson<String?>(json['localPath']),
      embeddedTrackId: serializer.fromJson<int?>(json['embeddedTrackId']),
      isForced: serializer.fromJson<bool>(json['isForced']),
      isSdh: serializer.fromJson<bool>(json['isSdh']),
      isDefault: serializer.fromJson<bool>(json['isDefault']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'itemId': serializer.toJson<String>(itemId),
      'origin': serializer.toJson<String>(origin),
      'label': serializer.toJson<String>(label),
      'format': serializer.toJson<String>(format),
      'languageCode': serializer.toJson<String?>(languageCode),
      'languageLabel': serializer.toJson<String?>(languageLabel),
      'fileId': serializer.toJson<String?>(fileId),
      'fileName': serializer.toJson<String?>(fileName),
      'localPath': serializer.toJson<String?>(localPath),
      'embeddedTrackId': serializer.toJson<int?>(embeddedTrackId),
      'isForced': serializer.toJson<bool>(isForced),
      'isSdh': serializer.toJson<bool>(isSdh),
      'isDefault': serializer.toJson<bool>(isDefault),
    };
  }

  SubtitleRefRow copyWith({
    String? id,
    String? itemId,
    String? origin,
    String? label,
    String? format,
    Value<String?> languageCode = const Value.absent(),
    Value<String?> languageLabel = const Value.absent(),
    Value<String?> fileId = const Value.absent(),
    Value<String?> fileName = const Value.absent(),
    Value<String?> localPath = const Value.absent(),
    Value<int?> embeddedTrackId = const Value.absent(),
    bool? isForced,
    bool? isSdh,
    bool? isDefault,
  }) => SubtitleRefRow(
    id: id ?? this.id,
    itemId: itemId ?? this.itemId,
    origin: origin ?? this.origin,
    label: label ?? this.label,
    format: format ?? this.format,
    languageCode: languageCode.present ? languageCode.value : this.languageCode,
    languageLabel:
        languageLabel.present ? languageLabel.value : this.languageLabel,
    fileId: fileId.present ? fileId.value : this.fileId,
    fileName: fileName.present ? fileName.value : this.fileName,
    localPath: localPath.present ? localPath.value : this.localPath,
    embeddedTrackId:
        embeddedTrackId.present ? embeddedTrackId.value : this.embeddedTrackId,
    isForced: isForced ?? this.isForced,
    isSdh: isSdh ?? this.isSdh,
    isDefault: isDefault ?? this.isDefault,
  );
  SubtitleRefRow copyWithCompanion(SubtitleRefsCompanion data) {
    return SubtitleRefRow(
      id: data.id.present ? data.id.value : this.id,
      itemId: data.itemId.present ? data.itemId.value : this.itemId,
      origin: data.origin.present ? data.origin.value : this.origin,
      label: data.label.present ? data.label.value : this.label,
      format: data.format.present ? data.format.value : this.format,
      languageCode:
          data.languageCode.present
              ? data.languageCode.value
              : this.languageCode,
      languageLabel:
          data.languageLabel.present
              ? data.languageLabel.value
              : this.languageLabel,
      fileId: data.fileId.present ? data.fileId.value : this.fileId,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      embeddedTrackId:
          data.embeddedTrackId.present
              ? data.embeddedTrackId.value
              : this.embeddedTrackId,
      isForced: data.isForced.present ? data.isForced.value : this.isForced,
      isSdh: data.isSdh.present ? data.isSdh.value : this.isSdh,
      isDefault: data.isDefault.present ? data.isDefault.value : this.isDefault,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SubtitleRefRow(')
          ..write('id: $id, ')
          ..write('itemId: $itemId, ')
          ..write('origin: $origin, ')
          ..write('label: $label, ')
          ..write('format: $format, ')
          ..write('languageCode: $languageCode, ')
          ..write('languageLabel: $languageLabel, ')
          ..write('fileId: $fileId, ')
          ..write('fileName: $fileName, ')
          ..write('localPath: $localPath, ')
          ..write('embeddedTrackId: $embeddedTrackId, ')
          ..write('isForced: $isForced, ')
          ..write('isSdh: $isSdh, ')
          ..write('isDefault: $isDefault')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    itemId,
    origin,
    label,
    format,
    languageCode,
    languageLabel,
    fileId,
    fileName,
    localPath,
    embeddedTrackId,
    isForced,
    isSdh,
    isDefault,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubtitleRefRow &&
          other.id == this.id &&
          other.itemId == this.itemId &&
          other.origin == this.origin &&
          other.label == this.label &&
          other.format == this.format &&
          other.languageCode == this.languageCode &&
          other.languageLabel == this.languageLabel &&
          other.fileId == this.fileId &&
          other.fileName == this.fileName &&
          other.localPath == this.localPath &&
          other.embeddedTrackId == this.embeddedTrackId &&
          other.isForced == this.isForced &&
          other.isSdh == this.isSdh &&
          other.isDefault == this.isDefault);
}

class SubtitleRefsCompanion extends UpdateCompanion<SubtitleRefRow> {
  final Value<String> id;
  final Value<String> itemId;
  final Value<String> origin;
  final Value<String> label;
  final Value<String> format;
  final Value<String?> languageCode;
  final Value<String?> languageLabel;
  final Value<String?> fileId;
  final Value<String?> fileName;
  final Value<String?> localPath;
  final Value<int?> embeddedTrackId;
  final Value<bool> isForced;
  final Value<bool> isSdh;
  final Value<bool> isDefault;
  final Value<int> rowid;
  const SubtitleRefsCompanion({
    this.id = const Value.absent(),
    this.itemId = const Value.absent(),
    this.origin = const Value.absent(),
    this.label = const Value.absent(),
    this.format = const Value.absent(),
    this.languageCode = const Value.absent(),
    this.languageLabel = const Value.absent(),
    this.fileId = const Value.absent(),
    this.fileName = const Value.absent(),
    this.localPath = const Value.absent(),
    this.embeddedTrackId = const Value.absent(),
    this.isForced = const Value.absent(),
    this.isSdh = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SubtitleRefsCompanion.insert({
    required String id,
    required String itemId,
    required String origin,
    required String label,
    required String format,
    this.languageCode = const Value.absent(),
    this.languageLabel = const Value.absent(),
    this.fileId = const Value.absent(),
    this.fileName = const Value.absent(),
    this.localPath = const Value.absent(),
    this.embeddedTrackId = const Value.absent(),
    this.isForced = const Value.absent(),
    this.isSdh = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       itemId = Value(itemId),
       origin = Value(origin),
       label = Value(label),
       format = Value(format);
  static Insertable<SubtitleRefRow> custom({
    Expression<String>? id,
    Expression<String>? itemId,
    Expression<String>? origin,
    Expression<String>? label,
    Expression<String>? format,
    Expression<String>? languageCode,
    Expression<String>? languageLabel,
    Expression<String>? fileId,
    Expression<String>? fileName,
    Expression<String>? localPath,
    Expression<int>? embeddedTrackId,
    Expression<bool>? isForced,
    Expression<bool>? isSdh,
    Expression<bool>? isDefault,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (itemId != null) 'item_id': itemId,
      if (origin != null) 'origin': origin,
      if (label != null) 'label': label,
      if (format != null) 'format': format,
      if (languageCode != null) 'language_code': languageCode,
      if (languageLabel != null) 'language_label': languageLabel,
      if (fileId != null) 'file_id': fileId,
      if (fileName != null) 'file_name': fileName,
      if (localPath != null) 'local_path': localPath,
      if (embeddedTrackId != null) 'embedded_track_id': embeddedTrackId,
      if (isForced != null) 'is_forced': isForced,
      if (isSdh != null) 'is_sdh': isSdh,
      if (isDefault != null) 'is_default': isDefault,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SubtitleRefsCompanion copyWith({
    Value<String>? id,
    Value<String>? itemId,
    Value<String>? origin,
    Value<String>? label,
    Value<String>? format,
    Value<String?>? languageCode,
    Value<String?>? languageLabel,
    Value<String?>? fileId,
    Value<String?>? fileName,
    Value<String?>? localPath,
    Value<int?>? embeddedTrackId,
    Value<bool>? isForced,
    Value<bool>? isSdh,
    Value<bool>? isDefault,
    Value<int>? rowid,
  }) {
    return SubtitleRefsCompanion(
      id: id ?? this.id,
      itemId: itemId ?? this.itemId,
      origin: origin ?? this.origin,
      label: label ?? this.label,
      format: format ?? this.format,
      languageCode: languageCode ?? this.languageCode,
      languageLabel: languageLabel ?? this.languageLabel,
      fileId: fileId ?? this.fileId,
      fileName: fileName ?? this.fileName,
      localPath: localPath ?? this.localPath,
      embeddedTrackId: embeddedTrackId ?? this.embeddedTrackId,
      isForced: isForced ?? this.isForced,
      isSdh: isSdh ?? this.isSdh,
      isDefault: isDefault ?? this.isDefault,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (itemId.present) {
      map['item_id'] = Variable<String>(itemId.value);
    }
    if (origin.present) {
      map['origin'] = Variable<String>(origin.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (languageCode.present) {
      map['language_code'] = Variable<String>(languageCode.value);
    }
    if (languageLabel.present) {
      map['language_label'] = Variable<String>(languageLabel.value);
    }
    if (fileId.present) {
      map['file_id'] = Variable<String>(fileId.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (embeddedTrackId.present) {
      map['embedded_track_id'] = Variable<int>(embeddedTrackId.value);
    }
    if (isForced.present) {
      map['is_forced'] = Variable<bool>(isForced.value);
    }
    if (isSdh.present) {
      map['is_sdh'] = Variable<bool>(isSdh.value);
    }
    if (isDefault.present) {
      map['is_default'] = Variable<bool>(isDefault.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SubtitleRefsCompanion(')
          ..write('id: $id, ')
          ..write('itemId: $itemId, ')
          ..write('origin: $origin, ')
          ..write('label: $label, ')
          ..write('format: $format, ')
          ..write('languageCode: $languageCode, ')
          ..write('languageLabel: $languageLabel, ')
          ..write('fileId: $fileId, ')
          ..write('fileName: $fileName, ')
          ..write('localPath: $localPath, ')
          ..write('embeddedTrackId: $embeddedTrackId, ')
          ..write('isForced: $isForced, ')
          ..write('isSdh: $isSdh, ')
          ..write('isDefault: $isDefault, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScanCursorsTable extends ScanCursors
    with TableInfo<$ScanCursorsTable, ScanCursorRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScanCursorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _providerMeta = const VerificationMeta(
    'provider',
  );
  @override
  late final GeneratedColumn<String> provider = GeneratedColumn<String>(
    'provider',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rootIdMeta = const VerificationMeta('rootId');
  @override
  late final GeneratedColumn<String> rootId = GeneratedColumn<String>(
    'root_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rootPathMeta = const VerificationMeta(
    'rootPath',
  );
  @override
  late final GeneratedColumn<String> rootPath = GeneratedColumn<String>(
    'root_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('/'),
  );
  static const VerificationMeta _pendingDirsMeta = const VerificationMeta(
    'pendingDirs',
  );
  @override
  late final GeneratedColumn<String> pendingDirs = GeneratedColumn<String>(
    'pending_dirs',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _currentDirMeta = const VerificationMeta(
    'currentDir',
  );
  @override
  late final GeneratedColumn<String> currentDir = GeneratedColumn<String>(
    'current_dir',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _currentPageTokenMeta = const VerificationMeta(
    'currentPageToken',
  );
  @override
  late final GeneratedColumn<String> currentPageToken = GeneratedColumn<String>(
    'current_page_token',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stageMeta = const VerificationMeta('stage');
  @override
  late final GeneratedColumn<String> stage = GeneratedColumn<String>(
    'stage',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scannedDirsMeta = const VerificationMeta(
    'scannedDirs',
  );
  @override
  late final GeneratedColumn<int> scannedDirs = GeneratedColumn<int>(
    'scanned_dirs',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _scannedFilesMeta = const VerificationMeta(
    'scannedFiles',
  );
  @override
  late final GeneratedColumn<int> scannedFiles = GeneratedColumn<int>(
    'scanned_files',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _foundTracksMeta = const VerificationMeta(
    'foundTracks',
  );
  @override
  late final GeneratedColumn<int> foundTracks = GeneratedColumn<int>(
    'found_tracks',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalBytesMeta = const VerificationMeta(
    'totalBytes',
  );
  @override
  late final GeneratedColumn<int> totalBytes = GeneratedColumn<int>(
    'total_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _failedDirsMeta = const VerificationMeta(
    'failedDirs',
  );
  @override
  late final GeneratedColumn<int> failedDirs = GeneratedColumn<int>(
    'failed_dirs',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    provider,
    rootId,
    rootPath,
    pendingDirs,
    currentDir,
    currentPageToken,
    stage,
    scannedDirs,
    scannedFiles,
    foundTracks,
    totalBytes,
    failedDirs,
    lastError,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'scan_cursors';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScanCursorRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('provider')) {
      context.handle(
        _providerMeta,
        provider.isAcceptableOrUnknown(data['provider']!, _providerMeta),
      );
    } else if (isInserting) {
      context.missing(_providerMeta);
    }
    if (data.containsKey('root_id')) {
      context.handle(
        _rootIdMeta,
        rootId.isAcceptableOrUnknown(data['root_id']!, _rootIdMeta),
      );
    } else if (isInserting) {
      context.missing(_rootIdMeta);
    }
    if (data.containsKey('root_path')) {
      context.handle(
        _rootPathMeta,
        rootPath.isAcceptableOrUnknown(data['root_path']!, _rootPathMeta),
      );
    }
    if (data.containsKey('pending_dirs')) {
      context.handle(
        _pendingDirsMeta,
        pendingDirs.isAcceptableOrUnknown(
          data['pending_dirs']!,
          _pendingDirsMeta,
        ),
      );
    }
    if (data.containsKey('current_dir')) {
      context.handle(
        _currentDirMeta,
        currentDir.isAcceptableOrUnknown(data['current_dir']!, _currentDirMeta),
      );
    }
    if (data.containsKey('current_page_token')) {
      context.handle(
        _currentPageTokenMeta,
        currentPageToken.isAcceptableOrUnknown(
          data['current_page_token']!,
          _currentPageTokenMeta,
        ),
      );
    }
    if (data.containsKey('stage')) {
      context.handle(
        _stageMeta,
        stage.isAcceptableOrUnknown(data['stage']!, _stageMeta),
      );
    } else if (isInserting) {
      context.missing(_stageMeta);
    }
    if (data.containsKey('scanned_dirs')) {
      context.handle(
        _scannedDirsMeta,
        scannedDirs.isAcceptableOrUnknown(
          data['scanned_dirs']!,
          _scannedDirsMeta,
        ),
      );
    }
    if (data.containsKey('scanned_files')) {
      context.handle(
        _scannedFilesMeta,
        scannedFiles.isAcceptableOrUnknown(
          data['scanned_files']!,
          _scannedFilesMeta,
        ),
      );
    }
    if (data.containsKey('found_tracks')) {
      context.handle(
        _foundTracksMeta,
        foundTracks.isAcceptableOrUnknown(
          data['found_tracks']!,
          _foundTracksMeta,
        ),
      );
    }
    if (data.containsKey('total_bytes')) {
      context.handle(
        _totalBytesMeta,
        totalBytes.isAcceptableOrUnknown(data['total_bytes']!, _totalBytesMeta),
      );
    }
    if (data.containsKey('failed_dirs')) {
      context.handle(
        _failedDirsMeta,
        failedDirs.isAcceptableOrUnknown(data['failed_dirs']!, _failedDirsMeta),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {provider};
  @override
  ScanCursorRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScanCursorRow(
      provider:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}provider'],
          )!,
      rootId:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}root_id'],
          )!,
      rootPath:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}root_path'],
          )!,
      pendingDirs:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}pending_dirs'],
          )!,
      currentDir: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}current_dir'],
      ),
      currentPageToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}current_page_token'],
      ),
      stage:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}stage'],
          )!,
      scannedDirs:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}scanned_dirs'],
          )!,
      scannedFiles:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}scanned_files'],
          )!,
      foundTracks:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}found_tracks'],
          )!,
      totalBytes:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}total_bytes'],
          )!,
      failedDirs:
          attachedDatabase.typeMapping.read(
            DriftSqlType.int,
            data['${effectivePrefix}failed_dirs'],
          )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      updatedAt:
          attachedDatabase.typeMapping.read(
            DriftSqlType.dateTime,
            data['${effectivePrefix}updated_at'],
          )!,
    );
  }

  @override
  $ScanCursorsTable createAlias(String alias) {
    return $ScanCursorsTable(attachedDatabase, alias);
  }
}

class ScanCursorRow extends DataClass implements Insertable<ScanCursorRow> {
  final String provider;
  final String rootId;
  final String rootPath;

  /// BFS 待扫队列，JSON 数组字符串（见 `PendingDir.toJson`）。
  ///
  /// 存 JSON 而不是拆成关联表：它是一份**只在扫描期间有意义**的临时状态，
  /// 没有任何按字段查询的需求，而拆表会让「每页落盘」这个高频操作
  /// 变成多表写入。
  final String pendingDirs;

  /// 当前目录，JSON 对象字符串。`null` 表示不在目录中途。
  final String? currentDir;
  final String? currentPageToken;

  /// 阶段（`ScanStage.name`）
  final String stage;
  final int scannedDirs;
  final int scannedFiles;
  final int foundTracks;
  final int totalBytes;
  final int failedDirs;
  final String? lastError;
  final DateTime updatedAt;
  const ScanCursorRow({
    required this.provider,
    required this.rootId,
    required this.rootPath,
    required this.pendingDirs,
    this.currentDir,
    this.currentPageToken,
    required this.stage,
    required this.scannedDirs,
    required this.scannedFiles,
    required this.foundTracks,
    required this.totalBytes,
    required this.failedDirs,
    this.lastError,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['provider'] = Variable<String>(provider);
    map['root_id'] = Variable<String>(rootId);
    map['root_path'] = Variable<String>(rootPath);
    map['pending_dirs'] = Variable<String>(pendingDirs);
    if (!nullToAbsent || currentDir != null) {
      map['current_dir'] = Variable<String>(currentDir);
    }
    if (!nullToAbsent || currentPageToken != null) {
      map['current_page_token'] = Variable<String>(currentPageToken);
    }
    map['stage'] = Variable<String>(stage);
    map['scanned_dirs'] = Variable<int>(scannedDirs);
    map['scanned_files'] = Variable<int>(scannedFiles);
    map['found_tracks'] = Variable<int>(foundTracks);
    map['total_bytes'] = Variable<int>(totalBytes);
    map['failed_dirs'] = Variable<int>(failedDirs);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ScanCursorsCompanion toCompanion(bool nullToAbsent) {
    return ScanCursorsCompanion(
      provider: Value(provider),
      rootId: Value(rootId),
      rootPath: Value(rootPath),
      pendingDirs: Value(pendingDirs),
      currentDir:
          currentDir == null && nullToAbsent
              ? const Value.absent()
              : Value(currentDir),
      currentPageToken:
          currentPageToken == null && nullToAbsent
              ? const Value.absent()
              : Value(currentPageToken),
      stage: Value(stage),
      scannedDirs: Value(scannedDirs),
      scannedFiles: Value(scannedFiles),
      foundTracks: Value(foundTracks),
      totalBytes: Value(totalBytes),
      failedDirs: Value(failedDirs),
      lastError:
          lastError == null && nullToAbsent
              ? const Value.absent()
              : Value(lastError),
      updatedAt: Value(updatedAt),
    );
  }

  factory ScanCursorRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScanCursorRow(
      provider: serializer.fromJson<String>(json['provider']),
      rootId: serializer.fromJson<String>(json['rootId']),
      rootPath: serializer.fromJson<String>(json['rootPath']),
      pendingDirs: serializer.fromJson<String>(json['pendingDirs']),
      currentDir: serializer.fromJson<String?>(json['currentDir']),
      currentPageToken: serializer.fromJson<String?>(json['currentPageToken']),
      stage: serializer.fromJson<String>(json['stage']),
      scannedDirs: serializer.fromJson<int>(json['scannedDirs']),
      scannedFiles: serializer.fromJson<int>(json['scannedFiles']),
      foundTracks: serializer.fromJson<int>(json['foundTracks']),
      totalBytes: serializer.fromJson<int>(json['totalBytes']),
      failedDirs: serializer.fromJson<int>(json['failedDirs']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'provider': serializer.toJson<String>(provider),
      'rootId': serializer.toJson<String>(rootId),
      'rootPath': serializer.toJson<String>(rootPath),
      'pendingDirs': serializer.toJson<String>(pendingDirs),
      'currentDir': serializer.toJson<String?>(currentDir),
      'currentPageToken': serializer.toJson<String?>(currentPageToken),
      'stage': serializer.toJson<String>(stage),
      'scannedDirs': serializer.toJson<int>(scannedDirs),
      'scannedFiles': serializer.toJson<int>(scannedFiles),
      'foundTracks': serializer.toJson<int>(foundTracks),
      'totalBytes': serializer.toJson<int>(totalBytes),
      'failedDirs': serializer.toJson<int>(failedDirs),
      'lastError': serializer.toJson<String?>(lastError),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ScanCursorRow copyWith({
    String? provider,
    String? rootId,
    String? rootPath,
    String? pendingDirs,
    Value<String?> currentDir = const Value.absent(),
    Value<String?> currentPageToken = const Value.absent(),
    String? stage,
    int? scannedDirs,
    int? scannedFiles,
    int? foundTracks,
    int? totalBytes,
    int? failedDirs,
    Value<String?> lastError = const Value.absent(),
    DateTime? updatedAt,
  }) => ScanCursorRow(
    provider: provider ?? this.provider,
    rootId: rootId ?? this.rootId,
    rootPath: rootPath ?? this.rootPath,
    pendingDirs: pendingDirs ?? this.pendingDirs,
    currentDir: currentDir.present ? currentDir.value : this.currentDir,
    currentPageToken:
        currentPageToken.present
            ? currentPageToken.value
            : this.currentPageToken,
    stage: stage ?? this.stage,
    scannedDirs: scannedDirs ?? this.scannedDirs,
    scannedFiles: scannedFiles ?? this.scannedFiles,
    foundTracks: foundTracks ?? this.foundTracks,
    totalBytes: totalBytes ?? this.totalBytes,
    failedDirs: failedDirs ?? this.failedDirs,
    lastError: lastError.present ? lastError.value : this.lastError,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ScanCursorRow copyWithCompanion(ScanCursorsCompanion data) {
    return ScanCursorRow(
      provider: data.provider.present ? data.provider.value : this.provider,
      rootId: data.rootId.present ? data.rootId.value : this.rootId,
      rootPath: data.rootPath.present ? data.rootPath.value : this.rootPath,
      pendingDirs:
          data.pendingDirs.present ? data.pendingDirs.value : this.pendingDirs,
      currentDir:
          data.currentDir.present ? data.currentDir.value : this.currentDir,
      currentPageToken:
          data.currentPageToken.present
              ? data.currentPageToken.value
              : this.currentPageToken,
      stage: data.stage.present ? data.stage.value : this.stage,
      scannedDirs:
          data.scannedDirs.present ? data.scannedDirs.value : this.scannedDirs,
      scannedFiles:
          data.scannedFiles.present
              ? data.scannedFiles.value
              : this.scannedFiles,
      foundTracks:
          data.foundTracks.present ? data.foundTracks.value : this.foundTracks,
      totalBytes:
          data.totalBytes.present ? data.totalBytes.value : this.totalBytes,
      failedDirs:
          data.failedDirs.present ? data.failedDirs.value : this.failedDirs,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScanCursorRow(')
          ..write('provider: $provider, ')
          ..write('rootId: $rootId, ')
          ..write('rootPath: $rootPath, ')
          ..write('pendingDirs: $pendingDirs, ')
          ..write('currentDir: $currentDir, ')
          ..write('currentPageToken: $currentPageToken, ')
          ..write('stage: $stage, ')
          ..write('scannedDirs: $scannedDirs, ')
          ..write('scannedFiles: $scannedFiles, ')
          ..write('foundTracks: $foundTracks, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('failedDirs: $failedDirs, ')
          ..write('lastError: $lastError, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    provider,
    rootId,
    rootPath,
    pendingDirs,
    currentDir,
    currentPageToken,
    stage,
    scannedDirs,
    scannedFiles,
    foundTracks,
    totalBytes,
    failedDirs,
    lastError,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScanCursorRow &&
          other.provider == this.provider &&
          other.rootId == this.rootId &&
          other.rootPath == this.rootPath &&
          other.pendingDirs == this.pendingDirs &&
          other.currentDir == this.currentDir &&
          other.currentPageToken == this.currentPageToken &&
          other.stage == this.stage &&
          other.scannedDirs == this.scannedDirs &&
          other.scannedFiles == this.scannedFiles &&
          other.foundTracks == this.foundTracks &&
          other.totalBytes == this.totalBytes &&
          other.failedDirs == this.failedDirs &&
          other.lastError == this.lastError &&
          other.updatedAt == this.updatedAt);
}

class ScanCursorsCompanion extends UpdateCompanion<ScanCursorRow> {
  final Value<String> provider;
  final Value<String> rootId;
  final Value<String> rootPath;
  final Value<String> pendingDirs;
  final Value<String?> currentDir;
  final Value<String?> currentPageToken;
  final Value<String> stage;
  final Value<int> scannedDirs;
  final Value<int> scannedFiles;
  final Value<int> foundTracks;
  final Value<int> totalBytes;
  final Value<int> failedDirs;
  final Value<String?> lastError;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const ScanCursorsCompanion({
    this.provider = const Value.absent(),
    this.rootId = const Value.absent(),
    this.rootPath = const Value.absent(),
    this.pendingDirs = const Value.absent(),
    this.currentDir = const Value.absent(),
    this.currentPageToken = const Value.absent(),
    this.stage = const Value.absent(),
    this.scannedDirs = const Value.absent(),
    this.scannedFiles = const Value.absent(),
    this.foundTracks = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.failedDirs = const Value.absent(),
    this.lastError = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ScanCursorsCompanion.insert({
    required String provider,
    required String rootId,
    this.rootPath = const Value.absent(),
    this.pendingDirs = const Value.absent(),
    this.currentDir = const Value.absent(),
    this.currentPageToken = const Value.absent(),
    required String stage,
    this.scannedDirs = const Value.absent(),
    this.scannedFiles = const Value.absent(),
    this.foundTracks = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.failedDirs = const Value.absent(),
    this.lastError = const Value.absent(),
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : provider = Value(provider),
       rootId = Value(rootId),
       stage = Value(stage),
       updatedAt = Value(updatedAt);
  static Insertable<ScanCursorRow> custom({
    Expression<String>? provider,
    Expression<String>? rootId,
    Expression<String>? rootPath,
    Expression<String>? pendingDirs,
    Expression<String>? currentDir,
    Expression<String>? currentPageToken,
    Expression<String>? stage,
    Expression<int>? scannedDirs,
    Expression<int>? scannedFiles,
    Expression<int>? foundTracks,
    Expression<int>? totalBytes,
    Expression<int>? failedDirs,
    Expression<String>? lastError,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (provider != null) 'provider': provider,
      if (rootId != null) 'root_id': rootId,
      if (rootPath != null) 'root_path': rootPath,
      if (pendingDirs != null) 'pending_dirs': pendingDirs,
      if (currentDir != null) 'current_dir': currentDir,
      if (currentPageToken != null) 'current_page_token': currentPageToken,
      if (stage != null) 'stage': stage,
      if (scannedDirs != null) 'scanned_dirs': scannedDirs,
      if (scannedFiles != null) 'scanned_files': scannedFiles,
      if (foundTracks != null) 'found_tracks': foundTracks,
      if (totalBytes != null) 'total_bytes': totalBytes,
      if (failedDirs != null) 'failed_dirs': failedDirs,
      if (lastError != null) 'last_error': lastError,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ScanCursorsCompanion copyWith({
    Value<String>? provider,
    Value<String>? rootId,
    Value<String>? rootPath,
    Value<String>? pendingDirs,
    Value<String?>? currentDir,
    Value<String?>? currentPageToken,
    Value<String>? stage,
    Value<int>? scannedDirs,
    Value<int>? scannedFiles,
    Value<int>? foundTracks,
    Value<int>? totalBytes,
    Value<int>? failedDirs,
    Value<String?>? lastError,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return ScanCursorsCompanion(
      provider: provider ?? this.provider,
      rootId: rootId ?? this.rootId,
      rootPath: rootPath ?? this.rootPath,
      pendingDirs: pendingDirs ?? this.pendingDirs,
      currentDir: currentDir ?? this.currentDir,
      currentPageToken: currentPageToken ?? this.currentPageToken,
      stage: stage ?? this.stage,
      scannedDirs: scannedDirs ?? this.scannedDirs,
      scannedFiles: scannedFiles ?? this.scannedFiles,
      foundTracks: foundTracks ?? this.foundTracks,
      totalBytes: totalBytes ?? this.totalBytes,
      failedDirs: failedDirs ?? this.failedDirs,
      lastError: lastError ?? this.lastError,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (provider.present) {
      map['provider'] = Variable<String>(provider.value);
    }
    if (rootId.present) {
      map['root_id'] = Variable<String>(rootId.value);
    }
    if (rootPath.present) {
      map['root_path'] = Variable<String>(rootPath.value);
    }
    if (pendingDirs.present) {
      map['pending_dirs'] = Variable<String>(pendingDirs.value);
    }
    if (currentDir.present) {
      map['current_dir'] = Variable<String>(currentDir.value);
    }
    if (currentPageToken.present) {
      map['current_page_token'] = Variable<String>(currentPageToken.value);
    }
    if (stage.present) {
      map['stage'] = Variable<String>(stage.value);
    }
    if (scannedDirs.present) {
      map['scanned_dirs'] = Variable<int>(scannedDirs.value);
    }
    if (scannedFiles.present) {
      map['scanned_files'] = Variable<int>(scannedFiles.value);
    }
    if (foundTracks.present) {
      map['found_tracks'] = Variable<int>(foundTracks.value);
    }
    if (totalBytes.present) {
      map['total_bytes'] = Variable<int>(totalBytes.value);
    }
    if (failedDirs.present) {
      map['failed_dirs'] = Variable<int>(failedDirs.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ScanCursorsCompanion(')
          ..write('provider: $provider, ')
          ..write('rootId: $rootId, ')
          ..write('rootPath: $rootPath, ')
          ..write('pendingDirs: $pendingDirs, ')
          ..write('currentDir: $currentDir, ')
          ..write('currentPageToken: $currentPageToken, ')
          ..write('stage: $stage, ')
          ..write('scannedDirs: $scannedDirs, ')
          ..write('scannedFiles: $scannedFiles, ')
          ..write('foundTracks: $foundTracks, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('failedDirs: $failedDirs, ')
          ..write('lastError: $lastError, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings
    with TableInfo<$SettingsTable, SettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<SettingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingRow(
      key:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}key'],
          )!,
      value:
          attachedDatabase.typeMapping.read(
            DriftSqlType.string,
            data['${effectivePrefix}value'],
          )!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class SettingRow extends DataClass implements Insertable<SettingRow> {
  final String key;
  final String value;
  const SettingRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(key: Value(key), value: Value(value));
  }

  factory SettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  SettingRow copyWith({String? key, String? value}) =>
      SettingRow(key: key ?? this.key, value: value ?? this.value);
  SettingRow copyWithCompanion(SettingsCompanion data) {
    return SettingRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingRow &&
          other.key == this.key &&
          other.value == this.value);
}

class SettingsCompanion extends UpdateCompanion<SettingRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<SettingRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return SettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $MediaItemsTable mediaItems = $MediaItemsTable(this);
  late final $MediaWorksTable mediaWorks = $MediaWorksTable(this);
  late final $SubtitleRefsTable subtitleRefs = $SubtitleRefsTable(this);
  late final $ScanCursorsTable scanCursors = $ScanCursorsTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    mediaItems,
    mediaWorks,
    subtitleRefs,
    scanCursors,
    settings,
  ];
}

typedef $$MediaItemsTableCreateCompanionBuilder =
    MediaItemsCompanion Function({
      required String id,
      required String provider,
      required String fileId,
      required String name,
      Value<String> dirId,
      Value<String> dirPath,
      required String groupKey,
      required String kind,
      Value<String?> title,
      Value<int?> year,
      Value<int?> season,
      Value<int?> episode,
      Value<int?> episodeEnd,
      Value<String> container,
      Value<String?> resolution,
      Value<int?> sizeBytes,
      Value<DateTime?> modifiedAt,
      Value<int?> durationMs,
      Value<String?> source,
      Value<String?> videoCodec,
      Value<String?> audioCodec,
      Value<String> flags,
      Value<String?> releaseGroup,
      Value<bool> isSampleOrExtra,
      required DateTime firstSeenAt,
      required DateTime updatedAt,
      Value<DateTime?> lastPlayedAt,
      Value<int?> resumePositionMs,
      Value<String?> thumbUrl,
      Value<int?> videoWidth,
      Value<int?> videoHeight,
      Value<int> rowid,
    });
typedef $$MediaItemsTableUpdateCompanionBuilder =
    MediaItemsCompanion Function({
      Value<String> id,
      Value<String> provider,
      Value<String> fileId,
      Value<String> name,
      Value<String> dirId,
      Value<String> dirPath,
      Value<String> groupKey,
      Value<String> kind,
      Value<String?> title,
      Value<int?> year,
      Value<int?> season,
      Value<int?> episode,
      Value<int?> episodeEnd,
      Value<String> container,
      Value<String?> resolution,
      Value<int?> sizeBytes,
      Value<DateTime?> modifiedAt,
      Value<int?> durationMs,
      Value<String?> source,
      Value<String?> videoCodec,
      Value<String?> audioCodec,
      Value<String> flags,
      Value<String?> releaseGroup,
      Value<bool> isSampleOrExtra,
      Value<DateTime> firstSeenAt,
      Value<DateTime> updatedAt,
      Value<DateTime?> lastPlayedAt,
      Value<int?> resumePositionMs,
      Value<String?> thumbUrl,
      Value<int?> videoWidth,
      Value<int?> videoHeight,
      Value<int> rowid,
    });

class $$MediaItemsTableFilterComposer
    extends Composer<_$AppDatabase, $MediaItemsTable> {
  $$MediaItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileId => $composableBuilder(
    column: $table.fileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dirId => $composableBuilder(
    column: $table.dirId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dirPath => $composableBuilder(
    column: $table.dirPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupKey => $composableBuilder(
    column: $table.groupKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get season => $composableBuilder(
    column: $table.season,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get episode => $composableBuilder(
    column: $table.episode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get episodeEnd => $composableBuilder(
    column: $table.episodeEnd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get container => $composableBuilder(
    column: $table.container,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resolution => $composableBuilder(
    column: $table.resolution,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get modifiedAt => $composableBuilder(
    column: $table.modifiedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get videoCodec => $composableBuilder(
    column: $table.videoCodec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get audioCodec => $composableBuilder(
    column: $table.audioCodec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get flags => $composableBuilder(
    column: $table.flags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get releaseGroup => $composableBuilder(
    column: $table.releaseGroup,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isSampleOrExtra => $composableBuilder(
    column: $table.isSampleOrExtra,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get firstSeenAt => $composableBuilder(
    column: $table.firstSeenAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get resumePositionMs => $composableBuilder(
    column: $table.resumePositionMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbUrl => $composableBuilder(
    column: $table.thumbUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get videoWidth => $composableBuilder(
    column: $table.videoWidth,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get videoHeight => $composableBuilder(
    column: $table.videoHeight,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MediaItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $MediaItemsTable> {
  $$MediaItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileId => $composableBuilder(
    column: $table.fileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dirId => $composableBuilder(
    column: $table.dirId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dirPath => $composableBuilder(
    column: $table.dirPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupKey => $composableBuilder(
    column: $table.groupKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get season => $composableBuilder(
    column: $table.season,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get episode => $composableBuilder(
    column: $table.episode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get episodeEnd => $composableBuilder(
    column: $table.episodeEnd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get container => $composableBuilder(
    column: $table.container,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resolution => $composableBuilder(
    column: $table.resolution,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get modifiedAt => $composableBuilder(
    column: $table.modifiedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get videoCodec => $composableBuilder(
    column: $table.videoCodec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get audioCodec => $composableBuilder(
    column: $table.audioCodec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get flags => $composableBuilder(
    column: $table.flags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get releaseGroup => $composableBuilder(
    column: $table.releaseGroup,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isSampleOrExtra => $composableBuilder(
    column: $table.isSampleOrExtra,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get firstSeenAt => $composableBuilder(
    column: $table.firstSeenAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get resumePositionMs => $composableBuilder(
    column: $table.resumePositionMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbUrl => $composableBuilder(
    column: $table.thumbUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get videoWidth => $composableBuilder(
    column: $table.videoWidth,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get videoHeight => $composableBuilder(
    column: $table.videoHeight,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MediaItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MediaItemsTable> {
  $$MediaItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get provider =>
      $composableBuilder(column: $table.provider, builder: (column) => column);

  GeneratedColumn<String> get fileId =>
      $composableBuilder(column: $table.fileId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get dirId =>
      $composableBuilder(column: $table.dirId, builder: (column) => column);

  GeneratedColumn<String> get dirPath =>
      $composableBuilder(column: $table.dirPath, builder: (column) => column);

  GeneratedColumn<String> get groupKey =>
      $composableBuilder(column: $table.groupKey, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<int> get season =>
      $composableBuilder(column: $table.season, builder: (column) => column);

  GeneratedColumn<int> get episode =>
      $composableBuilder(column: $table.episode, builder: (column) => column);

  GeneratedColumn<int> get episodeEnd => $composableBuilder(
    column: $table.episodeEnd,
    builder: (column) => column,
  );

  GeneratedColumn<String> get container =>
      $composableBuilder(column: $table.container, builder: (column) => column);

  GeneratedColumn<String> get resolution => $composableBuilder(
    column: $table.resolution,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<DateTime> get modifiedAt => $composableBuilder(
    column: $table.modifiedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get videoCodec => $composableBuilder(
    column: $table.videoCodec,
    builder: (column) => column,
  );

  GeneratedColumn<String> get audioCodec => $composableBuilder(
    column: $table.audioCodec,
    builder: (column) => column,
  );

  GeneratedColumn<String> get flags =>
      $composableBuilder(column: $table.flags, builder: (column) => column);

  GeneratedColumn<String> get releaseGroup => $composableBuilder(
    column: $table.releaseGroup,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isSampleOrExtra => $composableBuilder(
    column: $table.isSampleOrExtra,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get firstSeenAt => $composableBuilder(
    column: $table.firstSeenAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get resumePositionMs => $composableBuilder(
    column: $table.resumePositionMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get thumbUrl =>
      $composableBuilder(column: $table.thumbUrl, builder: (column) => column);

  GeneratedColumn<int> get videoWidth => $composableBuilder(
    column: $table.videoWidth,
    builder: (column) => column,
  );

  GeneratedColumn<int> get videoHeight => $composableBuilder(
    column: $table.videoHeight,
    builder: (column) => column,
  );
}

class $$MediaItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MediaItemsTable,
          MediaItemRow,
          $$MediaItemsTableFilterComposer,
          $$MediaItemsTableOrderingComposer,
          $$MediaItemsTableAnnotationComposer,
          $$MediaItemsTableCreateCompanionBuilder,
          $$MediaItemsTableUpdateCompanionBuilder,
          (
            MediaItemRow,
            BaseReferences<_$AppDatabase, $MediaItemsTable, MediaItemRow>,
          ),
          MediaItemRow,
          PrefetchHooks Function()
        > {
  $$MediaItemsTableTableManager(_$AppDatabase db, $MediaItemsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$MediaItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer:
              () => $$MediaItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer:
              () => $$MediaItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> provider = const Value.absent(),
                Value<String> fileId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> dirId = const Value.absent(),
                Value<String> dirPath = const Value.absent(),
                Value<String> groupKey = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<int?> season = const Value.absent(),
                Value<int?> episode = const Value.absent(),
                Value<int?> episodeEnd = const Value.absent(),
                Value<String> container = const Value.absent(),
                Value<String?> resolution = const Value.absent(),
                Value<int?> sizeBytes = const Value.absent(),
                Value<DateTime?> modifiedAt = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> source = const Value.absent(),
                Value<String?> videoCodec = const Value.absent(),
                Value<String?> audioCodec = const Value.absent(),
                Value<String> flags = const Value.absent(),
                Value<String?> releaseGroup = const Value.absent(),
                Value<bool> isSampleOrExtra = const Value.absent(),
                Value<DateTime> firstSeenAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> lastPlayedAt = const Value.absent(),
                Value<int?> resumePositionMs = const Value.absent(),
                Value<String?> thumbUrl = const Value.absent(),
                Value<int?> videoWidth = const Value.absent(),
                Value<int?> videoHeight = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaItemsCompanion(
                id: id,
                provider: provider,
                fileId: fileId,
                name: name,
                dirId: dirId,
                dirPath: dirPath,
                groupKey: groupKey,
                kind: kind,
                title: title,
                year: year,
                season: season,
                episode: episode,
                episodeEnd: episodeEnd,
                container: container,
                resolution: resolution,
                sizeBytes: sizeBytes,
                modifiedAt: modifiedAt,
                durationMs: durationMs,
                source: source,
                videoCodec: videoCodec,
                audioCodec: audioCodec,
                flags: flags,
                releaseGroup: releaseGroup,
                isSampleOrExtra: isSampleOrExtra,
                firstSeenAt: firstSeenAt,
                updatedAt: updatedAt,
                lastPlayedAt: lastPlayedAt,
                resumePositionMs: resumePositionMs,
                thumbUrl: thumbUrl,
                videoWidth: videoWidth,
                videoHeight: videoHeight,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String provider,
                required String fileId,
                required String name,
                Value<String> dirId = const Value.absent(),
                Value<String> dirPath = const Value.absent(),
                required String groupKey,
                required String kind,
                Value<String?> title = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<int?> season = const Value.absent(),
                Value<int?> episode = const Value.absent(),
                Value<int?> episodeEnd = const Value.absent(),
                Value<String> container = const Value.absent(),
                Value<String?> resolution = const Value.absent(),
                Value<int?> sizeBytes = const Value.absent(),
                Value<DateTime?> modifiedAt = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> source = const Value.absent(),
                Value<String?> videoCodec = const Value.absent(),
                Value<String?> audioCodec = const Value.absent(),
                Value<String> flags = const Value.absent(),
                Value<String?> releaseGroup = const Value.absent(),
                Value<bool> isSampleOrExtra = const Value.absent(),
                required DateTime firstSeenAt,
                required DateTime updatedAt,
                Value<DateTime?> lastPlayedAt = const Value.absent(),
                Value<int?> resumePositionMs = const Value.absent(),
                Value<String?> thumbUrl = const Value.absent(),
                Value<int?> videoWidth = const Value.absent(),
                Value<int?> videoHeight = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaItemsCompanion.insert(
                id: id,
                provider: provider,
                fileId: fileId,
                name: name,
                dirId: dirId,
                dirPath: dirPath,
                groupKey: groupKey,
                kind: kind,
                title: title,
                year: year,
                season: season,
                episode: episode,
                episodeEnd: episodeEnd,
                container: container,
                resolution: resolution,
                sizeBytes: sizeBytes,
                modifiedAt: modifiedAt,
                durationMs: durationMs,
                source: source,
                videoCodec: videoCodec,
                audioCodec: audioCodec,
                flags: flags,
                releaseGroup: releaseGroup,
                isSampleOrExtra: isSampleOrExtra,
                firstSeenAt: firstSeenAt,
                updatedAt: updatedAt,
                lastPlayedAt: lastPlayedAt,
                resumePositionMs: resumePositionMs,
                thumbUrl: thumbUrl,
                videoWidth: videoWidth,
                videoHeight: videoHeight,
                rowid: rowid,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          BaseReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MediaItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MediaItemsTable,
      MediaItemRow,
      $$MediaItemsTableFilterComposer,
      $$MediaItemsTableOrderingComposer,
      $$MediaItemsTableAnnotationComposer,
      $$MediaItemsTableCreateCompanionBuilder,
      $$MediaItemsTableUpdateCompanionBuilder,
      (
        MediaItemRow,
        BaseReferences<_$AppDatabase, $MediaItemsTable, MediaItemRow>,
      ),
      MediaItemRow,
      PrefetchHooks Function()
    >;
typedef $$MediaWorksTableCreateCompanionBuilder =
    MediaWorksCompanion Function({
      required String key,
      required String provider,
      required String kind,
      Value<String> category,
      required String title,
      Value<String?> originalTitle,
      Value<int?> year,
      Value<String?> overview,
      Value<String?> posterUrl,
      Value<String?> posterFile,
      Value<double?> posterFaceX,
      Value<String?> backdropUrl,
      Value<String?> backdropFile,
      Value<double?> rating,
      Value<String> genres,
      Value<String?> onlineId,
      required String source,
      Value<DateTime?> scrapedAt,
      Value<int> itemCount,
      Value<int> totalBytes,
      Value<DateTime?> lastModifiedAt,
      Value<DateTime?> lastPlayedAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$MediaWorksTableUpdateCompanionBuilder =
    MediaWorksCompanion Function({
      Value<String> key,
      Value<String> provider,
      Value<String> kind,
      Value<String> category,
      Value<String> title,
      Value<String?> originalTitle,
      Value<int?> year,
      Value<String?> overview,
      Value<String?> posterUrl,
      Value<String?> posterFile,
      Value<double?> posterFaceX,
      Value<String?> backdropUrl,
      Value<String?> backdropFile,
      Value<double?> rating,
      Value<String> genres,
      Value<String?> onlineId,
      Value<String> source,
      Value<DateTime?> scrapedAt,
      Value<int> itemCount,
      Value<int> totalBytes,
      Value<DateTime?> lastModifiedAt,
      Value<DateTime?> lastPlayedAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$MediaWorksTableFilterComposer
    extends Composer<_$AppDatabase, $MediaWorksTable> {
  $$MediaWorksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get overview => $composableBuilder(
    column: $table.overview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get posterUrl => $composableBuilder(
    column: $table.posterUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get posterFile => $composableBuilder(
    column: $table.posterFile,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get posterFaceX => $composableBuilder(
    column: $table.posterFaceX,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get backdropUrl => $composableBuilder(
    column: $table.backdropUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get backdropFile => $composableBuilder(
    column: $table.backdropFile,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get genres => $composableBuilder(
    column: $table.genres,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get onlineId => $composableBuilder(
    column: $table.onlineId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get scrapedAt => $composableBuilder(
    column: $table.scrapedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get itemCount => $composableBuilder(
    column: $table.itemCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastModifiedAt => $composableBuilder(
    column: $table.lastModifiedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MediaWorksTableOrderingComposer
    extends Composer<_$AppDatabase, $MediaWorksTable> {
  $$MediaWorksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get overview => $composableBuilder(
    column: $table.overview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get posterUrl => $composableBuilder(
    column: $table.posterUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get posterFile => $composableBuilder(
    column: $table.posterFile,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get posterFaceX => $composableBuilder(
    column: $table.posterFaceX,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get backdropUrl => $composableBuilder(
    column: $table.backdropUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get backdropFile => $composableBuilder(
    column: $table.backdropFile,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get genres => $composableBuilder(
    column: $table.genres,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get onlineId => $composableBuilder(
    column: $table.onlineId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get scrapedAt => $composableBuilder(
    column: $table.scrapedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get itemCount => $composableBuilder(
    column: $table.itemCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastModifiedAt => $composableBuilder(
    column: $table.lastModifiedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MediaWorksTableAnnotationComposer
    extends Composer<_$AppDatabase, $MediaWorksTable> {
  $$MediaWorksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get provider =>
      $composableBuilder(column: $table.provider, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => column,
  );

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<String> get overview =>
      $composableBuilder(column: $table.overview, builder: (column) => column);

  GeneratedColumn<String> get posterUrl =>
      $composableBuilder(column: $table.posterUrl, builder: (column) => column);

  GeneratedColumn<String> get posterFile => $composableBuilder(
    column: $table.posterFile,
    builder: (column) => column,
  );

  GeneratedColumn<double> get posterFaceX => $composableBuilder(
    column: $table.posterFaceX,
    builder: (column) => column,
  );

  GeneratedColumn<String> get backdropUrl => $composableBuilder(
    column: $table.backdropUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get backdropFile => $composableBuilder(
    column: $table.backdropFile,
    builder: (column) => column,
  );

  GeneratedColumn<double> get rating =>
      $composableBuilder(column: $table.rating, builder: (column) => column);

  GeneratedColumn<String> get genres =>
      $composableBuilder(column: $table.genres, builder: (column) => column);

  GeneratedColumn<String> get onlineId =>
      $composableBuilder(column: $table.onlineId, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<DateTime> get scrapedAt =>
      $composableBuilder(column: $table.scrapedAt, builder: (column) => column);

  GeneratedColumn<int> get itemCount =>
      $composableBuilder(column: $table.itemCount, builder: (column) => column);

  GeneratedColumn<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastModifiedAt => $composableBuilder(
    column: $table.lastModifiedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$MediaWorksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MediaWorksTable,
          MediaWorkRow,
          $$MediaWorksTableFilterComposer,
          $$MediaWorksTableOrderingComposer,
          $$MediaWorksTableAnnotationComposer,
          $$MediaWorksTableCreateCompanionBuilder,
          $$MediaWorksTableUpdateCompanionBuilder,
          (
            MediaWorkRow,
            BaseReferences<_$AppDatabase, $MediaWorksTable, MediaWorkRow>,
          ),
          MediaWorkRow,
          PrefetchHooks Function()
        > {
  $$MediaWorksTableTableManager(_$AppDatabase db, $MediaWorksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$MediaWorksTableFilterComposer($db: db, $table: table),
          createOrderingComposer:
              () => $$MediaWorksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer:
              () => $$MediaWorksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> provider = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> category = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> originalTitle = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> overview = const Value.absent(),
                Value<String?> posterUrl = const Value.absent(),
                Value<String?> posterFile = const Value.absent(),
                Value<double?> posterFaceX = const Value.absent(),
                Value<String?> backdropUrl = const Value.absent(),
                Value<String?> backdropFile = const Value.absent(),
                Value<double?> rating = const Value.absent(),
                Value<String> genres = const Value.absent(),
                Value<String?> onlineId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<DateTime?> scrapedAt = const Value.absent(),
                Value<int> itemCount = const Value.absent(),
                Value<int> totalBytes = const Value.absent(),
                Value<DateTime?> lastModifiedAt = const Value.absent(),
                Value<DateTime?> lastPlayedAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaWorksCompanion(
                key: key,
                provider: provider,
                kind: kind,
                category: category,
                title: title,
                originalTitle: originalTitle,
                year: year,
                overview: overview,
                posterUrl: posterUrl,
                posterFile: posterFile,
                posterFaceX: posterFaceX,
                backdropUrl: backdropUrl,
                backdropFile: backdropFile,
                rating: rating,
                genres: genres,
                onlineId: onlineId,
                source: source,
                scrapedAt: scrapedAt,
                itemCount: itemCount,
                totalBytes: totalBytes,
                lastModifiedAt: lastModifiedAt,
                lastPlayedAt: lastPlayedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String provider,
                required String kind,
                Value<String> category = const Value.absent(),
                required String title,
                Value<String?> originalTitle = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> overview = const Value.absent(),
                Value<String?> posterUrl = const Value.absent(),
                Value<String?> posterFile = const Value.absent(),
                Value<double?> posterFaceX = const Value.absent(),
                Value<String?> backdropUrl = const Value.absent(),
                Value<String?> backdropFile = const Value.absent(),
                Value<double?> rating = const Value.absent(),
                Value<String> genres = const Value.absent(),
                Value<String?> onlineId = const Value.absent(),
                required String source,
                Value<DateTime?> scrapedAt = const Value.absent(),
                Value<int> itemCount = const Value.absent(),
                Value<int> totalBytes = const Value.absent(),
                Value<DateTime?> lastModifiedAt = const Value.absent(),
                Value<DateTime?> lastPlayedAt = const Value.absent(),
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => MediaWorksCompanion.insert(
                key: key,
                provider: provider,
                kind: kind,
                category: category,
                title: title,
                originalTitle: originalTitle,
                year: year,
                overview: overview,
                posterUrl: posterUrl,
                posterFile: posterFile,
                posterFaceX: posterFaceX,
                backdropUrl: backdropUrl,
                backdropFile: backdropFile,
                rating: rating,
                genres: genres,
                onlineId: onlineId,
                source: source,
                scrapedAt: scrapedAt,
                itemCount: itemCount,
                totalBytes: totalBytes,
                lastModifiedAt: lastModifiedAt,
                lastPlayedAt: lastPlayedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          BaseReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MediaWorksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MediaWorksTable,
      MediaWorkRow,
      $$MediaWorksTableFilterComposer,
      $$MediaWorksTableOrderingComposer,
      $$MediaWorksTableAnnotationComposer,
      $$MediaWorksTableCreateCompanionBuilder,
      $$MediaWorksTableUpdateCompanionBuilder,
      (
        MediaWorkRow,
        BaseReferences<_$AppDatabase, $MediaWorksTable, MediaWorkRow>,
      ),
      MediaWorkRow,
      PrefetchHooks Function()
    >;
typedef $$SubtitleRefsTableCreateCompanionBuilder =
    SubtitleRefsCompanion Function({
      required String id,
      required String itemId,
      required String origin,
      required String label,
      required String format,
      Value<String?> languageCode,
      Value<String?> languageLabel,
      Value<String?> fileId,
      Value<String?> fileName,
      Value<String?> localPath,
      Value<int?> embeddedTrackId,
      Value<bool> isForced,
      Value<bool> isSdh,
      Value<bool> isDefault,
      Value<int> rowid,
    });
typedef $$SubtitleRefsTableUpdateCompanionBuilder =
    SubtitleRefsCompanion Function({
      Value<String> id,
      Value<String> itemId,
      Value<String> origin,
      Value<String> label,
      Value<String> format,
      Value<String?> languageCode,
      Value<String?> languageLabel,
      Value<String?> fileId,
      Value<String?> fileName,
      Value<String?> localPath,
      Value<int?> embeddedTrackId,
      Value<bool> isForced,
      Value<bool> isSdh,
      Value<bool> isDefault,
      Value<int> rowid,
    });

class $$SubtitleRefsTableFilterComposer
    extends Composer<_$AppDatabase, $SubtitleRefsTable> {
  $$SubtitleRefsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get itemId => $composableBuilder(
    column: $table.itemId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get languageCode => $composableBuilder(
    column: $table.languageCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get languageLabel => $composableBuilder(
    column: $table.languageLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileId => $composableBuilder(
    column: $table.fileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get embeddedTrackId => $composableBuilder(
    column: $table.embeddedTrackId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isForced => $composableBuilder(
    column: $table.isForced,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isSdh => $composableBuilder(
    column: $table.isSdh,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SubtitleRefsTableOrderingComposer
    extends Composer<_$AppDatabase, $SubtitleRefsTable> {
  $$SubtitleRefsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get itemId => $composableBuilder(
    column: $table.itemId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get languageCode => $composableBuilder(
    column: $table.languageCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get languageLabel => $composableBuilder(
    column: $table.languageLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileId => $composableBuilder(
    column: $table.fileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get embeddedTrackId => $composableBuilder(
    column: $table.embeddedTrackId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isForced => $composableBuilder(
    column: $table.isForced,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isSdh => $composableBuilder(
    column: $table.isSdh,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SubtitleRefsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SubtitleRefsTable> {
  $$SubtitleRefsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get itemId =>
      $composableBuilder(column: $table.itemId, builder: (column) => column);

  GeneratedColumn<String> get origin =>
      $composableBuilder(column: $table.origin, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumn<String> get languageCode => $composableBuilder(
    column: $table.languageCode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get languageLabel => $composableBuilder(
    column: $table.languageLabel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fileId =>
      $composableBuilder(column: $table.fileId, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<int> get embeddedTrackId => $composableBuilder(
    column: $table.embeddedTrackId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isForced =>
      $composableBuilder(column: $table.isForced, builder: (column) => column);

  GeneratedColumn<bool> get isSdh =>
      $composableBuilder(column: $table.isSdh, builder: (column) => column);

  GeneratedColumn<bool> get isDefault =>
      $composableBuilder(column: $table.isDefault, builder: (column) => column);
}

class $$SubtitleRefsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SubtitleRefsTable,
          SubtitleRefRow,
          $$SubtitleRefsTableFilterComposer,
          $$SubtitleRefsTableOrderingComposer,
          $$SubtitleRefsTableAnnotationComposer,
          $$SubtitleRefsTableCreateCompanionBuilder,
          $$SubtitleRefsTableUpdateCompanionBuilder,
          (
            SubtitleRefRow,
            BaseReferences<_$AppDatabase, $SubtitleRefsTable, SubtitleRefRow>,
          ),
          SubtitleRefRow,
          PrefetchHooks Function()
        > {
  $$SubtitleRefsTableTableManager(_$AppDatabase db, $SubtitleRefsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$SubtitleRefsTableFilterComposer($db: db, $table: table),
          createOrderingComposer:
              () => $$SubtitleRefsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer:
              () =>
                  $$SubtitleRefsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> itemId = const Value.absent(),
                Value<String> origin = const Value.absent(),
                Value<String> label = const Value.absent(),
                Value<String> format = const Value.absent(),
                Value<String?> languageCode = const Value.absent(),
                Value<String?> languageLabel = const Value.absent(),
                Value<String?> fileId = const Value.absent(),
                Value<String?> fileName = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<int?> embeddedTrackId = const Value.absent(),
                Value<bool> isForced = const Value.absent(),
                Value<bool> isSdh = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SubtitleRefsCompanion(
                id: id,
                itemId: itemId,
                origin: origin,
                label: label,
                format: format,
                languageCode: languageCode,
                languageLabel: languageLabel,
                fileId: fileId,
                fileName: fileName,
                localPath: localPath,
                embeddedTrackId: embeddedTrackId,
                isForced: isForced,
                isSdh: isSdh,
                isDefault: isDefault,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String itemId,
                required String origin,
                required String label,
                required String format,
                Value<String?> languageCode = const Value.absent(),
                Value<String?> languageLabel = const Value.absent(),
                Value<String?> fileId = const Value.absent(),
                Value<String?> fileName = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<int?> embeddedTrackId = const Value.absent(),
                Value<bool> isForced = const Value.absent(),
                Value<bool> isSdh = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SubtitleRefsCompanion.insert(
                id: id,
                itemId: itemId,
                origin: origin,
                label: label,
                format: format,
                languageCode: languageCode,
                languageLabel: languageLabel,
                fileId: fileId,
                fileName: fileName,
                localPath: localPath,
                embeddedTrackId: embeddedTrackId,
                isForced: isForced,
                isSdh: isSdh,
                isDefault: isDefault,
                rowid: rowid,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          BaseReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SubtitleRefsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SubtitleRefsTable,
      SubtitleRefRow,
      $$SubtitleRefsTableFilterComposer,
      $$SubtitleRefsTableOrderingComposer,
      $$SubtitleRefsTableAnnotationComposer,
      $$SubtitleRefsTableCreateCompanionBuilder,
      $$SubtitleRefsTableUpdateCompanionBuilder,
      (
        SubtitleRefRow,
        BaseReferences<_$AppDatabase, $SubtitleRefsTable, SubtitleRefRow>,
      ),
      SubtitleRefRow,
      PrefetchHooks Function()
    >;
typedef $$ScanCursorsTableCreateCompanionBuilder =
    ScanCursorsCompanion Function({
      required String provider,
      required String rootId,
      Value<String> rootPath,
      Value<String> pendingDirs,
      Value<String?> currentDir,
      Value<String?> currentPageToken,
      required String stage,
      Value<int> scannedDirs,
      Value<int> scannedFiles,
      Value<int> foundTracks,
      Value<int> totalBytes,
      Value<int> failedDirs,
      Value<String?> lastError,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$ScanCursorsTableUpdateCompanionBuilder =
    ScanCursorsCompanion Function({
      Value<String> provider,
      Value<String> rootId,
      Value<String> rootPath,
      Value<String> pendingDirs,
      Value<String?> currentDir,
      Value<String?> currentPageToken,
      Value<String> stage,
      Value<int> scannedDirs,
      Value<int> scannedFiles,
      Value<int> foundTracks,
      Value<int> totalBytes,
      Value<int> failedDirs,
      Value<String?> lastError,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$ScanCursorsTableFilterComposer
    extends Composer<_$AppDatabase, $ScanCursorsTable> {
  $$ScanCursorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rootId => $composableBuilder(
    column: $table.rootId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rootPath => $composableBuilder(
    column: $table.rootPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pendingDirs => $composableBuilder(
    column: $table.pendingDirs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get currentDir => $composableBuilder(
    column: $table.currentDir,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get currentPageToken => $composableBuilder(
    column: $table.currentPageToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stage => $composableBuilder(
    column: $table.stage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get scannedDirs => $composableBuilder(
    column: $table.scannedDirs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get scannedFiles => $composableBuilder(
    column: $table.scannedFiles,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get foundTracks => $composableBuilder(
    column: $table.foundTracks,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get failedDirs => $composableBuilder(
    column: $table.failedDirs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ScanCursorsTableOrderingComposer
    extends Composer<_$AppDatabase, $ScanCursorsTable> {
  $$ScanCursorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rootId => $composableBuilder(
    column: $table.rootId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rootPath => $composableBuilder(
    column: $table.rootPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pendingDirs => $composableBuilder(
    column: $table.pendingDirs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get currentDir => $composableBuilder(
    column: $table.currentDir,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get currentPageToken => $composableBuilder(
    column: $table.currentPageToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stage => $composableBuilder(
    column: $table.stage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get scannedDirs => $composableBuilder(
    column: $table.scannedDirs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get scannedFiles => $composableBuilder(
    column: $table.scannedFiles,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get foundTracks => $composableBuilder(
    column: $table.foundTracks,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get failedDirs => $composableBuilder(
    column: $table.failedDirs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ScanCursorsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ScanCursorsTable> {
  $$ScanCursorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get provider =>
      $composableBuilder(column: $table.provider, builder: (column) => column);

  GeneratedColumn<String> get rootId =>
      $composableBuilder(column: $table.rootId, builder: (column) => column);

  GeneratedColumn<String> get rootPath =>
      $composableBuilder(column: $table.rootPath, builder: (column) => column);

  GeneratedColumn<String> get pendingDirs => $composableBuilder(
    column: $table.pendingDirs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get currentDir => $composableBuilder(
    column: $table.currentDir,
    builder: (column) => column,
  );

  GeneratedColumn<String> get currentPageToken => $composableBuilder(
    column: $table.currentPageToken,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stage =>
      $composableBuilder(column: $table.stage, builder: (column) => column);

  GeneratedColumn<int> get scannedDirs => $composableBuilder(
    column: $table.scannedDirs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get scannedFiles => $composableBuilder(
    column: $table.scannedFiles,
    builder: (column) => column,
  );

  GeneratedColumn<int> get foundTracks => $composableBuilder(
    column: $table.foundTracks,
    builder: (column) => column,
  );

  GeneratedColumn<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get failedDirs => $composableBuilder(
    column: $table.failedDirs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ScanCursorsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ScanCursorsTable,
          ScanCursorRow,
          $$ScanCursorsTableFilterComposer,
          $$ScanCursorsTableOrderingComposer,
          $$ScanCursorsTableAnnotationComposer,
          $$ScanCursorsTableCreateCompanionBuilder,
          $$ScanCursorsTableUpdateCompanionBuilder,
          (
            ScanCursorRow,
            BaseReferences<_$AppDatabase, $ScanCursorsTable, ScanCursorRow>,
          ),
          ScanCursorRow,
          PrefetchHooks Function()
        > {
  $$ScanCursorsTableTableManager(_$AppDatabase db, $ScanCursorsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$ScanCursorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer:
              () => $$ScanCursorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer:
              () =>
                  $$ScanCursorsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> provider = const Value.absent(),
                Value<String> rootId = const Value.absent(),
                Value<String> rootPath = const Value.absent(),
                Value<String> pendingDirs = const Value.absent(),
                Value<String?> currentDir = const Value.absent(),
                Value<String?> currentPageToken = const Value.absent(),
                Value<String> stage = const Value.absent(),
                Value<int> scannedDirs = const Value.absent(),
                Value<int> scannedFiles = const Value.absent(),
                Value<int> foundTracks = const Value.absent(),
                Value<int> totalBytes = const Value.absent(),
                Value<int> failedDirs = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScanCursorsCompanion(
                provider: provider,
                rootId: rootId,
                rootPath: rootPath,
                pendingDirs: pendingDirs,
                currentDir: currentDir,
                currentPageToken: currentPageToken,
                stage: stage,
                scannedDirs: scannedDirs,
                scannedFiles: scannedFiles,
                foundTracks: foundTracks,
                totalBytes: totalBytes,
                failedDirs: failedDirs,
                lastError: lastError,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String provider,
                required String rootId,
                Value<String> rootPath = const Value.absent(),
                Value<String> pendingDirs = const Value.absent(),
                Value<String?> currentDir = const Value.absent(),
                Value<String?> currentPageToken = const Value.absent(),
                required String stage,
                Value<int> scannedDirs = const Value.absent(),
                Value<int> scannedFiles = const Value.absent(),
                Value<int> foundTracks = const Value.absent(),
                Value<int> totalBytes = const Value.absent(),
                Value<int> failedDirs = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => ScanCursorsCompanion.insert(
                provider: provider,
                rootId: rootId,
                rootPath: rootPath,
                pendingDirs: pendingDirs,
                currentDir: currentDir,
                currentPageToken: currentPageToken,
                stage: stage,
                scannedDirs: scannedDirs,
                scannedFiles: scannedFiles,
                foundTracks: foundTracks,
                totalBytes: totalBytes,
                failedDirs: failedDirs,
                lastError: lastError,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          BaseReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ScanCursorsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ScanCursorsTable,
      ScanCursorRow,
      $$ScanCursorsTableFilterComposer,
      $$ScanCursorsTableOrderingComposer,
      $$ScanCursorsTableAnnotationComposer,
      $$ScanCursorsTableCreateCompanionBuilder,
      $$ScanCursorsTableUpdateCompanionBuilder,
      (
        ScanCursorRow,
        BaseReferences<_$AppDatabase, $ScanCursorsTable, ScanCursorRow>,
      ),
      ScanCursorRow,
      PrefetchHooks Function()
    >;
typedef $$SettingsTableCreateCompanionBuilder =
    SettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$SettingsTableUpdateCompanionBuilder =
    SettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$SettingsTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SettingsTable,
          SettingRow,
          $$SettingsTableFilterComposer,
          $$SettingsTableOrderingComposer,
          $$SettingsTableAnnotationComposer,
          $$SettingsTableCreateCompanionBuilder,
          $$SettingsTableUpdateCompanionBuilder,
          (
            SettingRow,
            BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>,
          ),
          SettingRow,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableManager(_$AppDatabase db, $SettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer:
              () => $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer:
              () => $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer:
              () => $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper:
              (p0) =>
                  p0
                      .map(
                        (e) => (
                          e.readTable(table),
                          BaseReferences(db, table, e),
                        ),
                      )
                      .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SettingsTable,
      SettingRow,
      $$SettingsTableFilterComposer,
      $$SettingsTableOrderingComposer,
      $$SettingsTableAnnotationComposer,
      $$SettingsTableCreateCompanionBuilder,
      $$SettingsTableUpdateCompanionBuilder,
      (SettingRow, BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>),
      SettingRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$MediaItemsTableTableManager get mediaItems =>
      $$MediaItemsTableTableManager(_db, _db.mediaItems);
  $$MediaWorksTableTableManager get mediaWorks =>
      $$MediaWorksTableTableManager(_db, _db.mediaWorks);
  $$SubtitleRefsTableTableManager get subtitleRefs =>
      $$SubtitleRefsTableTableManager(_db, _db.subtitleRefs);
  $$ScanCursorsTableTableManager get scanCursors =>
      $$ScanCursorsTableTableManager(_db, _db.scanCursors);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
}
