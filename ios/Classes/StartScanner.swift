//
//  StartScanner.swift
//  Pods



import Flutter
import QuickLook

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
                    ObjectScannerPlugin.pendingResult?([
                        "path": nil,
                        "msg": "无法打开扫描界面"
                    ])
                    ObjectScannerPlugin.pendingResult = nil
                }
            }
        } else {
            print("IOS: 当前设备系统版本不支持");
            result([
                "path":nil,
                "msg":"当前设备系统版本不支持"
            ])
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
                    ObjectScannerPlugin.pendingResult?([
                        "path": nil,
                        "msg": "无法打开扫描界面"
                    ])
                    ObjectScannerPlugin.pendingResult = nil
                }
            }
        } else {
            print("IOS: 当前设备系统版本不支持");
            result([
                "path":nil,
                "msg":"当前设备系统版本不支持"
            ])
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
                    ObjectScannerPlugin.pendingResult?([
                        "path": nil,
                        "msg": "无法打开扫描界面"
                    ])
                    ObjectScannerPlugin.pendingResult = nil
                }
            }
        } else {
            print("IOS: 当前设备系统版本不支持");
            result([
                "path":nil,
                "msg":"当前设备系统版本不支持，需要 iOS 14.0+"
            ])
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
            result(["path": nil, "msg": "文件不存在: \(path)"] as [String: Any?])
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
                        result(["path": nil, "msg": "打包 sidecar 文件失败"] as [String: Any?])
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                guard let top = ViewUtils.topViewController() else {
                    if let z = tempZipURL { try? FileManager.default.removeItem(at: z) }
                    result(["path": nil, "msg": "无法获取当前界面"] as [String: Any?])
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
                        result(["path": nil, "msg": "导出失败: \(error.localizedDescription)"] as [String: Any?])
                    } else if completed {
                        result(["path": shareURL.path, "msg": "success"] as [String: Any?])
                    } else {
                        result(["path": nil, "msg": "已取消"] as [String: Any?])
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

    //打开USDZ文件
    static func openUSDZ(result: @escaping FlutterResult,path:String){
        
        if #available(iOS 17.0, *) {
            print("IOS: 开始空间扫描");
            
            // 保存 result，等扫描完成后再回调
            ObjectScannerPlugin.pendingResult = result
            DispatchQueue.main.async {
                var res = ViewUtils.presentScanner(rootView: USDZPreview(usdzPath: path))
                if !res {
                    ObjectScannerPlugin.pendingResult?([
                        "path": nil,
                        "msg": "无法打开预览界面"
                    ])
                    ObjectScannerPlugin.pendingResult = nil
                }
            }
        } else {
            print("IOS: 当前设备系统版本不支持");
            result([
                "path":nil,
                "msg":"当前设备系统版本不支持"
            ])
        }
    }
    
}
