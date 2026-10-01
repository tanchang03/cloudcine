import 'package:cloudcine/core/utils/file_names.dart';
import 'package:flutter_test/flutter_test.dart';

/// 自然序比较。
///
/// 用错比较函数的后果**只在目录列表里看得见**：`第10期` 排在 `第2期` 前面。
/// 这不是「顺序不太好看」—— 用户翻目录时靠的就是数字顺序，乱掉之后
/// 找一集要从头翻到尾。
void main() {
  group('数字段按数值比', () {
    test('多位数比一位数大', () {
      expect(naturalCompare('第2期', '第10期'), lessThan(0));
      expect(naturalCompare('S01E02', 'S01E10'), lessThan(0));
      // 逐字符比较会得出相反结论（`'1' < '2'`），这条就是防它回退的。
      expect('第10期'.compareTo('第2期'), lessThan(0));
    });

    test('位数多的一定更大，不受 int 上限影响', () {
      // 文件名里的数字段长度不受控，解析成 int 会溢出。
      expect(naturalCompare('a99999999999999999999', 'a9999999999999999999'),
          greaterThan(0));
    });

    test('前导零不影响数值，但两个不同的名字仍有确定顺序', () {
      // `007` 与 `7` 数值相等，此时必须靠逐字符比较定序 ——
      // 返回 0 的话 `List.sort` 不保证稳定，列表每次重建都可能换位置。
      expect(naturalCompare('007', '7'), isNot(0));
      expect(naturalCompare('7', '007'), isNot(0));
    });

    test('数字段之后的字符继续参与比较', () {
      expect(naturalCompare('E01.mkv', 'E01.mp4'), lessThan(0));
      expect(naturalCompare('E02', 'E010'), lessThan(0));
    });
  });

  group('非数字段', () {
    test('大小写不敏感', () {
      expect(naturalCompare('abc', 'ABC'), isNot(0));
      expect(naturalCompare('abc', 'abd'), lessThan(0));
      // 只有大小写不同时，必须给出确定顺序（不能是 0）。
      expect(naturalCompare('ABC', 'abc'), isNot(0));
    });

    test('中文按码点比，结果稳定', () {
      expect(naturalCompare('电影', '剧集'), isNot(0));
      expect(naturalCompare('电影', '电影'), 0);
    });

    test('短的是长的前缀时，短的在前', () {
      expect(naturalCompare('电影', '电影2'), lessThan(0));
      expect(naturalCompare('Show', 'Show S02'), lessThan(0));
    });

    test('典型目录名排序', () {
      final names = ['第10期', '第2期', '第1期', '第20期'];
      names.sort(naturalCompare);
      expect(names, ['第1期', '第2期', '第10期', '第20期']);
    });

    test('数字开头的目录名', () {
      final names = ['2023', '1999', '2024', '1080p'];
      names.sort(naturalCompare);
      expect(names, ['1080p', '1999', '2023', '2024']);
    });
  });
}
