import 'package:drift/drift.dart';

import '../../domain/adapters/download_task_store.dart';
import '../../domain/entities/download_task.dart';
import 'app_database.dart';

/// [DownloadTaskStore] 的 drift 实现。
class DriftDownloadTaskStore implements DownloadTaskStore {
  DriftDownloadTaskStore(this._db);

  final AppDatabase _db;

  @override
  Future<List<DownloadTask>> loadAll() async {
    final query = _db.select(_db.downloadTasks)
      // 新的在前。同一个时刻创建的（批量下载一个目录）靠 `id` 兜底 ——
      // 不加 tie-breaker 的话 SQLite 不保证稳定顺序，列表会在两次刷新
      // 之间自己重排，看着像「任务在乱跳」。
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
      ]);
    final rows = await query.get();
    return rows.map(_toEntity).toList();
  }

  @override
  Future<void> save(DownloadTask task) async {
    await _db.into(_db.downloadTasks).insertOnConflictUpdate(
          DownloadTasksCompanion(
            id: Value(task.id),
            provider: Value(task.provider),
            fileId: Value(task.fileId),
            name: Value(task.name),
            dirPath: Value(task.dirPath),
            savePath: Value(task.savePath),
            sizeBytes: Value(task.sizeBytes),
            receivedBytes: Value(task.receivedBytes),
            status: Value(task.status.name),
            error: Value(task.error),
            createdAt: Value(task.createdAt),
            updatedAt: Value(task.updatedAt),
          ),
        );
  }

  @override
  Future<void> remove(String id) async {
    await (_db.delete(_db.downloadTasks)..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<void> removeMany(List<String> ids) async {
    if (ids.isEmpty) return;
    await (_db.delete(_db.downloadTasks)..where((t) => t.id.isIn(ids))).go();
  }

  @override
  Future<void> removeCompleted() async {
    await (_db.delete(_db.downloadTasks)
          ..where((t) => t.status.equals(DownloadStatus.completed.name)))
        .go();
  }

  @override
  Future<int> pauseRunning(DateTime at) async {
    return (_db.update(_db.downloadTasks)
          ..where((t) => t.status.equals(DownloadStatus.downloading.name)))
        .write(
      DownloadTasksCompanion(
        status: Value(DownloadStatus.paused.name),
        updatedAt: Value(at),
      ),
    );
  }

  static DownloadTask _toEntity(DownloadTaskRow row) => DownloadTask(
        id: row.id,
        provider: row.provider,
        fileId: row.fileId,
        name: row.name,
        dirPath: row.dirPath,
        savePath: row.savePath,
        sizeBytes: row.sizeBytes,
        receivedBytes: row.receivedBytes,
        // 读不懂的状态退回 `paused`（见 `DownloadStatus.parse`）。
        status: DownloadStatus.parse(row.status),
        error: row.error,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );
}
