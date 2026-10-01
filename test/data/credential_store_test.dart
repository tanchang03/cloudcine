import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloudcine/data/auth/secret_backend.dart';
import 'package:cloudcine/data/auth/secret_cipher.dart';
import 'package:cloudcine/data/auth/secure_credential_store.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 能记录调用、也能按需失败的假后端。
///
/// 用它而不是 [InMemorySecretBackend] 是为了两件事：
///   1. 断言「写进后端的 key 长什么样」（后端是**全用户共享**的命名空间，
///      裸 key 会撞别的用途，这条规则值得钉死）；
///   2. 模拟后端故障，验证降级行为。
class _RecordingBackend implements SecretBackend {
  final Map<String, String> store = <String, String>{};

  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;

  @override
  bool get isPersistent => true;

  @override
  Future<String?> read(String key) async {
    if (failRead) throw const SecretBackendException('读失败（测试注入）');
    return store[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw const SecretBackendException('写失败（测试注入）');
    store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw const SecretBackendException('删失败（测试注入）');
    store.remove(key);
  }
}

AuthCredential _credential({
  DriveProvider provider = DriveProvider.quark,
  Map<String, String>? cookies,
  Map<String, String>? tokens,
  Map<String, String>? extra,
  DateTime? capturedAt,
}) {
  return AuthCredential(
    provider: provider,
    mode: AuthMode.qrCode,
    capturedAt: capturedAt ?? DateTime(2026, 10, 1, 12, 30),
    cookies: cookies ?? const {'__pus': 'p1', '__puus': 'p2'},
    tokens: tokens ?? const {'access_token': 't1'},
    extra: extra ?? const {'device': '不该落库'},
  );
}

void main() {
  group('SecureCredentialStore 往返', () {
    test('存进去再读出来，cookie / token / 模式 / 时间都在', () async {
      final backend = _RecordingBackend();
      final store = SecureCredentialStore(backend: backend);

      await store.save(_credential());
      final loaded = await store.load(DriveProvider.quark);

      expect(loaded, isNotNull);
      expect(loaded!.provider, DriveProvider.quark);
      expect(loaded.mode, AuthMode.qrCode);
      expect(loaded.capturedAt, DateTime(2026, 10, 1, 12, 30));
      expect(loaded.cookies, {'__pus': 'p1', '__puus': 'p2'});
      expect(loaded.tokens, {'access_token': 't1'});
    });

    test('extra 不落库 —— 里面可能有设备指纹之类不该长期留的东西', () async {
      final backend = _RecordingBackend();
      final store = SecureCredentialStore(backend: backend);

      await store.save(_credential(extra: {'device': '指纹'}));
      final loaded = await store.load(DriveProvider.quark);

      expect(loaded!.extra, isEmpty);
      // 落库的原始 JSON 里也不能出现那个值。
      expect(backend.store.values.join(), isNot(contains('指纹')));
    });

    test('key 必须带 cloudcine.credential. 前缀', () async {
      final backend = _RecordingBackend();
      final store = SecureCredentialStore(backend: backend);

      await store.save(_credential());

      // 钥匙串是**整个用户共享**的命名空间：裸写 'quark' 会和别的应用撞。
      expect(backend.store.keys, contains('cloudcine.credential.quark'));
      expect(backend.store.keys, isNot(contains('quark')));
    });
  });

  group('已授权网盘索引', () {
    test('save 后出现在索引里，clear 后消失', () async {
      final store = SecureCredentialStore(backend: _RecordingBackend());

      expect(await store.authorizedProviders(), isEmpty);
      await store.save(_credential());
      expect(await store.authorizedProviders(), [DriveProvider.quark]);
      await store.clear(DriveProvider.quark);
      expect(await store.authorizedProviders(), isEmpty);
    });

    test('重复 save 不会把同一个网盘写两遍', () async {
      final store = SecureCredentialStore(backend: _RecordingBackend());

      await store.save(_credential(cookies: {'__pus': 'a'}));
      await store.save(_credential(cookies: {'__pus': 'b'}));

      expect(await store.authorizedProviders(), [DriveProvider.quark]);
      final loaded = await store.load(DriveProvider.quark);
      expect(loaded!.cookies['__pus'], 'b');
    });
  });

  group('后端故障时的降级 —— 这些是「改错不报错」类', () {
    test('写失败不抛出：落库失败不该让用户连本次会话都用不了', () async {
      final backend = _RecordingBackend()..failWrite = true;
      final store = SecureCredentialStore(backend: backend);

      // 抛出的话，QuarkAdapter.authorize 会在「凭证已校验通过」之后失败，
      // 报错还指向授权 —— 排查成本高得多。
      await expectLater(store.save(_credential()), completes);
      expect(await store.load(DriveProvider.quark), isNull);
    });

    test('读失败按「未授权」处理，不抛出', () async {
      final backend = _RecordingBackend()..failRead = true;
      final store = SecureCredentialStore(backend: backend);

      // 签名变更、权限被拒、通道没注册都走这条：应用要能起来，
      // 用户重新登录一次即可。
      expect(await store.load(DriveProvider.quark), isNull);
      expect(await store.authorizedProviders(), isEmpty);
    });

    test('删失败不抛出（内存里的会话已经清掉了）', () async {
      final backend = _RecordingBackend()..failDelete = true;
      final store = SecureCredentialStore(backend: backend);

      await expectLater(store.clear(DriveProvider.quark), completes);
    });

    test('后端回空串等于没存过 —— 不能拿 "" 去 jsonDecode', () async {
      final backend = _RecordingBackend()
        ..store['cloudcine.credential.quark'] = '';
      final store = SecureCredentialStore(backend: backend);

      expect(await store.load(DriveProvider.quark), isNull);
    });

    test('脏数据（非 JSON / 非对象）按未授权处理，不抛出', () async {
      final backend = _RecordingBackend()
        ..store['cloudcine.credential.quark'] = '这不是 JSON';
      final store = SecureCredentialStore(backend: backend);
      expect(await store.load(DriveProvider.quark), isNull);

      backend.store['cloudcine.credential.quark'] = '[1,2,3]';
      expect(await store.load(DriveProvider.quark), isNull);
    });

    test('索引是脏数据时返回空列表，不抛出', () async {
      final backend = _RecordingBackend()
        ..store['cloudcine.credential.providers'] = '{"not":"a list"}';
      final store = SecureCredentialStore(backend: backend);

      expect(await store.authorizedProviders(), isEmpty);
    });

    test('索引里有未知网盘 id 时跳过它，不影响已知的', () async {
      final backend = _RecordingBackend()
        ..store['cloudcine.credential.providers'] = '["quark","未来网盘"]';
      final store = SecureCredentialStore(backend: backend);

      expect(await store.authorizedProviders(), [DriveProvider.quark]);
    });
  });

  group('supportsPersistence', () {
    test('透传后端的持久化能力 —— UI 据此提示「本次会话有效」', () {
      expect(
        SecureCredentialStore(backend: _RecordingBackend()).supportsPersistence,
        isTrue,
      );
      expect(
        SecureCredentialStore(backend: InMemorySecretBackend())
            .supportsPersistence,
        isFalse,
      );
    });

    test('内存后端也能完整走完存 / 读 / 清', () async {
      final store = SecureCredentialStore(backend: InMemorySecretBackend());

      await store.save(_credential());
      expect((await store.load(DriveProvider.quark))!.cookies['__pus'], 'p1');
      await store.clear(DriveProvider.quark);
      expect(await store.load(DriveProvider.quark), isNull);
    });
  });

  group('EncryptedFileSecretBackend（macOS 走的就是这个）', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('cloudcine_cred_'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    EncryptedFileSecretBackend backend({
      String material = 'machine-uuid\nhost\nuser\n/home',
      String name = 'credentials.enc',
    }) =>
        EncryptedFileSecretBackend(
          filePath: '${dir.path}/$name',
          keyMaterial: () async => material,
          random: Random(3),
        );

    test('落盘的必须是密文 —— 文件里不能出现 cookie 的值', () async {
      final file = File('${dir.path}/credentials.enc');
      final store = SecureCredentialStore(backend: backend());

      await store.save(_credential(cookies: {'__pus': 'SUPER-SECRET-VALUE'}));

      expect(file.existsSync(), isTrue);
      final raw = file.readAsBytesSync();
      final asText = utf8.decode(raw, allowMalformed: true);
      // 这条是这套方案的**全部意义**：文件被单独拷走也不该泄露凭证。
      expect(asText.contains('SUPER-SECRET-VALUE'), isFalse);
      expect(asText.contains('__pus'), isFalse);
    });

    test('写入是原子的：不留 .tmp 残留', () async {
      final store = SecureCredentialStore(backend: backend());
      await store.save(_credential());

      // 先写临时文件再 rename；rename 失败或忘了删就会留下这个。
      expect(File('${dir.path}/credentials.enc.tmp').existsSync(), isFalse);
    });

    test('往返：存进去再读出来，cookie / token 都在', () async {
      final store = SecureCredentialStore(backend: backend());
      await store.save(_credential());

      final loaded = await store.load(DriveProvider.quark);
      expect(loaded!.cookies, {'__pus': 'p1', '__puus': 'p2'});
      expect(loaded.tokens, {'access_token': 't1'});
    });

    test('多次写入互不覆盖（键空间是共享的）', () async {
      final b = backend();
      await b.write('a', '1');
      await b.write('b', '2');
      await b.write('a', '3');

      expect(await b.read('a'), '3');
      expect(await b.read('b'), '2');
    });

    test('delete 之后读回 null；删不存在的 key 不报错', () async {
      final b = backend();
      await b.write('a', '1');
      await b.delete('a');
      expect(await b.read('a'), isNull);
      await expectLater(b.delete('从来不存在'), completes);
    });

    test('文件不存在时读回 null（第一次启动）', () async {
      expect(await backend().read('任何键'), isNull);
    });

    test('文件被改过一个字节 → 抛 SecretBackendException（不返回脏数据）', () async {
      final path = '${dir.path}/credentials.enc';
      final store = SecureCredentialStore(backend: backend());
      await store.save(_credential());

      final raw = File(path).readAsBytesSync();
      raw[raw.length - 1] ^= 0x01;
      File(path).writeAsBytesSync(raw);

      await expectLater(
        backend().read('cloudcine.credential.quark'),
        throwsA(isA<SecretBackendException>()),
      );
    });

    test('换机器（密钥材料变了）→ 解不开，按未登录处理', () async {
      final store = SecureCredentialStore(backend: backend());
      await store.save(_credential());

      // 表现必须是「读不到」而不是「读到垃圾」或「崩」。
      final other = SecureCredentialStore(backend: backend(material: '别的机器'));
      expect(await other.load(DriveProvider.quark), isNull);
    });

    test('文件被清空 → 当没有凭证，不抛', () async {
      final path = '${dir.path}/credentials.enc';
      final store = SecureCredentialStore(backend: backend());
      await store.save(_credential());
      File(path).writeAsBytesSync(const <int>[]);

      expect(await backend().read('cloudcine.credential.quark'), isNull);
    });

    test('文件损坏后再登录，必须能写进去（否则陷进死循环）', () async {
      final path = '${dir.path}/credentials.enc';
      File(path).writeAsBytesSync(List<int>.generate(64, (i) => i * 3 % 256));

      // 这是最容易漏的一条：写路径如果也跟着抛，用户就会
      // 「登录成功 → 存不进去 → 下次启动又未登录」，界面上还看不出原因。
      final store = SecureCredentialStore(backend: backend());
      await store.save(_credential());

      // 存进去了，而且真的读得回来。
      final loaded = await store.load(DriveProvider.quark);
      expect(loaded!.cookies['__pus'], 'p1');
    });

    test('文件内容是合法密文但不是一张表 → 写路径也照样覆盖', () async {
      final path = '${dir.path}/credentials.enc';
      // 用同一份密钥材料封一段「不是表」的 JSON 进去。
      File(path).writeAsBytesSync(
        SecretCipher('machine-uuid\nhost\nuser\n/home').seal('[1,2,3]'),
      );

      final store = SecureCredentialStore(backend: backend());
      await expectLater(store.save(_credential()), completes);
      expect((await store.load(DriveProvider.quark))!.cookies['__pus'], 'p1');
    });

    test('文件损坏时 delete 直接删掉整个文件，而不是卡住', () async {
      final path = '${dir.path}/credentials.enc';
      File(path).writeAsBytesSync(List<int>.generate(40, (i) => i + 1));

      final b = backend();
      await expectLater(b.delete('随便什么键'), completes);
      // 留着只会让人困惑；写路径能覆盖，但删就该删干净。
      expect(File(path).existsSync(), isFalse);
      expect(await b.read('随便什么键'), isNull);
    });

    test('目录不存在时会自己建出来', () async {
      final b = EncryptedFileSecretBackend(
        filePath: '${dir.path}/深/几层/credentials.enc',
        keyMaterial: () async => 'material',
        random: Random(3),
      );
      await expectLater(b.write('k', 'v'), completes);
      expect(await b.read('k'), 'v');
    });

    test('并发写不同的键：一个都不能丢（读全表→改→写全表必须串行）', () async {
      // 这个后端的写是「读全表 → 改一项 → 写全表」，而整个文件是**一个**加密块 ——
      // 也就是说它是典型的 read-modify-write，**天然有竞态**：
      // 两个并发 write 各自读到同一份快照，各自加自己的键，然后各自写回整表，
      // 后写的那个把先写的那个键整个抹掉。表现是「另一个网盘的凭证莫名其妙没了」，
      // 而磁盘上文件完好、解密也正常、没有任何报错。
      //
      // 所以「串行化」不是优化，是正确性的前提。
      final b = backend();

      await Future.wait(<Future<void>>[
        for (var i = 0; i < 20; i++) b.write('k$i', 'v$i'),
      ]);

      for (var i = 0; i < 20; i++) {
        expect(
          await b.read('k$i'),
          'v$i',
          reason: '第 $i 个键被另一次并发写的「写全表」覆盖掉了',
        );
      }
    });

    test('并发写与删除混在一起也不会留下半状态', () async {
      final b = backend();
      for (var i = 0; i < 5; i++) {
        await b.write('keep$i', 'v$i');
      }

      await Future.wait(<Future<void>>[
        for (var i = 0; i < 5; i++) b.delete('keep$i'),
        b.write('added', 'x'),
      ]);

      // 关键：不论这 6 个操作以什么顺序落地，结果都必须自洽 ——
      // 要么 added 在、要么不在，但**绝不能**出现「解不开」或半张表。
      expect(await b.read('added'), 'x');
      for (var i = 0; i < 5; i++) {
        expect(await b.read('keep$i'), isNull);
      }
    });
  });

  // -------------------------------------------------------------------
  // 密钥材料
  // -------------------------------------------------------------------

  group('密钥材料（localKeyMaterial）', () {
    // 这一组钉的是一条**会静默咬人**的规则：密钥材料里掺了什么，用户改了什么
    // 就会掉登录 —— 而掉登录在界面上只表现为「怎么又要扫码了」，
    // 用户完全无从把「我昨天改过电脑名称」和这件事联系起来。
    test('优先用 IOPlatformUUID，不掺主机名/家目录（改电脑名不该掉登录）', () async {
      final material = await localKeyMaterial();

      if (material.startsWith('platform-uuid\n')) {
        // 正常路径：ioreg 拿得到硬件 UUID，那它**独自**就够钉死这台机器了。
        expect(material, isNot(contains(Platform.localHostname)));

        final home = Platform.environment['HOME'];
        if (home != null && home.isNotEmpty) {
          expect(material, isNot(contains(home)));
        }
        final user = Platform.environment['USER'];
        if (user != null && user.isNotEmpty) {
          expect(material, isNot(contains(user)));
        }
      } else {
        // ioreg 被拦 / 非 macOS：这时才退回兜底材料（带主机名与用户名）。
        expect(material, startsWith('fallback\n'));
      }
    });

    test('同一台机器上重复取结果必须一致 —— 否则每次启动都解不开', () async {
      expect(await localKeyMaterial(), await localKeyMaterial());
    });
  });

  // -------------------------------------------------------------------
  // 平台路由
  // -------------------------------------------------------------------

  group('按平台挑后端', () {
    // ⚠️ 这一组钉的**就是本次改造的目的本身**，别删。
    //
    // 钥匙串在 ad-hoc 签名下**必然**每次启动弹「请输入登录钥匙串密码」
    // （ACL 只认 cdhash，而 cdhash 每次重建都变，详见
    // EncryptedFileSecretBackend 的类文档）。整套加密文件方案就是为了躲开它。
    //
    // 而「macOS 走哪个后端」这件事**没有任何别的地方会守**：
    // 谁哪天觉得 `flutter_secure_storage` 更"标准"、把 macOS 也塞进它，
    // 编译过、别的测试也全绿 —— 只有用户启动应用时会看到弹框，
    // 而那时没人会想到来跑测试找原因。
    //
    // ⚠️⚠️ 必须**显式**覆盖 `defaultTargetPlatform`，不能靠「测试跑在 macOS 上」。
    // framework 里 `defaultTargetPlatform` 有这么一段 assert：
    //     if (Platform.environment.containsKey('FLUTTER_TEST'))
    //       result = TargetPlatform.android;
    // 而 `flutter test` 正是会设 `FLUTTER_TEST` 的 —— 于是测试环境里
    // **所有平台一律被当成 android**。不覆盖的话这个用例测的是 android 那条路，
    // 跟 macOS 毫无关系（实测：它就是这么红起来的）。
    test('macOS 必须走加密文件，绝不能回到系统钥匙串', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final backend =
          SecretBackend.forPlatform(supportDirPath: '/tmp/cloudcine-路由用例');

      expect(backend, isA<EncryptedFileSecretBackend>());
      expect(
        (backend as EncryptedFileSecretBackend).filePath,
        endsWith('credentials.enc'),
        reason: '文件名是约定的一部分：用户要能照着文档去应用支持目录找它',
      );
    });

    test('其它平台仍走系统安全存储 —— 那边没有「签名身份」这个问题', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect(
        SecretBackend.forPlatform(supportDirPath: '/tmp/x'),
        isA<FlutterSecureStorageBackend>(),
      );
    });
  });

  // -------------------------------------------------------------------
  // 端到端：store 架在真正的加密文件后端上
  // -------------------------------------------------------------------

  group('端到端：SecureCredentialStore + 真加密文件', () {
    // 这一组补的是一个**真实的测试空洞**：
    //   - `SecureCredentialStore` 那几组用的是内存假后端（存的是明文），
    //     验的是「存/读/索引/降级」这套逻辑；
    //   - `EncryptedFileSecretBackend` 那组用的是**裸 key**、绕开了 store，
    //     验的是「加密/原子写/坏文件」。
    //
    // 两头都绿，**中间那一截却从没跑过** —— 真密钥材料 + 真加密 + 真文件，
    // 叠上 store 的「先写凭证、再读索引、再写索引」多段式，接起来到底能不能免登，
    // 在此之前没有任何用例回答。而用户唯一能感知的恰恰就是这一条。
    //
    // 所以这里刻意**不注入** keyMaterial，走真实的 `localKeyMaterial()`：
    // 这条路的重点就是「真的那一套」。
    late Directory dir;

    String pathOf() => '${dir.path}/credentials.enc';
    SecretBackend realBackend() => EncryptedFileSecretBackend(filePath: pathOf());

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cloudcine-e2e');
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('扫码登录存下 → 换全新实例重开 → 免登（这就是「重启」）', () async {
      final store = SecureCredentialStore(backend: realBackend());
      expect(
        store.supportsPersistence,
        isTrue,
        reason: 'UI 据此显示「永久」而不是「本次会话有效」—— 说错了用户会以为白登录了',
      );

      await store.save(_credential());
      expect(File(pathOf()).existsSync(), isTrue);

      // 磁盘上不能出现 cookie 明文 —— 这是整套方案的底线。
      final raw = String.fromCharCodes(File(pathOf()).readAsBytesSync());
      expect(raw, isNot(contains('__pus')), reason: '连 cookie 名都不该出现，何况值');
      expect(raw, isNot(contains('access_token')));

      // 「重启」= 全新 store + 全新后端实例，任何内存缓存都不在。
      final reopened = SecureCredentialStore(backend: realBackend());
      final restored = await reopened.load(DriveProvider.quark);

      expect(restored, isNotNull);
      expect(restored!.cookies['__pus'], 'p1');
      expect(restored.cookies['__puus'], 'p2');
      expect(restored.tokens['access_token'], 't1');
      expect(restored.mode, AuthMode.qrCode);
      expect(restored.capturedAt, DateTime(2026, 10, 1, 12, 30));
      expect(restored.extra, isEmpty, reason: 'extra 从不落库，重启后当然也没有');

      // 索引也要跟着活过来：设置页靠它列出「已授权网盘」。
      expect(
        await reopened.authorizedProviders(),
        contains(DriveProvider.quark),
      );
    });

    test('退出登录 → 重开 → 真的没登录（索引也不能剩）', () async {
      final store = SecureCredentialStore(backend: realBackend());
      await store.save(_credential());
      await store.clear(DriveProvider.quark);

      final reopened = SecureCredentialStore(backend: realBackend());
      expect(await reopened.load(DriveProvider.quark), isNull);
      expect(
        await reopened.authorizedProviders(),
        isNot(contains(DriveProvider.quark)),
        reason: '索引没清干净的话，设置页会显示一个「已授权但读不出凭证」的鬼条目',
      );
    });

    test('连着存两个网盘：后一次写不能把前一次挤掉', () async {
      // 盯的是真实加密文件那条读写链上的覆盖问题：store 的 save 是
      // 「写凭证 → 读索引 → 写索引」，而每次写都是「读全表 → 改 → 写全表」。
      // 只要有一步用错了快照，第二次 save 就会把第一个网盘抹掉，
      // 而表现是「另一个网盘莫名其妙要重新登录」。
      final store = SecureCredentialStore(backend: realBackend());
      await store.save(_credential());
      await store.save(
        _credential(provider: DriveProvider.baidu, cookies: {'BDUSS': 'b1'}),
      );

      final reopened = SecureCredentialStore(backend: realBackend());
      expect((await reopened.load(DriveProvider.quark))!.cookies['__pus'], 'p1');
      expect((await reopened.load(DriveProvider.baidu))!.cookies['BDUSS'], 'b1');
      expect(
        await reopened.authorizedProviders(),
        containsAll(<DriveProvider>[DriveProvider.quark, DriveProvider.baidu]),
      );
    });
  });
}
