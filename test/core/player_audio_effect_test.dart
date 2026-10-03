import 'package:cloudcine/core/utils/player_audio_effect.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「音效」预设 → mpv 属性的映射。
///
/// ## 为什么这些用例值得写
///
/// 这一层全是**改错不报错**的规则：
///
///   - 少写一个属性 → 从「直通」切回「跟随片源」时旧值留着，声音继续被原样
///     送出去，界面却显示已经切回来了；
///   - 属性名写错（`audio-channel` 少个 s）→ media_kit 的 `setProperty`
///     把 mpv 的返回码丢掉，失败完全静默，表现成「菜单点了没反应」；
///   - `parse` 对读不懂的值抛异常 → 设置库被旧版本写坏一次，播放器就起不来。
///
/// 三条在真机上都不会抛异常，只会看起来「本来就没这个功能」。
void main() {
  group('PlayerAudioEffect 预设表', () {
    test('每个预设都写全了属性，不会留下上一个预设的残值', () {
      // 这一条是**核心**：切换音效时我们只设不删，所以每个预设都必须显式
      // 覆盖它关心的每一个键。少写 `audio-spdif` 的后果最隐蔽 ——
      // 从「直通」切回「跟随片源」后码流仍然被原样送给设备，用户听到的是
      // 「切回来了但没声音」。
      for (final p in PlayerAudioEffect.all) {
        final props = PlayerAudioEffect.mpvProperties(p);
        expect(
          props.keys,
          containsAll(<String>['audio-channels', 'audio-spdif']),
          reason: '预设 ${p.value} 少写了属性，切档会留下旧值',
        );
        expect(props['audio-spdif'], isNotEmpty);
        expect(props['audio-channels'], isNotEmpty);
      }
    });

    test('只有直通那一档打开 spdif，其余一律 no', () {
      for (final p in PlayerAudioEffect.all) {
        final spdif = PlayerAudioEffect.mpvProperties(p)['audio-spdif'];
        expect(
          spdif == 'no',
          p != AudioEffectPreset.passthrough,
          reason: '${p.value} 的 audio-spdif=$spdif 与「只有直通才开」不符',
        );
      }
    });

    test('直通那一档不把声道压成 stereo', () {
      // 压成 stereo 的话 mpv 会先把 5.1 下混成 2.0 再交给设备 ——
      // 功放收到的已经不是原码了，直通等于白开，而且**没有任何报错**。
      expect(
        PlayerAudioEffect.mpvProperties(AudioEffectPreset.passthrough)[
            'audio-channels'],
        isNot('stereo'),
      );
    });

    test('默认档就是跟随片源（不上混、不下混）', () {
      expect(
        PlayerAudioEffect.mpvProperties(AudioEffectPreset.auto)['audio-channels'],
        'auto-safe',
      );
      expect(PlayerAudioEffect.defaultPreset, AudioEffectPreset.auto.value);
    });
  });

  group('PlayerAudioEffect.parse', () {
    test('已知值原样还原', () {
      for (final p in PlayerAudioEffect.all) {
        expect(PlayerAudioEffect.parse(p.value), p);
      }
    });

    test('null / 空串 / 读不懂的值一律退回默认，绝不抛', () {
      // 设置库是用户能手动改的（也能被旧版本写坏）。为一个字符串把播放器
      // 拦在启动之前，代价远大于「音效回到默认」。
      for (final raw in <String?>[null, '', 'stereo ', 'STEREO', '杜比', '未知']) {
        expect(
          PlayerAudioEffect.parse(raw),
          AudioEffectPreset.auto,
          reason: '输入 "$raw" 应当退回默认档',
        );
      }
    });

    test('存储值就是枚举名，改名等于让老用户的设置失效', () {
      // 这不是实现细节，是**兼容性契约**：库里存的是这个字符串。
      for (final p in PlayerAudioEffect.all) {
        expect(p.value, p.name);
      }
    });

    test('没有两个预设共用同一个存储值', () {
      final values = PlayerAudioEffect.all.map((p) => p.value).toSet();
      expect(values.length, PlayerAudioEffect.all.length);
    });
  });

  group('PlayerAudioEffect 文案', () {
    test('每个预设都有名字和一句说明', () {
      for (final p in PlayerAudioEffect.all) {
        expect(PlayerAudioEffect.label(p), isNotEmpty);
        // 说明那行不能空：不写清「什么时候它才有区别」的话，「立体声」在
        // 笔记本上与「跟随片源」**完全一样**，用户会以为功能坏了。
        expect(PlayerAudioEffect.detail(p), isNotEmpty);
      }
    });

    test('四个预设的名字互不相同（菜单里要按名字认）', () {
      final labels = PlayerAudioEffect.all.map(PlayerAudioEffect.label).toSet();
      expect(labels.length, PlayerAudioEffect.all.length);
    });
  });

  // ## 为什么这一组非有不可
  //
  // macOS 上把 `audio-spdif` 下发出去，mpv 的音频输出就永远建不起来，而音频是
  // mpv 的主时钟 —— **整部片一动不动**（位置冻在起点、画面不动），不是「没声音」。
  // 更糟的是它只在**开流时**生效：播放中改它毫无效果，于是用户会以为没问题，
  // 下次打开才发现播不了（实测与复现配方见 `player_audio_effect.dart` 类文档）。
  //
  // 所以这里守的是三条**都不报错**的规则：读出来的档位、菜单里列的档位、
  // 真正会下发到 mpv 的属性。任何一条漏掉，症状都是「用户打不开影片」。
  group('平台守卫：macOS 上「直通」必须失效', () {
    test('macOS：直通读作跟随片源，且不会下发 audio-spdif', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect(PlayerAudioEffect.passthroughAvailable, isFalse);

      // ① 库里存着的 `passthrough`（老用户装过这个版本）必须读成 auto。
      //    否则菜单勾着「直通」、实际按「跟随片源」在放，两边对不上。
      expect(
        PlayerAudioEffect.parse(AudioEffectPreset.passthrough.value),
        AudioEffectPreset.auto,
        reason: '老设置里的 passthrough 没被折掉，会继续下发 spdif → 影片卡死',
      );

      // ② 真会送到 mpv 的那份属性里不能再有 spdif 名单。
      //    断言走「normalize → mpvProperties」这条链，而不是直接断言
      //    `mpvProperties(passthrough)`：后者是纯映射表，故意不含平台判断
      //    （守卫的位置见 `PlayerAudioEffect.apply`）。
      expect(
        PlayerAudioEffect.mpvProperties(
          PlayerAudioEffect.normalize(AudioEffectPreset.passthrough),
        )['audio-spdif'],
        'no',
        reason: '只要还有一条路径把 spdif 名单下发出去，macOS 上影片就会卡死',
      );

      // ③ 菜单里不能再列它 —— 列出来就必须点得动。
      expect(
        PlayerAudioEffect.selectable,
        isNot(contains(AudioEffectPreset.passthrough)),
        reason: 'macOS 上把「直通」列在菜单里，用户点了就是「没反应」',
      );
      expect(
        PlayerAudioEffect.selectable.length,
        PlayerAudioEffect.all.length - 1,
      );
    });

    test('macOS：另外三档一个字都不许动', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      // 守卫是**只针对直通**的。写成「macOS 上随便折成 auto」的话，
      // 「环绕上混」和「立体声」会一起静默失效 —— 同样是点了没反应。
      for (final p in <AudioEffectPreset>[
        AudioEffectPreset.auto,
        AudioEffectPreset.upmix,
        AudioEffectPreset.stereo,
      ]) {
        expect(PlayerAudioEffect.parse(p.value), p);
        expect(PlayerAudioEffect.normalize(p), p);
        expect(PlayerAudioEffect.selectable, contains(p));
      }
    });

    test('其他平台仍然保留直通（别把守卫写宽了）', () {
      // 只在 macOS 上关掉它，是因为**只有 macOS 上有实测证据**。
      // 顺手把这条写成用例：以后有人「顺手」把守卫扩大到全平台时，这里会红。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect(PlayerAudioEffect.passthroughAvailable, isTrue);
      expect(
        PlayerAudioEffect.parse(AudioEffectPreset.passthrough.value),
        AudioEffectPreset.passthrough,
      );
      expect(PlayerAudioEffect.normalize(AudioEffectPreset.passthrough),
          AudioEffectPreset.passthrough);
      expect(PlayerAudioEffect.selectable, PlayerAudioEffect.all);
    });
  });
}
