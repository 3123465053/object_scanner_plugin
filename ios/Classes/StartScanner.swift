//
//  StartScanner.swift
//  Pods



import Flutter
import QuickLook
import ARKit

//开始扫描
//这里把扫描的方法做个统一管理

struct StartScanner{
    
    //开始扫描某一个物体
    static func scannerObject(result: @escaping FlutterResult){
        if #available(iOS 17.0, *) {
            print("IOS: 开始扫描");
            
            // 保存 result，等扫描完成后再回调
            ObjectScannerPlugin.pendingResult = result
            DispatchQueue.main.async {
                var res = ViewUtils.presentScanner(rootView: ObjectScannerView())
                if !res {
                    ObjectScannerPlugin.pendingResult?(["path": NSNull(), "msg": "无法打开扫描界面"] as [String: Any])
                    ObjectScannerPlugin.pendingResult = nil
                }
            }
        } else {
            print("IOS: 当前设备系统版本不支持");
            result(["path": NSNull(), "msg": "当前设备系统版本不支持"] as [String: Any])
        }
    }

    //扫描房间
    static func scannerRoom(result: @escaping FlutterResult){
        if #available(iOS 17.0, *) {
            print("IOS: 开始房间扫描");

            // 保存 result，等扫描完成后再回调
            ObjectScannerPlugin.pendingResult = result
            DispatchQueue.main.async {
                var res = ViewUtils.presentScanner(rootView: RoomScannerView())
                if !res {
                    ObjectScannerPlugin.pendingResult?(["path": NSNull(), "msg": "无法打开扫描界面"] as [String: Any])
                    ObjectScannerPlugin.pendingResult = nil
                }
            }
        } else {
            print("IOS: 当前设备系统版本不支持");
            result(["path": NSNull(), "msg": "当前设备系统版本不支持"] as [String: Any])
        }
    }

    //空间扫描
    static func scannerSpace(result: @escaping FlutterResult){
        if #available(iOS 17.0, *) {
            print("IOS: 开始空间扫描 (RealityKit)");

            // 保存 result，等扫描完成后再回调
            ObjectScannerPlugin.pendingResult = result
            DispatchQueue.main.async {
                var res = ViewUtils.presentScanner(rootView: SpaceScanView())
                if !res {
                    ObjectScannerPlugin.pendingResult?(["path": NSNull(), "msg": "无法打开扫描界面"] as [String: Any])
                    ObjectScannerPlugin.pendingResult = nil
                }
            }
        } else {
            print("IOS: 当前设备系统版本不支持");
            result(["path": NSNull(), "msg": "当前设备系统版本不支持，需要 iOS 14.0+"] as [String: Any])
        }
    }
    
    //格式转换
    static func convertFormat(result: @escaping FlutterResult, inputPath: String, outputFormat: String){
        FormatConverter.convert(inputPath: inputPath, outputFormat: outputFormat, result: result)
    }

    //导出文件（系统分享面板：保存到文件、AirDrop、微信、邮件等）
    //注：obj/usd/usda/usdc 等格式会产生外挂纹理（.mtl / .png），
    //   若所在目录存在 sidecar 文件，会自动打包成 zip 再分享，保证纹理完整
    static func exportFile(result: @escaping FlutterResult, path: String){
        guard FileManager.default.fileExists(atPath: path) else {
            result(["path": NSNull(), "msg": "文件不存在: \(path)"] as [String: Any])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let fileURL = URL(fileURLWithPath: path)
            let parentDir = fileURL.deletingLastPathComponent()
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

            // 仅当文件位于 convert 创建的独立子目录中，且目录含 sidecar 时才打包
            // （避免把整个 Documents 根目录压进 zip）
            let isInSubfolder = parentDir.standardizedFileURL.path != documentsDir.standardizedFileURL.path
            let contents = (try? FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil)) ?? []
            let needsZip = isInSubfolder && contents.count > 1

            var shareURL = fileURL
            var tempZipURL: URL? = nil

            if needsZip {
                if let zipURL = zipDirectory(parentDir) {
                    shareURL = zipURL
                    tempZipURL = zipURL
                } else {
                    DispatchQueue.main.async {
                        result(["path": NSNull(), "msg": "打包 sidecar 文件失败"] as [String: Any])
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                guard let top = ViewUtils.topViewController() else {
                    if let z = tempZipURL { try? FileManager.default.removeItem(at: z) }
                    result(["path": NSNull(), "msg": "无法获取当前界面"] as [String: Any])
                    return
                }

                let vc = UIActivityViewController(activityItems: [shareURL], applicationActivities: nil)

                // iPad 必须设置 popover 源，否则崩溃
                if let pop = vc.popoverPresentationController {
                    pop.sourceView = top.view
                    pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                    pop.permittedArrowDirections = []
                }

                vc.completionWithItemsHandler = { activityType, completed, _, error in
                    if let z = tempZipURL { try? FileManager.default.removeItem(at: z) }
                    if let error = error {
                        result(["path": NSNull(), "msg": "导出失败: \(error.localizedDescription)"] as [String: Any])
                    } else if completed {
                        result(["path": shareURL.path, "msg": "success"] as [String: Any])
                    } else {
                        result(["path": NSNull(), "msg": "已取消"] as [String: Any])
                    }
                }

                top.present(vc, animated: true)
            }
        }
    }

    /// 用 NSFileCoordinator .forUploading 把目录打包成 zip（iOS 原生，无需三方库）
    private static func zipDirectory(_ dirURL: URL) -> URL? {
        var coordError: NSError?
        var resultURL: URL?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: dirURL, options: [.forUploading], error: &coordError) { tempURL in
            // tempURL 是系统生成的临时 zip，闭包结束后会被清理，需先复制出来
            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(dirURL.lastPathComponent).zip")
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.copyItem(at: tempURL, to: destURL)
                resultURL = destURL
            } catch {
                print("zip 复制失败: \(error.localizedDescription)")
            }
        }
        if let err = coordError {
            print("NSFileCoordinator 打包失败: \(err.localizedDescription)")
        }
        return resultURL
    }

    // AR Quick Look 预览
    // 使用 ARQuickLookPreviewItem + QLPreviewController(.fullScreen)
    // 非 USDZ 格式先在后台转换为 USDZ，再开启 AR 预览；临时文件关闭后自动删除。
    static func openARQuickLook(result: @escaping FlutterResult, path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            result(["msg": "文件不存在: \(path)"] as [String: Any])
            return
        }

        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

        if ext == "usdz" {
            // 已经是 USDZ，直接预览
            DispatchQueue.main.async {
                presentARQuickLook(result: result, usdzPath: path, tempPath: nil)
            }
        } else {
            // 非 USDZ：后台转换，完成后再开启 AR 预览
            DispatchQueue.global(qos: .userInitiated).async {
                FormatConverter.convert(inputPath: path, outputFormat: "usdz") { convResult in
                    let dict    = convResult as? [String: Any] ?? [:]
                    let msg     = dict["msg"]  as? String ?? ""
                    let outPath = dict["path"] as? String ?? ""

                    guard msg == "success",
                          !outPath.isEmpty,
                          FileManager.default.fileExists(atPath: outPath) else {
                        DispatchQueue.main.async {
                            result(["msg": "转换 USDZ 失败: \(msg)"] as [String: Any])
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        // tempPath = outPath，AR 关闭后由 coordinator 清理
                        presentARQuickLook(result: result, usdzPath: outPath, tempPath: outPath)
                    }
                }
            }
        }
    }

    private static func presentARQuickLook(result: @escaping FlutterResult,
                                           usdzPath: String,
                                           tempPath: String?) {
        guard let top = ViewUtils.topViewController() else {
            result(["msg": "无法获取当前界面"] as [String: Any])
            return
        }
        let url         = URL(fileURLWithPath: usdzPath)
        let coordinator = ARQLCoordinator(url: url, result: result, tempPath: tempPath)
        let qlVC        = QLPreviewController()
        qlVC.dataSource = coordinator
        qlVC.delegate   = coordinator
        qlVC.modalPresentationStyle = .fullScreen
        objc_setAssociatedObject(qlVC, &ARQLCoordinator.key,
                                 coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(qlVC, animated: true)
    }

    //打开USDZ文件
    static func openUSDZ(result: @escaping FlutterResult,path:String){
        
        if #available(iOS 17.0, *) {
            print("IOS: 开始空间扫描");
            
            // 保存 result，等扫描完成后再回调
            ObjectScannerPlugin.pendingResult = result
            DispatchQueue.main.async {
                var res = ViewUtils.presentScanner(rootView: USDZPreview(usdzPath: path))
                if !res {
                    ObjectScannerPlugin.pendingResult?(["path": NSNull(), "msg": "无法打开预览界面"] as [String: Any])
                    ObjectScannerPlugin.pendingResult = nil
                }
            }
        } else {
            print("IOS: 当前设备系统版本不支持");
            result(["path": NSNull(), "msg": "当前设备系统版本不支持"] as [String: Any])
        }
    }

}

// MARK: - ARQLCoordinator
// QLPreviewController 的 DataSource + Delegate。
// ARQuickLookPreviewItem 会直接以 AR 模式打开 USDZ，无需用户手动切换标签。

private class ARQLCoordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    static var key: UInt8 = 0
    let fileURL: URL
    let flutterResult: FlutterResult
    /// 转换产生的临时 USDZ 路径，AR 关闭后自动删除；原本就是 USDZ 时为 nil
    let tempPath: String?

    init(url: URL, result: @escaping FlutterResult, tempPath: String? = nil) {
        self.fileURL      = url
        self.flutterResult = result
        self.tempPath     = tempPath
    }

    // MARK: QLPreviewControllerDataSource

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        let item = ARQuickLookPreviewItem(fileAt: fileURL)
        item.allowsContentScaling = true
        return item
    }

    // MARK: QLPreviewControllerDelegate

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        // 清理临时转换文件
        if let tmp = tempPath {
            try? FileManager.default.removeItem(atPath: tmp)
        }
        flutterResult(["msg": "success"] as [String: Any])
    }
}
