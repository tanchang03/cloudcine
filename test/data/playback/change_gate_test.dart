import 'package:cloudcine/data/playback/change_gate.dart';
import 'package:cloudcine/domain/services/playback_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「值没变就不发」的闸。
///
/// 它看着只有三行，但两个引擎的**全部事件**都从它过。判错的后果不是报错，
/// 而是「订阅方莫名其妙地频繁重建」或者「换集后界面不刷新」—— 都属于
/// 最难从现象反推到原因的那一类，所以这里把边界钉住。
void main() {
  group('ChangeGate 基本语义', () {
    test('第一次一定放行', () {
      // 闸是「值没变就不发」，而**没有上一次**不等于「没变」。
      // 首值被吞掉的后果是「打开片子后音量/倍速读数永远是初始值」。
      final gate = ChangeGate<int>();
      expect(gate.accept(1), isTrue);
    });

    test('同一个值第二次不放行', () {
      final gate = ChangeGate<int>();
      gate.accept(1);
      expect(gate.accept(1), isFalse);
    });

    test('值变了就放行', () {
      final gate = ChangeGate<int>();
      gate.accept(1);
      expect(gate.accept(2), isTrue);
      // 回到旧值也算变（比的是「和上一次一样吗」，不是「见过没有」）。
      expect(gate.accept(1), isTrue);
    });

    test('reset 之后同一个值重新放行', () {
      // 换源时**必须**能重新放行：新流的 duration 恰好等于旧流的情况并不
      // 罕见（换集时两集时长相同、轨道号相同都会撞上），不 reset 就会
      // 「换集后音轨菜单不刷新」。
      final gate = ChangeGate<int>();
      gate.accept(1);
      gate.reset();
      expect(gate.accept(1), isTrue);
    });

    test('null 也是一个值，不会被当成「没设过」', () {
      // `activeSubtitleTrackId` 的 `null` 表示「没有字幕在显示」，
      // 是**要上报的状态**，不是「还没有值」。
      //
      // ⚠️ 第一条断言就是这里最容易写错的地方：如果闸只拿 `_last == null`
      // 判断「没发过」，首次上报 null 会被吞掉 —— 而这个用例当初就是**红着**
      // 抓出那个 bug 的，别把它简化掉。
      final gate = ChangeGate<int?>();
      expect(gate.accept(null), isTrue);
      expect(gate.accept(null), isFalse);
      expect(gate.accept(3), isTrue);
      expect(gate.accept(null), isTrue);
    });

    test('reset 之后首次上报 null 同样放行', () {
      // 换集到一部「没有字幕」的片子时走的正是这条路。
      final gate = ChangeGate<int?>();
      gate.accept(3);
      gate.reset();
      expect(gate.accept(null), isTrue);
    });

    test('Duration 走值相等（引擎里 position / bufferEnd 都是它）', () {
      final gate = ChangeGate<Duration>();
      gate.accept(const Duration(seconds: 1));
      // 新建一个内容相同的对象：不靠值相等就会被判成「变了」，
      // 于是每一拍都上报一次播放头。
      expect(gate.accept(const Duration(seconds: 1)), isFalse);
    });

    test('没有值相等的自定义类型会被当成「每次都变」', () {
      // ⚠️ 这条是**反面**用例，钉住「闸依赖 `==`」这个前提。
      // 如果哪天有人把某个值对象换成没实现 `==` 的类，闸就静默失效了 ——
      // 这个测试说明了那种情况下的表现，而 `EngineVideoSize` 那条正向用例
      // （下面）才是我们真正要求的。
      //
      // ⚠️ 必须用**非 const** 构造：`const _NoEquality(1)` 会被 Dart 规范化
      // 成同一个实例，于是 `==` 走的是 `identical` 而意外成立 —— 那样这条
      // 反面用例会以「通过了」的姿态失效（第一版就是这么写错的）。
      final gate = ChangeGate<_NoEquality>();
      gate.accept(_NoEquality(1));
      expect(gate.accept(_NoEquality(1)), isTrue);
    });

    test('EngineVideoSize 有值相等，所以闸能挡住同尺寸的重复上报', () {
      // 这是跨文件的不变量：闸用 `==`，而 `EngineVideoSize` 必须实现它。
      // 少了 `==`，加载指示器会跟着每一拍重建。
      //
      // ⚠️ 这里用 `EngineVideoSize(...)` 而**不是** `const EngineVideoSize(...)`：
      // const 会被规范化成同一个实例，于是靠 `identical` 就通过了，
      // 而那样这条用例根本测不到 `==` 有没有实现。
      final gate = ChangeGate<EngineVideoSize>();
      gate.accept(EngineVideoSize(1920, 1080));
      expect(gate.accept(EngineVideoSize(1920, 1080)), isFalse);
      expect(gate.accept(EngineVideoSize(3840, 2160)), isTrue);
    });

    test('String 指纹（轨道清单那条路）', () {
      final gate = ChangeGate<String>();
      gate.accept('1,2#3#');
      expect(gate.accept('1,2#3#'), isFalse);
      expect(gate.accept('1,2#4#'), isTrue);
    });
  });
}

class _NoEquality {
  const _NoEquality(this.value);

  final int value;
}
