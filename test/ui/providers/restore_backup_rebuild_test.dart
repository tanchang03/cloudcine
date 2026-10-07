import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/download_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';

/// 恢复备份换掉 `AppDatabase` 之后，**挂在它下面的 Notifier 要能重建**。
///
/// ## 为什么值得一个文件
///
/// Riverpod 的 `Notifier` 实例是**跨重建复用**的：依赖一变，`build()` 会在
/// **同一个对象**上被再调一次。于是 `build()` 里那些「一次性初始化」的写法
/// 全部有雷 —— 最典型的是把对象赋给一个 `late final` 字段，第二次赋值直接抛
/// `LateInitializationError: Field '_queue' has already been initialized`，
/// 而它的表现是**整个界面变红**（2026-10-07 恢复备份后真机踩到，
/// `DownloadQueueController._queue` 就是这一颗）。
///
/// 这条路径在 2026-10-07 之前**从来没被触发过**：`databaseProvider` 一直是
/// 启动时注入一次的常量，所以「谁 watch 它」等于「谁永远不重建」。恢复备份
/// 改成「换掉整个 `AppDatabase` 实例」（`DatabaseHandle.swap`）之后，
/// 这条链第一次真的动了，雷就响了。
///
/// 所以这个文件钉住两件事：换代之后**下游确实重建了**，而且**重建不抛**。
void main() {
  test('换掉 AppDatabase → 下载队列重建而不是崩在 late final 上', () async {
    final first = AppDatabase.memory();
    addTearDown(first.close);

    final container = ProviderContainer(
      overrides: [
        databaseHandleProvider.overrideWith(() => DatabaseHandle(first)),
        adapterRegistryProvider.overrideWithValue(
          AdapterRegistry([FakeDriveAdapter(const {})]),
        ),
      ],
    );
    addTearDown(container.dispose);

    // 先把队列建起来（这一步会 watch `downloadTaskStoreProvider` →
    // `databaseProvider` → `databaseHandleProvider`）。
    expect(container.read(downloadQueueProvider), isEmpty);
    final storeBefore = container.read(downloadTaskStoreProvider);

    // 模拟恢复备份的第 ③ 步：换上一个**新**实例。
    final second = AppDatabase.memory();
    addTearDown(second.close);
    container.read(databaseHandleProvider.notifier).swap(second);

    expect(
      container.read(downloadTaskStoreProvider),
      isNot(same(storeBefore)),
      reason: '换库必须让下游重建 —— 旧 store 握着的是已经被 close 掉的连接，'
          '继续用它写下载进度会抛 StateError。这一条同时是下面那条断言的'
          '**前提**：不重建的话，下面测的就不是 `build()` 能不能重入。',
    );

    // ⛔ 这一句就是当初崩掉的地方。
    expect(
      container.read(downloadQueueProvider),
      isEmpty,
      reason: '恢复备份必须让下载队列**重建**（它的 store 还指着被换掉的那个库），'
          '而不是在 `late final _queue` 上第二次赋值。'
          '这里抛 LateInitializationError 的话，用户在恢复备份后会看到整页红色。',
    );
  });

  /// 持有者**自己**被重建时，必须仍然给出「换上的那一个」。
  ///
  /// ## 为什么这条比上面那条更要命
  ///
  /// 上面那条测的是「换库之后下游跟着走」；这条测的是「换库这件事本身不能被
  /// 冲掉」。Riverpod 会**复用 Notifier 实例**再调一次 `build()`，所以
  /// `DatabaseHandle.build()` 里如果写的是 `return _initial;`，重建一次就等于
  /// 把刚换上的新库**退回给启动时那个已经 `close()` 的旧实例**。
  ///
  /// 那个后果比恢复失败更难查：恢复**成功了**、日志全绿、列表也刷出来了，
  /// 然后过一会儿某个 provider 被 invalidate，整个应用突然开始抛
  /// `Can't re-open a database after closing it` —— 看起来像是「用着用着库坏了」。
  ///
  /// 触发 `build()` 重跑的方式有很多（`ref.invalidate`、热重载、依赖变化），
  /// 这里用最直接的一种。
  test('持有者重建后仍然给出换上的那一个，不退回启动时那个', () async {
    final first = AppDatabase.memory();
    final second = AppDatabase.memory();
    addTearDown(second.close);

    final container = ProviderContainer(
      overrides: [
        databaseHandleProvider.overrideWith(() => DatabaseHandle(first)),
      ],
    );
    addTearDown(container.dispose);

    expect(identical(container.read(databaseProvider), first), isTrue);

    // 真实现场：旧库这时已经被关掉了（`closeDatabase()` 是恢复流程的第 1 步）。
    await first.close();
    container.read(databaseHandleProvider.notifier).swap(second);

    // 逼持有者重建 —— 这一下会走 `build()`。
    container.invalidate(databaseHandleProvider);

    expect(
      identical(container.read(databaseProvider), second),
      isTrue,
      reason: '`build()` 返回 `_initial` 的话，这里拿到的是那个**已经关掉的**'
          '旧实例；之后每一次查询都会抛 `Can\'t re-open a database after '
          'closing it`，而且是在「恢复成功」之后才炸。',
    );
  });
}
