import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/now_playing_bars.dart';
import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:cloudcine/ui/windows/player_window_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 剧集面板里的**一行**。
///
/// ## 为什么单独渲染这一行来测
///
/// 播放窗口整体在 `flutter test` 里建不出来（`Player()` 抛
/// `Cannot find Mpv.framework …`，libmpv 不在 rpath 里），所以「面板上到底
/// 显示什么」在整窗用例里够不到。而这一行里全是**改错不报错**的规则：
///
///   - 主标题该是**文件名**还是集号；
///   - 「正在播放」动效**只画在当前那一行**（画满全表 = 等于没有信息）；
///   - 进度条只在真看过一点时才出现。
///
/// 三条错了都不会抛异常，只会看起来「本来就这么设计的」。
///
/// ⚠️ **不用 `pumpAndSettle`**：当前那一行挂着 `NowPlayingBars` 的
/// `repeat()` 动画，`pumpAndSettle` 会一直等到超时。另外每条渲染了动效的用例
/// 结束前都要把它卸下来（`pumpWidget(SizedBox.shrink())`），
/// 否则测试框架会报「A Ticker was active when the test ended」。
void main() {
  const fileName = 'The.Glory.S01E01.2160p.NF.WEB-DL.SDR.HEVC.DDP5.1.Atmos-老K.mkv';

  PlaylistEntry entry({
    String title = '第 1 集',
    String name = fileName,
    String subtitle = '2160P · MKV · H.265 · 12.3 GB',
    Duration resume = Duration.zero,
    Duration duration = const Duration(minutes: 60),
  }) =>
      PlaylistEntry(
        itemId: 'q:1',
        title: title,
        fileName: name,
        subtitle: subtitle,
        resumePosition: resume,
        duration: duration,
      );

  Future<void> render(
    WidgetTester tester,
    PlaylistEntry e, {
    required bool current,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: EpisodeTile(
            entry: e,
            current: current,
            progress: episodeProgressOf(e),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// 把树换掉，让 `NowPlayingBars` 的 ticker 随组件一起 dispose。
  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets('主标题是文件名 —— 这是这一行的主要信息', (tester) async {
    await render(tester, entry(), current: false);
    expect(find.text(fileName), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('集号进副标题，且排在码率前面', (tester) async {
    await render(tester, entry(), current: false);
    expect(find.text('第 1 集 · 2160P · MKV · H.265 · 12.3 GB'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('上游没给文件名时主标题退回集号，不会空着', (tester) async {
    await render(tester, entry(name: ''), current: false);
    expect(find.text('第 1 集'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('当前播放那一行才有动效图标', (tester) async {
    await render(tester, entry(), current: true);
    expect(find.byType(NowPlayingBars), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('非当前的行**没有**动效 —— 画满全表等于没有信息', (tester) async {
    await render(tester, entry(), current: false);
    expect(find.byType(NowPlayingBars), findsNothing);
    await unmount(tester);
  });

  testWidgets('看过一点才画进度条', (tester) async {
    await render(
      tester,
      entry(resume: const Duration(minutes: 12), duration: const Duration(minutes: 60)),
      current: false,
    );
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.2, 0.001));
    await unmount(tester);
  });

  testWidgets('没看过就不画进度条（一条空进度条会被读成「已看完」的反面）', (tester) async {
    await render(tester, entry(), current: false);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await unmount(tester);
  });

  group('episodeProgressOf', () {
    test('时长未知时返回 0，不编一个假进度', () {
      expect(
        episodeProgressOf(entry(
          resume: const Duration(minutes: 5),
          duration: Duration.zero,
        )),
        0,
      );
    });

    test('超过总时长时夹到 1（续播点可能比时长还大）', () {
      expect(
        episodeProgressOf(entry(
          resume: const Duration(minutes: 90),
          duration: const Duration(minutes: 60),
        )),
        1.0,
      );
    });
  });
}
