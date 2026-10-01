import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 凭证文件的对称加密。
///
/// 落盘结构：`magic(5) || salt(16) || nonce(16) || 密文 || mac(32)`
///
/// ## 为什么不是 AES-GCM
///
/// 本仓库只依赖 `package:crypto`（SHA-256 / HMAC），没有 AES 实现。
/// 为这一个文件引入 `cryptography` / `pointycastle` 不划算，所以这里用
/// **PRF 构造**：HMAC-SHA256 当伪随机函数，密钥用 RFC 5869 的 HKDF 派生，
/// 再用计数器模式产生密钥流。这不是「自己发明密码学」——
/// TLS 1.3 的密钥派生就是 HKDF，而「HMAC(密钥, nonce‖计数器)」当密钥流
/// 与 CTR 模式等价，安全性只依赖 HMAC-SHA256 是 PRF 这一个假设。
///
/// **唯一的前提是：同一密钥下 nonce 绝不重复。** 每次 [seal] 都新取
/// 16 字节随机数，密钥则每次都由 `salt` 重新派生 —— 两者都变，不会撞。
///
/// 认证用 **encrypt-then-MAC**（先加密、再对头部+密文算 MAC）。
/// 先验 MAC 再解密，所以**不会**拿被篡改的数据去喂密钥流。
///
/// ## ⚠️ 它保护不了什么
///
/// 密钥由本机标识（`IOPlatformUUID`）派生（见 `localKeyMaterial`），
/// 所以**任何能在本机以本用户身份跑起来的程序都能解开**。
/// 它防的是「`credentials.enc` 被单独拷走 / 被同步上传」。
///
/// 这是刻意的取舍，不是疏漏：macOS 上想让系统钥匙串**不弹框**，
/// 就必须有稳定的代码签名身份；本项目走 ad-hoc 签名（身份是 cdhash，
/// 每次重新构建都变），钥匙串那条路已实测走不通 —— 见 `SecureCredentialStore`。
class SecretCipher {
  SecretCipher(this.keyMaterial, {Random? random})
      : _random = random ?? Random.secure();

  /// 派生密钥用的材料。**不是**密钥本身。
  final String keyMaterial;

  final Random _random;

  /// 文件头。用来一眼认出「这是不是我们的文件」，也能让格式升级有据可依。
  static const List<int> magic = <int>[0x43, 0x4C, 0x44, 0x43, 0x31]; // "CLDC1"

  static const int saltLength = 16;
  static const int nonceLength = 16;
  static const int macLength = 32;

  /// HKDF 的 info。改它等于换密钥，**老文件会解不开**。
  static const String _info = 'cloudcine.credentials.v1';

  static final List<int> _infoBytes = utf8.encode(_info);

  /// 加密。返回可直接落盘的字节。
  Uint8List seal(String plaintext) {
    final salt = _randomBytes(saltLength);
    final nonce = _randomBytes(nonceLength);
    final keys = _deriveKeys(salt);

    final body = utf8.encode(plaintext);
    final ciphertext = _xor(body, _keystream(keys.enc, nonce, body.length));

    final header = <int>[...magic, ...salt, ...nonce];
    final mac = Hmac(sha256, keys.mac).convert(<int>[...header, ...ciphertext]).bytes;

    return Uint8List.fromList(<int>[...header, ...ciphertext, ...mac]);
  }

  /// 解密。**任何异常都返回 `null`**（magic 不对 / 太短 / MAC 不匹配）。
  ///
  /// 刻意不抛：调用方要的是「能不能拿到明文」这一个二元结论，
  /// 把「损坏」和「篡改」区分开对用户没有意义 —— 两者都只能让用户重新登录。
  String? open(List<int> blob) {
    final headerLength = magic.length + saltLength + nonceLength;
    if (blob.length < headerLength + macLength) return null;
    if (!_constantTimeEquals(blob.sublist(0, magic.length), magic)) return null;

    final salt = blob.sublist(magic.length, magic.length + saltLength);
    final nonce = blob.sublist(magic.length + saltLength, headerLength);
    final ciphertext = blob.sublist(headerLength, blob.length - macLength);
    final mac = blob.sublist(blob.length - macLength);

    final keys = _deriveKeys(salt);
    // 先验 MAC 再解密 —— 不拿没验过的数据去喂密钥流。
    final expected = Hmac(sha256, keys.mac)
        .convert(blob.sublist(0, blob.length - macLength))
        .bytes;
    if (!_constantTimeEquals(mac, expected)) return null;

    final plain = _xor(ciphertext, _keystream(keys.enc, nonce, ciphertext.length));
    try {
      return utf8.decode(plain);
    } on FormatException {
      // MAC 过了却解不出 UTF-8，说明密钥材料变了（比如换了机器/用户名）
      // 却碰巧撞上同一把盐 —— 概率极低，但返回 null 比抛出去好。
      return null;
    }
  }

  // -------------------------------------------------------------------
  // 密钥派生
  // -------------------------------------------------------------------

  /// HKDF-SHA256（RFC 5869）：extract + expand，一把取出 64 字节。
  ///
  /// 前 32 字节当加密密钥、后 32 字节当 MAC 密钥 —— **两个方向必须用不同的
  /// 密钥**，复用会让「加密」和「认证」两个原语的假设互相干扰。
  ({List<int> enc, List<int> mac}) _deriveKeys(List<int> salt) {
    final okm = _hkdf(utf8.encode(keyMaterial), salt, _infoBytes, 64);
    return (enc: okm.sublist(0, 32), mac: okm.sublist(32, 64));
  }

  static List<int> _hkdf(List<int> ikm, List<int> salt, List<int> info, int length) {
    final prk = Hmac(sha256, salt).convert(ikm).bytes;

    final out = <int>[];
    var previous = const <int>[];
    var counter = 1;
    while (out.length < length) {
      // T(i) = HMAC(prk, T(i-1) ‖ info ‖ i)
      previous = Hmac(sha256, prk)
          .convert(<int>[...previous, ...info, counter])
          .bytes;
      out.addAll(previous);
      counter++;
    }
    return out.sublist(0, length);
  }

  /// 密钥流：`HMAC(key, nonce ‖ 大端计数器)` 逐块拼出来。
  ///
  /// 与 CTR 模式等价 —— 计数器从 0 单调递增、长度固定 4 字节，
  /// 同一 nonce 下不会出现重复的输入块。
  static List<int> _keystream(List<int> key, List<int> nonce, int length) {
    if (length == 0) return const <int>[];

    final out = <int>[];
    var counter = 0;
    while (out.length < length) {
      out.addAll(Hmac(sha256, key).convert(<int>[...nonce, ..._be32(counter)]).bytes);
      counter++;
    }
    return out.sublist(0, length);
  }

  static List<int> _be32(int value) => <int>[
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  static List<int> _xor(List<int> a, List<int> b) {
    assert(a.length == b.length);
    final out = Uint8List(a.length);
    for (var i = 0; i < a.length; i++) {
      out[i] = a[i] ^ b[i];
    }
    return out;
  }

  /// 逐字节比较、不提前返回。防止「按耗时猜 MAC」。
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256));
}
