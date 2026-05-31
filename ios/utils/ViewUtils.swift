//
//  ViewUtils.swift
//  Pods
//
//  Created by 杨棒 on 2025/12/25.
//


import SwiftUI

//界面相关的工具
struct ViewUtils{
    
    //调用UI界面(需要传入调起哪个界面)
    @available(iOS 17.0, *)
    static func presentScanner(rootView: some View) -> Bool {
        
        guard let vc = self.topViewController() else { return false }
        
        let hostingVC = UIHostingController(rootView: rootView)
        hostingVC.modalPresentationStyle = .fullScreen
        vc.present(hostingVC, animated: true)
        return true
    }
    
    
    //获取正在显示的最上层 UIViewController，以便能正常显示 否则会报警告或者页面被遮住 无法显示
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

struct L10n {
    private static var isChinese: Bool {
        let lang = Locale.current.languageCode ?? ""
        return lang.hasPrefix("zh")
    }

    static var close: String             { isChinese ? "关闭"           : "Close" }
    static var cancel: String            { isChinese ? "取消"           : "Cancel" }
    static var notice: String            { isChinese ? "提示"           : "Notice" }

    // ObjectScanner
    static var startCapture: String      { isChinese ? "开始捕捉"       : "Start Capture" }
    static var finishAndBuild: String    { isChinese ? "结束并生成模型"  : "Finish & Build" }
    static var generateNow: String       { isChinese ? "立即生成"       : "Generate Now" }
    static var aimAtObject: String       { isChinese ? "请将中心点对准物体" : "Aim center at object" }
    static var ready: String             { isChinese ? "就绪"           : "Ready" }
    static var tooFewImages: String      {
        isChinese
            ? "图片数量过少，模型生成可能不成功，请确保有10张以上的图片"
            : "Too few images. Generation may fail. Please capture more than 10 images."
    }
    static var closingWillStop: String   {
        isChinese ? "(关闭会停止模型生成)" : "(Closing will stop model generation)"
    }

    // RoomScanner
    static var doneScan: String          { isChinese ? "完成扫描"           : "Done Scanning" }
    static var noSupportRoomPlan: String { isChinese ? "设备不支持 RoomPlan"  : "Device doesn't support RoomPlan" }
    static var requiresLiDAR: String     {
        isChinese
            ? "需要支持 LiDAR 的设备\n(iPhone 12 Pro 及以上)"
            : "Requires a LiDAR-capable device\n(iPhone 12 Pro and later)"
    }

    // SpaceScanner
    static var moveToScan: String        { isChinese ? "慢慢移动设备扫描物体" : "Move device slowly to scan" }
    static var stopAndExport: String     { isChinese ? "停止并导出"           : "Stop & Export" }

    // UnsupportedDeviceView
    static var deviceNotSupported: String  { isChinese ? "设备不支持"              : "Device Not Supported" }
    static var noLiDAR: String             { isChinese ? "此设备不支持 LiDAR 技术" : "This device doesn't support LiDAR" }
    static var requiresIPhone12Pro: String { isChinese ? "需要 iPhone 12 Pro 或更新的设备" : "Requires iPhone 12 Pro or newer" }

    static func generatingModel(_ percent: Int) -> String {
        isChinese ? "正在生成 3D 模型: \(percent)%" : "Generating 3D Model: \(percent)%"
    }
}
