import 'dart:convert';
import 'dart:typed_data';

import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/data/http/token_bucket.dart';
import 'package:cloudcine/data/remote/quark/quark_adapter.dart';
import 'package:cloudcine/data/remote/quark/quark_endpoints.dart';
import 'package:cloudcine/domain/adapters/credential_store.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// 夸克**上传编排**的回归测试。
///
/// ## 为什么必须有这条测试
///
/// 2026-10-02 的真实现场：设置页点「上传备份」失败，
/// `DriveException(unknown, code=43001, http=400, 完成上传: request cpp error[complete file failed!])`。
/// 日志显示 pre → hash → 3 片 PUT **全部 200**，只有收尾那一步 400。
///
/// 根因是收尾少做了一步、且另一步的参数写错：
///   1. 必须先向 OSS 提交 `CompleteMultipartUpload` XML（带 `x-oss-callback`），
///      让对象存储真正把分片合并成一个对象；
///   2. 再调 `/file/upload/finish`，body 只有 `{task_id, obj_key}`。
///
/// 旧实现只做了第 2 步，而且 body 写成了 `{task_id, part_info_list}`。
///
/// `quark_upload_complete_test.dart` 钉的是 XML 的**形状**；这条测试钉的是
/// **编排** —— 谁先谁后、每个端点收到什么 body、哪些请求必须发生。
/// 这类错误**不抛异常**，只让上传静默失败（或 43001），所以必须锁住。
void main() {
  const taskId = 'TASK-1';
  const bucket = 'mybucket';
  const objKey = 'obj/hello.ccbak';
  const uploadId = 'UPLOAD-1';
  const uploadUrl = 'https://oss-cn-zhangjiakou.aliyuncs.com';
  const newFid = 'FID-AFTER-UPLOAD';

  /// 预上传响应：正常返回 COS 信息 + callback。
  Map<String, Object?> preBody() => {
        'status': 200,
        'code': 0,
        'data': {
          'task_id': taskId,
          'bucket': bucket,
          'obj_key': objKey,
          'upload_id': uploadId,
          'auth_info': {'access_key': 'AK', 'secret_key': 'SK'},
          'upload_url': uploadUrl,
          'part_size': 4,
          'callback': {'callbackUrl': 'https://drive-pc.quark.cn/cb'},
        },
      };

  Map<String, Object?> hashBody({required bool finish, String? fid}) => {
        'status': 200,
        'code': 0,
        'data': {
          'finish': finish,
          if (fid != null) 'fid': fid,
        },
      };

  Map<String, Object?> authBody() => {
        'status': 200,
        'code': 0,
        'data': {'auth_key': 'AUTH-KEY-1'},
      };

  Map<String, Object?> finishBody() => {
        'status': 200,
        'code': 0,
        'data': {'fid': newFid},
      };

  group('分片上传的编排顺序', () {
    test('收尾必须两步：OSS 合并 → finish，且 finish 只收 {task_id, obj_key}',
        () async {
      final (:adapter, :http) = await readyUploadAdapter(
        pre: preBody(),
        hash: hashBody(finish: false),
        auth: authBody(),
        finish: finishBody(),
      );

      final fid = await adapter.uploadFile(
        parentId: 'PDIR',
        fileName: 'hello.ccbak',
        bytes: List<int>.generate(10, (i) => i), // 10B ÷ 4B = 3 片
      );

      expect(fid, newFid);

      // ---- 编排顺序：pre → hash → auth×3 → auth(合并) → finish ----
      expect(
        http.postPaths,
        [
          QuarkEndpoints.uploadPre,
          QuarkEndpoints.uploadHash,
          QuarkEndpoints.uploadAuth, // 片 1
          QuarkEndpoints.uploadAuth, // 片 2
          QuarkEndpoints.uploadAuth, // 片 3
          QuarkEndpoints.uploadAuth, // 合并前再取一次授权
          QuarkEndpoints.uploadFinish,
        ],
        reason: '顺序错了（尤其把 finish 提到 OSS 合并之前）就是 43001 的成因',
      );

      // ---- 分片 PUT：3 次，partNumber 升序 ----
      expect(http.puts.length, 3);
      expect(
        http.puts.map((p) => _queryOf(p.url)['partNumber']).toList(),
        ['1', '2', '3'],
      );
      // 每片都必须带上授权头
      for (final p in http.puts) {
        expect(p.headers?['Authorization'], 'AUTH-KEY-1');
      }

      // ---- OSS 合并：POST 原始 XML 到 OSS，带 x-oss-callback ----
      expect(http.posts.length, 1,
          reason: '必须向 OSS 提交一次 CompleteMultipartUpload，否则分片不会被合并');
      final ossPost = http.posts.single;
      expect(_queryOf(ossPost.url)['uploadId'], uploadId);
      expect(ossPost.headers?['x-oss-callback'], isNotNull,
          reason: '缺 x-oss-callback 时 OSS 合并不回调夸克，对象不会入库');
      expect(ossPost.headers?['Content-Type'], 'application/xml');
      expect(ossPost.headers?['Content-MD5'], isNotNull);

      // XML 内容：ETag 带引号、PartNumber 升序
      final xml = utf8.decode(ossPost.body);
      expect(xml, contains('<ETag>"etag-1"</ETag>'),
          reason: 'PUT 返回的 ETag 带引号 → 代码先剥引号再回填，XML 里必须重新带上');
      expect(xml.indexOf('<PartNumber>1</PartNumber>'),
          lessThan(xml.indexOf('<PartNumber>2</PartNumber>')));
      expect(xml.indexOf('<PartNumber>2</PartNumber>'),
          lessThan(xml.indexOf('<PartNumber>3</PartNumber>')));

      // ---- finish 的 body —— 这一条就是 43001 的直接回归守卫 ----
      final finishCall =
          http.calls.lastWhere((c) => c.path == QuarkEndpoints.uploadFinish);
      expect(
        finishCall.body,
        {'task_id': taskId, 'obj_key': objKey},
        reason: 'finish 的 body 只能是 task_id + obj_key。'
            '写成 {task_id, part_info_list} 正是 43001 的成因',
      );
      expect(
        (finishCall.body as Map).containsKey('part_info_list'),
        isFalse,
        reason: '分片信息只属于 OSS 的 CompleteMultipartUpload，不属于 finish',
      );
    });

    test('小文件只有一片，照样走完整的两步收尾', () async {
      final (:adapter, :http) = await readyUploadAdapter(
        pre: preBody(),
        hash: hashBody(finish: false),
        auth: authBody(),
        finish: finishBody(),
      );

      await adapter.uploadFile(
        parentId: '',
        fileName: 'tiny.ccbak',
        bytes: const [1, 2, 3], // 3B < 4B → 1 片
      );

      expect(http.puts.length, 1);
      expect(http.posts.length, 1, reason: '哪怕只有一片也要走 OSS 合并');
      expect(
        http.postPaths.last,
        QuarkEndpoints.uploadFinish,
        reason: 'finish 必须排在 OSS 合并之后',
      );
    });

    test('part_size 缺省时回落到 4MB（大文件被正确切分）', () async {
      final pre = preBody();
      (pre['data'] as Map).remove('part_size');
      final (:adapter, :http) = await readyUploadAdapter(
        pre: pre,
        hash: hashBody(finish: false),
        auth: authBody(),
        finish: finishBody(),
      );

      await adapter.uploadFile(
        parentId: '',
        fileName: 'big.bin',
        bytes: List<int>.filled(4 * 1024 * 1024 + 1, 7), // 4MiB + 1B → 2 片
      );

      expect(http.puts.length, 2);
    });
  });

  group('秒传（hash 命中）', () {
    test('finish=true 时直接返回 fid，绝不做分片与 OSS 合并', () async {
      final (:adapter, :http) = await readyUploadAdapter(
        pre: preBody(),
        hash: hashBody(finish: true, fid: 'INSTANT-FID'),
        auth: authBody(),
        finish: finishBody(),
      );

      final fid = await adapter.uploadFile(
        parentId: '',
        fileName: 'known.ccbak',
        bytes: List<int>.generate(10, (i) => i),
      );

      expect(fid, 'INSTANT-FID');
      expect(http.puts, isEmpty, reason: '秒传命中不该再传任何分片');
      expect(http.posts, isEmpty, reason: '秒传命中不该做 OSS 合并');
      expect(
        http.postPaths,
        [QuarkEndpoints.uploadPre, QuarkEndpoints.uploadHash],
        reason: '只该打 pre + hash 两个请求',
      );
    });
  });

  group('预上传响应不完整时必须在动分片之前就报错', () {
    test('缺 bucket/obj_key/upload_id → 抛 malformedResponse', () async {
      final pre = preBody();
      (pre['data'] as Map).remove('bucket');
      final (:adapter, :http) = await readyUploadAdapter(
        pre: pre,
        hash: hashBody(finish: false),
        auth: authBody(),
        finish: finishBody(),
      );

      await expectLater(
        adapter.uploadFile(
          parentId: '',
          fileName: 'x.bin',
          bytes: List<int>.generate(10, (i) => i),
        ),
        throwsA(isA<DriveException>()
            .having((e) => e.type, 'type', DriveErrorType.malformedResponse)),
      );
      expect(http.puts, isEmpty, reason: '拿不到 COS 信息就不该开始传分片');
    });

    test('缺 callback → 合并阶段报错（而不是静默成功）', () async {
      final pre = preBody();
      (pre['data'] as Map).remove('callback');
      final (:adapter, :http) = await readyUploadAdapter(
        pre: pre,
        hash: hashBody(finish: false),
        auth: authBody(),
        finish: finishBody(),
      );

      await expectLater(
        adapter.uploadFile(
          parentId: '',
          fileName: 'x.bin',
          bytes: List<int>.generate(10, (i) => i),
        ),
        throwsA(isA<DriveException>()
            .having((e) => e.type, 'type', DriveErrorType.malformedResponse)),
      );
      expect(http.posts, isEmpty, reason: '没有 callback 就不该发 OSS 合并请求');
    });
  });

  group('回调与进度', () {
    test('onProgress 单调递增，最后一次等于总大小', () async {
      final (:adapter, http: _) = await readyUploadAdapter(
        pre: preBody(),
        hash: hashBody(finish: false),
        auth: authBody(),
        finish: finishBody(),
      );

      final seen = <int>[];
      await adapter.uploadFile(
        parentId: '',
        fileName: 'p.bin',
        bytes: List<int>.generate(10, (i) => i),
        onProgress: (sent, total) => seen.add(sent),
      );

      expect(seen, [4, 8, 10], reason: '每片一片回填一次，末次等于总大小');
    });
  });
}

/// 取 URL 的查询参数（大小写敏感即可，OSS 用 partNumber / uploadId）。
Map<String, String> _queryOf(String url) => Uri.parse(url).queryParameters;

/// 造一个已完成会话校验、且带上传路由的适配器。
///
/// `part_size` 由调用方在 `pre` 里给（默认 4 字节，方便用小文件造多片）。
Future<({QuarkAdapter adapter, _FakeUploadHttp http})> readyUploadAdapter({
  required Map<String, Object?> pre,
  required Map<String, Object?> hash,
  required Map<String, Object?> auth,
  required Map<String, Object?> finish,
}) async {
  final http = _FakeUploadHttp({
    QuarkEndpoints.member: {
      'status': 200,
      'code': 0,
      'data': {'member_type': 'SUPER_VIP'},
    },
    QuarkEndpoints.uploadPre: pre,
    QuarkEndpoints.uploadHash: hash,
    QuarkEndpoints.uploadAuth: auth,
    QuarkEndpoints.uploadFinish: finish,
  });
  final adapter = QuarkAdapter(
    http: http,
    credentialStore: _FakeStore(),
    // 单测不真的 sleep：节流桶用假 delay。
    linkBucket: TokenBucket(ratePerSecond: 1.0, delay: (d) async {}),
    listBucket: TokenBucket(ratePerSecond: 3.0, delay: (d) async {}),
  );
  await adapter.restoreSession();
  return (adapter: adapter, http: http);
}

/// 按路径分发预置响应的假客户端，**额外记录** OSS 的 PUT/POST 原始调用。
class _FakeUploadHttp implements HttpClientLike {
  _FakeUploadHttp(this.routes);

  final Map<String, Map<String, Object?>?> routes;

  /// 普通 JSON 请求（pre / hash / auth / finish / member）。
  final List<({String method, String path, Object? body})> calls = [];

  /// OSS 分片 PUT。
  final List<({String url, List<int> body, Map<String, String>? headers})> puts =
      [];

  /// OSS 完成合并 POST。
  final List<({String url, List<int> body, Map<String, String>? headers})>
      posts = [];

  List<String> get postPaths => [
        for (final c in calls)
          if (c.method == 'POST') c.path,
      ];

  static const List<String> _known = [
    QuarkEndpoints.member,
    QuarkEndpoints.uploadPre,
    QuarkEndpoints.uploadHash,
    QuarkEndpoints.uploadAuth,
    QuarkEndpoints.uploadFinish,
  ];

  static String _pathOf(String url) {
    final p = Uri.parse(url).path;
    for (final key in _known) {
      if (p.endsWith(key)) return key;
    }
    return p;
  }

  HttpResult _respond(String url) {
    final path = _pathOf(url);
    if (!routes.containsKey(path)) {
      return HttpResult.networkFailure('未预置响应：$path');
    }
    final body = routes[path];
    if (body == null) return HttpResult.networkFailure('模拟网络失败：$path');
    return HttpResult(statusCode: 200, json: body);
  }

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) async {
    calls.add((method: 'GET', path: _pathOf(url), body: null));
    return _respond(url);
  }

  @override
  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    calls.add((method: 'POST', path: _pathOf(url), body: body));
    return _respond(url);
  }

  @override
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async =>
      null;

  @override
  Future<String> putBytes(
    String url, {
    required List<int> body,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    puts.add((url: url, body: body, headers: headers));
    // OSS 真实返回的 ETag 是带双引号的；适配器负责剥掉，再在 XML 里回填。
    return '"etag-${_queryOf(url)['partNumber']}"';
  }

  @override
  Future<String> postBytes(
    String url, {
    required List<int> body,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    posts.add((url: url, body: body, headers: headers));
    return '{"status":200,"code":0}';
  }

  @override
  void close() {}
}

class _FakeStore implements CredentialStore {
  @override
  Future<void> save(AuthCredential credential) async {}

  @override
  Future<AuthCredential?> load(DriveProvider provider) async => AuthCredential(
        provider: DriveProvider.quark,
        mode: AuthMode.manualCookie,
        capturedAt: DateTime(2026, 10, 2),
        cookies: const {'__pus': 'PUSVALUE', '__puus': 'PUUSVALUE'},
      );

  @override
  Future<void> clear(DriveProvider provider) async {}

  @override
  Future<List<DriveProvider>> authorizedProviders() async =>
      const [DriveProvider.quark];

  @override
  bool get supportsPersistence => true;
}
