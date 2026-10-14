/// 播放进度的**独立存储模型** —— 纯数据 + 纯合并，不碰 IO。
///
/// ## 为什么要有它（而不继续用 `media_items` 的三列）
///
/// 进度原先就存在媒体库索引库 `cloudcine.sqlite` 的 `media_items` 里
/// （`resume_position_ms` / `max_position_ms` / `last_played_at`）。那个位置
/// 有两个**必然丢数据**的缺口：
///
///   1. **清空索引库**（设置页「清空索引库」）删的正是 `media_items` —— 进度
///      跟着一起没了；
///   2. **恢复媒体库备份**（`.ccbak`）装的是 `cloudcine.sqlite` 的**原始字节**，
///      恢复 = 整文件替换 —— 本地进度被备份里那份旧进度覆盖。
///
/// 这两件事都是用户**主动**做的、而且都合理（重建索引 / 换机器），所以不能靠
/// 「劝用户别做」来规避。唯一的出路是**把进度挪出那个文件**。
///
/// ## 它同时是跨端同步的载荷
///
/// 进度天然是**逐条**的（一条 = 一个文件看到哪儿了），而媒体库同步是**整份**
/// 的 LWW。用整份 LWW 同步进度有一个立刻能撞上的坏处：A 机器在看第 1 集、
/// B 机器在看第 2 集，两边各推一次整份，后推的那份会把对方那一集抹掉。
///
/// 所以这里按**条目**做 LWW（[ProgressEntry.mergedWith]），而
/// [ProgressBook.mergeFrom] 只把「远程更权威」的那些条目换过来。
///
/// ## ⛔ 单位一律是「毫秒 / Unix 秒」，与库里那三列逐字对齐
///
///   * `resumeMs` / `maxMs` —— **毫秒**（库里是 `resume_position_ms` /
///     `max_position_ms`）；
///   * `playedAtSec` / `updatedAtSec` —— **Unix 秒**（库里的 `last_played_at`
///     是 drift 的 `DateTimeColumn`，口径就是秒）。
///
/// 混用毫秒和秒是这类字段最容易犯、又**最不容易被发现**的错：写成毫秒的
/// 「秒」列在 1970 年附近，排序看着「有值」，只是永远垫底。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 一个媒体项的进度条目。
///
/// 三个业务字段与库里的三列一一对应，[updatedAtSec] 是**同步用的**第四项。
class ProgressEntry {
  const ProgressEntry({
    this.resumeMs,
    this.maxMs,
    this.playedAtSec,
    required this.updatedAtSec,
  });

  /// 续播点（毫秒）。`null` = 没有可续的点（没播过 / 已看完 / 用户关了
  /// 「记住播放进度」）。语义与 `media_items.resume_position_ms` 完全一致。
  final int? resumeMs;

  /// 历史最大播放位置（毫秒，**只增不减**）。`null` = 从没播过。
  /// 语义与 `media_items.max_position_ms` 完全一致。
  final int? maxMs;

  /// 最后一次播放时刻（Unix 秒）。`null` = 没播过。
  ///
  /// ⚠️ 它同时是「已读回执」：用户在列表里**点开**一集（哪怕只看了 3 秒）
  /// 就会写它，剧集行的 `■ NEW` 与追剧角标都靠它消失。见
  /// `follow_read.dart`。
  final int? playedAtSec;

  /// 这一条**最后一次被写入**的时刻（Unix 秒）。
  ///
  /// ## 为什么必须单独存一份，而不是复用 [playedAtSec]
  ///
  /// 两者在「播放中」高度重合（每 10 秒一次进度回报会同时推进它们），
  /// 但**不是同一件事**：
  ///
  ///   * [playedAtSec] 是**业务语义**（什么时候看的），要跟着备份跨端走；
  ///   * [updatedAtSec] 是**合并语义**（哪一份更新），只服务于 LWW。
  ///
  /// 分开的直接好处：「看完清续播点」这一步只改 [resumeMs] 与
  /// [updatedAtSec]，不会把 [playedAtSec] 往前推 —— 否则「最近播放」的排序
  /// 会被一次清理动作扰动。
  final int updatedAtSec;

  /// 三个业务字段全空 = 这一条什么信息都没有。
  bool get isEmpty => resumeMs == null && maxMs == null && playedAtSec == null;

  /// 只有「已读」而没有「位置」—— 用户在列表里点开过，但没播够 10 秒。
  ///
  /// 追剧的 NEW 判定要区分「点过」与「看过」，见 `follow_read.dart`。
  bool get isReadOnly =>
      playedAtSec != null && resumeMs == null && maxMs == null;

  /// 与 [other] 合并，返回**胜出**的那一份。
  ///
  /// ## 规则（三条，缺一条就会丢进度）
  ///
  ///   1. **[updatedAtSec] 大的一方赢**，拿走 `resumeMs` 与 `playedAtSec`；
  ///      相等时**保留自己**（`>=`）—— 这样两台设备在同一秒各写一次时，
  ///      结果在两台机器上是**同一个**（都保留自己的那份，而两份在这一刻
  ///      本来就等价），不会来回抖。
  ///   2. **[maxMs] 取两边的较大值**，与谁赢无关。它是「历史最远位置」，
  ///      **只增不减**是它的定义 —— 用 LWW 会让「另一台机器看得更远」
  ///      这件事被一次较晚的、位置较浅的写入抹掉，而用户看到的是进度条倒退。
  ///   3. **[playedAtSec] 也取较大值**，理由同上：「最近播放」不该倒退。
  ///
  /// ⛔ 规则 2 / 3 与规则 1 **方向相反**是刻意的：可加合的量取并集，
  ///    有状态的量取 LWW。把 `maxMs` 也交给 LWW 是最容易犯的那个错。
  ProgressEntry mergedWith(ProgressEntry other) {
    final selfWins = updatedAtSec >= other.updatedAtSec;
    final winner = selfWins ? this : other;
    return ProgressEntry(
      resumeMs: winner.resumeMs,
      maxMs: _maxOrNull(maxMs, other.maxMs),
      playedAtSec: _maxOrNull(playedAtSec, other.playedAtSec),
      updatedAtSec: winner.updatedAtSec,
    );
  }

  /// 这一条与 [other] 是否**内容相同**（含 [updatedAtSec]）。
  ///
  /// 合并后用它判断「要不要回写 / 要不要上传」—— 内容没变就不要动网盘。
  bool sameAs(ProgressEntry other) =>
      resumeMs == other.resumeMs &&
      maxMs == other.maxMs &&
      playedAtSec == other.playedAtSec &&
      updatedAtSec == other.updatedAtSec;

  /// 序列化成一个紧凑的 JSON 对象（`null` 的字段直接省掉）。
  ///
  /// 省字段不是为了好看：一份进度文件动辄几千条，每条少三个键就是几百 KB
  /// 的差别，而这个文件每 30 分钟就要传一次。
  Map<String, Object?> toJson() => {
        if (resumeMs != null) 'r': resumeMs,
        if (maxMs != null) 'm': maxMs,
        if (playedAtSec != null) 'p': playedAtSec,
        'u': updatedAtSec,
      };

  /// 从 JSON 反序列化。**任何一处不合法就返回 `null`**（整条丢弃）。
  ///
  /// ⛔ 宁可丢一条，也不要带着一个「字段类型不对」的条目进入合并 ——
  ///    那会让 [mergedWith] 在比较时抛，而它跑在同步路径上，
  ///    一次抛就整轮同步失败，且用户看不到任何原因。
  static ProgressEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final u = _asInt(raw['u']);
    if (u == null) return null; // 没有合并判据的条目无法参与 LWW，只能丢。
    return ProgressEntry(
      resumeMs: _asInt(raw['r']),
      maxMs: _asInt(raw['m']),
      playedAtSec: _asInt(raw['p']),
      updatedAtSec: u,
    );
  }

  @override
  String toString() =>
      'ProgressEntry(resume=$resumeMs, max=$maxMs, played=$playedAtSec, '
      'updated=$updatedAtSec)';

  static int? _asInt(Object? v) {
    if (v is int) return v;
    // JSON 里数字可能被解析成 double（`1e3` / `1000.0`）。
    if (v is double && v.isFinite) return v.toInt();
    return null;
  }

  static int? _maxOrNull(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a >= b ? a : b;
  }
}

/// 一部作品的**片头 / 片尾**记录（进度文件 v2）。
///
/// ## 为什么它在**进度文件**里，而不是只在 `media_works`
///
/// `media_works.intro_start_ms` 那几列**会**随 `.ccbak` 走，但那条通道是
/// **手动**的（用户得去点「上传备份 / 从网盘恢复」）。而片头片尾是**播放侧**
/// 的数据：用户在这台机器上标了一次，另一台机器上立刻该生效。所以它跟播放
/// 进度走同一条**静默**通道（每 30 分钟一次 + 退出播放器时一次）。
///
/// `media_works` 那几列因此退化成**物化投影**（与进度三列同一种角色）：
/// 播放器与 SQL 查询读它，而真源是这个文件。
///
/// ## ⛔ 两组字段、两个时间戳
///
/// 手标与学习是**两条独立支路**（`media_works` 里也是两组列），所以合并时
/// 也各判各的：
///
/// | 组 | 字段 | 判据 |
/// |---|---|---|
/// | 手标 | [introStartMs] / [introEndMs] / [outroOffsetMs] | [manualUpdatedAtSec] |
/// | 学习 | [learnedIntroEndMs] / [learnedOutroOffsetMs] / [learnedSamples] | [learnedUpdatedAtSec] |
///
/// ⛔ 合成一个时间戳的话，「A 机手标了片头、B 机学出了片尾」会变成互相覆盖
///    —— 而两台机器都显示同步成功，用户只会觉得「有时候同步丢东西」。
///
/// ## ⛔ 单位
///
/// 三个毫秒字段一律**毫秒**（与 `media_works` 的列逐字对齐）；
/// 两个时间戳一律 **Unix 秒**（与 [ProgressEntry.updatedAtSec] 同口径）。
/// 片尾存的是**距末尾的偏移**，不是绝对时间 —— 各集片长不同，绝对时间跨集
/// 不可比（与学习那条路同一条理由）。
class WorkSkipEntry {
  const WorkSkipEntry({
    this.introStartMs,
    this.introEndMs,
    this.outroOffsetMs,
    this.manualUpdatedAtSec = 0,
    this.learnedIntroEndMs,
    this.learnedOutroOffsetMs,
    this.learnedSamples = 0,
    this.learnedUpdatedAtSec = 0,
  });

  /// 手标片头起点（毫秒）。`null` = 没标。
  final int? introStartMs;

  /// 手标片头终点（毫秒）。与 [introStartMs] 成对，半条当没有。
  final int? introEndMs;

  /// 手标**片尾偏移**（毫秒，距末尾）。`null` = 没标。
  ///
  /// ⛔ 存偏移不存绝对时间：用户在第 1 集标「41:30」，第 2 集片长不同，
  ///    绝对时间搬过去就错了；而「离结尾还有 90 秒」是同一件事。
  final int? outroOffsetMs;

  /// 手标那一组最后一次被写入（Unix 秒）。`0` = 从没手标过。
  final int manualUpdatedAtSec;

  /// 学习出的片头**终点**（毫秒）。起点恒为 `0`（片头总在开头），不单独存。
  final int? learnedIntroEndMs;

  /// 学习出的片尾偏移（毫秒，距末尾）。
  final int? learnedOutroOffsetMs;

  /// 学习结论背后的样本数。纯说明性数字，不参与合并判据。
  final int learnedSamples;

  /// 学习那一组最后一次被写入（Unix 秒）。`0` = 从没学过。
  final int learnedUpdatedAtSec;

  /// 手标那一组有没有内容。
  bool get hasManual => introStartMs != null || introEndMs != null || outroOffsetMs != null;

  /// 学习那一组有没有内容。
  bool get hasLearned => learnedIntroEndMs != null || learnedOutroOffsetMs != null;

  /// 两组都空 = 这一条什么信息都没有（落盘与上传时直接丢掉）。
  bool get isEmpty => !hasManual && !hasLearned;

  /// 与 [other] 合并，返回**胜出**的那一份。
  ///
  /// ⛔ 两组**各判各的**（见类文档）。组内是**整体** LWW，不是逐字段 ——
  ///    一次「清除」与一次「设定」都是整组替换，逐字段合并会让清除动作
  ///    只清掉一半，而界面上看起来是「清不干净」。
  ///
  /// 相等时**保留自己**（`>=`）：两台设备在同一秒各写一次时，结果在两台
  /// 机器上是同一个，不会来回抖（与 [ProgressEntry.mergedWith] 同一条）。
  WorkSkipEntry mergedWith(WorkSkipEntry other) {
    final manualWins = manualUpdatedAtSec >= other.manualUpdatedAtSec;
    final m = manualWins ? this : other;
    final learnedWins = learnedUpdatedAtSec >= other.learnedUpdatedAtSec;
    final l = learnedWins ? this : other;
    return WorkSkipEntry(
      introStartMs: m.introStartMs,
      introEndMs: m.introEndMs,
      outroOffsetMs: m.outroOffsetMs,
      manualUpdatedAtSec: m.manualUpdatedAtSec,
      learnedIntroEndMs: l.learnedIntroEndMs,
      learnedOutroOffsetMs: l.learnedOutroOffsetMs,
      learnedSamples: l.learnedSamples,
      learnedUpdatedAtSec: l.learnedUpdatedAtSec,
    );
  }

  /// 内容是否与 [other] 完全相同（含两个时间戳）。合并后据此判断要不要上传。
  bool sameAs(WorkSkipEntry other) =>
      introStartMs == other.introStartMs &&
      introEndMs == other.introEndMs &&
      outroOffsetMs == other.outroOffsetMs &&
      manualUpdatedAtSec == other.manualUpdatedAtSec &&
      learnedIntroEndMs == other.learnedIntroEndMs &&
      learnedOutroOffsetMs == other.learnedOutroOffsetMs &&
      learnedSamples == other.learnedSamples &&
      learnedUpdatedAtSec == other.learnedUpdatedAtSec;

  /// 序列化成紧凑 JSON（`null` 字段与 `0` 时间戳都省掉）。
  ///
  /// ⛔ 键名短是为了体积：这个文件每 30 分钟传一次，而作品条数与剧集数同级。
  Map<String, Object?> toJson() => {
        if (introStartMs != null) 'is': introStartMs,
        if (introEndMs != null) 'ie': introEndMs,
        if (outroOffsetMs != null) 'oo': outroOffsetMs,
        if (manualUpdatedAtSec > 0) 'mu': manualUpdatedAtSec,
        if (learnedIntroEndMs != null) 'le': learnedIntroEndMs,
        if (learnedOutroOffsetMs != null) 'lo': learnedOutroOffsetMs,
        if (learnedSamples > 0) 'ls': learnedSamples,
        if (learnedUpdatedAtSec > 0) 'lu': learnedUpdatedAtSec,
      };

  /// 从 JSON 反序列化。
  ///
  /// ⛔ **两组都空的条目一律丢掉**（[isEmpty]）：它不带任何信息，留着只会
  ///    一直参与合并与上传，让「两边其实都没东西」也判定为有差异。
  ///
  /// ⚠️ 与 [ProgressEntry.fromJson] 不同，这里**不要求时间戳非零**。
  ///    理由：手标那一组可能来自 `MediaRepository.skipMarkerSnapshot` 的
  ///    播种，而 `media_works` 上**没有手标时刻这一列** —— 那批记录的时间戳
  ///    只能是 `0`。丢掉它们等于「老用户升级前标好的片头永远同步不出去」，
  ///    而那正是播种要解决的问题。
  ///
  ///    `0` 的语义是「有内容、但没有时间依据」：合并时它**必输给任何带
  ///    时间戳的一组**（[mergedWith] 的 `>=` 判据），两台设备都只有播种
  ///    记录时各自保留自己 —— 这个窄窗口已知且接受（要两台机器都为同一部
  ///    作品留着手标、且值不同；任一台重新标一次就会盖上真时间戳并胜出）。
  static WorkSkipEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final entry = WorkSkipEntry(
      introStartMs: _asInt(raw['is']),
      introEndMs: _asInt(raw['ie']),
      outroOffsetMs: _asInt(raw['oo']),
      manualUpdatedAtSec: _asInt(raw['mu']) ?? 0,
      learnedIntroEndMs: _asInt(raw['le']),
      learnedOutroOffsetMs: _asInt(raw['lo']),
      learnedSamples: _asInt(raw['ls']) ?? 0,
      learnedUpdatedAtSec: _asInt(raw['lu']) ?? 0,
    );
    return entry.isEmpty ? null : entry;
  }

  @override
  String toString() =>
      'WorkSkipEntry(手标 $introStartMs→$introEndMs / 距末尾 $outroOffsetMs @$manualUpdatedAtSec, '
      '学习 →$learnedIntroEndMs / 距末尾 $learnedOutroOffsetMs ($learnedSamples 样本) '
      '@$learnedUpdatedAtSec)';

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is double && v.isFinite) return v.toInt();
    return null;
  }
}

/// 全量进度：`itemId -> ProgressEntry`。
///
/// `itemId` 的口径与 `media_items.id` **逐字一致**（`provider:fileId`），
/// 这是它能与媒体库对上的唯一依据。
///
/// ## ⛔ 为什么键用 `provider:fileId` 而不是路径或文件名
///
/// 跨端同步要求「两台设备对同一个文件算出同一个键」。文件名会被改、目录会
/// 被移动，而 `fileId` 是网盘侧给文件分配的稳定 id —— 只要文件还在网盘上，
/// 两边算出来就是同一个字符串。
///
/// 代价是**删掉再重新上传同一个文件**会换一个 `fileId`，那条进度就找不回来
/// （它变成一条永不匹配的孤儿）。这个代价是接受的：另一种做法（按路径）
/// 在改目录名时丢得更频繁，而重新上传本来就是「换了一个文件」。
class ProgressBook {
  ProgressBook([
    Map<String, ProgressEntry>? items,
    Map<String, WorkSkipEntry>? works,
  ])  : items = items ?? <String, ProgressEntry>{},
        works = works ?? <String, WorkSkipEntry>{};

  /// 全部条目。**直接持有这个 Map**（不做防御性拷贝）：它只在本文件与
  /// `ProgressStore` 之间流转，拷贝一份几千条的 Map 是白花的开销。
  final Map<String, ProgressEntry> items;

  /// 作品级的片头 / 片尾记录：`media_works.key -> WorkSkipEntry`（v2 新增）。
  ///
  /// 键的口径与 `media_works.key` **逐字一致**（`provider:groupId`），
  /// 与 [items] 的 `provider:fileId` 不是一回事 —— 别互相塞。
  final Map<String, WorkSkipEntry> works;

  /// 条目数。
  int get length => items.length;

  /// 作品级记录数。
  int get workCount => works.length;

  bool get isEmpty => items.isEmpty && works.isEmpty;

  /// 取一条；没有返回 `null`。
  ProgressEntry? operator [](String itemId) => items[itemId];

  /// 写入 / 覆盖一条。
  void operator []=(String itemId, ProgressEntry entry) =>
      items[itemId] = entry;

  /// 写入 / 覆盖一条（与 `[]=` 等价，具名形式更好读）。
  void put(String itemId, ProgressEntry entry) => items[itemId] = entry;

  /// 取一部作品的片头 / 片尾记录；没有返回 `null`。
  WorkSkipEntry? skipFor(String workKey) => works[workKey];

  /// 写入 / 覆盖一部作品的片头 / 片尾记录。
  ///
  /// ⛔ 内容是空（两组都空）时**直接删掉这一条**，而不是留一个空壳：
  ///    空壳会一直参与合并与上传，让「两边其实都没东西」也判定为有差异。
  void putSkip(String workKey, WorkSkipEntry entry) {
    if (entry.isEmpty) {
      works.remove(workKey);
    } else {
      works[workKey] = entry;
    }
  }

  /// 有没有条目。
  bool get isNotEmpty => items.isNotEmpty || works.isNotEmpty;

  /// 把 [other] 合进**自己**，返回**被改变（或新增）的条目数**。
  ///
  /// 返回 0 意味着两边已经一致 —— 调用方据此决定「不用上传」。
  /// 这个判据很重要：没有它的话，每 30 分钟一次的空同步都会在网盘上
  /// 走一遍「先删后传」，而那是**有失败风险**的（见
  /// `LibraryBackupService.uploadFileToBackupDir` 的文档）。
  ///
  /// ⛔ 两段（[items] / [works]）都算进返回值：只算前者的话，一次「只改了
  ///    片头标记」的同步会判定为「无需上传」，用户看到的是标记同步不过去。
  int mergeFrom(ProgressBook other) {
    var changed = 0;
    for (final e in other.items.entries) {
      final mine = items[e.key];
      if (mine == null) {
        items[e.key] = e.value;
        changed++;
        continue;
      }
      final merged = mine.mergedWith(e.value);
      if (!merged.sameAs(mine)) {
        items[e.key] = merged;
        changed++;
      }
    }
    for (final e in other.works.entries) {
      final mine = works[e.key];
      if (mine == null) {
        works[e.key] = e.value;
        changed++;
        continue;
      }
      final merged = mine.mergedWith(e.value);
      if (!merged.sameAs(mine)) {
        works[e.key] = merged;
        changed++;
      }
    }
    return changed;
  }

  /// 序列化为 JSON 文本。
  String toJsonString() => jsonEncode(toJson());

  /// 序列化为 UTF-8 字节（上传网盘用）。
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(toJsonString()));

  Map<String, Object?> toJson() => {
        'v': formatVersion,
        'items': items.map((k, v) => MapEntry(k, v.toJson())),
        // ⛔ `works` 为空时**整个键省掉**：绝大多数用户的绝大多数时候这一
        //    段是空的，而这一项每 30 分钟就要序列化 + 上传一次。
        //    读回来时缺键 = 空（见 [fromJson]），两端都认。
        if (works.isNotEmpty)
          'works': works.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// 从 JSON 文本解析。
  ///
  /// ⛔ **绝不抛**。文件可能被截断（写入一半断电）、可能是别的程序放在
  /// 同名位置的垃圾、也可能是未来版本写的、字段更多。任何一种都只该导致
  /// 「这一次同步什么都没读到」，而不是让应用启动失败。
  ///
  /// 单条不合法只丢那一条（见 [ProgressEntry.fromJson]），整个文件不合法
  /// 才退回空书。
  static ProgressBook fromJsonString(String text) {
    try {
      final root = jsonDecode(text);
      if (root is! Map) return ProgressBook();
      return fromJson(root);
    } catch (_) {
      return ProgressBook();
    }
  }

  /// 从已解析的 JSON 对象构造。同样不抛。
  ///
  /// ⛔ `items` 缺失 ⇒ 空书；`works` 缺失 ⇒ 空映射（**不是**空书）——
  ///    v1 的文件里没有 `works`，那是合法的老文件，它的 items 必须照读。
  static ProgressBook fromJson(Map<Object?, Object?> root) {
    final out = ProgressBook();
    final raw = root['items'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final key = e.key;
        if (key is! String || key.isEmpty) continue;
        final entry = ProgressEntry.fromJson(e.value);
        if (entry == null) continue;
        out.items[key] = entry;
      }
    }
    final rawWorks = root['works'];
    if (rawWorks is Map) {
      for (final e in rawWorks.entries) {
        final key = e.key;
        if (key is! String || key.isEmpty) continue;
        final entry = WorkSkipEntry.fromJson(e.value);
        if (entry == null) continue;
        out.works[key] = entry;
      }
    }
    return out;
  }

  /// 从字节解析（下载来的文件）。
  static ProgressBook fromBytes(List<int> bytes) {
    try {
      return fromJsonString(utf8.decode(bytes));
    } catch (_) {
      return ProgressBook();
    }
  }

  @override
  String toString() => 'ProgressBook(${items.length} 条 + ${works.length} 部作品)';

  /// 进度文件的**格式版本**，写在 JSON 顶层的 `v`。
  ///
  /// ⚠️ 与媒体库的 `schemaVersion`（19）**不是一回事**，别混：
  ///   * 那个是「SQLite 表结构」的版本，改它要两端同改 DDL；
  ///   * 这个是「这个 JSON 长什么样」的版本，两端只在**字段增删**时才动它。
  ///
  /// 读取端目前**不校验**这个值（字段是向后兼容的：认不出来的键直接忽略，
  /// 缺的键按 `null` 处理），留着是为了将来真要做破坏性变更时有个抓手。
  ///
  ///   * **v1** —— 只有 `items`；
  ///   * **v2** —— 多了 `works`（作品级片头 / 片尾，见 [WorkSkipEntry]）。
  ///     ⛔ v1 的读取端（旧版本应用）会**忽略** `works` 并照常写回 ——
  ///     于是它上传的那一份会把作品级记录**丢掉**。这是接受的：那一端
  ///     本来就不认识这个功能，而它下一次同步会从另一端再合回来。
  static const int formatVersion = 2;
}
