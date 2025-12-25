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
