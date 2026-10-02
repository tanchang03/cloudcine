import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/widgets/genre_edit_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「编辑类型标签」对话框。
///
/// ## 为什么要一个 widget 测试
///
/// 这一条路上每一层都单独有测试了：保护规则在 `mergeWorkForUpsert`
/// （见 `test/data/work_genres_manual_test.dart`）、写库在 `setWorkGenres`。
/// 剩下唯一没被覆盖的是**接线**：用户敲进去的类型有没有真的递到那一层。
///
/// 而它坏掉的样子和「自定义作品信息」那边一模一样 —— 点「保存」，弹窗
/// 正常关闭，库里一个字没变，**没有任何报错**。用户只会以为是自己没点到。
void main() {
  final now = DateTime(2026, 10, 2);

  MediaWork work({
    List<String> genres = const ['犯罪'],
    bool genresManual = false,
  }) =>
      MediaWork(
        key: 'w',
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: '标题',
        category: MediaCategory.movie,
        genres: genres,
        genresManual: genresManual,
        source: ScrapeSource.online,
        updatedAt: now,
      );

  late InMemoryMediaRepository repo;

  /// 挂一棵最小的树，并点开对话框。
  Future<void> open(WidgetTester tester, {MediaWork? target}) async {
    final w = target ?? work();
    repo = InMemoryMediaRepository();
    await repo.upsertWorks([w], now: now);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [mediaRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => GenreEditDialog.show(context, w),
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

  testWidgets('打开时列出当前类型', (tester) async {
    await open(tester, target: work(genres: const ['犯罪', '剧情']));

    expect(find.text('编辑类型标签'), findsOneWidget);
    expect(find.text('犯罪'), findsOneWidget);
    expect(find.text('剧情'), findsOneWidget);
  });

  testWidgets('输入框敲一个 → 加进当前类型', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), '动画');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 「动画」本来也在常用列表里，但加进当前类型后就从常用列表里去掉了，
    // 所以这里恰好只剩一个。
    expect(find.text('动画'), findsOneWidget);
  });

  testWidgets('点常用类型 chip → 直接加进去', (tester) async {
    await open(tester);

    final chip = find.text('动画');
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(find.text('动画'), findsOneWidget);
  });

  testWidgets('重复添加不会出现两个，并说明为什么没反应', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), '动画');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '动画');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(find.text('动画'), findsOneWidget);
    expect(
      find.text('「动画」已经在列表里了。'),
      findsOneWidget,
      reason: '加重复项是唯一会「静默无反应」的操作。输入框清空了、列表没变，'
          '不解释一句的话，用户只会以为自己没点到。',
    );
  });

  testWidgets('点 X 删掉一个类型', (tester) async {
    await open(tester, target: work(genres: const ['犯罪', '剧情']));

    // ⚠️ 不能用 `find.byIcon(Icons.close_rounded)` —— 对话框头部那个
    // 「关闭」用的是同一个图标，`.first` 会点到它、把整个对话框关掉。
    await tester.tap(find.byTooltip('移除「犯罪」'));
    await tester.pumpAndSettle();

    // ⚠️ 断言「删除键没了」而不是「『犯罪』这几个字没了」：犯罪本来就在
    // 常用类型列表里，删掉之后它会**回到**那一排 —— 字还在，但已经不属于
    // 「当前类型」了。按字找会永远失败，且失败原因与真正的 bug 无关。
    expect(find.byTooltip('移除「犯罪」'), findsNothing);
    expect(find.byTooltip('移除「剧情」'), findsOneWidget);
    expect(
      find.text('编辑类型标签'),
      findsOneWidget,
      reason: '删一个类型不该把对话框也关掉。',
    );
  });

  testWidgets('保存 → 库里类型更新且被标记为手动', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), '动画');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('编辑类型标签'), findsNothing, reason: '保存成功就该关掉。');

    final saved = await repo.workByKey('w');
    expect(saved!.genres, containsAll(<String>['犯罪', '动画']));
    expect(
      saved.genresManual,
      isTrue,
      reason: '不置标记的话，用户下次「为了补张海报」再刮一次，'
          '刚改好的类型就被覆盖了 —— 改了也白改。',
    );
  });

  testWidgets('取消 → 不写库', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), '动画');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('编辑类型标签'), findsNothing);
    final saved = await repo.workByKey('w');
    expect(
      saved!.genres,
      ['犯罪'],
      reason: '对话框里改的是副本。取消就该原样不动 —— 否则「取消」'
          '这个名字就是在撒谎。',
    );
    expect(saved.genresManual, isFalse);
  });

  testWidgets('没手动编辑过时不显示「恢复自动判定」', (tester) async {
    await open(tester);

    expect(find.text('恢复自动判定'), findsNothing);
  });

  testWidgets('手动编辑过时显示「恢复自动判定」，点了只清标记、保留类型', (tester) async {
    await open(tester, target: work(genres: const ['动画'], genresManual: true));

    expect(find.text('恢复自动判定'), findsOneWidget);
    await tester.tap(find.text('恢复自动判定'));
    await tester.pumpAndSettle();

    final saved = await repo.workByKey('w');
    expect(
      saved!.genres,
      ['动画'],
      reason: '「交回自动」不是「清空」—— 用户只是想让刮削以后能再接管，'
          '没说要丢掉现在这些标签。',
    );
    expect(saved.genresManual, isFalse);
  });
}
