import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'object_scanner_plugin_platform_interface.dart';

//具体的实现
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
  startScannerObject()async{
   var res = await  methodChannel.invokeMethod("startScannerObject");
   return res;
  }

  //开始扫描房间
  @override
  startScannerRoom() async{
    var res = await  methodChannel.invokeMethod("startScannerRoom");
    return res;
  }

  //开始空间扫描
  @override
  startScannerSpace()async {
    var res = await  methodChannel.invokeMethod("startScannerSpace");
    return res;
  }

  //预览USDZ文件
  @override
  openUSDZ(String path) async {
    var res = await methodChannel.invokeMethod("openUSDZ", {"path": path});
    return res;
  }

  //格式转换
  @override
  convertFormat(String inputPath, String outputFormat) async {
    var res = await methodChannel.invokeMethod("convertFormat", {
      "inputPath": inputPath,
      "outputFormat": outputFormat,
    });
    return res;
  }
}
