import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **手标片尾（schema 19）跨文件接线的守卫。**
///
/// ## 为什么必须用静态检查
///
/// 片尾这条链路上最要命的一种漏法**不是算错，而是「传了但没人用」**：
///
/// ```
/// 库里 outro_offset_ms → MediaWork.outroOffsetMs → 简介页显示「手动标记」
///                                              ↘ 播放器：从来没看过这一列
/// ```
///
/// 界面正常、日志正常、纯函数单测（`OutroSkip` / `MediaWork.outroStart`）
/// 全绿 —— 只有真正播到片尾时才发现「没跳」。PC 端比 Android 端更容易漏，
/// 因为手标片尾要**跨一次引擎边界**才能到达独立播放窗口：
///
/// ```
/// 主窗口 repo.setWorkOutroOffset → PlayRequest.outroOffsetMs
///   → 独立窗口 _manualOutroOffset → _maybeNotifyOutro
/// ```
///
/// 中间任何一环断了都不报错。所以这里钉的是**接线**，不是数值：
///
///   1. 内置播放页起播时要把手标片尾传进控制器；
///   2. 独立窗口的 `PlayRequest` 要带上它；
///   3. 独立窗口的片尾判定要走 `OutroSkip`（与内置页**同一份**判据）；
///   4. 独立窗口改完要能回主窗口落库。
///
/// ⛔ **必须先剔掉注释**：本仓库的文档注释里到处写着 `OutroSkip` /
///    `outroOffsetMs` 这种说明性引用，不剔的话「把调用行注释掉」会被判成「还在」。
void main() {
  String read(String rel) {
    final f = File(rel);
    expect(
      f.existsSync(),
      isTrue,
      reason: '找不到 $rel —— 文件挪位置了？路径要跟着改。'
          '（`flutter test` 的工作目录 = 仓库根）',
    );
    return f.readAsStringSync();
  }

  /// 剔掉整行注释后的源码。
  ///
  /// ⛔ 行级过滤而不是剥块注释：源文件里有网盘 URL 之类的字符串字面量，
  ///    按 `//` 粗暴切断会把 `"https://…"` 的后半截连同引号一起吃掉。
  String codeOnly(String src) => src
      .split('\n')
      .where((l) {
        final t = l.trimLeft();
        return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
      })
      .join('\n');

  /// 取一个**块体**函数的函数体（从声明到配对的 `}`）。
  String blockBody(String code, String header) {
    final start = code.indexOf(header);
    expect(start, greaterThanOrEqualTo(0), reason: '源码里找不到 `$header`');
    final open = code.indexOf('{', start);
    expect(open, greaterThanOrEqualTo(0), reason: '`$header` 不是块体？');
    var depth = 0;
    for (var i = open; i < code.length; i++) {
      if (code[i] == '{') depth++;
      if (code[i] == '}') {
        depth--;
        if (depth == 0) return code.substring(open, i + 1);
      }
    }
    return code.substring(open);
  }

  /// 取一个**表达式体**成员（`… => expr;`）到第一个分号为止。
  String exprBody(String code, String header) {
    final start = code.indexOf(header);
    expect(start, greaterThanOrEqualTo(0), reason: '源码里找不到 `$header`');
    final end = code.indexOf(';', start);
    expect(end, greaterThanOrEqualTo(0), reason: '`$header` 后面找不到 `;`');
    return code.substring(start, end + 1);
  }

  test('内置播放页起播时把手标片尾传进控制器', () {
    final code = codeOnly(read('lib/ui/pages/player_page.dart'));

    expect(
      code.contains('manualOutroOffset: _manualOutroOffsetOf(work)'),
      isTrue,
      reason: '`_open()` 没有把 `manualOutroOffset` 交给控制器。'
          '少了它，内置播放页的片尾取值链里就只剩「学习」那一级 —— '
          '用户手标的片尾完全不生效，而界面上一切正常。',
    );
    expect(
      code.contains('_controller.applyManualOutro('),
      isTrue,
      reason: '换集 / 重读作品之后没有把新的手标片尾同步进控制器。'
          '少了它，标完片尾要退出播放页再进来才生效。',
    );
  });

  test('独立窗口的 PlayRequest 带上手标片尾', () {
    final code = codeOnly(read('lib/ui/windows/desktop_play.dart'));

    expect(
      code.contains('outroOffsetMs: work?.outroOffsetMs'),
      isTrue,
      reason: '`desktop_play.dart` 没有把 `outroOffsetMs` 放进 `PlayRequest`。'
          '手标片尾**跨不过引擎边界**，独立窗口永远只能按学习结论跳 —— '
          '而用户是在主窗口标的那一份，他会以为「标了没用」。',
    );
  });

  test('独立窗口的片尾判定走 OutroSkip（与内置页同一份判据）', () {
    final code = codeOnly(read('lib/ui/windows/player_window_app.dart'));
    final body = blockBody(code, 'void _maybeNotifyOutro(');

    expect(
      body.contains('OutroSkip.effectiveOffset('),
      isTrue,
      reason: '`_maybeNotifyOutro` 没有走 `OutroSkip` 的取值链（手标 > 学习）。'
          '独立窗口跑在另一个引擎里、够不到 `PlaybackController`，'
          '自己拼一遍就会变成「内置页跳得对、窗口跳得怪」。',
    );
    expect(
      body.contains('OutroSkip.start('),
      isTrue,
      reason: '`_maybeNotifyOutro` 没有走 `OutroSkip.start` 的落点换算'
          '（片长未知 / 偏移 ≥ 片长时必须返回 null，不跳也不提示）。',
    );
  });

  test('控制器与作品实体的片尾换算都委托给 OutroSkip', () {
    final controller = codeOnly(read('lib/domain/services/playback_controller.dart'));
    final getter = exprBody(controller, 'get outroStart');

    expect(
      getter.contains('OutroSkip.start(') && getter.contains('OutroSkip.effectiveOffset('),
      isTrue,
      reason: '`PlaybackController.outroStart` 没有走 `OutroSkip`。'
          '「手标 > 学习」这条链只能有一份实现 —— 各写一遍迟早漂移成'
          '「片头认手标、片尾只认学习」。',
    );

    final work = codeOnly(read('lib/domain/entities/media_work.dart'));
    for (final name in ['outroStart', 'learnedOutroStart']) {
      expect(
        blockBody(work, 'Duration? $name(Duration duration)').contains('OutroSkip.start('),
        isTrue,
        reason: '`MediaWork.$name` 没有委托给 `OutroSkip.start`。'
            '手标与学习读的是两组**独立**的列，但「片长 - 偏移」这条换算规则'
            '只能有一份 —— 各写一遍的典型症状是「手标的能跳、学出来的跳不了」。',
      );
    }
  });

  test('独立窗口改完片尾要能回主窗口落库', () {
    final code = codeOnly(read('lib/ui/windows/player_bridge_host.dart'));
    final body = blockBody(code, 'onSaveIntroRange');

    expect(
      body.contains('setWorkOutroOffset('),
      isTrue,
      reason: '`onSaveIntroRange` 没有调 `repo.setWorkOutroOffset`。'
          '独立窗口里标的片尾落不了库 —— 关掉窗口就没了，而界面上写着「已保存」。',
    );
  });
}
