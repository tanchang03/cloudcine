import '../entities/download_task.dart';

/// 下载记录的持久化契约。
///
/// ## 为什么要有这层抽象（而不是让 `DownloadQueue` 直接拿 `AppDatabase`）
///
/// 项目的分层规矩是 `domain/` 不 import drift（见 `MediaRepository`）。
/// 下载队列的调度逻辑 —— 并发数、暂停 / 继续、失败重试、启动时把
/// `downloading` 归一成 `paused` —— 是这个功能里**唯一值得写测试**的部分，
/// 而它一旦直接持有 `AppDatabase`，测一次就得起一个真的 SQLite
/// （还得跑 `build_runner` 生成的那堆代码）。
///
/// 有了这层抽象，队列的测试只需要一个内存里的 `Map`。
abstract class DownloadTaskStore {
  /// 全部下载记录，按创建时间**倒序**（新的在前）。
  Future<List<DownloadTask>> loadAll();

  /// 写入（不存在则插入，存在则整行覆盖）。
  Future<void> save(DownloadTask task);

  /// 删掉一条。
  Future<void> remove(String id);

  /// 批量删掉。
  Future<void> removeMany(List<String> ids);

  /// 删掉全部已完成的记录（失败的不删 —— 用户可能还想重试）。
  Future<void> removeCompleted();

  /// 把「下载中」的行改成「已暂停」，返回改了几行。
  ///
  /// ## 为什么是单独一个方法，而不是 `loadAll` 之后逐条 `save`
  ///
  /// 它要在**应用启动的最开始**跑完，而那时可能有几十条记录。逐条 `save`
  /// 就是几十次事务；更重要的是，那样写会让「重启后不该自动开始下载」
  /// 这条规矩散落在调用方 —— 而它是一条**安全**规矩（见
  /// `DownloadStatus.paused` 的文档：搞错了会一开应用就闷头下几十 GB）。
  /// 收进存储层，只有一处 SQL，改不动也漏不掉。
  Future<int> pauseRunning(DateTime at);
}
