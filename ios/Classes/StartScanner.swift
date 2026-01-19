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
            print("IOS: 开始空间扫描");
            
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
                "msg":"当前设备系统版本不支持"
            ])
        }
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
