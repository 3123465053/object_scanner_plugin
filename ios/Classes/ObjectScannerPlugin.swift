import Flutter
import SwiftUI
import UIKit

//需要实现 FlutterPlugin + FlutterStreamHandler
public class ObjectScannerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    static var channel: FlutterMethodChannel?
    static var pendingResult: FlutterResult?

    /// EventChannel sink：后台转换完成后通过它把结果推到 Dart
    static var eventSink: FlutterEventSink? = nil

    // MARK: - 注册

    public static func register(with registrar: FlutterPluginRegistrar) {
        // MethodChannel — 原有同步调用
        let channel = FlutterMethodChannel(
            name: "object_scanner_plugin",
            binaryMessenger: registrar.messenger()
        )
        self.channel = channel
        let instance = ObjectScannerPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)

        // EventChannel — 后台转换结果推送
        let eventChannel = FlutterEventChannel(
            name: "object_scanner_plugin/conversion_events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)

        // PlatformView（SwiftUI 嵌入）
        registrar.register(
            SwiftUIFactory(messenger: registrar.messenger()),
            withId: "swift_ui_view"
        )
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?,
                         eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        ObjectScannerPlugin.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        ObjectScannerPlugin.eventSink = nil
        return nil
    }

    // MARK: - MethodChannel

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

        case "openARQuickLook":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "path is required", details: nil))
                return
            }
            StartScanner.openARQuickLook(result: result, path: path)

        case "openUSDZ":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "path is required", details: nil))
                return
            }
            StartScanner.openUSDZ(result: result, path: path)

        case "convertFormat":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String,
                  let outputFormat = args["outputFormat"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "inputPath and outputFormat are required",
                                    details: nil))
                return
            }
            StartScanner.convertFormat(result: result,
                                       inputPath: inputPath,
                                       outputFormat: outputFormat)

        // ── 新增：后台转换，立即返回 jobId，完成后通过 EventChannel 推送结果 ──
        case "startConvertFormat":
            guard let args = call.arguments as? [String: Any],
                  let inputPath   = args["inputPath"]   as? String,
                  let outputFormat = args["outputFormat"] as? String,
                  let jobId       = args["jobId"]       as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "inputPath, outputFormat, jobId are required",
                                    details: nil))
                return
            }
            // 立即告知 Dart "已启动"，不等转换完成
            result(nil)

            // 后台跑转换，完成后推送事件
            StartScanner.convertFormat(
                result: { convResult in
                    var response: [String: Any] = ["jobId": jobId]
                    if let dict = convResult as? [String: Any] {
                        response["path"] = dict["path"] ?? NSNull()
                        response["msg"]  = dict["msg"]  ?? ""
                    } else {
                        response["path"] = NSNull()
                        response["msg"]  = "未知错误"
                    }
                    DispatchQueue.main.async {
                        ObjectScannerPlugin.eventSink?(response)
                    }
                },
                inputPath: inputPath,
                outputFormat: outputFormat
            )

        case "exportFile":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "path is required", details: nil))
                return
            }
            StartScanner.exportFile(result: result, path: path)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
