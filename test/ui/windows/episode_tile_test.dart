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

  /// [max] 不传时取 [resume]：绝大多数用例只关心「看过多少」，而真实数据里
  /// 历史最大位置总是 `>=` 续播点（它是下界）。要造「看完的那一集」那种
  /// 「续播点已清、历史还在」的状态时显式传 `max:` 并把 `resume` 留成 0。
  PlaylistEntry entry({
    String title = '第 1 集',
    String name = fileName,
    String subtitle = '2160P · MKV · H.265 · 12.3 GB',
    Duration resume = Duration.zero,
    Duration? max,
    Duration duration = const Duration(minutes: 60),
    String? thumbUrl,
  }) =>
      PlaylistEntry(
        itemId: 'q:1',
        title: title,
        fileName: name,
        subtitle: subtitle,
        thumbnailUrl: thumbUrl,
        resumePosition: resume,
        maxPosition: max ?? resume,
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

  testWidgets('**看完的一集画满格** —— 哪怕续播点已经被清掉', (tester) async {
    // 播到结尾：历史最大位置记满，而「已看完」把续播点清成 0。
    await render(
      tester,
      entry(max: const Duration(minutes: 60), duration: const Duration(minutes: 60)),
      current: false,
    );

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(
      bar.value,
      1.0,
      reason: '分子取 `maxPosition` 而不是 `resumePosition`。取后者的话，'
          '用户刚看完一集回到面板上，那一行**什么都不显示** —— 而它是唯一'
          '该显示满格的那一行。',
    );
    await unmount(tester);
  });

  testWidgets('看过但**时长未知** → 不画（不画一条读起来像「没看过」的空槽）', (tester) async {
    await render(
      tester,
      entry(resume: const Duration(minutes: 12), duration: Duration.zero),
      current: false,
    );
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: '拿不到分母时进度只能是 0，画出来是一条空的槽 —— 读起来就是'
          '「没看过」，而它其实看过。与详情页文件列表同一条口径。',
    );
    await unmount(tester);
  });

  testWidgets('有缩略图地址但取不到图 → 安静退回占位图，不是红块', (tester) async {
    // 夸克缩略图要主窗口带着 Cookie 去下（见 `PlayerBridgeMethod.fetchThumbnail`），
    // 测试里没有跨引擎通道，所以这条路必然失败 —— 正好用来验「失败要安静」：
    // 一块红色报错图会把整个剧集面板变成噪点，而用户看不出是网络问题。
    await render(
      tester,
      entry(thumbUrl: 'https://drive.example.com/thumb-f1'),
      current: false,
    );
    // 等异步那一步（必然失败的取图）跑完，再确认界面没被它带崩。
    await tester.pump();
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
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

    test('超过总时长时夹到 1（上报位置可能比时长还大）', () {
      expect(
        episodeProgressOf(entry(
          resume: const Duration(minutes: 90),
          duration: const Duration(minutes: 60),
        )),
        1.0,
      );
    });

    test('读的是历史最大位置，不是续播点', () {
      expect(
        episodeProgressOf(entry(
          // 看完 → 续播点被清成 0，历史最大位置还在。
          resume: Duration.zero,
          max: const Duration(minutes: 30),
          duration: const Duration(minutes: 60),
        )),
        closeTo(0.5, 0.001),
      );
    });
  });
}
