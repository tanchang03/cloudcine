import 'package:cloudcine/data/remote/quark/quark_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测夸克上传收尾的 XML 构造。
///
/// 这组用例钉的是**两条错了不报错、只表现为「合并上传失败」的规则**：
///   - ETag 必须带双引号（OSS 要求原样回填 PUT 响应里的值）；
///   - 分片必须按 part_number 升序。
/// 两者任一做错，OSS 都只会回一个笼统的失败，排查成本极高 ——
/// 所以用纯函数把它们钉死在测试里。
void main() {
  group('buildCompleteMultipartXml', () {
    test('ETag 必须被双引号包起来', () {
      final xml = QuarkAdapter.buildCompleteMultipartXml([
        {'part_number': 1, 'etag': 'ABC123'},
      ]);

      expect(xml, contains('<ETag>"ABC123"</ETag>'));
      // 反例：不带引号会让 OSS 认为分片不匹配
      expect(xml, isNot(contains('<ETag>ABC123</ETag>')));
    });

    test('分片按 part_number 升序排列，即使传入是乱序', () {
      final xml = QuarkAdapter.buildCompleteMultipartXml([
        {'part_number': 3, 'etag': 'C'},
        {'part_number': 1, 'etag': 'A'},
        {'part_number': 2, 'etag': 'B'},
      ]);

      final i1 = xml.indexOf('<PartNumber>1</PartNumber>');
      final i2 = xml.indexOf('<PartNumber>2</PartNumber>');
      final i3 = xml.indexOf('<PartNumber>3</PartNumber>');
      expect(i1, greaterThan(0));
      expect(i1, lessThan(i2));
      expect(i2, lessThan(i3));
    });

    test('XML 头与根节点固定', () {
      final xml = QuarkAdapter.buildCompleteMultipartXml([
        {'part_number': 1, 'etag': 'X'},
      ]);

      expect(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'), isTrue);
      expect(xml, contains('<CompleteMultipartUpload>'));
      expect(xml, contains('</CompleteMultipartUpload>'));
    });

    test('多分片：每片都出现，数量对得上', () {
      final xml = QuarkAdapter.buildCompleteMultipartXml([
        for (var i = 1; i <= 5; i++) {'part_number': i, 'etag': 'E$i'},
      ]);

      expect('<Part>'.allMatches(xml).length, 5);
      for (var i = 1; i <= 5; i++) {
        expect(xml, contains('<PartNumber>$i</PartNumber>'));
        expect(xml, contains('<ETag>"E$i"</ETag>'));
      }
    });

    test('缺字段不炸：part_number 缺失当 0、etag 缺失当空串', () {
      final xml = QuarkAdapter.buildCompleteMultipartXml([
        {'etag': 'ONLY_ETAG'},
        {'part_number': 2},
      ]);

      expect(xml, contains('<PartNumber>0</PartNumber>'));
      expect(xml, contains('<ETag>"ONLY_ETAG"</ETag>'));
      expect(xml, contains('<ETag>""</ETag>'));
    });

    test('单分片（小文件）也走同一格式', () {
      final xml = QuarkAdapter.buildCompleteMultipartXml([
        {'part_number': 1, 'etag': 'SINGLE'},
      ]);

      expect(xml, contains('<PartNumber>1</PartNumber>'));
      expect(xml, contains('<ETag>"SINGLE"</ETag>'));
    });
  });
}
