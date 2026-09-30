import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这条请求是**跨引擎**传的：它先被编码进方法通道，再由另一侧的
/// [PlayRequest.fromJson] 还原。
///
/// 所以「编解码对称」不是可选项 —— 一旦不对称，表现是「窗口起来了但什么都
/// 没播」，既不抛异常也没有日志。同理，请求头丢了的表现是夸克直链 412。
void main() {
  group('PlayRequest 编解码', () {
    test('字段能原样过一趟通道', () {
      const original = PlayRequest(
        url: 'https://cdn.example.com/a.m3u8?sign=abc',
        title: '银翼杀手',
        headers: <String, String>{
          'Cookie': 'k=v',
          'Referer': 'https://pan.quark.cn',
        },
        qualityLabel: '4k(2160p)',
        startPosition: Duration(minutes: 12, seconds: 3),
      );

      final restored = PlayRequest.fromJson(original.toJson());

      expect(restored, original);
      expect(restored!.headers['Cookie'], 'k=v');
      expect(restored.startPosition, const Duration(minutes: 12, seconds: 3));
    });

    test('请求头不能丢 —— 丢了就是夸克 412', () {
      const original = PlayRequest(
        url: 'https://cdn.example.com/a.m3u8',
        title: 'x',
        headers: <String, String>{'Cookie': 'k=v'},
      );

      expect(PlayRequest.fromJson(original.toJson())!.headers, {'Cookie': 'k=v'});
    });

    test('可选字段缺省时不崩', () {
      final restored = PlayRequest.fromJson(const <String, Object?>{
        'url': 'https://a/b.mp4',
        'title': 't',
      })!;

      expect(restored.headers, isEmpty);
      expect(restored.qualityLabel, isNull);
      expect(restored.startPosition, Duration.zero);
    });

    test('畸形输入一律返回 null，绝不抛异常', () {
      // 播放窗口拿到解不开的请求时，正确行为是安静地停在空舞台，
      // 而不是崩掉一个刚起来的窗口。
      const raws = <Object?>[
        null,
        'string',
        42,
        <String>[],
        <String, Object?>{},
        <String, Object?>{'url': ''},
        <String, Object?>{'url': 1},
      ];

      for (final raw in raws) {
        expect(() => PlayRequest.fromJson(raw), returnsNormally, reason: 'raw=$raw');
        expect(PlayRequest.fromJson(raw), isNull, reason: 'raw=$raw');
      }
    });

    test('请求头里混进非字符串值只丢那一项，不整条作废', () {
      final restored = PlayRequest.fromJson(const <String, Object?>{
        'url': 'https://a/b.mp4',
        'title': 't',
        'headers': <Object?, Object?>{'Cookie': 'k=v', 'Bad': 42},
      });

      expect(restored, isNotNull);
      expect(restored!.headers, {'Cookie': 'k=v'});
    });

    test('startPosition 为负 / 非整数时按 0 处理', () {
      for (final raw in const <Object?>[-5, 'abc', null, 1.5]) {
        final restored = PlayRequest.fromJson(<String, Object?>{
          'url': 'https://a/b.mp4',
          'title': 't',
          'startPositionMs': raw,
        })!;

        expect(restored.startPosition, Duration.zero, reason: 'raw=$raw');
      }
    });

    test('qualityId 要往返 —— 它是刷新直链时保住档位的唯一依据', () {
      const original = PlayRequest(
        url: 'https://a/b.mp4',
        title: 't',
        qualityId: '4k',
        qualityLabel: '4k(2160p)',
      );

      final restored = PlayRequest.fromJson(original.toJson())!;

      expect(restored.qualityId, '4k');
      // label 只用于显示，缺了它刷新照样能保住档位；反之不行。
      expect(restored.qualityLabel, '4k(2160p)');
    });

    test('qualityId 缺省或空串都归一成 null', () {
      for (final raw in const <Object?>[null, '', 42]) {
        final restored = PlayRequest.fromJson(<String, Object?>{
          'url': 'https://a/b.mp4',
          'title': 't',
          'qualityId': raw,
        })!;

        expect(restored.qualityId, isNull, reason: 'raw=$raw');
      }
    });

    test('档位不同就不相等 —— 否则「刷新后换了档」会被当成同一条请求', () {
      const a = PlayRequest(url: 'u', title: 't', qualityId: '4k');
      const b = PlayRequest(url: 'u', title: 't', qualityId: 'super');

      expect(a == b, isFalse);
    });
  });

  group('PlayRequest.describe', () {
    test('只出片名与档位，绝不带直链或请求头', () {
      const request = PlayRequest(
        url: 'https://cdn.example.com/a.m3u8?sign=SUPERSECRET',
        title: '银翼杀手',
        headers: <String, String>{'Cookie': 'SECRETCOOKIE'},
        qualityLabel: '4k(2160p)',
      );

      final text = request.describe();

      expect(text, contains('银翼杀手'));
      expect(text, contains('4k(2160p)'));
      // 诊断日志是给用户复制粘贴用的，不能成为泄露渠道。
      expect(text, isNot(contains('SUPERSECRET')));
      expect(text, isNot(contains('SECRETCOOKIE')));
      expect(request.toString(), isNot(contains('SUPERSECRET')));
    });

    test('没有档位标签时只出片名', () {
      const request = PlayRequest(url: 'https://a/b.mp4', title: 'x');

      expect(request.describe(), 'x');
    });
  });

  group('PlayRequest 值语义', () {
    test('字段相同即相等，请求头的键序不影响', () {
      const a = PlayRequest(
        url: 'u',
        title: 't',
        headers: <String, String>{'A': '1', 'B': '2'},
      );
      const b = PlayRequest(
        url: 'u',
        title: 't',
        headers: <String, String>{'B': '2', 'A': '1'},
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('请求头不同就不相等 —— 否则「带没带 Cookie」会被判成同一个请求', () {
      const a = PlayRequest(
        url: 'u',
        title: 't',
        headers: <String, String>{'Cookie': '1'},
      );
      const b = PlayRequest(
        url: 'u',
        title: 't',
        headers: <String, String>{'Cookie': '2'},
      );

      expect(a == b, isFalse);
    });
  });
}
