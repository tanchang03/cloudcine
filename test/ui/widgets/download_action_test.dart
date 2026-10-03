import 'dart:io';

import 'package:cloudcine/ui/widgets/download_action.dart';
import 'package:flutter_test/flutter_test.dart';

/// 没有系统保存面板的平台（Android / TV）上，「文件存到哪」这条判定。
///
/// ## 为什么值得单独测
///
/// 这条路**做错了不报错**：`File.openWrite` 默认就是覆盖写，所以撞名时
/// 直接用原路径不会抛任何异常 —— 只是把用户上一次下载的同一个文件
/// **静默替换掉**。等到他发现时，旧的那份已经没了。
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cloudcine_name_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('不撞名时原样返回，不加后缀', () {
    final path = '${tmp.path}/片子.zip';
    expect(dedupePath(path), path,
        reason: '第一次下载不该被改名 —— 平白多一个 `(1)` 会让人以为下重了');
  });

  test('撞名时加 `(1)`，且后缀在扩展名**之前**', () {
    final path = '${tmp.path}/片子.zip';
    File(path).writeAsStringSync('第一份');

    final second = dedupePath(path);
    expect(second, '${tmp.path}/片子 (1).zip');
    expect(File(second).existsSync(), isFalse);

    File(second).writeAsStringSync('第二份');
    expect(dedupePath(path), '${tmp.path}/片子 (2).zip');
  });

  test('连扩展名都没有的文件也能去重', () {
    final path = '${tmp.path}/README';
    File(path).writeAsStringSync('x');
    expect(dedupePath(path), '${tmp.path}/README (1)');
  });

  test('多个点号时只认最后一段当扩展名', () {
    final path = '${tmp.path}/Show.S01E01.chs.srt';
    File(path).writeAsStringSync('x');
    expect(dedupePath(path), '${tmp.path}/Show.S01E01.chs (1).srt');
  });
}
