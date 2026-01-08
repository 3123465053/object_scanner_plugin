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

}
