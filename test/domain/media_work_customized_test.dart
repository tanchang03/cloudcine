import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/entities/work_poster.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「清除刮削 + 自定义」的纯规则（[MediaWork.customized]）。
///
/// ## 为什么值得一个文件
///
/// 这个方法要做的恰恰是 `copyWith` **做不到**的事：把可空字段改回 `null`。
/// `copyWith` 对每个可空字段都用 `??` 兜底（传 `null` 等于「不改」），
/// 所以「清空海报」只要有一处写漏，就会**静默地什么都不发生** ——
/// 编译通过、落库成功、界面上那张刮错的海报还挂在那儿，而用户以为自己
/// 刚刚把它清掉了。
///
/// 逐字段断言而不是抽查几个：漏掉的代价正是「看不出来」。
void main() {
  final now = DateTime(2026, 10, 2);

  /// 一条**被刮错过**的作品行：在线元数据一应俱全。
  MediaWork scraped() => MediaWork(
        key: 'show',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        category: MediaCategory.movie,
        title: '低俗小说',
        originalTitle: 'Pulp Fiction',
        year: 1994,
        overview: '两个杀手…',
        posterUrl: 'https://image.tmdb.org/wrong.jpg',
        posterFile: 'show_abc123.jpg',
        posterFaceX: 0.42,
        backdropUrl: 'https://image.tmdb.org/wrong_b.jpg',
        backdropFile: 'show_def456.jpg',
        rating: 8.9,
        genres: const ['犯罪', '剧情'],
        onlineId: 'movie/680',
        source: ScrapeSource.online,
        scrapedAt: DateTime(2026, 1, 1),
        itemCount: 12,
        totalBytes: 9000000,
        lastModifiedAt: DateTime(2026, 9, 20),
        firstSeenAt: DateTime(2026, 3, 1),
        lastPlayedAt: DateTime(2026, 9, 25),
        updatedAt: DateTime(2026, 1, 1),
      );

  MediaWork subject() => scraped().customized(
        title: '2024 演唱会现场',
        category: MediaCategory.other,
        updatedAt: now,
      );

  test('在线刮削的产物逐个清空', () {
    final w = subject();

    expect(w.originalTitle, isNull);
    expect(w.year, isNull);
    expect(w.overview, isNull);
    expect(
      w.posterUrl,
      isNull,
      reason: '这条是用户点「自定义」的**主要动机** —— 那张刮错的海报。',
    );
    expect(w.posterFile, isNull, reason: '缓存文件名是按 URL 散列的，地址清了它也必须清。');
    expect(
      w.posterFaceX,
      isNull,
      reason: '锚点必须跟着地址一起清。留着它，PosterImage 会拿上一张'
          '（视频帧的）人脸位置去裁下一张海报。',
    );
    expect(w.backdropUrl, isNull);
    expect(w.backdropFile, isNull);
    expect(w.rating, isNull);
    expect(
      w.genres,
      isEmpty,
      reason: '没被用户编辑过的类型就是刮削的产物 —— 正是要清的东西。',
    );
    expect(w.genresManual, isFalse);
    expect(w.onlineId, isNull);
    expect(
      w.scrapedAt,
      isNull,
      reason: '「刮削时刻」跟着刮削信息一起走，留着它等于说这一行还有在线来源。',
    );
  });

  test('写入用户指定的片名与分类，并把分类锁住', () {
    final w = subject();

    expect(w.title, '2024 演唱会现场');
    expect(w.category, MediaCategory.other);
    expect(
      w.categoryManual,
      isTrue,
      reason: '分类是用户在对话框里选的。不置这个标记，下次重扫 / 重刮'
          '会被 MediaCategoryGuesser 用目录名或 kind 改写 —— '
          '用户看到的是「我设的「其他」过几天自己变回「剧集」了」。',
    );
  });

  test('B：分类没动就不新加锁 —— 「只想清数据」不该把错分类冻死', () {
    // 对话框预填当前分类（scraped() 是 movie）。用户只清在线信息、没改分类 →
    // 不该把它锁住，否则之后手动重刮也改不动（原 bug 现场）。
    final w = scraped().customized(
      title: '低俗小说',
      category: MediaCategory.movie, // 与 scraped() 的 category 相同
      updatedAt: now,
    );

    expect(
      w.categoryManual,
      isFalse,
      reason: '用户没在这个对话框里表达「我要这个分类」—— 别顺手锁住它。',
    );
  });

  test('B：真的改了分类才锁', () {
    final w = scraped().customized(
      title: '低俗小说',
      category: MediaCategory.documentary, // 与 movie 不同
      updatedAt: now,
    );

    expect(
      w.categoryManual,
      isTrue,
      reason: '用户主动选了另一个分类 → 这是明确的指定，锁住；'
          '后续重扫 / 自动刮削不许改写。',
    );
  });

  test('B：此前已有的锁，在「没改分类」时原样保留', () {
    final w = scraped()
        .copyWith(categoryManual: true)
        .customized(
          title: '低俗小说',
          category: MediaCategory.movie, // 与当前相同
          updatedAt: now,
        );

    expect(
      w.categoryManual,
      isTrue,
      reason: '用户更早的明确指定，不该被一次「只为清数据」的操作悄悄解锁。',
    );
  });

  test('来源标记成「手动修改」—— 不是「文件名解析」', () {
    final w = subject();

    expect(
      w.source,
      ScrapeSource.manual,
      reason: '`local` 的含义是「这一行是文件名解析的产物」，于是下一次扫描时'
          '`mergeWorkForUpsert` 会拿文件名解析出的标题**覆盖掉用户刚敲进去的'
          '片名**。`manual` 才落进那边的保护分支。',
    );
    expect(w.source.label, '手动修改');
    expect(
      w.isScraped,
      isTrue,
      reason: '这个标记的含义是「这条信息不是文件名猜的」，用户写死的当然算。'
          '详情页据此把来源 chip 画成绿色、图标用 cloud_done。',
    );
  });

  test('与刮削无关的字段原样保留', () {
    final w = subject();

    expect(w.key, 'show');
    expect(w.provider, DriveProvider.quark);
    expect(w.kind, MediaKind.episode);
    expect(
      w.itemCount,
      12,
      reason: '漏抄这一列的话它会变成构造器的默认值 0 —— 卡片副标题上的'
          '「12 集」直接消失，而没有任何报错。',
    );
    expect(w.totalBytes, 9000000);
    expect(w.lastModifiedAt, DateTime(2026, 9, 20));
    expect(
      w.firstSeenAt,
      DateTime(2026, 3, 1),
      reason: '它决定「最近添加」排序。被刷成 null 的话，这部作品会从'
          '「最近添加」里消失。',
    );
    expect(w.lastPlayedAt, DateTime(2026, 9, 25));
    expect(w.updatedAt, now);
  });

  test('有网盘缩略图 → 清掉刮错的海报后回落到它', () {
    final w = scraped().customized(
      title: '2024 演唱会现场',
      category: MediaCategory.other,
      updatedAt: now,
      drivePoster: const WorkPoster(
        url: 'https://drive-pc.quark.cn/1/clouddrive/file/video/thumbnail?fid=x',
        faceX: 0.31,
      ),
    );

    expect(
      w.posterUrl,
      'https://drive-pc.quark.cn/1/clouddrive/file/video/thumbnail?fid=x',
      reason: '用户点「自定义」是为了**去掉刮错的那张**，不是让这部作品'
          '从此没有封面。网盘缩略图一直在库里（MediaItem.thumbUrl），'
          '清成 null 的话整墙会变成片名首字的灰块。',
    );
    expect(w.posterFaceX, 0.31, reason: '锚点跟着这一张图一起回来。');
    expect(
      w.posterFile,
      isNull,
      reason: '换了图就必须清缓存文件名：`PosterCache.pathFor` 见 '
          '`knownFile` 存在就直接返回旧文件，留着它封面会显示成前一张。',
    );
    expect(w.backdropUrl, isNull, reason: '背景图没有网盘来源，该清还是清。');
  });

  test('清之前用的本来就是网盘缩略图 → 缓存文件名留着', () {
    const thumb = 'https://drive-pc.quark.cn/thumb?fid=x';
    final w = scraped()
        .copyWith(
          posterUrl: thumb,
          posterFile: 'show_abc123.jpg',
          posterFaceX: 0.31,
        )
        .customized(
          title: '2024 演唱会现场',
          category: MediaCategory.other,
          updatedAt: now,
          drivePoster: const WorkPoster(url: thumb, faceX: 0.31),
        );

    expect(
      w.posterFile,
      'show_abc123.jpg',
      reason: '地址没变就是同一张图，缓存文件仍然有效 —— 清掉它会让本来'
          '秒出的封面重新下一遍（网盘缩略图还得带 Cookie）。',
    );
  });

  test('没有网盘缩略图 → 封面真的清空（不是「清了个寂寞」）', () {
    final w = scraped().customized(
      title: '2024 演唱会现场',
      category: MediaCategory.other,
      updatedAt: now,
      drivePoster: null,
    );

    expect(w.posterUrl, isNull);
    expect(w.posterFaceX, isNull);
  });

  test('用户手敲并锁住的类型标签原样保留（连同锁一起）', () {
    // 用户先在详情页「编辑类型」里挑了类型 —— 那一步会置 `genresManual`。
    final w = scraped()
        .copyWith(genres: const ['真人秀', '脱口秀'], genresManual: true)
        .customized(
          title: '2024 演唱会现场',
          category: MediaCategory.other,
          updatedAt: now,
        );

    expect(
      w.genres,
      const ['真人秀', '脱口秀'],
      reason: '`mergeWorkForUpsert` 里那条 `genresManual` 分支排在保护模式'
          '**之前** —— 用户手敲的类型连重刮削都不许覆盖。「清在线信息」'
          '却把它整份抹掉的话，用户挑好的标签会凭空消失。',
    );
    expect(
      w.genresManual,
      isTrue,
      reason: '漏抄这个标记等于**偷偷解锁**：标签这次是保住了，可下一次'
          '刮削会把它们整份覆盖 —— 用户看到的是「我编辑过的类型自己变了」。',
    );
  });
}
