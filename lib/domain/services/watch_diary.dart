/// 观影日记的**独立存储模型** —— 纯数据 + 纯合并，不碰 IO。
///
/// ## 为什么要有它（而不是往 `media_works` 上加几列）
///
/// 日记记的是**历史事实**（「我看过什么、我给它几分」），媒体库记的是
/// **当前状态**（「现在能看什么」）。后者可以重建（重扫一次就有了），
/// 前者不能 —— 网盘上的资源删了、索引库清了、换了台设备重扫，
/// 评分和短评都不该跟着消失。
///
/// 三条路都验证过，只有「独立文件」成立：
///
///   1. 存 `media_works` 加列 → 清理作品时**级联删掉**，直接违反需求；
///   2. 新建 sqlite 表 → 恢复 `.ccbak` 是**整文件字节替换**，一定被覆盖；
///   3. 独立 JSON 文件 → 上面两条都不存在（见 `DiaryStore` 的类文档）。
///
/// ## 它同时是跨端同步的载荷
///
/// 与 `ProgressBook` 同一条理由：日记天然是**逐条**的，而媒体库备份是
/// **整份**的 LWW。用整份同步的话，PC 端记入《三体》、手机端记入《狂飙》，
/// 后同步的那台会把另一条抹掉。所以这里按**条目**做 LWW。
///
/// ## ⛔ 合并规则是「两类字段、两个方向」，别统一成 LWW
///
/// | 字段 | 规则 | 为什么 |
/// |---|---|---|
/// | `rating` / `review` / `tags` / `favorite` / `deletedAt` | `updatedAt` 大者赢 | 这是**用户的决定**，后改的说了算 |
/// | `episodeWatched` / `lastWatchedSec` | 取**较大值** | 「另一台看得更多」不该被抹掉（同 `ProgressEntry.maxMs`） |
/// | `addedAtSec` | 取**较小值** | 「什么时候第一次记入」是历史事实，不该被推后 |
/// | `episodeTotal` / `completionRatio` | 跟 `addedAtSec` **较早**那份 | 完成率的分母要在同一时刻定格，否则两端算出的比例对不上 |
///
/// ⛔ 把 `episodeWatched` 也交给 LWW 是最容易犯的错：一台看了 22 集，
///    被一台只看 20 集的设备改回 20 —— 而两边都显示同步成功。
///
/// ## 单位
///
///   * `durationMs` / `maxPosMs` —— **毫秒**（与 `media_items.duration_ms` /
///     `max_position_ms` 逐字对齐）；
///   * `addedAtSec` / `lastWatchedSec` / `updatedAtSec` / `deletedAtSec` ——
///     **Unix 秒**（与 `ProgressEntry` 同口径）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'diary_eligibility.dart';

/// 一条日记记录 = 一部作品的身份快照 + 完成度快照 + 个人评价。
///
/// ⛔ **身份字段全是快照**：`title` / `year` / `posterFile` 这些在记入那一刻
///    抄一份存下来，之后**永不回查媒体库**。少了这一步，用户清理一次索引库
///    就会看到「日记里那一条变成空白」—— 而那正是这个功能要避免的事。
class DiaryEntry {
  const DiaryEntry({
    required this.id,
    required this.provider,
    required this.title,
    required this.kind,
    required this.episodeTotal,
    required this.episodeWatched,
    required this.completionRatio,
    required this.addedAtSec,
    required this.updatedAtSec,
    this.workKey,
    this.originalTitle,
    this.year,
    this.category,
    this.genres = const <String>[],
    this.posterUrl,
    this.posterFile,
    this.posterFaceX,
    this.durationMs,
    this.maxPosMs,
    this.lastWatchedSec,
    this.rating,
    this.review,
    this.tags = const <String>[],
    this.favorite = false,
    this.deletedAtSec,
    this.device = '',
    this.itemIds = const <String>[],
  });

  /// 主键。**不是 `work_key`** —— 见 [idFor]。
  final String id;

  /// `quark` / `baidu`。只用于「资源还在不在」的探测。
  final String provider;

  /// 原作品键。**弱引用**：可能失效（重扫 / 改名 / 清理），只用于跳转播放。
  ///
  /// ⛔ 绝不拿它做展示查询 —— 那等于把日记挂回媒体库的生命周期上。
  final String? workKey;

  final String title;
  final String? originalTitle;
  final int? year;

  /// `movie` / `tv` / `anime` / `variety` / `other`（`MediaKind.name`）。
  final String kind;

  /// 媒体库一级分类快照（`MediaCategory.name`）。
  final String? category;

  final List<String> genres;
  final String? posterUrl;

  /// 本地海报文件名（在 `diary_posters/` 下）。
  ///
  /// ⛔ 记入时把海报**拷进日记专用目录**，不进 `PosterCache` 的 LRU ——
  ///    否则缓存一清，日记就变成一片破图，而这个功能的第一印象全在封面上。
  final String? posterFile;

  /// 海报人脸锚点（0~1），与 [posterFile] 成对。
  final double? posterFaceX;

  /// 记入那一刻这部剧**库里有多少集**（冻结值）。
  ///
  /// ⛔ 不实时算：用户删掉 18 集之后，剩下的集全看完会让完成率变成 100%，
  ///    而事实是「24 集里只看了 20 集」。日记是历史事实，不能被后来的删除改写。
  final int episodeTotal;

  /// 记入那一刻**看完了多少集**（冻结值）。
  final int episodeWatched;

  /// `episodeWatched / episodeTotal`，冗余存一份便于排序与展示。
  final double completionRatio;

  /// 电影口径用的两个数（剧集也存，便于将来换口径重算）。
  final int? durationMs;
  final int? maxPosMs;

  /// **首次**记入时刻（Unix 秒）。合并时取**较小**值。
  final int addedAtSec;

  /// 最后一次播放时刻（Unix 秒）。合并时取**较大**值。
  final int? lastWatchedSec;

  /// 个人评分。`null` = 未评分；否则 `1..10` 的整数（= 0.5~5 星 × 2）。
  ///
  /// ⛔ 存 1~10 而不是 0.5~5.0 的 double：整数比较不会出现
  ///    `4.4999999 != 4.5` 这种让「同一份数据在两台机器上不等」的浮点问题。
  final int? rating;

  /// 短评。空串归一化成 `null`（见 [copyWith]）。
  final String? review;

  final List<String> tags;

  /// 收藏置顶。
  final bool favorite;

  /// **墓碑**。非空 = 用户删过这一条（Unix 秒）。
  ///
  /// ## ⛔ 为什么删除要留墓碑，而不是直接把这条从文件里删掉
  ///
  /// 场景：A 机器删掉一条 → 上传（文件里没有这条了）→ B 机器还有 →
  /// B 上传 → **日记复活**。这是所有同步设计里最容易踩的坑。
  ///
  /// 留墓碑之后，删除本身也参与 LWW：`deletedAtSec` 所在的 `updatedAtSec`
  /// 更大的一方赢。展示时过滤掉 `deletedAtSec != null` 的条目，
  /// 观感与「真删掉」完全一致。墓碑保留 180 天后物理清理
  /// （比任何设备的离线时长都长）。
  final int? deletedAtSec;

  /// 这一条**最后一次被写入**的时刻（Unix 秒）。合并判据。
  ///
  /// ⛔ 与 [lastWatchedSec] 分开：后者是业务语义（什么时候看的），
  ///    前者是合并语义（哪一份更新）。合成一个的话，「改个评分」会把
  ///    「最近看」往前推，时间轴排序就乱了。
  final int updatedAtSec;

  /// 产生/最后修改这一条设备标识。仅用于排查，不参与合并。
  final String device;

  /// 记入时的文件 id 列表。只用于「资源还在就跳过去重看」，可为空。
  final List<String> itemIds;

  /// 已删除（墓碑）。
  bool get isDeleted => deletedAtSec != null;

  /// 已评分。
  bool get isRated => rating != null;

  /// 星级（0.5 ~ 5.0），UI 用。
  double? get stars => rating == null ? null : rating! / 2;

  // -------------------------------------------------------------------
  // 合并
  // -------------------------------------------------------------------

  /// 与 [other] 合并，返回**胜出**的那一份。
  ///
  /// 三组字段三个方向，理由见库文档的表格。相等时**保留自己**（`>=`）：
  /// 两台设备在同一秒各写一次时，结果在两台机器上是同一个，不会来回抖
  /// （与 `ProgressEntry.mergedWith` 同一条）。
  DiaryEntry mergedWith(DiaryEntry other) {
    final selfWins = updatedAtSec >= other.updatedAtSec;
    final user = selfWins ? this : other;

    // 身份与完成度跟「先记入」的那一份 —— 它是这份日记的原始快照。
    final first = addedAtSec <= other.addedAtSec ? this : other;

    return DiaryEntry(
      id: id,
      provider: first.provider,
      workKey: user.workKey ?? first.workKey,
      title: first.title,
      originalTitle: first.originalTitle ?? other.originalTitle,
      year: first.year,
      kind: first.kind,
      category: first.category ?? other.category,
      genres: first.genres.isNotEmpty ? first.genres : other.genres,
      posterUrl: first.posterUrl ?? other.posterUrl,
      // 海报是「本机下载到的那张」：任意一端有就用它（文件名两端通用）。
      posterFile: posterFile ?? other.posterFile,
      posterFaceX: posterFaceX ?? other.posterFaceX,
      episodeTotal: first.episodeTotal,
      episodeWatched:
          episodeWatched >= other.episodeWatched ? episodeWatched : other.episodeWatched,
      completionRatio: _maxRatio(completionRatio, other.completionRatio),
      durationMs: first.durationMs ?? other.durationMs,
      maxPosMs: _maxInt(maxPosMs, other.maxPosMs),
      addedAtSec: first.addedAtSec,
      lastWatchedSec: _maxInt(lastWatchedSec, other.lastWatchedSec),
      rating: user.rating,
      review: user.review,
      tags: user.tags,
      favorite: user.favorite,
      deletedAtSec: user.deletedAtSec,
      updatedAtSec: user.updatedAtSec,
      device: user.device,
      itemIds: _unionIds(itemIds, other.itemIds),
    );
  }

  /// 内容是否与 [other] 完全相同（含 [updatedAtSec]）。
  ///
  /// 合并后据此判断「要不要上传」—— 内容没变就不要动网盘
  /// （上传是**有失败风险**的动作，见 `uploadFileToBackupDir` 的文档）。
  bool sameAs(DiaryEntry other) {
    if (id != other.id ||
        provider != other.provider ||
        workKey != other.workKey ||
        title != other.title ||
        originalTitle != other.originalTitle ||
        year != other.year ||
        kind != other.kind ||
        category != other.category ||
        posterUrl != other.posterUrl ||
        posterFile != other.posterFile ||
        posterFaceX != other.posterFaceX ||
        episodeTotal != other.episodeTotal ||
        episodeWatched != other.episodeWatched ||
        completionRatio != other.completionRatio ||
        durationMs != other.durationMs ||
        maxPosMs != other.maxPosMs ||
        addedAtSec != other.addedAtSec ||
        lastWatchedSec != other.lastWatchedSec ||
        rating != other.rating ||
        review != other.review ||
        favorite != other.favorite ||
        deletedAtSec != other.deletedAtSec ||
        updatedAtSec != other.updatedAtSec ||
        device != other.device) {
      return false;
    }
    return _sameList(genres, other.genres) &&
        _sameList(tags, other.tags) &&
        _sameList(itemIds, other.itemIds);
  }

  /// 改评分 / 短评 / 标签 / 收藏 / 删除，返回**新的一条**。
  ///
  /// [at] 是测试注入的「现在」；生产路径传 `null`（用 `DateTime.now()`）。
  ///
  /// ⛔ 只改用户可改的那几项，身份与完成度快照原样保留 —— 评价一个人
  ///    不会让他变年轻。
  DiaryEntry copyWith({
    int? rating,
    bool clearRating = false,
    String? review,
    List<String>? tags,
    bool? favorite,
    int? deletedAtSec,
    bool clearDeleted = false,
    String? posterFile,
    DateTime? at,
  }) {
    final now = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    // 时间戳只前进：设备时钟回拨时不该让新改动输给远程的旧值
    // （与 `ProgressStore._nextUpdated` 同一条）。
    final next = now > updatedAtSec ? now : updatedAtSec;
    return DiaryEntry(
      id: id,
      provider: provider,
      workKey: workKey,
      title: title,
      originalTitle: originalTitle,
      year: year,
      kind: kind,
      category: category,
      genres: genres,
      posterUrl: posterUrl,
      posterFile: posterFile ?? this.posterFile,
      posterFaceX: posterFaceX,
      episodeTotal: episodeTotal,
      episodeWatched: episodeWatched,
      completionRatio: completionRatio,
      durationMs: durationMs,
      maxPosMs: maxPosMs,
      addedAtSec: addedAtSec,
      lastWatchedSec: lastWatchedSec,
      rating: clearRating ? null : (rating ?? this.rating),
      review: review == null
          ? this.review
          : (review.trim().isEmpty ? null : review.trim()),
      tags: tags ?? this.tags,
      favorite: favorite ?? this.favorite,
      deletedAtSec: clearDeleted ? null : (deletedAtSec ?? this.deletedAtSec),
      updatedAtSec: next,
      device: device,
      itemIds: itemIds,
    );
  }

  /// 标记为删除（墓碑）。见 [deletedAtSec] 的文档。
  DiaryEntry tombstoned({DateTime? at}) => copyWith(deletedAtSec: 1, at: at);

  /// 从判定快照构造一条**新记入**的日记条目。
  ///
  /// [at] 是「记入这一刻」（Unix 秒），同时作为 [addedAtSec] 与 [updatedAtSec]。
  /// 合并判据从这一刻起算，所以两端各自首次记入同一条时，谁先上传谁赢，
  /// 另一方在下一轮合并时自然接纳（见 [mergedWith] 的 `>=` 规则）。
  ///
  /// 主键用 [idFor] 在两端独立算 —— 这是跨端合并的前提。
  factory DiaryEntry.fromSnapshot(DiarySnapshot snap, {required int atSec}) => DiaryEntry(
        id: idFor(provider: snap.provider, title: snap.title, year: snap.year),
        provider: snap.provider,
        workKey: snap.workKey,
        title: snap.title,
        originalTitle: snap.originalTitle,
        year: snap.year,
        kind: snap.kind,
        category: snap.category,
        genres: snap.genres,
        posterUrl: snap.posterUrl,
        posterFile: snap.posterFile,
        posterFaceX: snap.posterFaceX,
        episodeTotal: snap.episodeTotal,
        episodeWatched: snap.episodeWatched,
        completionRatio: snap.completionRatio,
        durationMs: snap.durationMs,
        maxPosMs: snap.maxPositionMs,
        addedAtSec: atSec,
        lastWatchedSec: snap.lastWatchedSec,
        updatedAtSec: atSec,
        itemIds: snap.sourceItemIds,
      );

  // -------------------------------------------------------------------
  // 主键
  // -------------------------------------------------------------------

  /// 生成稳定的主键。
  ///
  /// ## ⛔ 为什么不是 `work_key`
  ///
  /// `work_key` 是**归组键**，它会变：重扫后文件名解析可能给出不同结果、
  /// 用户手动合并作品、换一台设备重扫时由目录名推导。拿它当主键，
  /// 同一部剧在两端会变成两条日记，或者改名后对不上。
  ///
  /// ## 为什么是「标题哈希」而不是 UUID
  ///
  /// 两端**必须独立算出同一个 id** —— 这是跨端合并的前提。UUID 做不到
  /// （谁先生成谁算），而「规范化标题 + 年份 + 季」是两端都有的信息。
  ///
  /// 已知代价：用户改了作品标题 → id 变 → 会多出一条日记。这是**可接受**的
  /// （改标题是主动行为，且旧记录还在），见设计文档 §10.2。
  static String idFor({
    required String provider,
    required String title,
    int? year,
    int? season,
  }) {
    final key = '${provider.toLowerCase()}|'
        '${normalizeTitle(title)}|'
        '${year ?? ''}|'
        '${season ?? ''}';
    return _fnv1a(key);
  }

  /// 标题归一化：全角转半角、去「第 X 季 / Season X」、去标点与空白、小写。
  ///
  /// ⛔ 归一化规则**两端必须逐字一致**。差一个字符，同一部剧就会在两端
  ///    算出两个 id，而表现是「日记同步了，但同一条变成了两条」。
  static String normalizeTitle(String raw) {
    var s = raw.toLowerCase();
    final buf = StringBuffer();
    for (final rune in s.runes) {
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        buf.writeCharCode(rune - 0xFEE0); // 全角 ASCII → 半角
      } else if (rune == 0x3000) {
        buf.write(' '); // 全角空格
      } else {
        buf.writeCharCode(rune);
      }
    }
    s = buf.toString();
    s = s.replaceAll(RegExp(r'第\s*[0-9一二三四五六七八九十]+\s*[季部]'), '');
    s = s.replaceAll(RegExp(r'season\s*\d+', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[\s\-_:：·・,，.。!！?？()（）\[\]【】《》<>/\\|]'), '');
    return s;
  }

  /// FNV-1a 32 位。选它是因为**实现只有五行、跨平台稳定**，
  /// 而 `String.hashCode` 不保证跨 Dart 版本一致 —— 换一次 SDK 就可能
  /// 让所有 id 变一遍，那等于全部日记重来。
  static String _fnv1a(String s) {
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  // -------------------------------------------------------------------
  // 序列化
  // -------------------------------------------------------------------
  //
  // ⛔ 键名用**可读全称**，不用 `ProgressEntry` 那种单字母缩写。
  //
  // 那边省字段是因为「几千条 × 每 30 分钟传一次」；这里一份日记是
  // 几百条、一辈子几乎不变，体积不是问题，而它是**不可再生**的数据 ——
  // 半年后回来排查「这条为什么评分不对」时，能直接读懂文件比省 100KB 重要。

  Map<String, Object?> toJson() => {
        'id': id,
        'provider': provider,
        if (workKey != null) 'workKey': workKey,
        'title': title,
        if (originalTitle != null) 'originalTitle': originalTitle,
        if (year != null) 'year': year,
        'kind': kind,
        if (category != null) 'category': category,
        if (genres.isNotEmpty) 'genres': genres,
        if (posterUrl != null) 'posterUrl': posterUrl,
        if (posterFile != null) 'posterFile': posterFile,
        if (posterFaceX != null) 'posterFaceX': posterFaceX,
        'epTotal': episodeTotal,
        'epWatched': episodeWatched,
        'ratio': completionRatio,
        if (durationMs != null) 'durationMs': durationMs,
        if (maxPosMs != null) 'maxPosMs': maxPosMs,
        'addedAt': addedAtSec,
        if (lastWatchedSec != null) 'lastWatched': lastWatchedSec,
        if (rating != null) 'rating': rating,
        if (review != null) 'review': review,
        if (tags.isNotEmpty) 'tags': tags,
        if (favorite) 'favorite': true,
        if (deletedAtSec != null) 'deletedAt': deletedAtSec,
        'u': updatedAtSec,
        if (device.isNotEmpty) 'device': device,
        if (itemIds.isNotEmpty) 'itemIds': itemIds,
      };

  /// 从 JSON 反序列化。**任何一处不合法就返回 `null`**（整条丢弃）。
  ///
  /// ⛔ 宁可丢一条，也不要带着一个字段类型不对的条目进入合并 ——
  ///    那会让 [mergedWith] 在比较时抛，而它跑在同步路径上，
  ///    一次抛就整轮同步失败，且用户看不到任何原因。
  static DiaryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    final kind = raw['kind'];
    final u = _asInt(raw['u']);
    final addedAt = _asInt(raw['addedAt']);
    // 缺主键 / 标题 / 合并判据 / 记入时刻 —— 这几项缺任何一个都没法用。
    if (id is! String || id.isEmpty) return null;
    if (title is! String || title.isEmpty) return null;
    if (kind is! String || kind.isEmpty) return null;
    if (u == null || addedAt == null) return null;

    final epTotal = _asInt(raw['epTotal']) ?? 0;
    final epWatched = _asInt(raw['epWatched']) ?? 0;
    return DiaryEntry(
      id: id,
      provider: raw['provider'] is String ? raw['provider'] as String : '',
      workKey: raw['workKey'] is String ? raw['workKey'] as String : null,
      title: title,
      originalTitle:
          raw['originalTitle'] is String ? raw['originalTitle'] as String : null,
      year: _asInt(raw['year']),
      kind: kind,
      category: raw['category'] is String ? raw['category'] as String : null,
      genres: _asStringList(raw['genres']),
      posterUrl: raw['posterUrl'] is String ? raw['posterUrl'] as String : null,
      posterFile:
          raw['posterFile'] is String ? raw['posterFile'] as String : null,
      posterFaceX: _asDouble(raw['posterFaceX']),
      episodeTotal: epTotal < 0 ? 0 : epTotal,
      episodeWatched: epWatched < 0 ? 0 : epWatched,
      completionRatio: _asDouble(raw['ratio']) ?? 0,
      durationMs: _asInt(raw['durationMs']),
      maxPosMs: _asInt(raw['maxPosMs']),
      addedAtSec: addedAt,
      lastWatchedSec: _asInt(raw['lastWatched']),
      rating: _asInt(raw['rating']),
      review: raw['review'] is String ? raw['review'] as String : null,
      tags: _asStringList(raw['tags']),
      favorite: raw['favorite'] == true,
      deletedAtSec: _asInt(raw['deletedAt']),
      updatedAtSec: u,
      device: raw['device'] is String ? raw['device'] as String : '',
      itemIds: _asStringList(raw['itemIds']),
    );
  }

  @override
  String toString() => 'DiaryEntry($id, $title, $episodeWatched/$episodeTotal, '
      'rating=$rating, u=$updatedAtSec${isDeleted ? ', 墓碑' : ''})';

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is double && v.isFinite) return v.toInt();
    return null;
  }

  static double? _asDouble(Object? v) {
    if (v is double && v.isFinite) return v;
    if (v is int) return v.toDouble();
    return null;
  }

  static List<String> _asStringList(Object? v) {
    if (v is! List) return const <String>[];
    final out = <String>[];
    for (final e in v) {
      if (e is String && e.isNotEmpty) out.add(e);
    }
    return out;
  }

  static int? _maxInt(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a >= b ? a : b;
  }

  static double _maxRatio(double a, double b) => a >= b ? a : b;

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 文件 id 并集（保序、去重、限长）。
  ///
  /// 限长是因为它只用于「重看」这一个动作 —— 一部剧 500 集的 id 列表
  /// 没有价值，而它会随每次同步在两端之间来回传。
  static List<String> _unionIds(List<String> a, List<String> b) {
    if (b.isEmpty) return a;
    final out = <String>[...a];
    for (final id in b) {
      if (!out.contains(id)) out.add(id);
      if (out.length >= 200) break;
    }
    return out;
  }
}

/// 一整本日记：`id -> DiaryEntry`。
///
/// 与 `ProgressBook` 同构：**纯内存 + 纯合并**，落盘交给 `DiaryStore`，
/// 网盘往返交给 `DiarySyncService`。这样合并逻辑可以完全不碰 IO 地测。
class DiaryBook {
  DiaryBook([Map<String, DiaryEntry>? entries])
      : entries = entries ?? <String, DiaryEntry>{};

  /// 全部条目（**含墓碑**）。
  ///
  /// ⛔ UI 请用 [visible]，同步请用 [entries] —— 墓碑必须参与合并与上传，
  ///    否则「A 删了、B 还留着」会被 B 复活。
  final Map<String, DiaryEntry> entries;

  /// 条数（含墓碑）。
  int get length => entries.length;

  /// 展示用：过滤掉墓碑。
  Iterable<DiaryEntry> get visible =>
      entries.values.where((e) => !e.isDeleted);

  /// 有效条数（不含墓碑）。
  int get visibleCount => visible.length;

  /// 已评分的条数。
  int get ratedCount => visible.where((e) => e.isRated).length;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  DiaryEntry? operator [](String id) => entries[id];

  /// 写入 / 覆盖一条。
  void put(DiaryEntry entry) => entries[entry.id] = entry;

  /// 取一部作品对应的条目（按 `workKey` 弱匹配）。
  ///
  /// 只用于「作品详情页显示已记入标识」这一处 —— 找不到就是没记入过，
  /// 不需要回退到标题匹配（那会把同名的两部片子搞混）。
  DiaryEntry? byWorkKey(String workKey) {
    if (workKey.isEmpty) return null;
    for (final e in entries.values) {
      if (e.workKey == workKey && !e.isDeleted) return e;
    }
    return null;
  }

  /// 把 [other] 合进**自己**，返回被改变（或新增）的条目数。
  ///
  /// 返回 0 意味着两边已经一致 —— 调用方据此决定「不用上传」。
  /// 这个判据很重要：没有它的话，每 30 分钟一次的空同步都会在网盘上
  /// 走一遍「先删后传」，而那是**有失败风险**的。
  int mergeFrom(DiaryBook other) {
    var changed = 0;
    for (final e in other.entries.entries) {
      final mine = entries[e.key];
      if (mine == null) {
        entries[e.key] = e.value;
        changed++;
        continue;
      }
      final merged = mine.mergedWith(e.value);
      if (!merged.sameAs(mine)) {
        entries[e.key] = merged;
        changed++;
      }
    }
    return changed;
  }

  /// 物理清理过老的墓碑（默认 180 天）。
  ///
  /// ⛔ 180 天不是拍的：它要比**任何一台设备的离线时长**长。清理得太早，
  ///    一台半年没开的机器一上线就会把已删的条目重新推回来。
  int pruneTombstones({Duration maxAge = const Duration(days: 180), DateTime? now}) {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final cutoff = at - maxAge.inSeconds;
    final dead = <String>[];
    for (final e in entries.entries) {
      final d = e.value.deletedAtSec;
      if (d != null && d < cutoff) dead.add(e.key);
    }
    for (final k in dead) {
      entries.remove(k);
    }
    return dead.length;
  }

  String toJsonString() => jsonEncode(toJson());

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(toJsonString()));

  Map<String, Object?> toJson() => {
        'v': formatVersion,
        'entries': entries.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// 从 JSON 文本解析。**绝不抛**。
  ///
  /// 文件可能被截断（写到一半断电）、可能是别的程序放在同名位置的垃圾、
  /// 也可能是未来版本写的。任何一种都只该导致「这一次同步什么都没读到」，
  /// 而不是让应用起不来。
  static DiaryBook fromJsonString(String text) {
    try {
      final root = jsonDecode(text);
      if (root is! Map) return DiaryBook();
      return fromJson(root);
    } catch (_) {
      return DiaryBook();
    }
  }

  static DiaryBook fromJson(Map<Object?, Object?> root) {
    final out = DiaryBook();
    final raw = root['entries'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final key = e.key;
        if (key is! String || key.isEmpty) continue;
        final entry = DiaryEntry.fromJson(e.value);
        if (entry == null) continue;
        out.entries[key] = entry;
      }
    }
    return out;
  }

  static DiaryBook fromBytes(List<int> bytes) {
    try {
      return fromJsonString(utf8.decode(bytes));
    } catch (_) {
      return DiaryBook();
    }
  }

  @override
  String toString() =>
      'DiaryBook(${entries.length} 条，其中墓碑 '
      '${entries.values.where((e) => e.isDeleted).length})';

  /// 日记文件的**格式版本**，写在 JSON 顶层的 `v`。
  ///
  /// ⚠️ 与媒体库的 `schemaVersion` 不是一回事：那个是 SQLite 表结构版本，
  /// 这个是「这个 JSON 长什么样」的版本。读取端目前不校验它（字段向后兼容），
  /// 留着是为了将来真要做破坏性变更时有个抓手。
  static const int formatVersion = 1;
}
