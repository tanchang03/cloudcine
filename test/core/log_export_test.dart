import 'dart:io';

import 'package:cloudcine/core/diagnostics/log_export.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「把日志传到网盘」这一步的可测部分。
///
/// 为什么值得单独测：这条路的产物是**要发出去**的东西。一旦文件名撞名
/// （上传是「先删后传」）或者正文被截得只剩开头几行，后果不是本机报错，
/// 而是「日志已经发过去了、看起来还挺正常、其实里面没有答案」——
/// 这种失败在拿到日志那一刻是**看不出来**的。
void main() {
  final now = DateTime(2026, 10, 4, 16, 45, 12);

  group('logExportFileName', () {
    test('月日时分秒都补零', () {
      expect(
        logExportFileName(
          now: DateTime(2026, 1, 2, 3, 4, 5),
          platformTag: 'android',
        ),
        'cloudcine-log-android-20260102-030405.txt',
      );
    });

    test('⚠️ 名字必须带时间戳 —— 上传是「先删后传」，固定名会毁掉上一份', () {
      final a = logExportFileName(now: now, platformTag: 'android');
      final b = logExportFileName(
        now: now.add(const Duration(seconds: 1)),
        platformTag: 'android',
      );
      expect(a, isNot(b));
    });

    test('平台标签进文件名，多设备上传时能分清来源', () {
      expect(
        logExportFileName(now: now, platformTag: 'macos'),
        startsWith('cloudcine-log-macos-'),
      );
    });
  });

  group('capLogText', () {
    test('没超上限就原样返回', () {
      expect(capLogText('abc', maxChars: 10), 'abc');
    });

    test('超了留末尾 —— 刚出问题的那一段永远在最后', () {
      expect(capLogText('0123456789', maxChars: 4), '6789');
    });

    test('⚠️ 按字符切，不按字节切：汉字被劈成半个就是乱码开头', () {
      final text = '日志' * 100; // 200 个字符
      final capped = capLogText(text, maxChars: 7);

      expect(capped.length, 7);
      // 切出来的必须是**原串的后缀** —— 按字节切会造出一个原串里
      // 根本不存在的片段（半个汉字 + 半个汉字）。
      expect(text.endsWith(capped), isTrue);
    });

    test('上限为 0 时不返回负数长度的崩', () {
      expect(capLogText('abc', maxChars: 0), '');
    });
  });

  group('buildLogExportPayload', () {
    test('文件可读时优先用文件 —— 启动那几行只在文件里', () async {
      final payload = await buildLogExportPayload(
        filePath: '/tmp/x.log',
        buffer: '缓冲里的旧行',
        now: now,
        platformTag: 'android',
        readFile: (_) async => '文件里的行',
      );

      expect(payload.source, LogExportSource.file);
      expect(payload.text, contains('文件里的行'));
      // 内存缓冲只有最后 800 行，「一打开就播不了」的答案早被挤掉了。
      expect(payload.text, isNot(contains('缓冲里的旧行')));
      expect(payload.fileName, 'cloudcine-log-android-20261004-164512.txt');
    });

    test('头部写清来源与路径 —— 读的人得先知道这份是不是完整的', () async {
      const path =
          '/data/user/0/com.cloudcine.cloudcine/app_flutter/logs/'
          'cloudcine-2026-10-04.log';
      final payload = await buildLogExportPayload(
        filePath: path,
        buffer: '',
        now: now,
        platformTag: 'android',
        readFile: (_) async => 'x',
      );

      expect(payload.text, contains('# 云影诊断日志'));
      expect(payload.text, contains('导出时间：2026-10-04 16:45:12'));
      expect(payload.text, contains('平台：android'));
      expect(payload.text, contains('来源：日志文件（完整）'));
      expect(payload.text, contains('日志文件：$path'));
    });

    test('超长时只发末尾，并在头部写明「被截了、原文多长」', () async {
      final raw = 'A' * 500;
      final payload = await buildLogExportPayload(
        filePath: '/tmp/x.log',
        buffer: '',
        now: now,
        platformTag: 'android',
        maxChars: 100,
        readFile: (_) async => raw,
      );

      expect(payload.source, LogExportSource.fileTruncated);
      expect(payload.text, contains('原文 500 字符，只发末尾 100 字符'));
      expect(payload.text.endsWith('A' * 100), isTrue);
      // 整份 500 字符不该被塞进去（否则电视的上行带宽要传很久）。
      expect(payload.text.length, lessThan(300));
    });

    test('文件读不到时退回内存缓冲，并说明原因', () async {
      final payload = await buildLogExportPayload(
        filePath: '/tmp/x.log',
        buffer: '缓冲里的行',
        now: now,
        platformTag: 'android',
        readFile: (_) async => throw const FileSystemException('权限不足'),
      );

      expect(payload.source, LogExportSource.buffer);
      expect(payload.text, contains('缓冲里的行'));
      expect(payload.text, contains('读取日志文件失败'));
    });

    test('没有文件路径时也退回缓冲（写盘失败的那台机器）', () async {
      final payload = await buildLogExportPayload(
        filePath: null,
        buffer: '只有内存里的行',
        now: now,
        platformTag: 'android',
      );

      expect(payload.source, LogExportSource.buffer);
      expect(payload.text, contains('只有内存里的行'));
      expect(payload.text, contains('本次没有日志文件'));
    });

    test('文件是空的也退回缓冲 —— 空文件比缓冲更没用', () async {
      final payload = await buildLogExportPayload(
        filePath: '/tmp/x.log',
        buffer: '内存里的行',
        now: now,
        platformTag: 'android',
        readFile: (_) async => '\n',
      );

      expect(payload.source, LogExportSource.buffer);
      expect(payload.text, contains('内存里的行'));
      expect(payload.text, contains('日志文件是空的'));
    });

    test('默认真的去读磁盘 —— 别让「注入的假读法」掩盖了真路径的错', () async {
      final dir = Directory.systemTemp.createTempSync('cloudcine_log_export_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final file = File('${dir.path}/cloudcine-2026-10-04.log');
      await file.writeAsString('真实文件里的一行');

      final payload = await buildLogExportPayload(
        filePath: file.path,
        buffer: '缓冲',
        now: now,
        platformTag: 'android',
      );

      expect(payload.source, LogExportSource.file);
      expect(payload.text, contains('真实文件里的一行'));
    });
  });

  group('logPlatformTag', () {
    test('给了 override 就用它（测试与跨平台构造都靠这条）', () {
      expect(logPlatformTag(override: 'android'), 'android');
      expect(logPlatformTag(override: 'macos'), 'macos');
    });

    test('没给 override 时能识别出当前平台，不会是 unknown', () {
      expect(logPlatformTag(), isNot('unknown'));
    });
  });
}
