import 'object_scanner_plugin_platform_interface.dart';

class ObjectScannerPlugin {
  Future<String?> getPlatformVersion() {
    return ObjectScannerPluginPlatform.instance.getPlatformVersion();
  }

  //扫描单个物体
  startScannerObject() {
    return ObjectScannerPluginPlatform.instance.startScannerObject();
  }

}
