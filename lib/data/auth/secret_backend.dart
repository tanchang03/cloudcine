import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../core/diagnostics/diag_log.dart';
import 'secret_cipher.dart';

/// 键值型「安全存储」后端契约。
///
/// 只管「按 key 读写一段字符串」，**不管序列化** —— 序列化留在
/// `SecureCredentialStore` 里，这样换后端不会动到已落库的数据格式。
abstract class SecretBackend {
  /// 按平台挑后端。
  ///
  /// - **macOS → [EncryptedFileSecretBackend]**：系统钥匙串那条路已实测走不通，
  ///   理由见那个类的文档。
  /// - **其它平台 → [FlutterSecureStorageBackend]**：Keystore / DPAPI /
  ///   libsecret 都不依赖「代码签名身份」，没有 macOS 那个问题。
  ///
  /// [supportDirPath] 是应用支持目录（`getApplicationSupportDirectory()`），
  /// 加密文件放它下面。macOS 上必传。
  factory SecretBackend.forPlatform({required String supportDirPath}) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      return EncryptedFileSecretBackend(
        filePath: p.join(supportDirPath, 'credentials.enc'),
      );
    }
    return FlutterSecureStorageBackend();
  }

  /// 读。没有这个 key 返回 `null`（**不是**错误）。
  Future<String?> read(String key);

  /// 写（不存在就创建，存在就覆盖）。
  Future<void> write(String key, String value);

  /// 删。key 不存在时**不报错**。
  Future<void> delete(String key);

  /// 能否跨进程持久化。`false` 时 UI 应提示「本次会话有效」。
  bool get isPersistent;
}

/// 后端不可用（文件坏了 / 密钥变了 / 系统安全存储拒绝）。
///
/// 把各种底层异常统一成一种类型，调用方只需 catch 一个。
/// **注意**：这里不做「自动降级到内存」—— 降级策略属于
/// `SecureCredentialStore` 的决定，后端只负责如实报错。
class SecretBackendException implements Exception {
  const SecretBackendException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message（$cause）';
}

// ---------------------------------------------------------------------------
// macOS：加密文件
// ---------------------------------------------------------------------------

/// macOS 专用的凭证后端：**加密落一个文件，完全不碰系统钥匙串**。
///
/// ## 为什么不用钥匙串
///
/// 钥匙串条目的 ACL 只认「创建它的那一份代码签名」。本仓库走 ad-hoc 签名
/// （不落库任何签名身份，谁 clone 下来都能直接构建），而 ad-hoc 的身份就是
/// **cdhash** —— 每重新构建一次就变一次，ACL 永远对不上，
/// **每次启动都弹「请输入登录钥匙串密码」**。
///
/// 2026-10-01 实测过的两条岔路，都**不要再走**：
///
/// 1. **自建通道 + 写入「任何程序都可访问」的 ACL**：不行。
///    打包成真正的 .app、走 `open` 启动复测过（ad-hoc 签名，重建后 cdhash
///    从 `6c1d9c6e…` 变成 `d61f0379…`，路径不变）：
///    `read` 返回 `-128 errSecUserCanceled` 且**阻塞了 3.2 秒**（模态授权框），
///    而 `write.delete` 反而放行。两种 ACL 写法都试过 ——
///    「任意程序」（`SecTrustedApplicationCreateFromPath(nil, …)`）与
///    「app 自己的路径」，都不行。连 Apple 自带的 `/usr/bin/security` 去读
///    也拿到 `-128`。
/// 2. **加 `keychain-access-groups` entitlement**：更糟。它只能由描述文件下发，
///    Xcode 构建直接失败（`"Runner" requires a provisioning profile.`），
///    而且 **ad-hoc 签名下会让 app 启动即崩**：taskgated 判定受限签名无效，
///    进程被 SIGKILL，报 `EXC_CRASH (SIGKILL (Code Signature Invalid))` /
///    `Taskgated Invalid Signature`，崩溃报告没有任何调用栈。
///
/// 真正能免弹框的只有「稳定签名身份」（Developer ID）——
/// 那要给这个播放器签上公司证书，本项目不做。所以改成文件方案：
/// **零弹框、零授权、零签名依赖**。
///
/// ## ⚠️ 代价：这是「混淆级」保护，不是真加密
///
/// 密钥由本机标识（`IOPlatformUUID`）派生（见 [localKeyMaterial]），
/// 所以**任何能在本机以本用户身份跑起来的程序都能解开**。
/// 它防的是「`credentials.enc` 被单独拷走 / 被同步上传」，
/// 防不住本机上的其它程序。密码学细节见 [SecretCipher]。
///
/// ## 数据格式
///
/// 整个文件是**一个**加密块，里面是一张 `key → value` 的 JSON 表 ——
/// 与 [FlutterSecureStorageBackend] 的键空间一一对应，所以换后端不会
/// 影响上层。代价是每次写都要「读全表 → 改一项 → 写全表」，
/// 但凭证一共就两三条，无所谓。
class EncryptedFileSecretBackend implements SecretBackend {
  EncryptedFileSecretBackend({
    required this.filePath,
    Future<String> Function()? keyMaterial,
    Random? random,
  })  : _keyMaterial = keyMaterial ?? localKeyMaterial,
        _random = random;

  /// 加密文件的完整路径。
  final String filePath;

  final Future<String> Function() _keyMaterial;
  final Random? _random;

  @override
  bool get isPersistent => true;

  /// 「读改写」的串行队列。**这不是优化，是正确性的前提。**
  ///
  /// 整个文件是**一个**加密块，里面是一张 `key → value` 表 —— 于是每次写都是
  /// 「读全表 → 改一项 → 写全表」，典型的 read-modify-write。两个并发的写会各自
  /// 读到同一份快照、各自加自己的键、各自写回整表，**后写的那个把先写的键整个抹掉**。
  ///
  /// 这个竞态特别难查，因为它的表现完全不像出错：磁盘上文件完好、能正常解密、
  /// 日志里一个字都没有，用户只会看到「另一个网盘的凭证莫名其妙要重新登录」。
  ///
  /// 顺带也解决了 `_store` 里那个固定名 `.tmp` 的抢占问题 —— 操作不重叠，
  /// 就不会有两个写入者同时盯着同一个临时文件。
  Future<void> _queue = Future<void>.value();

  /// 把一次操作排进队列，保证本后端的任意两次操作**永不交错**。
  ///
  /// 注意异常处理：失败要原样交给调用方（`write` 的失败要让上层记日志），
  /// 但**绝不能让队列断掉** —— 队列一旦带着错误往下走，后续每次操作都会
  /// 收到上一次的异常，报的还不是真因。
  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  @override
  Future<String?> read(String key) =>
      _serialized(() async => (await _load())[key]);

  @override
  Future<void> write(String key, String value) => _serialized(() async {
        // ⚠️ 写路径**必须容忍坏文件**（`tolerateCorrupt: true`）。
        // 否则文件一旦解不开（损坏、或换了机器），写也会失败 → 用户陷进
        // 「登录成功 → 存不进去 → 下次启动又未登录」的死循环，
        // 而且**只在诊断日志里留一行**，从界面完全看不出来。
        // 宁可丢掉旧内容，也要让新凭证存得下去。
        final store = await _load(tolerateCorrupt: true);
        store[key] = value;
        await _store(store);
      });

  @override
  Future<void> delete(String key) => _serialized(() async {
        final file = File(filePath);
        if (!await file.exists()) return;

        Map<String, String> store;
        try {
          store = await _load();
        } on SecretBackendException {
          // 文件本来就解不开 —— 没有「保住其它键」可言，直接整个删掉，
          // 免得它一直卡在那里（写路径虽然能覆盖，但留着只会让人困惑）。
          diag.warn('凭证', '凭证文件解不开，直接删除：$filePath');
          await file.delete();
          return;
        }

        if (store.remove(key) == null) return; // 本来就没有 → 不白写一次盘
        await _store(store);
      });

  // -------------------------------------------------------------------
  // 文件读写
  // -------------------------------------------------------------------

  /// 读出整张表。
  ///
  /// [tolerateCorrupt] 为 `true` 时，**解不开的文件当成空表**而不是报错 ——
  /// 只有写路径会这么用，理由见 [write]。
  Future<Map<String, String>> _load({bool tolerateCorrupt = false}) async {
    final file = File(filePath);
    if (!await file.exists()) return <String, String>{};

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return <String, String>{};

    final plain = SecretCipher(await _keyMaterial(), random: _random).open(bytes);
    if (plain == null) {
      // 解不开 = 换了机器/用户名，或者文件被改过。
      if (tolerateCorrupt) {
        diag.warn('凭证', '凭证文件解不开，按空文件处理并覆盖写入');
        return <String, String>{};
      }
      // 抛出去让上层记一条明确的诊断日志，然后按「未登录」处理。
      throw const SecretBackendException('凭证文件解不开（密钥变了或文件被改动）');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(plain);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map) {
      if (tolerateCorrupt) {
        diag.warn('凭证', '凭证文件内容不是一张表，按空文件处理并覆盖写入');
        return <String, String>{};
      }
      throw const SecretBackendException('凭证文件内容不是一张表');
    }
    return <String, String>{
      for (final entry in decoded.entries) '${entry.key}': '${entry.value}',
    };
  }

  Future<void> _store(Map<String, String> store) async {
    final blob = SecretCipher(await _keyMaterial(), random: _random)
        .seal(jsonEncode(store));

    final file = File(filePath);
    await file.parent.create(recursive: true);

    // 先写临时文件再 rename：rename 在同一文件系统内是原子的，
    // 断电/崩溃时要么是旧文件、要么是新文件，不会留半个。
    final temp = File('$filePath.tmp');
    await temp.writeAsBytes(blob, flush: true);
    await temp.rename(filePath);
  }
}

/// 派生凭证文件密钥的机器标识。
///
/// 刻意**不**落盘：它必须能从当前环境重新算出来，否则换一次机器就解不开。
/// 反过来也意味着它不构成密钥管理 —— 见 [EncryptedFileSecretBackend] 的警告。
///
/// ## 为什么只用 `IOPlatformUUID`，不再拌主机名/用户名/家目录
///
/// 那三项**对「文件被拷到别的机器」这个威胁零收益** —— 拷走文件的人在自己
/// 机器上当然有自己的主机名和用户名，它们不是秘密。而 `IOPlatformUUID` 本身
/// 就是每台机器唯一、跨机器不可伪造的，已经足够把文件钉死在这台机器上。
///
/// 而把它们拌进来的**代价却是真的**：macOS 的 `Platform.localHostname` 跟着
/// 「电脑名称」走（系统设置 → 通用 → 关于本机 → 名称）。用户给自己的 Mac 改个
/// 名字，`gethostname()` 就变，`credentials.enc` 当场解不开 ——
/// 表现是**静默要求重新登录**，而且用户完全无从把这两件事联系起来。
/// 等于纯加故障面、零收益。
///
/// 只有拿不到 UUID 时（`ioreg` 被拦、非 macOS）才退回那三项做兜底 ——
/// 那时至少还有一层「不同用户互不相通」的弱绑定。
Future<String> localKeyMaterial() async {
  final uuid = await _platformUuid();
  if (uuid.isNotEmpty) return 'platform-uuid\n$uuid';

  // 兜底路径。这里才用主机名/用户名/家目录，理由见上。
  return <String>[
    'fallback',
    Platform.localHostname,
    Platform.environment['USER'] ?? '',
    Platform.environment['HOME'] ?? '',
  ].join('\n');
}

String? _cachedPlatformUuid;

Future<String> _platformUuid() async {
  if (_cachedPlatformUuid != null) return _cachedPlatformUuid!;
  if (!Platform.isMacOS) return _cachedPlatformUuid = '';

  try {
    // 从 IOKit 拿硬件 UUID。不用 `system_profiler`：那个要几秒钟。
    final result = await Process.run(
      'ioreg',
      <String>['-rd1', '-c', 'IOPlatformExpertDevice'],
    );
    final match = RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"')
        .firstMatch('${result.stdout}');
    _cachedPlatformUuid = match?.group(1) ?? '';
  } catch (e) {
    // 拿不到不影响功能（还有主机名/用户名兜底），只少一层机器绑定。
    diag.warn('凭证', '读不到 IOPlatformUUID，退化为主机名+用户名派生密钥：$e');
    _cachedPlatformUuid = '';
  }
  return _cachedPlatformUuid!;
}

// ---------------------------------------------------------------------------
// 其它平台：系统安全存储
// ---------------------------------------------------------------------------

/// 其它平台的安全存储后端（iOS / Android / Windows / Linux）。
///
/// 仍然是 `flutter_secure_storage`：Keystore / DPAPI / libsecret 那条路径
/// 不依赖「代码签名身份」，也就没有 macOS 上那个弹框问题。
class FlutterSecureStorageBackend implements SecretBackend {
  FlutterSecureStorageBackend({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  bool get isPersistent => true;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException catch (e) {
      throw SecretBackendException('安全存储读取失败（${e.code}）', cause: e.message);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException catch (e) {
      throw SecretBackendException('安全存储写入失败（${e.code}）', cause: e.message);
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on PlatformException catch (e) {
      throw SecretBackendException('安全存储删除失败（${e.code}）', cause: e.message);
    }
  }
}

/// 内存后端。**测试与「不持久化」模式用**。
///
/// 它存在的第二个理由是 Web：`flutter_secure_storage` 的 Web 实现只有
/// localStorage + 弱混淆，**不是真安全存储**，所以那条路上用这个。
class InMemorySecretBackend implements SecretBackend {
  InMemorySecretBackend([Map<String, String>? seed])
      : _store = <String, String>{...?seed};

  final Map<String, String> _store;

  @override
  bool get isPersistent => false;

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }
}
