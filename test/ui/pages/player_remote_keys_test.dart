import 'package:cloudcine/ui/pages/player_page.dart';
import 'package:cloudcine/ui/widgets/player_keys.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放页的遥控器按键路由。
///
/// 为什么值得单独测：这套路由最典型的故障是**键名写错**。
/// Android TV 遥控器的中心 OK 键键码是 23，映射到 `LogicalKeyboardKey.select`，
/// **不是 `enter`、也不是 `space`**。原来的实现是 `CallbackShortcuts` 只绑了
/// `space`，于是遥控器按下去「毫无反应」—— 不报错、不崩溃、也不进日志，
/// 用户看到的现象就是「这个功能没做」。只有断言能钉住它。
///
/// 另一半（同样重要）是**不能过度接管**：焦点在按钮上时 OK 与 ←/→ 必须放行，
/// 否则 OK 会「既暂停又点按钮」、←/→ 会「既快退又不换焦点」——
/// 后者会让 TV 用户永远选不到字幕和清晰度。
void main() {
  // 画面区拿到焦点 —— TV 上「遥控器指着画面」的常态。
  const onStage = true;
  // 焦点在控制栏按钮 / 菜单 / 错误遮罩上。
  const onWidget = false;

  group('画面区：OK 与方向键归播放器', () {
    test('OK 键（select）是播放/暂停 —— 这条就是「遥控器按不出暂停」的修复', () {
      expect(
        resolveRemoteKey(
          key: LogicalKeyboardKey.select,
          immersive: false,
          stageFocused: onStage,
        ),
        RemoteKeyAction.playPause,
        reason: 'TV 遥控器中心键的键码是 23 → LogicalKeyboardKey.select；'
            '它不是 enter、也不是 space，写错就等于这个键不存在',
      );
    });

    test('enter 同样当播放/暂停（部分手柄/键盘把 OK 报成 enter）', () {
      expect(
        resolveRemoteKey(
          key: LogicalKeyboardKey.enter,
          immersive: false,
          stageFocused: onStage,
        ),
        RemoteKeyAction.playPause,
      );
    });

    test('←/→ 是快退/快进 10 秒', () {
      expect(
        resolveRemoteKey(
          key: LogicalKeyboardKey.arrowLeft,
          immersive: false,
          stageFocused: onStage,
        ),
        RemoteKeyAction.seekBack,
      );
      expect(
        resolveRemoteKey(
          key: LogicalKeyboardKey.arrowRight,
          immersive: false,
          stageFocused: onStage,
        ),
        RemoteKeyAction.seekForward,
      );
    });

    test('↑/↓ 一律放行 —— 「从画面往下走到控制栏」靠的就是焦点遍历', () {
      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
      ]) {
        expect(
          resolveRemoteKey(key: key, immersive: false, stageFocused: onStage),
          RemoteKeyAction.ignored,
          reason: '一旦在这里接管 ↑/↓，遥控器就再也走不到控制栏，'
              '等于选不了字幕/清晰度/音轨',
        );
      }
    });
  });

  group('焦点在控件上：OK 与方向键必须放行给焦点系统', () {
    test('OK 放行，否则会「既暂停又点按钮」', () {
      expect(
        resolveRemoteKey(
          key: LogicalKeyboardKey.select,
          immersive: false,
          stageFocused: onWidget,
        ),
        RemoteKeyAction.ignored,
        reason: '焦点在字幕按钮上时按 OK，应当只打开字幕菜单，不该同时暂停',
      );
    });

    test('←/→ 放行，否则焦点永远在按钮之间挪不动', () {
      for (final key in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        expect(
          resolveRemoteKey(key: key, immersive: false, stageFocused: onWidget),
          RemoteKeyAction.ignored,
          reason: '这是「控制栏按钮能被遥控器选中」的前提；'
              '接管了就只剩播放/暂停可用',
        );
      }
    });
  });

  group('不挑焦点位置的专用键', () {
    test('遥控器的播放/暂停键在任何位置都生效', () {
      for (final focused in [onStage, onWidget]) {
        expect(
          resolveRemoteKey(
            key: LogicalKeyboardKey.mediaPlayPause,
            immersive: false,
            stageFocused: focused,
          ),
          RemoteKeyAction.playPause,
        );
      }
    });

    test('遥控器的快退/快进键在任何位置都生效', () {
      for (final focused in [onStage, onWidget]) {
        expect(
          resolveRemoteKey(
            key: LogicalKeyboardKey.mediaRewind,
            immersive: false,
            stageFocused: focused,
          ),
          RemoteKeyAction.seekBack,
        );
        expect(
          resolveRemoteKey(
            key: LogicalKeyboardKey.mediaFastForward,
            immersive: false,
            stageFocused: focused,
          ),
          RemoteKeyAction.seekForward,
        );
      }
    });

    test('空格键在任何位置都还是播放/暂停（桌面端原有手感不能丢）', () {
      for (final focused in [onStage, onWidget]) {
        expect(
          resolveRemoteKey(
            key: LogicalKeyboardKey.space,
            immersive: false,
            stageFocused: focused,
          ),
          RemoteKeyAction.playPause,
        );
      }
    });

    test('数字键在任何位置都跳到 N% —— 它是「明确的意图」，不像 OK 那样有歧义', () {
      // 为什么「不挑焦点」是对的：焦点停在字幕按钮上时按 5，用户要的仍然是
      // 「跳到一半」，而不是「激活字幕按钮」。反过来若在这里放行，TV 用户就
      // 只剩方向键可用 —— 而方向键拖不动进度条（§5.5）。
      for (final focused in [onStage, onWidget]) {
        for (final entry in seekDigitKeys.entries) {
          expect(
            resolveRemoteKey(
              key: entry.key,
              immersive: false,
              stageFocused: focused,
            ),
            RemoteKeyAction.seekPercent,
            reason: '${entry.key}（数字 ${entry.value}）没路由到 seekPercent '
                '(stageFocused=$focused)',
          );
        }
      }
    });

    test('比例由键本身算 —— 0 → 0.0、5 → 0.5、9 → 0.9（不能跳结尾）', () {
      // `resolveRemoteKey` 只回答「该干什么」，「是哪个数字」由这张共享表回答。
      // 分开的原因：两个播放器都要用同一个枚举，而比例是纯数据。
      expect(seekFractionForKey(LogicalKeyboardKey.digit0), 0.0);
      expect(seekFractionForKey(LogicalKeyboardKey.digit5), 0.5);
      expect(seekFractionForKey(LogicalKeyboardKey.digit9), 0.9);
      expect(seekFractionForKey(LogicalKeyboardKey.numpad7), 0.7);
      // 不提供「跳到结尾」：用户真正想按的是「不看了」，入口是返回键。
      expect(
        seekDigitKeys.values,
        everyElement(lessThan(10)),
        reason: '表里不该有 10 —— 跳到结尾会立刻触发播完退出，看起来像崩了',
      );
      expect(seekFractionForKey(LogicalKeyboardKey.keyA), isNull);
    });
  });

  group('沉浸模式不能是单向门', () {
    test('遥控器上任何认识的键，第一下都先把控制栏叫回来', () {
      const remoteKeys = [
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.mediaPlayPause,
      ];
      for (final key in remoteKeys) {
        expect(
          resolveRemoteKey(key: key, immersive: true, stageFocused: onStage),
          RemoteKeyAction.showControls,
          reason: 'TV 上没有 Esc。原来只有 Esc 能退出沉浸，'
              '进了沉浸模式就等于画面被锁死（$key）',
        );
      }
    });

    test('沉浸模式里数字键也是先叫回控制栏 —— 漏掉就是「按 5 没反应」', () {
      // 判据是「认不认得这个键」（`_remoteKeys`）。数字键漏出这张表的话，
      // 沉浸模式下按 5 不会跳转、也不会叫回控制栏 —— 表现是「数字键时灵时不灵」，
      // 而它其实只是少了一行。
      for (final entry in seekDigitKeys.entries) {
        expect(
          resolveRemoteKey(
            key: entry.key,
            immersive: true,
            stageFocused: onStage,
          ),
          RemoteKeyAction.showControls,
          reason: '${entry.key} 不在「认识的键」里 —— 沉浸模式下它会被吞掉',
        );
      }
    });

    test('沉浸模式里按 Esc 也是先退出沉浸，不是直接退出播放页', () {
      expect(
        resolveRemoteKey(
          key: LogicalKeyboardKey.escape,
          immersive: true,
          stageFocused: onStage,
        ),
        RemoteKeyAction.showControls,
        reason: '两步走：第一下退沉浸、第二下才离开播放页（原有行为，别改）',
      );
    });

    test('非沉浸模式按 Esc 才是退出播放页', () {
      expect(
        resolveRemoteKey(
          key: LogicalKeyboardKey.escape,
          immersive: false,
          stageFocused: onStage,
        ),
        RemoteKeyAction.pop,
      );
    });
  });

  test('没有映射的键一律放行，不吞按键', () {
    for (final key in [
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.mediaStop,
    ]) {
      expect(
        resolveRemoteKey(key: key, immersive: false, stageFocused: onStage),
        RemoteKeyAction.ignored,
      );
    }
  });
}
