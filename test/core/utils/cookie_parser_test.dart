import 'package:cloudcine/core/utils/cookie_parser.dart';
import 'package:cloudcine/data/remote/quark/quark_endpoints.dart';
import 'package:flutter_test/flutter_test.dart';

/// 诊断日志里 Cookie 只能出现**键名**。
///
/// 诊断日志是给用户复制粘贴用的（要发给别人排查），Cookie 的值是凭证 ——
/// 值一旦漏出去等于把账号交出去。而键名必须能看见，理由见下面那个 group。
void main() {
  group('cookieHeaderKeyNames', () {
    test('只取键名，值一个字都不带', () {
      final names = cookieHeaderKeyNames(
        '__pus=secret1; __puus=secret2; Video-Auth=secret3',
      );

      expect(names, ['__pus', '__puus', 'Video-Auth']);
      // 反向断言才是这条用例的重点：任何一个值出现在结果里就是泄露。
      for (final name in names) {
        expect(name.contains('secret'), isFalse);
      }
    });

    test('空头 / null 返回空表，不是抛异常', () {
      // 没有库记录时（内置自检视频）根本没有 Cookie 头，那条日志路径照样要能走。
      expect(cookieHeaderKeyNames(''), isEmpty);
      expect(cookieHeaderKeyNames(null), isEmpty);
    });

    test('带空格与没有 = 的片段也能收下', () {
      // ffmpeg / 服务端偶尔会给不带值的键；漏掉它会让「少了一个键」看上去
      // 像「少了一个别的键」，排查方向直接跑偏。
      expect(
        cookieHeaderKeyNames('  __pus=a ;   Video-Auth  '),
        ['__pus', 'Video-Auth'],
      );
    });
  });

  group('转码档（HLS）的鉴权 Cookie 不能被轮换回填丢掉', () {
    test('knownCookieNames 必须含 Video-Auth', () {
      // 为什么这条是硬指标（2026-10-04 实测）：
      //
      // 夸克签发**转码档**的接口 `/file/play/info` 每个响应都下发
      // `Video-Auth`，而转码档的地址是 `media.m3u8` —— 那个 URL **不带签名**
      // （同一个文件隔几小时取回来一模一样），鉴权全靠这个 cookie。
      //
      // 它不在 [knownCookieNames] 里就会被 `_absorbRotatedCookies` 静默丢弃，
      // 于是 mpv 取 m3u8 / 分片拿到 404 —— 用户看到的是「只有声音没画面、
      // 播两秒就 EOF」。而原画走 `/file/audioplay`（地址自带签名、不下发
      // 这个 cookie），所以症状恰好是「原画正常、转码档全挂」。
      //
      // 写这条断言是因为清理 cookie 列表时极易顺手删掉这个「看起来不像
      // 会话键」的名字，而删掉的后果不会报错、只会悄悄坏。
      expect(QuarkEndpoints.knownCookieNames, contains('Video-Auth'));
    });
  });
}
