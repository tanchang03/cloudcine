import 'package:cloudcine/ui/pages/player_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「正在加载…」这一层的判据。
///
/// 2026-10-05 起判据收成一条：`isLoading`。`isLoading` 同时被 `open()`（首次
/// 开播 / 换集 / 重试）与 `switchQuality`（切画质）置位 —— 这几件事用户都
/// 该看到「加载中 + 下载速率」的过渡（选完集 / 切完画质后 OSD 已收起，过渡
/// 层是唯一的反馈）。
///
/// ⚠️ 判据必须从 `isLoading` **推导**、不能是页面自己的锁存标志位：某条
/// 提前返回的分支忘了清，指示就会永远挂在画面上 —— 而「永远不收」比
/// 「早收」糟得多（窗口那边的加载罩注释同理）。
void main() {
  test('正在加载（首次开播 / 换集 / 切画质都会置位）→ 显示', () {
    expect(
      shouldShowSwitchVeil(
        isLoading: true,
        duration: Duration.zero,
      ),
      isTrue,
      reason: '用户选完集 / 切完画质后 OSD 已收起，这一层是唯一的反馈 —— '
          '首次开播时长为零也照常显示',
    );
  });

  test('切画质（时长还在 + 正在加载）→ 显示', () {
    expect(
      shouldShowSwitchVeil(
        isLoading: true,
        duration: const Duration(minutes: 42),
      ),
      isTrue,
      reason: '`switchQuality` 不走 `open()`，时长还在 —— 换档同样显示加载过渡',
    );
  });

  test('不在加载（网络卡顿只走缓冲圈）→ 不显示', () {
    expect(
      shouldShowSwitchVeil(
        isLoading: false,
        duration: const Duration(minutes: 42),
      ),
      isFalse,
      reason: '网络跟不上走的是「缓冲中…」的通用圈，不挂「加载中」过渡 —— '
          '两者混在一起，「切档」与「网卡了」就再也分不出来',
    );
  });

  test('加载刚结束（isLoading 落回 false）→ 立刻不显示', () {
    expect(
      shouldShowSwitchVeil(
        isLoading: false,
        duration: Duration.zero,
      ),
      isFalse,
      reason: '判据是从 `isLoading` 推导的、不是锁存状态：`switchQuality` 的'
          '`try/finally` 保证它会落回 false，所以指示不会卡在画面上',
    );
  });
}
