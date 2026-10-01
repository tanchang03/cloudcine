import 'package:cloudcine/core/utils/drive_paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// 路径归一化。
///
/// 这条规则唯一的、也是最容易漏掉的后果：**同一个目录出现两种键**。
/// 扫描器写的是 `/电影/`（带结尾斜杠），而界面/剪贴板给的是 `/电影`；
/// 不做归一化时目录树会多出一个同名节点、「按目录筛文件」一条都查不到 ——
/// 两种表现都不报错，只是结果变空或变乱。
void main() {
  group('normalizeDrivePath', () {
    test('根的各种写法都归到 `/`', () {
      for (final raw in ['', '   ', '/', '//', r'\', '.']) {
        expect(normalizeDrivePath(raw), driveRootPath, reason: '输入：$raw');
      }
    });

    test('去掉结尾斜杠 —— 扫描器写的路径一律带它', () {
      // `MediaItem.dirPath` 是 `/电影/`，树内部必须统一成 `/电影`，
      // 否则 `/电影` 与 `/电影/` 会变成两个不同的键。
      expect(normalizeDrivePath('/电影/'), '/电影');
      expect(normalizeDrivePath('/电影/科幻/2023/'), '/电影/科幻/2023');
    });

    test('补齐前导斜杠 —— 用户可能只打一段目录名', () {
      expect(normalizeDrivePath('电影'), '/电影');
      expect(normalizeDrivePath('电影/科幻'), '/电影/科幻');
    });

    test('反斜杠与重复斜杠一并收拾', () {
      // 从 Windows 上复制过来的路径是反斜杠；多打的斜杠在手工输入时很常见。
      expect(normalizeDrivePath(r'\电影\科幻'), '/电影/科幻');
      expect(normalizeDrivePath('//电影//科幻//'), '/电影/科幻');
    });

    test('首尾空格不算目录名的一部分', () {
      // 从详情页「复制路径」粘过来的文本经常带一个换行或空格。
      expect(normalizeDrivePath('  /电影/  '), '/电影');
    });

    test('`..` 当成普通目录名，不当上级', () {
      // 网盘上真的可以有叫 `..` 的目录。把它解释成「上级」会把两个不相干
      // 的目录并成一个，而用户在界面上看不出发生了什么。
      expect(normalizeDrivePath('/电影/../科幻'), '/电影/../科幻');
    });

    test('幂等：归一化过的路径再归一化不变', () {
      for (final raw in ['/电影/科幻/', '电影', r'\a\b', '/']) {
        final once = normalizeDrivePath(raw);
        expect(normalizeDrivePath(once), once, reason: '输入：$raw');
      }
    });
  });

  group('drivePathWithTrailingSlash', () {
    test('补上结尾斜杠，根保持单独的 `/`', () {
      expect(drivePathWithTrailingSlash('/电影'), '/电影/');
      expect(drivePathWithTrailingSlash('/电影/'), '/电影/');
      // 根**不能**变成 `//`：`MediaItem.dirPath` 里根就是 `/`。
      expect(drivePathWithTrailingSlash('/'), '/');
      expect(drivePathWithTrailingSlash(''), '/');
    });
  });

  group('drivePathParent / drivePathName', () {
    test('父目录逐级上退，根的父亲是自己', () {
      expect(drivePathParent('/电影/科幻/2023'), '/电影/科幻');
      expect(drivePathParent('/电影'), '/');
      // 根的父亲是自己 —— 调用方据此判断「已经在最上层」，
      // 不需要再额外判空，也就不会漏判。
      expect(drivePathParent('/'), '/');
    });

    test('末段名', () {
      expect(drivePathName('/电影/科幻'), '科幻');
      expect(drivePathName('/电影/'), '电影');
      expect(drivePathName('/'), '/');
    });

    test('末段名里有点号、括号、空格都要原样保留', () {
      expect(drivePathName('/电影/流浪地球2 (2023)'), '流浪地球2 (2023)');
      expect(drivePathName('/剧/Show.S01'), 'Show.S01');
    });
  });

  group('drivePathSegments', () {
    test('根没有段，其余按层切开', () {
      expect(drivePathSegments('/'), isEmpty);
      expect(drivePathSegments('/电影'), ['电影']);
      expect(drivePathSegments('/电影/科幻/2023'), ['电影', '科幻', '2023']);
    });
  });

  group('drivePathIsUnder', () {
    test('自己算在自己的下面', () {
      // 因为调用方的语义是「这个目录下的文件」—— 直接躺在这个目录里的
      // 文件必须被算进去。
      expect(drivePathIsUnder('/电影', '/电影'), isTrue);
    });

    test('前缀必须按**整段**比，不能只比字符串', () {
      // 只比 `startsWith` 的话 `/电影2` 会被判成 `/电影` 的子目录，
      // 于是「按目录筛文件」会混进一个完全不相干的目录的内容。
      expect(drivePathIsUnder('/电影2', '/电影'), isFalse);
      expect(drivePathIsUnder('/电影/科幻', '/电影'), isTrue);
    });

    test('根之下包含一切', () {
      expect(drivePathIsUnder('/随便什么', '/'), isTrue);
      expect(drivePathIsUnder('/', '/'), isTrue);
    });

    test('两边形状不一致也要判对', () {
      expect(drivePathIsUnder('/电影/科幻/', '/电影'), isTrue);
      expect(drivePathIsUnder('电影/科幻', '/电影/'), isTrue);
    });
  });

  group('drivePathJoin', () {
    // 它拼出来的形状必须与 `MediaItem.dirPath` 完全一致（带结尾斜杠），
    // 否则目录视图按路径归并时同一个目录会裂成两个键 —— 表现是
    // 「已入库」标记时有时无。
    test('拼出来的子目录路径一律带结尾斜杠', () {
      expect(drivePathJoin('/', '电影'), '/电影/');
      expect(drivePathJoin('/电影', '科幻'), '/电影/科幻/');
      expect(drivePathJoin('/电影/', '科幻'), '/电影/科幻/');
      expect(drivePathJoin('电影', '科幻'), '/电影/科幻/');
      expect(drivePathJoin(r'\电影\科幻', '2023'), '/电影/科幻/2023/');
    });

    test('父路径是根时不会拼出双斜杠', () {
      expect(drivePathJoin('/', '电影'), isNot(contains('//')));
      expect(drivePathJoin('//', '电影'), '/电影/');
    });
  });
}
