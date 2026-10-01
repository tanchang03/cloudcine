import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloudcine/data/auth/secret_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定种子的伪随机源。只为让「结构对不对」这件事可复现，
/// **不要**在生产代码里这么用 —— 默认是 `Random.secure()`。
///
/// ⚠️ 必须是**同一个实例**反复用：每次 `Random(1)` 都从头开始，
/// 会给出同一串随机数，于是两次 seal 拿到同样的盐和 nonce —— 那正好是
/// 下面「两次密文必须不同」那条要防的事。
final Random _sharedRandom = Random(1);

void main() {
  SecretCipher cipher([String material = 'machine-uuid\nhost\nuser\n/home']) =>
      SecretCipher(material, random: _sharedRandom);

  group('SecretCipher 往返', () {
    test('加密再解密拿回原文', () {
      final sealed = cipher().seal('{"__pus":"abc"}');
      expect(cipher().open(sealed), '{"__pus":"abc"}');
    });

    test('空串也能往返 —— 不能把「空」当成「失败」', () {
      final sealed = cipher().seal('');
      expect(cipher().open(sealed), '');
    });

    test('跨多个密钥流块的长明文也要对（每块 32 字节，这里远超）', () {
      // 计数器拼接写错时，超过 32 字节的明文就会从第 33 字节开始乱掉。
      final long = List.generate(500, (i) => '第$i条-cookie-value').join('|');
      final sealed = cipher().seal(long);
      expect(cipher().open(sealed), long);
    });

    test('非 ASCII（中文、emoji）往返不炸', () {
      const text = '夸克网盘 🎬 凭证 —— 中文';
      expect(cipher().open(cipher().seal(text)), text);
    });
  });

  group('每次加密都换盐和 nonce —— 否则同一明文会出同一密文', () {
    test('两次 seal 同一明文，密文必须不同', () {
      final a = cipher().seal('same-plaintext');
      final b = cipher().seal('same-plaintext');

      expect(a, isNot(equals(b)));
      // 但都能解开。
      expect(cipher().open(a), 'same-plaintext');
      expect(cipher().open(b), 'same-plaintext');
    });

    test('头部结构固定：magic + 16 字节盐 + 16 字节 nonce', () {
      final sealed = cipher().seal('x');
      expect(sealed.sublist(0, SecretCipher.magic.length), SecretCipher.magic);
      // 明文 1 字节 → 密文 1 字节 → 总长 = 5 + 16 + 16 + 1 + 32
      expect(sealed.length, 5 + 16 + 16 + 1 + 32);
    });

    test('两次的盐与 nonce 不同', () {
      final a = cipher().seal('x');
      final b = cipher().seal('x');
      final saltA = a.sublist(5, 5 + SecretCipher.saltLength);
      final saltB = b.sublist(5, 5 + SecretCipher.saltLength);
      expect(saltA, isNot(equals(saltB)));
    });
  });

  group('认证：任何改动都必须解不开（返回 null，不抛异常）', () {
    test('改密文里一个字节 → null', () {
      final sealed = Uint8List.fromList(cipher().seal('secret'));
      // 密文从 5+16+16 开始，改它。
      sealed[5 + 16 + 16] ^= 0x01;
      expect(cipher().open(sealed), isNull);
    });

    test('改 MAC 一个字节 → null', () {
      final sealed = Uint8List.fromList(cipher().seal('secret'));
      sealed[sealed.length - 1] ^= 0x01;
      expect(cipher().open(sealed), isNull);
    });

    test('改盐 → null（盐参与密钥派生，MAC 也覆盖了它）', () {
      final sealed = Uint8List.fromList(cipher().seal('secret'));
      sealed[5] ^= 0x01;
      expect(cipher().open(sealed), isNull);
    });

    test('改 nonce → null', () {
      final sealed = Uint8List.fromList(cipher().seal('secret'));
      sealed[5 + 16] ^= 0x01;
      expect(cipher().open(sealed), isNull);
    });

    test('截断 → null', () {
      final sealed = cipher().seal('secret');
      expect(cipher().open(sealed.sublist(0, sealed.length - 1)), isNull);
      expect(cipher().open(sealed.sublist(0, 10)), isNull);
    });

    test('magic 不对 → null（一眼认出不是我们的文件）', () {
      final sealed = Uint8List.fromList(cipher().seal('secret'));
      sealed[0] = 0x00;
      expect(cipher().open(sealed), isNull);
    });

    test('空字节 → null，不抛', () {
      expect(cipher().open(const <int>[]), isNull);
    });

    test('拿别的密钥材料解 → null（换机器/换用户名的情形）', () {
      final sealed = SecretCipher('machine-A\nhost\nuser\n/home').seal('secret');
      expect(SecretCipher('machine-B\nhost\nuser\n/home').open(sealed), isNull);
    });

    test('随机字节喂进去不抛异常', () {
      final noise = List<int>.generate(200, (i) => (i * 37 + 11) % 256);
      expect(cipher().open(noise), isNull);
    });
  });

  group('派生：不同密钥材料必须得出不同密钥', () {
    test('同材料同盐同 nonce 才可复现（这里用同一把注入随机源验证）', () {
      // 两个 cipher 用**同一个种子** → 盐与 nonce 相同 → 密文必须逐字节相同。
      // 这验证「密钥派生是确定性的」；一旦不是，重启后就解不开自己的文件。
      final a = SecretCipher('material', random: Random(7)).seal('hello');
      final b = SecretCipher('material', random: Random(7)).seal('hello');
      expect(a, equals(b));
    });

    test('材料差一个字符，密文就完全不同', () {
      final a = SecretCipher('material', random: Random(7)).seal('hello');
      final b = SecretCipher('material ', random: Random(7)).seal('hello');
      expect(a, isNot(equals(b)));
    });
  });

  group('落盘的东西里不能出现明文', () {
    test('密文与原始 JSON 之间没有可见的重叠', () {
      const payload = '{"cookies":{"__pus":"VERY-SECRET-TOKEN"}}';
      final sealed = cipher().seal(payload);
      // latin1 解码只是为了「用肉眼可查的方式」扫一遍；解不出来不算错。
      final asText = String.fromCharCodes(sealed);
      expect(asText.contains('VERY-SECRET-TOKEN'), isFalse);
      expect(asText.contains('cookies'), isFalse);
      // 明文能出现在里面的话，加密就是假的。
      expect(utf8.decode(sealed, allowMalformed: true).contains('__pus'), isFalse);
    });
  });
}
