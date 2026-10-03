import 'package:cloudcine/ui/pages/player_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「正在切换…」这一层的判据。
///
/// 它容易漂：`isLoading` 同时被 `open()`（首次开播 / 换集 / 重试）与
/// `switchQuality` 置位，谁要是图省事直接拿 `isLoading` 当条件，**首次开播**
/// 就会挂上「正在切换…」—— 用户刚点开一部片就看到「正在切换」，只会以为
/// 应用在乱切。所以判据抽成纯函数、每一档都钉死。
///
/// 反过来的错法也要钉：如果为了保险加一个「见过就清」的锁存标志位，
/// 某条提前返回的分支忘了清，指示就会**永远**挂在画面上 —— 而「永远不收」
/// 比「早收」糟得多（窗口那边的加载罩注释同理）。
void main() {
  test('换档中（时长还在 + 正在加载）→ 显示', () {
    expect(
      shouldShowSwitchVeil(
        isLoading: true,
        duration: const Duration(minutes: 42),
      ),
      isTrue,
      reason: '`switchQuality` 不走 `open()`，所以时长还在 —— 这正是「同一部片'
          '换一档」，也是唯一该显示这句文案的场合',
    );
  });

  test('首次载入（正在加载但时长为零）→ 不显示', () {
    expect(
      shouldShowSwitchVeil(isLoading: true, duration: Duration.zero),
      isFalse,
      reason: '`open()` 会把时长归零。这里若误报，用户刚点开一部片就会看到'
          '「正在切换…」，而他根本没切过任何东西',
    );
  });

  test('播放中网络卡顿（不在加载）→ 不显示', () {
    expect(
      shouldShowSwitchVeil(
        isLoading: false,
        duration: const Duration(minutes: 42),
      ),
      isFalse,
      reason: '网络跟不上走的是通用缓冲圈。两者混在一起，「切档」与「网卡了」'
          '就再也分不出来 —— 而用户对这两件事的处置完全不同',
    );
  });

  test('换档刚结束（加载已落回 false）→ 立刻不显示', () {
    expect(
      shouldShowSwitchVeil(
        isLoading: false,
        duration: const Duration(minutes: 42),
      ),
      isFalse,
      reason: '判据是从 `isLoading` 推导的、不是锁存状态：`switchQuality` 的'
          '`try/finally` 保证它会落回 false，所以指示不会卡在画面上',
    );
  });

  test('时长非零即算「已经播过」—— 与时长大小无关', () {
    for (final d in const [
      Duration(milliseconds: 1),
      Duration(seconds: 3),
      Duration(hours: 3),
    ]) {
      expect(
        shouldShowSwitchVeil(isLoading: true, duration: d),
        isTrue,
        reason: '判据是「> 0」而不是某个门槛：只要这一条流解出过时长，'
            '换档时它就在（$d）',
      );
    }
  });
}
