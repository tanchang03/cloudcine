import 'dart:collection';
import 'dart:typed_data';

/// 按块缓存源流字节的 **LRU**。
///
/// ## 为什么是 LRU 而不是「滑动窗口」
///
/// mpv 打开 MKV 时会来回读：先读文件头，再**跳到文件尾**读 `Cues`（MKV 的
/// 索引常放在尾部），然后回到开头开始播。严格的滑动窗口会在这几次跳跃里
/// 把头尾反复淘汰掉，于是每播一段就要重下一次文件头。LRU 正好相反 ——
/// 反复被访问的头尾块会一直留在缓存里。
///
/// ## 为什么淘汰不需要「钉住」正在读的块
///
/// 取出的是 Dart 对象引用，从表里移除**不影响**已经拿在手的 `Uint8List`。
/// 所以读的过程中块被淘汰是安全的，不需要 pin/unpin 那一套。
class ChunkCache {
  ChunkCache({required this.maxBytes}) : assert(maxBytes > 0);

  /// 缓存上限（字节）。超过就淘汰**最久未被访问**的块。
  final int maxBytes;

  /// 按插入序排列：越靠前 = 越久没被碰过。
  final LinkedHashMap<int, Uint8List> _map = LinkedHashMap<int, Uint8List>();

  int _bytes = 0;

  /// 最近一次 [put] 的块。淘汰时**永远跳过它**，理由见 [_evict]。
  int? _lastPut;

  /// 当前持有的字节数。
  int get bytes => _bytes;

  int get count => _map.length;

  bool contains(int index) => _map.containsKey(index);

  /// 取一块并**刷新它的新鲜度**。没有返回 `null`。
  Uint8List? get(int index) {
    final value = _map.remove(index);
    if (value == null) return null;
    _map[index] = value;
    return value;
  }

  /// 放入一块。已有同序号的旧数据会被替换并从计数里扣掉。
  void put(int index, Uint8List data) {
    final old = _map.remove(index);
    if (old != null) _bytes -= old.lengthInBytes;
    _map[index] = data;
    _bytes += data.lengthInBytes;
    _lastPut = index;
    _evict();
  }

  void _evict() {
    if (_bytes <= maxBytes) return;
    // 先快照键：迭代中改表会抛 `Concurrent modification`。
    for (final key in _map.keys.toList()) {
      if (_bytes <= maxBytes) break;
      // ⚠️ 刚放进去的那块**绝不淘汰**。单块就超过上限时（块比上限还大，
      // 或上限被配得很小）淘汰它会让这次下载白做，而播放器的读取请求立刻
      // 又会来要同一块 —— 下载、删除、再下载，无限循环。
      if (key == _lastPut) continue;
      final removed = _map.remove(key);
      if (removed != null) _bytes -= removed.lengthInBytes;
    }
  }

  void clear() {
    _map.clear();
    _bytes = 0;
    _lastPut = null;
  }
}
