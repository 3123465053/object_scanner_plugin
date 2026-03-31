import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'object_scanner_plugin_method_channel.dart';

//虚类
abstract class ObjectScannerPluginPlatform extends PlatformInterface {
  /// Constructs a ObjectScannerPluginPlatform.
  ObjectScannerPluginPlatform() : super(token: _token);

  static final Object _token = Object();

  static ObjectScannerPluginPlatform _instance = MethodChannelObjectScannerPlugin();

  /// The default instance of [ObjectScannerPluginPlatform] to use.
  ///
  /// Defaults to [MethodChannelObjectScannerPlugin].
  static ObjectScannerPluginPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ObjectScannerPluginPlatform] when
  /// they register themselves.
  static set instance(ObjectScannerPluginPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  startScannerObject() {
    throw UnimplementedError('startScannerObject has not been implemented.');
  }

  startScannerRoom() {
    throw UnimplementedError('startScannerRoom has not been implemented.');
  }

  startScannerSpace() {
    throw UnimplementedError('startScannerSpace has not been implemented.');
  }

  openUSDZ(String path) {
    throw UnimplementedError('openUSDZ has not been implemented.');
  }

  /// 格式转换
  /// inputPath: 输入文件路径
  /// outputFormat: 目标格式
  ///   ModelIO:  obj, stl, ply, usd, usda, usdc, abc
  ///   SceneKit: usdz, dae, scn
  ///   自定义:    glb, gltf
  /// inputPath: 支持 usdz/usd/obj/stl/ply/abc/fbx 等 ModelIO 可读取的格式
  convertFormat(String inputPath, String outputFormat) {
    throw UnimplementedError('convertFormat has not been implemented.');
  }

}
