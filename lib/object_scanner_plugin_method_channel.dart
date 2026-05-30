import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'object_scanner_plugin_platform_interface.dart';

//具体的实现
/// An implementation of [ObjectScannerPluginPlatform] that uses method channels.
class MethodChannelObjectScannerPlugin extends ObjectScannerPluginPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('object_scanner_plugin');

  /// EventChannel：接收后台转换完成事件
  static const _eventChannel =
      EventChannel('object_scanner_plugin/conversion_events');

  /// 广播流，所有监听者共享同一条 EventChannel 连接
  Stream<Map<String, dynamic>>? _conversionStream;

  @override
  Stream<Map<String, dynamic>> get conversionResultStream {
    _conversionStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) => Map<String, dynamic>.from(event as Map));
    return _conversionStream!;
  }

  /// 自增计数器：保证 jobId 绝对唯一
  /// （时间戳在快速连续调用时会撞同一毫秒，导致 jobId 冲突、任务互相覆盖）
  static int _jobCounter = 0;

  /// 启动后台格式转换，立即返回 jobId
  @override
  Future<String> startConvertFormatBg(
      String inputPath, String outputFormat) async {
    // 时间戳 + 自增计数器，确保并发调用也不会产生重复 jobId
    final jobId = '${DateTime.now().millisecondsSinceEpoch}_${_jobCounter++}';
    await methodChannel.invokeMethod('startConvertFormat', {
      'inputPath': inputPath,
      'outputFormat': outputFormat,
      'jobId': jobId,
    });
    return jobId;
  }

  @override
  Future<String?> getPlatformVersion() async {
    final version =
        await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  //开始扫描
  @override
  startScannerObject() async {
    var res = await methodChannel.invokeMethod("startScannerObject");
    return res;
  }

  //开始扫描房间
  @override
  startScannerRoom() async {
    var res = await methodChannel.invokeMethod("startScannerRoom");
    return res;
  }

  //开始空间扫描
  @override
  startScannerSpace() async {
    var res = await methodChannel.invokeMethod("startScannerSpace");
    return res;
  }

  //预览USDZ文件
  @override
  openUSDZ(String path) async {
    var res = await methodChannel.invokeMethod("openUSDZ", {"path": path});
    return res;
  }

  // AR Quick Look（WKWebView rel="ar"，直接全屏 AR）
  @override
  openARQuickLook(String path) async {
    var res = await methodChannel.invokeMethod("openARQuickLook", {"path": path});
    return res;
  }

  //格式转换（同步等待，保留原接口）
  @override
  convertFormat(String inputPath, String outputFormat) async {
    var res = await methodChannel.invokeMethod("convertFormat", {
      "inputPath": inputPath,
      "outputFormat": outputFormat,
    });
    return res;
  }

  //导出文件
  @override
  exportFile(String path) async {
    var res = await methodChannel.invokeMethod("exportFile", {"path": path});
    return res;
  }
}
