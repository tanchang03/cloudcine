import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/ui/providers/settings_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设置门控。
///
/// 「能不能联网刮」被合成**一个**判断（总开关 AND 至少一个数据源），
/// 是因为它们对应的失败模式在用户眼里完全是同一件事：
/// 「我明明开了刮削，怎么没海报」。拆开的话 UI 要各写一遍组合逻辑，
/// 漏一处就会出现「按钮是亮的、点了什么都不发生」。
void main() {
  group('canScrapeOnline：总开关 × 至少一个源', () {
    test('开关开 + 只有 TMDB Key → 可用', () {
      const s = AppSettings(onlineScrape: true, tmdbApiKey: 'v3-key');
      expect(s.canScrapeOnline, isTrue);
    });

    test('开关开 + 只有豆瓣 Cookie → 可用', () {
      const s = AppSettings(onlineScrape: true, doubanCookie: 'bid=abc;ck=def');
      expect(s.canScrapeOnline, isTrue,
          reason: '只用豆瓣是**正当用法**：TMDB 在境内被 DNS 污染、'
              '永远拿不到结果，此时唯一能用的源就是豆瓣');
    });

    test('开关开 + 一个源都没配 → 不可用', () {
      const s = AppSettings(onlineScrape: true);
      expect(s.canScrapeOnline, isFalse,
          reason: '这是最常见的「我明明开了刮削」—— 只开总开关不填 Key。'
              '若这里返回 true，UI 会亮着按钮让用户白点');
    });

    test('开关关 + 配了源 → 不可用（总开关优先）', () {
      const s = AppSettings(
        onlineScrape: false,
        tmdbApiKey: 'v3-key',
        doubanCookie: 'bid=abc',
      );
      expect(s.canScrapeOnline, isFalse,
          reason: '总开关就是「我要完全离线」的意思，'
              '不能被「之前填过 Key」越过');
    });

    test('源里只有空白字符 → 不算配了源', () {
      const s = AppSettings(
        onlineScrape: true,
        tmdbApiKey: '   ',
        doubanCookie: ' ',
      );
      expect(s.canScrapeOnline, isFalse,
          reason: '输入框里留了几个空格就被当成配好了，总开关会形同虚设 —— '
              '而用户看到的是「开关是开的、就是没海报」');
    });
  });

  group('canAutoScrape：还要自动开关也打开', () {
    test('两个开关都开 + 有源 → 会自动刮', () {
      const s = AppSettings(
        onlineScrape: true,
        autoScrapeOnScan: true,
        tmdbApiKey: 'v3-key',
      );
      expect(s.canAutoScrape, isTrue);
    });

    test('有源 + 总开关开，但自动开关关 → 不自动刮', () {
      const s = AppSettings(onlineScrape: true, tmdbApiKey: 'v3-key');
      expect(s.canAutoScrape, isFalse,
          reason: '自动刮削**默认关**是产品决定：豆瓣匿名额度只有约 10 个搜索词，'
              '一次全盘扫描（145 部作品 × 最多 2 个词）必然中途耗尽，'
              '而耗尽后是 103 need_login —— 用户看到的是「豆瓣一条都刮不到」');
    });

    test('自动开关开但没配源 → 仍然不自动刮', () {
      const s = AppSettings(onlineScrape: true, autoScrapeOnScan: true);
      expect(s.canAutoScrape, isFalse,
          reason: '避免「开关是开的但没源」这种看起来生效、实际什么都没发生的情况');
    });

    test('总开关关 → 自动刮跟着关', () {
      const s = AppSettings(
        onlineScrape: false,
        autoScrapeOnScan: true,
        doubanCookie: 'bid=abc',
      );
      expect(s.canAutoScrape, isFalse);
    });
  });

  group('fromValues：缺失时的默认值', () {
    test('全新安装（一个键都没有）', () {
      final s = AppSettings.fromValues(const <String, String?>{});

      expect(s.onlineScrape, isFalse);
      expect(s.autoScrapeOnScan, isFalse,
          reason: '自动刮削默认关，判据必须是「等于 true」而不是「不等于 false」');
      expect(s.autoMergeByOnlineId, isTrue,
          reason: '自动归一默认**开**，判据必须是「不等于 false」而不是「等于 true」'
              '—— 这两项刻意相反。写反的后果不是报错，而是「新装用户永远不合库」');
      expect(s.autoLoadSubtitles, isTrue,
          reason: '字幕默认**加载**，与 PlaybackController 的缺省行为一致 —— '
              '两处不一致会出现「设置页显示开、实际没加载」');
      expect(s.rememberPosition, isTrue);
      expect(s.autoPlayNext, isTrue,
          reason: '连播默认**开**：它只在 completed 事件到来时动一下播放列表游标，'
              '不发请求、不改库，没有任何代价。默认关的话用户看剧时每集结束'
              '都要拿起遥控器 —— 而这个功能的意义恰恰是躺着看完一整季');
      expect(s.skipIntro, isTrue,
          reason: '跳片头默认**开**的前提是「没有标识就什么都不做」：'
              '区间只有文件章节 / 手标两路来源，两路都没有时这条规则空转，'
              '所以开着它不会出现「看的好好的忽然跳了 90 秒」');
      expect(s.playerVolume, 100);
      expect(s.playerRate, 1);
      expect(s.scanIntervalMs, 350);
      expect(s.scanMaxDepth, 12);
      expect(s.logLevel, 'info');
      expect(s.tmdbApiKey, '');
      expect(s.tmdbApiBase, '');
      expect(s.doubanCookie, '');
      expect(s.lastScanAt, isNull);
    });

    test('缺 autoScrapeOnScan 这个键，但其他键写了值，仍然不自动刮', () {
      final s = AppSettings.fromValues(const <String, String?>{
        SettingKeys.onlineScrape: 'true',
        SettingKeys.tmdbApiKey: 'v3-key',
        SettingKeys.autoLoadSubtitles: 'false',
      });

      expect(s.onlineScrape, isTrue);
      expect(s.autoLoadSubtitles, isFalse);
      expect(s.canScrapeOnline, isTrue);
      expect(s.autoScrapeOnScan, isFalse,
          reason: '老版本数据库里根本没有这个键。缺键必须等价于「关」，'
              '否则升级后会自动把整盘刮一遍');
      expect(s.canAutoScrape, isFalse);
    });

    test('显式写入 true 才打开', () {
      final s = AppSettings.fromValues(const <String, String?>{
        SettingKeys.onlineScrape: 'true',
        SettingKeys.autoScrapeOnScan: 'true',
      });

      expect(s.autoScrapeOnScan, isTrue);
      expect(s.canAutoScrape, isFalse,
          reason: '两个开关都开了但一个源都没配，仍然什么都不该发生');
    });

    test('自动归一只认「显式 false」才关掉', () {
      // 缺键 = 开（与 `autoScrapeOnScan` 相反）。判据写成 `== 'true'` 的话，
      // 老库升级上来会**静默地关掉**归一，而用户在设置页看到开关是开的。
      expect(
        AppSettings.fromValues(const <String, String?>{})
            .autoMergeByOnlineId,
        isTrue,
      );
      expect(
        AppSettings.fromValues(const <String, String?>{
          SettingKeys.autoMergeByOnlineId: 'false',
        }).autoMergeByOnlineId,
        isFalse,
      );
      expect(
        AppSettings.fromValues(const <String, String?>{
          SettingKeys.autoMergeByOnlineId: 'true',
        }).autoMergeByOnlineId,
        isTrue,
      );
    });

    test('连播与跳片头也只认「显式 false」才关掉', () {
      // 与 `autoMergeByOnlineId` 同一族：判据写成 `== 'true'` 的话，
      // 老库升级上来会**静默地**把两项都关掉，而设置页的开关是**开着**的
      // —— 用户看到的是「开关明明打开了，怎么不连播 / 不跳片头」，
      // 一个没人会想到去查的默认值问题。
      final fresh = AppSettings.fromValues(const <String, String?>{});
      expect(fresh.autoPlayNext, isTrue);
      expect(fresh.skipIntro, isTrue);

      final off = AppSettings.fromValues(const <String, String?>{
        SettingKeys.autoPlayNext: 'false',
        SettingKeys.skipIntro: 'false',
      });
      expect(off.autoPlayNext, isFalse);
      expect(off.skipIntro, isFalse);
    });

    test('关掉「记住播放进度」不影响连播', () {
      // 两者在代码里是独立的。绑在一起（`rememberPosition && autoPlayNext`）
      // 看着省事，实际会造出「关了记住进度就再也不连播」这种没人预料得到的
      // 联动 —— 而设置页的两条提示文案里**都没有**提到对方。
      final s = AppSettings.fromValues(const <String, String?>{
        SettingKeys.rememberPosition: 'false',
      });
      expect(s.rememberPosition, isFalse);
      expect(s.autoPlayNext, isTrue,
          reason: '连播的触发条件是 completed 事件，与「有没有存续播点」无关');
    });

    test('数值与日期解析失败时退回默认值', () {
      final s = AppSettings.fromValues(const <String, String?>{
        SettingKeys.playerVolume: '很响',
        SettingKeys.playerRate: '',
        SettingKeys.scanIntervalMs: 'x',
        SettingKeys.scanMaxDepth: '',
        SettingKeys.lastScanAt: 'not-a-date',
      });

      expect(s.playerVolume, 100);
      expect(s.playerRate, 1);
      expect(s.scanIntervalMs, 350);
      expect(s.scanMaxDepth, 12);
      expect(s.lastScanAt, isNull);
      expect(s.debugOverlay, isFalse,
          reason: '调试浮层默认**关** —— 见下面那一组');
    });
  });

  group('调试指标浮层：默认关，要显式打开', () {
    // 这一组与上面几项**方向相反**（缺失即关），所以判据必须写成 `== 'true'`。
    // 写反的后果不是报错，而是「每个用户一装上就顶着一排数字，而设置页的
    // 开关是关着的」—— 用户会以为这开关坏了、关不掉。
    test('全新安装（一个键都没有）→ 不显示', () {
      expect(
        AppSettings.fromValues(const <String, String?>{}).debugOverlay,
        isFalse,
        reason: '它是排查工具不是功能：一排每秒刷新的数字叠在画面上，'
            '日常看片只会挡视线',
      );
    });

    test('老库升级：别的键都有、唯独缺这一个 → 仍然不显示', () {
      final s = AppSettings.fromValues(const <String, String?>{
        SettingKeys.logLevel: 'debug',
        SettingKeys.streamRelay: 'true',
        SettingKeys.autoPlayNext: 'true',
      });
      expect(s.logLevel, 'debug');
      expect(s.streamRelay, isTrue);
      expect(s.debugOverlay, isFalse,
          reason: '缺键必须等价于关。缺键即开的话，所有老用户升级完都会'
              '发现自己界面上多了一排数字');
    });

    test('只有显式写入 true 才打开', () {
      expect(
        AppSettings.fromValues(const <String, String?>{
          SettingKeys.debugOverlay: 'true',
        }).debugOverlay,
        isTrue,
      );
      expect(
        AppSettings.fromValues(const <String, String?>{
          SettingKeys.debugOverlay: 'false',
        }).debugOverlay,
        isFalse,
      );
      // ⛔ 这一条是整组的**判据**：它区分 `== 'true'` 与 `!= 'false'` 两种写法。
      // 换成 `!= 'false'` 的话，'1'、任何非空字符串、乃至于老版本写进去的
      // 乱码**全都会打开浮层** —— 而这正是「默认值写反了」最难查的形态：
      // 代码看着是「不等于 false 就开」，用户看到的是「关不掉」。
      //
      // 注意 `SettingsStore.readBool` 认 '1'，但那条路不参与 `AppSettings`
      // （读设置走的是 `readAll` + `fromValues`），所以这里只认字面量 'true'
      // 不会造成「设置页显示关、实际开着」的不一致。
      expect(
        AppSettings.fromValues(const <String, String?>{
          SettingKeys.debugOverlay: '1',
        }).debugOverlay,
        isFalse,
      );
    });

    test('默认构造与 copyWith 都保持这个默认值', () {
      // `AppSettings()` 是设置还没从库里读出来时的兜底值（见
      // `SettingsController.set` 里的 `valueOrNull ?? const AppSettings()`）。
      // 它必须是「关」，否则第一次改任何设置都会顺手把浮层打开。
      expect(const AppSettings().debugOverlay, isFalse);
      expect(const AppSettings().copyWith().debugOverlay, isFalse);
      expect(const AppSettings().copyWith(debugOverlay: true).debugOverlay,
          isTrue);
    });
  });
}
