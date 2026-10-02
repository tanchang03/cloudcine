import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/widgets/customize_work_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「自定义作品信息」对话框。
///
/// ## 为什么要一个 widget 测试
///
/// 这条路上**每一层都已经有测试了**：清字段的规则在 `MediaWork.customized`、
/// 不被自动刮削覆盖的守卫在 `mergeWorkForUpsert`、整行写库在
/// `customizeWork`。剩下唯一没被覆盖的是**接线**：对话框有没有把用户敲进去
/// 的字真的递到那一层。
///
/// 而它坏掉的样子特别难查 —— 点「清除并保存」，弹窗正常关闭，库里什么都
/// 没变，**没有任何报错**。用户会以为是自己没点到。
void main() {
  final now = DateTime(2026, 10, 2);

  /// 一条**被刮错过**的作品：片名与分类都不是用户要的。
  MediaWork scraped() => MediaWork(
        key: 'w',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '低俗小说',
        category: MediaCategory.movie,
        year: 1994,
        overview: '两个杀手…',
        posterUrl: 'https://image.tmdb.org/wrong.jpg',
        rating: 8.9,
        genres: const ['犯罪'],
        onlineId: 'movie/680',
        source: ScrapeSource.online,
        scrapedAt: DateTime(2026, 1, 1),
        itemCount: 3,
        updatedAt: now,
      );

  late InMemoryMediaRepository repo;

  /// 挂一棵最小的树，并点开对话框。
  Future<void> open(WidgetTester tester) async {
    repo = InMemoryMediaRepository();
    await repo.upsertWorks([scraped()], now: now);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [mediaRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => CustomizeWorkDialog.show(context, scraped()),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('打开时预填当前的片名与分类', (tester) async {
    await open(tester);

    expect(find.text('自定义作品信息'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '低俗小说',
      reason: '用户多半只改一处（片名对了但分类不对，或反过来），'
          '从空白开始会逼他重敲另一处。',
    );
  });

  testWidgets('改片名 + 换分类 → 保存后库里那一行变成「手动修改」', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), '2024 演唱会现场');

    // 打开分类下拉，选「其他」。
    await tester.tap(find.byType(DropdownButton<MediaCategory>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('其他').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('清除并保存'));
    await tester.pumpAndSettle();

    expect(find.text('自定义作品信息'), findsNothing, reason: '保存成功就该关掉。');

    final saved = await repo.workByKey('w');
    expect(saved!.title, '2024 演唱会现场');
    expect(saved.category, MediaCategory.other);
    expect(saved.categoryManual, isTrue);
    expect(saved.source, ScrapeSource.manual);
    expect(
      saved.posterUrl,
      isNull,
      reason: '刮错的那张海报必须被清掉 —— 这是用户点这个按钮的主要动机。',
    );
    expect(saved.rating, isNull);
    expect(saved.genres, isEmpty);
    expect(saved.itemCount, 3, reason: '文件数与刮削无关，原样保留。');
  });

  testWidgets('片名为空 → 就地提示，一个字都不写库', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('清除并保存'));
    await tester.pumpAndSettle();

    expect(find.text('片名不能为空。'), findsOneWidget);
    expect(
      find.text('自定义作品信息'),
      findsOneWidget,
      reason: '留在原地让用户改，而不是关掉对话框让他从头再来。',
    );

    final saved = await repo.workByKey('w');
    expect(saved!.title, '低俗小说');
    expect(saved.source, ScrapeSource.online, reason: '没通过校验就不该有任何副作用。');
  });

  testWidgets('取消 → 不写库', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), '不该被保存');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('自定义作品信息'), findsNothing);
    final saved = await repo.workByKey('w');
    expect(saved!.title, '低俗小说');
    expect(saved.source, ScrapeSource.online);
  });
}
