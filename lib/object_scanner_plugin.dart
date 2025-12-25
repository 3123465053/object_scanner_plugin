import 'object_scanner_plugin_platform_interface.dart';

class ObjectScannerPlugin {
  Future<String?> getPlatformVersion() {
    return ObjectScannerPluginPlatform.instance.getPlatformVersion();
  }

    startScanner() {
    return ObjectScannerPluginPlatform.instance.startScanner();
  }
}
