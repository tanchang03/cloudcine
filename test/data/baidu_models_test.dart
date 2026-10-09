import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/data/remote/baidu/baidu_endpoints.dart';
import 'package:cloudcine/data/remote/baidu/baidu_models.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/quality_option.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:flutter_test/flutter_test.dart';

/// 百度响应 → 领域模型的映射。
///
/// ## 这一组测试守的是「**不报错**的那一类故障」
///
/// 映射器里几乎每一处判错都**不会抛异常**，只会让结果变得安静地不对：
///   - 列表位置认错 → 列表永远为空 → 扫描器认为「这个网盘一个文件都没有」；
///   - `isdir` 语义照抄夸克 → **整个目录树反过来**（文件当目录递归、
///     目录当文件入库）；
///   - `fs_id` 走 `toString()` → 数字型 ID 变成 `1234567890.0`，
///     于是「同一条记录每次算出来的主键都不一样」；
///   - `dlink` 不补 scheme → 播放器拿到一个没有 host 的 URI。
///
/// 这些全都只能靠测试钉住。
void main() {
  HttpResult res(Map<String, Object?>? body, {int status = 200}) =>
      HttpResult(statusCode: status, json: body);

  group('listItemsOf：列表在**顶层**，不在 data.list', () {
    test('百度实际形状（顶层 list）', () {
      final r = res({
        'errno': 0,
        'list': [
          {'fs_id': 1, 'server_filename': 'a.mkv', 'isdir': 0},
        ],
        'request_id': 123,
      });
      expect(BaiduMapper.listItemsOf(r), hasLength(1));
    });

    test('顶层 info（/api/filemetas 的形状）', () {
      final r = res({
        'errno': 0,
        'info': [
          {'fs_id': 2, 'path': '/a.mkv', 'dlink': 'https://x/y'},
        ],
      });
      expect(BaiduMapper.listItemsOf(r), hasLength(1));
    });

    test('退到 data.list —— 防御未来改版', () {
      final r = res({
        'errno': 0,
        'data': {
          'list': [
            {'fs_id': 3, 'server_filename': 'c.mkv'},
          ],
        },
      });
      expect(BaiduMapper.listItemsOf(r), hasLength(1));
    });

    test('顶层 list 为空数组时退到 data.list（别被空数组骗住）', () {
      final r = res({
        'errno': 0,
        'list': <Object?>[],
        'data': {
          'list': [
            {'fs_id': 4, 'server_filename': 'd.mkv'},
          ],
        },
      });
      expect(BaiduMapper.listItemsOf(r), hasLength(1));
    });

    test('没有列表时返回空，而不是抛', () {
      expect(BaiduMapper.listItemsOf(res({'errno': 0})), isEmpty);
      expect(BaiduMapper.listItemsOf(res(null)), isEmpty);
    });
  });

  group('parseIsDirectory：⛔ isdir 的 0/1 语义与夸克**相反**', () {
    test('isdir=1 是目录，isdir=0 是文件', () {
      expect(BaiduMapper.parseIsDirectory({'isdir': 1}), isTrue);
      expect(BaiduMapper.parseIsDirectory({'isdir': 0}), isFalse);
    });

    test('字符串与布尔形态都认（服务端返回类型不稳定）', () {
      expect(BaiduMapper.parseIsDirectory({'isdir': '1'}), isTrue);
      expect(BaiduMapper.parseIsDirectory({'isdir': '0'}), isFalse);
      expect(BaiduMapper.parseIsDirectory({'isdir': true}), isTrue);
      expect(BaiduMapper.parseIsDirectory({'isdir': false}), isFalse);
      expect(BaiduMapper.parseIsDirectory({'isdir': 'true'}), isTrue);
    });

    test('缺失时**保守判为文件** —— 判成目录会让 BFS 队列爆炸', () {
      expect(BaiduMapper.parseIsDirectory({}), isFalse);
      expect(BaiduMapper.parseIsDirectory({'size': 100}), isFalse);
    });

    test('toEntry 把 isdir=1 映射成 isDirectory=true（端到端一次）', () {
      final dir = BaiduMapper.toEntry({
        'fs_id': 100,
        'server_filename': '电影',
        'isdir': 1,
        'path': '/电影',
      });
      final file = BaiduMapper.toEntry({
        'fs_id': 101,
        'server_filename': 'a.mkv',
        'isdir': 0,
        'size': 1024,
        'path': '/电影/a.mkv',
      });

      expect(dir!.isDirectory, isTrue);
      expect(file!.isDirectory, isFalse);
      // 目录不报体积 / 时长 / 缩略图 —— 报了会让列表显示「0 B 的目录」。
      expect(dir.sizeBytes, 0);
      expect(dir.durationMs, isNull);
      expect(dir.thumbnailUrl, isNull);
    });
  });

  group('fs_id → 字符串主键', () {
    test('数字型 fs_id 不带小数点（主键是文本，带 .0 就每次都不一样）', () {
      expect(
        BaiduMapper.toEntry({
          'fs_id': 1234567890,
          'server_filename': 'a.mkv',
        })!.id,
        '1234567890',
      );
    });

    test('JSON 解析器给整数型 double 时也走 toInt', () {
      expect(
        BaiduMapper.toEntry({
          'fs_id': 1234567890.0,
          'server_filename': 'a.mkv',
        })!.id,
        '1234567890',
      );
    });

    test('字符串型 fs_id 原样保留', () {
      expect(
        BaiduMapper.toEntry({
          'fs_id': '987654321',
          'server_filename': 'a.mkv',
        })!.id,
        '987654321',
      );
    });

    test('缺 fs_id 或文件名时跳过脏数据，而不是造一条 id 为空的记录', () {
      expect(BaiduMapper.toEntry({'server_filename': 'a.mkv'}), isNull);
      expect(BaiduMapper.toEntry({'fs_id': 1}), isNull);
      expect(BaiduMapper.toEntry({'fs_id': 1, 'server_filename': ''}), isNull);
    });
  });

  group('toEntry：字段名与单位', () {
    test('名称字段是 server_filename，不是 name', () {
      final e = BaiduMapper.toEntry({
        'fs_id': 1,
        'server_filename': '流浪地球.mkv',
      });
      expect(e!.name, '流浪地球.mkv');
    });

    test('duration 单位是**秒**，转毫秒', () {
      final e = BaiduMapper.toEntry({
        'fs_id': 1,
        'server_filename': 'a.mkv',
        'duration': 5400,
      });
      expect(e!.durationMs, 5400000);
    });

    test('duration=0 归一成 null（显示 00:00 会让人以为文件是空的）', () {
      final e = BaiduMapper.toEntry({
        'fs_id': 1,
        'server_filename': 'a.mkv',
        'duration': 0,
      });
      expect(e!.durationMs, isNull);
    });

    test('server_mtime 是 unix **秒**', () {
      final e = BaiduMapper.toEntry({
        'fs_id': 1,
        'server_filename': 'a.mkv',
        'server_mtime': 1759900000,
      });
      expect(e!.modifiedAt, isNotNull);
      expect(e.modifiedAt!.year, greaterThan(2020));
    });

    test('path 直接来自响应（百度给的是完整路径，不必扫描器拼）', () {
      final e = BaiduMapper.toEntry({
        'fs_id': 1,
        'server_filename': 'a.mkv',
        'path': '/电影/科幻/a.mkv',
      });
      expect(e!.path, '/电影/科幻/a.mkv');
    });
  });

  group('parsePathIndex：路径缓存的数据来源', () {
    test('列表项自带 path ⇒ 白捡一批 fs_id → path', () {
      final r = res({
        'errno': 0,
        'list': [
          {'fs_id': 11, 'server_filename': 'a', 'isdir': 1, 'path': '/a'},
          {'fs_id': 12, 'server_filename': 'b', 'isdir': 1, 'path': '/b'},
        ],
      });
      expect(
        BaiduMapper.parsePathIndex(r),
        {'11': '/a', '12': '/b'},
      );
    });

    test('没有 path 的项不进索引（进了会污染缓存，让取链打错路径）', () {
      final r = res({
        'errno': 0,
        'list': [
          {'fs_id': 11, 'server_filename': 'a'},
        ],
      });
      expect(BaiduMapper.parsePathIndex(r), isEmpty);
    });
  });

  group('dlink：协议相对地址必须补 scheme', () {
    test('//d.pcs.baidu.com/… → https://d.pcs.baidu.com/…', () {
      final uri = BaiduMapper.dlinkOf({
        'dlink': '//d.pcs.baidu.com/file/abc?fid=1',
      });
      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.host, 'd.pcs.baidu.com');
    });

    test('绝对地址原样用', () {
      final uri = BaiduMapper.dlinkOf({'dlink': 'https://x.com/a'});
      expect(uri!.toString(), 'https://x.com/a');
    });

    test('也认 url / download_url（三条路由的字段名不一样）', () {
      expect(BaiduMapper.dlinkOf({'url': 'https://x/a'}), isNotNull);
      expect(BaiduMapper.dlinkOf({'download_url': 'https://x/a'}), isNotNull);
      expect(BaiduMapper.dlinkOf({'link': 'https://x/a'}), isNotNull);
    });

    test('没有地址字段时返回 null（调用方据此换下一条路由）', () {
      expect(BaiduMapper.dlinkOf({'path': '/a.mkv'}), isNull);
      expect(BaiduMapper.dlinkOf({'dlink': ''}), isNull);
    });

    test('parseDlink 先扫列表，再扫顶层', () {
      final fromList = res({
        'errno': 0,
        'list': [
          {'dlink': 'https://from-list'},
        ],
      });
      expect(BaiduMapper.parseDlink(fromList).toString(), 'https://from-list');

      final fromTop = res({'errno': 0, 'dlink': 'https://from-top'});
      expect(BaiduMapper.parseDlink(fromTop).toString(), 'https://from-top');

      expect(BaiduMapper.parseDlink(res({'errno': 0})), isNull);
    });
  });

  group('toStreamTicket：直链请求头', () {
    /// 按给定**形状**造票据（形状由 [BaiduMapper.dlinkHeaders] 决定，
    /// 与适配器走的是同一个函数 —— 断言的就是真实形状）。
    StreamTicket ticket({
      String userAgent = BaiduEndpoints.netdiskDlinkUserAgent,
      String cookieHeader = '',
      bool includeCookie = true,
      bool includeReferer = true,
      DateTime? now,
    }) =>
        BaiduMapper.toStreamTicket(
          url: Uri.parse('https://d.pcs.baidu.com/a'),
          headers: BaiduMapper.dlinkHeaders(
            userAgent: userAgent,
            cookieHeader: cookieHeader,
            includeCookie: includeCookie,
            includeReferer: includeReferer,
          ),
          now: now,
        );

    test('官方路由（xpan）直链：UA 是 pan.baidu.com', () {
      final t = ticket(userAgent: BaiduEndpoints.officialDlinkUserAgent);
      expect(t.headers['User-Agent'], 'pan.baidu.com');
    });

    test('crack 形状：UA 是 netdisk', () {
      expect(ticket().headers['User-Agent'], 'netdisk');
    });

    test('⛔ 形状开关必须能试出「不带 Cookie / 不带 Referer」', () {
      // 这两个开关是 2026-10-09 那轮对照实验留下的：当时要能逐条试
      // 「带/不带 Cookie」「带/不带 Referer」。结论是**必须带 Cookie**
      // （见 `BaiduAdapter._dlinkHeaders`），但开关本身仍有价值 ——
      // 官方 xpan 路由与 crack 路由的形状不同，靠它区分。
      final bare = ticket(includeCookie: false, includeReferer: false);
      expect(bare.headers.containsKey('Cookie'), isFalse);
      expect(bare.headers.containsKey('Referer'), isFalse);
      expect(bare.headers['User-Agent'], 'netdisk');

      final noReferer = ticket(cookieHeader: 'BDUSS=xxx', includeReferer: false);
      expect(noReferer.headers['Cookie'], 'BDUSS=xxx');
      expect(noReferer.headers.containsKey('Referer'), isFalse);
    });

    test('有会话时带 Cookie，没有时不带空 Cookie 头', () {
      expect(ticket(cookieHeader: 'BDUSS=xxx').headers['Cookie'], 'BDUSS=xxx');
      expect(ticket().headers.containsKey('Cookie'), isFalse);
    });

    test('默认形状带 Referer（网页域）', () {
      expect(ticket().headers['Referer'], '${BaiduEndpoints.panHost}/');
    });

    test('expiresAt = 取链时刻 + 8 小时（dlink 不带过期时间戳）', () {
      final now = DateTime(2026, 10, 8, 12);
      final t = ticket(now: now);
      expect(t.expiresAt, now.add(BaiduEndpoints.dlinkTtl));
      expect(t.expiresAt!.difference(now), const Duration(hours: 8));
    });

    test('支持 Range（能拖进度条）', () {
      expect(ticket().supportsRange, isTrue);
    });
  });

  group('parseVipType：字段可能包在 data 里，也可能在顶层', () {
    test('data.vip_type', () {
      expect(
        BaiduMapper.parseVipType({
          'data': {'vip_type': 2},
        }),
        BaiduVipType.svip,
      );
    });

    test('顶层 vip_type', () {
      expect(BaiduMapper.parseVipType({'vip_type': 1}), BaiduVipType.vip);
    });

    test('超过 svip 的值也归到 svip（别溢出成普通用户）', () {
      expect(BaiduMapper.parseVipType({'vip_type': 9}), BaiduVipType.svip);
    });

    test('字符串形态 product_name 兜底', () {
      expect(
        BaiduMapper.parseVipType({'product_name': 'SVIP'}),
        BaiduVipType.svip,
      );
      expect(
        BaiduMapper.parseVipType({'product_name': 'vip'}),
        BaiduVipType.vip,
      );
    });

    test('认不出来时返回 normal 而不是抛 —— 抛会让容量条一起不显示', () {
      expect(BaiduMapper.parseVipType({}), BaiduVipType.normal);
      expect(BaiduMapper.parseVipType({'foo': 'bar'}), BaiduVipType.normal);
    });
  });

  group('mergeAccountInfo / mergeQuota', () {
    CloudAccount base() => CloudAccount(
          provider: DriveProvider.baidu,
          authMode: AuthMode.qrCode,
          authorizedAt: DateTime(2026, 10, 8),
        );

    test('昵称优先 netdisk_name，uk 作为 userId', () {
      final a = BaiduMapper.mergeAccountInfo(base(), {
        'data': {
          'netdisk_name': '云影测试号',
          'uk': 123456789,
          'avatar_url': 'https://x/avatar',
          'vip_type': 2,
        },
      });
      expect(a.displayName, '云影测试号');
      expect(a.userId, '123456789');
      expect(a.avatarUrl, 'https://x/avatar');
      expect(a.memberLabel, '超级会员');
    });

    test('容量在顶层也能认（/api/quota 的实际形状）', () {
      final a = BaiduMapper.mergeQuota(base(), {
        'total': 2199023255552,
        'used': 1099511627776,
      });
      expect(a.storageTotalBytes, 2199023255552);
      expect(a.storageUsedBytes, 1099511627776);
      expect(a.storageRatio, closeTo(0.5, 0.001));
    });

    test('容量为 0 时当「不知道」而不是「用满了」', () {
      final a = BaiduMapper.mergeQuota(base(), {'total': 0, 'used': 0});
      expect(a.storageTotalBytes, isNull);
      expect(a.hasStorageInfo, isFalse);
    });
  });

  group('toQualityOption：转码档', () {
    test('id 是稳定字符串（会被持久化到 playback_prefs）', () {
      final q = BaiduMapper.toQualityOption(type: BaiduResolution.p720);
      expect(q.id, 'baidu_2');
      expect(BaiduResolution.typeFromId(q.id), BaiduResolution.p720);
    });

    test('label 是客户端菜单文案，短名另有一份（电视 chip 只放短名）', () {
      final q = BaiduMapper.toQualityOption(type: BaiduResolution.k4);
      expect(q.label, '4K 原画');
      expect(BaiduResolution.shortLabelFor(BaiduResolution.k4), '4K');
    });

    test('⛔ 转码档**都不是**原画 —— 否则默认播放会走转码流', () {
      for (final type in BaiduResolution.all) {
        final q = BaiduMapper.toQualityOption(type: type);
        expect(q.isOriginal, isFalse, reason: '档位 $type 不该被标成原画');
      }
    });

    test('没有地址时 isAvailable=false（UI 置灰而不是隐藏）', () {
      final q = BaiduMapper.toQualityOption(type: BaiduResolution.p480);
      expect(q.isAvailable, isFalse);

      final withUrl = BaiduMapper.toQualityOption(
        type: BaiduResolution.p480,
        url: Uri.parse('https://x/a'),
      );
      expect(withUrl.isAvailable, isTrue);
    });

    test('SVIP 档位带「超级会员专享」说明，非 SVIP 档位不带', () {
      expect(
        BaiduMapper.toQualityOption(type: BaiduResolution.p480).detail,
        isNull,
      );
      expect(
        BaiduMapper.toQualityOption(type: BaiduResolution.p720).detail,
        '超级会员专享',
      );
      expect(
        BaiduMapper.toQualityOption(type: BaiduResolution.intelligentHd).detail,
        '智能高清增强',
      );
    });
  });

  group('BaiduResolution：档位表与会员门禁', () {
    test('默认档位：非 SVIP 480P，SVIP 1080P（客户端两套默认值）', () {
      expect(BaiduResolution.defaultFor(BaiduVipType.normal), BaiduResolution.p480);
      expect(BaiduResolution.defaultFor(BaiduVipType.vip), BaiduResolution.p480);
      expect(BaiduResolution.defaultFor(BaiduVipType.svip), BaiduResolution.p1080);
    });

    test('切档是 SVIP 特权：>480P 的档位都要 SVIP', () {
      expect(BaiduResolution.requiresSvip(BaiduResolution.p360), isFalse);
      expect(BaiduResolution.requiresSvip(BaiduResolution.p480), isFalse);
      expect(BaiduResolution.requiresSvip(BaiduResolution.p720), isTrue);
      expect(BaiduResolution.requiresSvip(BaiduResolution.k4), isTrue);
      expect(BaiduResolution.requiresSvip(BaiduResolution.intelligentHd), isTrue);
    });

    test('档位枚举值与客户端逐字一致（0..6）', () {
      expect(BaiduResolution.p360, 0);
      expect(BaiduResolution.p480, 1);
      expect(BaiduResolution.p720, 2);
      expect(BaiduResolution.p1080, 3);
      expect(BaiduResolution.k2, 4);
      expect(BaiduResolution.k4, 5);
      expect(BaiduResolution.intelligentHd, 6);
      expect(BaiduResolution.none, -1);
    });

    test('heightFor 让清晰度菜单能正确排序', () {
      expect(BaiduResolution.heightFor(BaiduResolution.p1080), 1080);
      expect(BaiduResolution.heightFor(BaiduResolution.k4), 2160);
      // 帧彩映画是 AI 增强而非固定分辨率 —— 给 null 让排序器按 id 排。
      expect(BaiduResolution.heightFor(BaiduResolution.intelligentHd), isNull);
    });
  });

  group('原画哨兵值', () {
    test('baiduOriginalQualityId 就是全应用共用的 kOriginalQualityId', () {
      // ⛔ 这两个值必须**逐字相同**。它不是一个「百度的 id」，而是
      // `QualityLabels.isOriginal` / `sortWeight` 认的那个哨兵
      // （`_originalWeight = -100000`）。
      // 一旦有人把百度的原画 id 写成 `'baidu_origin'` 之类，
      // `isOriginal` 会静默返回 false，默认播放就变成转码流 ——
      // 而**不报任何错**，只是画质悄悄掉了。
      expect(baiduOriginalQualityId, kOriginalQualityId);
    });
  });

  group('category：决定走哪条直链通道', () {
    // 快通道（`origin=dlna`）实测 1410 KB/s（视频）/ 1024 KB/s（音频），
    // 普通通道只有 ~80 KB/s —— 差 15~30 倍。判错**不报错**，只是慢 30 倍，
    // 所以这两个判定必须被钉住。

    test('categoryOf 读的是 info[] 里那个数字', () {
      HttpResult res(Object? category) => HttpResult(
            statusCode: 200,
            json: {
              'errno': 0,
              'info': [
                {'fs_id': 1, 'category': category},
              ],
            },
          );

      expect(BaiduMapper.categoryOf(res(1)), 1);
      expect(BaiduMapper.categoryOf(res(4)), 4);
      // 服务端偶尔给字符串 —— 按数字解析，不要静默变成 null。
      expect(BaiduMapper.categoryOf(res('2')), 2);
      // 缺字段 / 响应是空的 ⇒ null（调用方据此走**保守**的慢通道）。
      expect(BaiduMapper.categoryOf(res(null)), isNull);
      expect(
        BaiduMapper.categoryOf(const HttpResult(statusCode: 200, json: {'errno': 0})),
        isNull,
      );
    });

    test('只有视频与音频能走快通道', () {
      expect(BaiduEndpoints.canUseDlna(BaiduEndpoints.categoryVideo), isTrue);
      expect(BaiduEndpoints.canUseDlna(BaiduEndpoints.categoryAudio), isTrue);
      // ⛔ 文档走 dlna 会被 CDN 回 `403 31329 hit illeage dlna` ——
      // 不是「慢」，是**根本下不了**，所以绝不能放进来。
      expect(BaiduEndpoints.canUseDlna(BaiduEndpoints.categoryDocument), isFalse);
      // 图片与其余类别**没实测过**：保守走慢通道（只会慢，不会坏）。
      expect(BaiduEndpoints.canUseDlna(BaiduEndpoints.categoryImage), isFalse);
      expect(BaiduEndpoints.canUseDlna(BaiduEndpoints.categoryOther), isFalse);
      // 解析不到类别时必须走慢通道 —— 猜成媒体会让文档直接 403。
      expect(BaiduEndpoints.canUseDlna(null), isFalse);
    });
  });
}
