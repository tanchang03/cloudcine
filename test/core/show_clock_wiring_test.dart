import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「播放时显示时间」这条开关的**接线守卫**。
///
/// 这个功能最容易坏的不是时钟本身，而是「某一端漏了一处」：默认值判据写反、
/// OSD 里加了行却没接回调、关掉之后定时器还在跑……这些都不报错，只表现为
/// 「开关点了没反应」或「新装用户看不到时间」。
///
/// 播放页在 `flutter test` 里起不来（`PlaybackController` 的 `Player` 是字段
/// 初始化器，一构造就启 libmpv），所以这一组用源码静态扫描钉住接线，
/// 与 `outro_wiring_test.dart` 同一套路。
String _read(String rel) => File(rel).readAsStringSync();

/// 剔掉 `//` 行注释 —— 注释里到处写着键名和常量名，直接 contains 会恒真。
String _codeOnly(String src) => src
    .split('\n')
    .map((l) => l.contains('//') ? l.substring(0, l.indexOf('//')) : l)
    .join('\n');

void main() {
  group('播放时显示时间：两端接线', () {
    test('设置键两端逐字同名，判据都是「缺失即开」', () {
      final keys = _codeOnly(_read('lib/data/db/settings_store.dart'));
      final pc =
          _codeOnly(_read('lib/ui/providers/settings_providers.dart'));
      final tv = _codeOnly(
        _read('android/app/src/main/java/com/cloudcine/tv/AppPrefs.kt'),
      );

      expect(keys, contains("showClock = 'show_clock'"));
      expect(pc, contains("v[SettingKeys.showClock] != 'false'"),
          reason: '判据写成 == true 会让新装用户看不到时间，而开关显示开启');
      expect(tv, contains('getBoolean(KEY_SHOW_CLOCK, true)'),
          reason: 'TV 端也必须默认开');
      expect(tv, contains('KEY_SHOW_CLOCK = "show_clock"'),
          reason: '两端键名不同步的症状是「电脑上关了、电视上还开着」');
    });

    test('TV 的 OSD 加了「显示时间」行，并且真的接上了回调', () {
      final src = _codeOnly(
        _read('android/app/src/main/java/com/cloudcine/tv/PlayerActivity.kt'),
      );

      expect(src, contains('out += clockRow()'));
      expect(src, contains('id = ROW_CLOCK'));
      expect(src, contains('ROW_CLOCK -> setClockOverlay(chip == 1)'),
          reason: '分派按 id，不按下标；漏接这一行时菜单里点「关闭」什么都不会发生');
      expect(src, contains('ui.removeCallbacks(clockTick)'),
          reason: '关掉 / 退出时不停心跳，会留一条每秒一次的 Runnable 空转');
    });

    test('PC 播放页：开关写库、时钟受开关门控、菜单入口在场', () {
      final src = _codeOnly(_read('lib/ui/pages/player_page.dart'));

      expect(src, contains('writeBool(SettingKeys.showClock, on)'));
      expect(src, contains('if (_showClock)'),
          reason: '关掉时应当连 widget 都不创建，而不是画一个透明的');
      expect(src, contains('_ClockMenu('));
      expect(src, contains('const IgnorePointer(child: _ClockLabel())'),
          reason: '时钟不能抢走「点画面退出沉浸」那一下点击');
    });

    test('设置页里也有同一个开关（改的是同一个键）', () {
      final src = _codeOnly(_read('lib/ui/pages/settings_page.dart'));
      expect(src, contains('set(showClock: v)'));
    });
  });
}
