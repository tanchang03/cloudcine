import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/services/media_discovery.dart';
import 'package:cloudcine/ui/pages/player_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进播放页时「要播哪一条」的判据（[resolvePlayItem]）。
///
/// 这条写错的表现是**静默的死路**：目录视图里点一个还没入库的视频，弹出来
/// 一句「找不到这个媒体项。可能它已被重新扫描移除」—— 而用户点的那部片子
/// 就在网盘上，只是还没进库。
///
/// 播放页本身太重（media_kit + 跨引擎通道），整页测不划算，所以这条判据
/// 抽成了纯函数，在这里把两种来源的优先级钉死。
void main() {
  /// 目录视图「直接播」造出来的那一条：只活在内存里，库里**没有**它。
  final transient = parseTransientMedia(
    entry: const DriveEntry(
      id: 'f1',
      name: 'Movie.2024.1080p.mkv',
      isDirectory: false,
    ),
    provider: DriveProvider.quark,
    dirPath: '/电影',
  ).item;

  test('给了条目对象就不再查库 —— 未入库的那条路只有它', () async {
    var looked = false;

    final item = await resolvePlayItem(
      itemId: transient.id,
      item: transient,
      lookup: (id) async {
        looked = true;
        return null;
      },
    );

    expect(item, same(transient));
    expect(
      looked,
      isFalse,
      reason: '库里**没有**这一行（直接播的条目一行都不落库）—— 查一次只会'
          '白跑一趟，而且拿回来的是 null，页面就会报「找不到这个媒体项」',
    );
  });

  test('没给对象时才按 id 查库 —— 深链接与旧版本带过来的链接走这一支', () async {
    var asked = '';

    final item = await resolvePlayItem(
      itemId: transient.id,
      item: null,
      lookup: (id) async {
        asked = id;
        return transient;
      },
    );

    expect(item, same(transient));
    expect(asked, transient.id, reason: '查的必须是这一条，不能是别的 id');
  });

  test('两边都没有 → null，由页面去说「找不到这个媒体项」', () async {
    final item = await resolvePlayItem(
      itemId: 'quark:早就没了',
      item: null,
      lookup: (id) async => null,
    );

    expect(item, isNull);
  });
}
