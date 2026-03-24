import 'object_scanner_plugin_platform_interface.dart';

// 最终对外提供的类
class ObjectScannerPlugin {
  Future<String?> getPlatformVersion() {
    return ObjectScannerPluginPlatform.instance.getPlatformVersion();
  }

  //扫描单个物体
  startScannerObject() {
    return ObjectScannerPluginPlatform.instance.startScannerObject();
  }

  //扫描房间
  startScannerRoom() {
    return ObjectScannerPluginPlatform.instance.startScannerRoom();
  }

  //扫描空间
  startScannerSpace() {
    return ObjectScannerPluginPlatform.instance.startScannerSpace();
  }

  //预览USDZ文件
  openUSDZ(String path) {
    return ObjectScannerPluginPlatform.instance.openUSDZ(path);
  }

}
