import Flutter
import SwiftUI
import UIKit

//需要实现 FlutterPlugin
public class ObjectScannerPlugin: NSObject, FlutterPlugin {
    static var channel: FlutterMethodChannel?
    static var pendingResult: FlutterResult?
    //必须重新的函数 运行时就会调用
  public static func register(with registrar: FlutterPluginRegistrar) {
      //创建一个方法通道
    let channel = FlutterMethodChannel(name: "object_scanner_plugin", binaryMessenger: registrar.messenger())
      self.channel = channel
      //当前的实例对象
    let instance = ObjectScannerPlugin()
      
    // 注册当前对象(当 Flutter通过这个channel调用方法时，用 instance.handle() 来处理)
    //只要一个对象实现了 FlutterPlugin
    //并且被注册为 MethodCallDelegate
    //Flutter 引擎就只会调用它的 handle()
    registrar.addMethodCallDelegate(instance, channel: channel)
      
// 注册 PlatformView，用于 Flutter 嵌入 SwiftUI
    registrar.register(
             SwiftUIFactory(messenger: registrar.messenger()),
             withId: "swift_ui_view"
    )
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "startScannerObject":
        StartScanner.scannerObject(result: result)
    case "startScannerRoom":
        StartScanner.scannerRoom(result: result)
    case "startScannerSpace":
        StartScanner.scannerSpace(result: result)
    case "openUSDZ":
           guard let args = call.arguments as? [String: Any],
                 let path = args["path"] as? String
                 else {
               result(FlutterError(code: "INVALID_ARGS", message: "Path is required", details: nil))
               return
           }
        StartScanner.openUSDZ(result: result, path: path)
           result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}




