import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'object_scanner_plugin_platform_interface.dart';

/// An implementation of [ObjectScannerPluginPlatform] that uses method channels.
class MethodChannelObjectScannerPlugin extends ObjectScannerPluginPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('object_scanner_plugin');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  //开始扫描
  @override
   startScanner()async{
    print("开始");
   var res = await  methodChannel.invokeMethod("startScanner");
   print("safdsdd");
   print(res);
   return res;
  }
}
