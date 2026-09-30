import '../../domain/adapters/cloud_drive_adapter.dart';
import '../../domain/entities/drive_provider.dart';

/// 适配器注册表：把「有哪些网盘」这件事收敛到一个可注入的容器。
///
/// 存在的理由是**新增网盘零改动**：加一家网盘只需要在组合根
/// （`app_providers.dart`）多注册一个适配器，扫描器、UI、播放器
/// 全都不认识任何具体网盘。
class AdapterRegistry implements DriveAdapterRegistry {
  AdapterRegistry(List<CloudDriveAdapter> adapters)
      : _byProvider = {for (final a in adapters) a.provider: a};

  final Map<DriveProvider, CloudDriveAdapter> _byProvider;

  @override
  CloudDriveAdapter? adapterFor(DriveProvider provider) =>
      _byProvider[provider];

  @override
  CloudDriveAdapter requireAdapter(DriveProvider provider) {
    final a = _byProvider[provider];
    if (a == null) {
      throw StateError('${provider.displayName} 尚未接入（没有注册适配器）');
    }
    return a;
  }

  @override
  List<CloudDriveAdapter> get all => _byProvider.values.toList();

  @override
  List<DriveProvider> get providers => _byProvider.keys.toList();
}
