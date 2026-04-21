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

  //格式转换
  // outputFormat 支持的输出格式:
  //   obj, stl, ply, usd, usda, usdc, abc  -- 通过 ModelIO
  //   usdz, dae, scn                        -- 通过 SceneKit
  //   glb, gltf                             -- 自定义 GLTF 2.0 导出器
  //
  // inputPath 支持的输入格式 (ModelIO 可读取):
  //   usdz, usd, obj, stl, ply, abc, fbx 等
  //
  // 不支持的格式: stp, igs, x_t, 3dxml, 3mf, jt, ifc, solidworks (无 iOS 原生 API)
  convertFormat(String inputPath, String outputFormat) {
    return ObjectScannerPluginPlatform.instance.convertFormat(inputPath, outputFormat);
  }

  //导出文件（调起系统分享面板：保存到文件、AirDrop、微信、邮件等）
  exportFile(String path) {
    return ObjectScannerPluginPlatform.instance.exportFile(path);
  }

}
