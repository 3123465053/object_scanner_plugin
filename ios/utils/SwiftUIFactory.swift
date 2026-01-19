//
//  SwiftUIFactory.swift
//  Pods
//
//  Created by 杨棒 on 2026/1/19.
//

// flutter 加载ios 原生端的视图

import UIKit
import Flutter
import SwiftUI

class SwiftUIFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let view = SwiftUIPlatformView(frame: frame)
        
        // 创建一个单独 MethodChannel 给每个 PlatformView
        let channel = FlutterMethodChannel(name: "swift_ui_view_\(viewId)", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            if call.method == "setParams", let params = call.arguments as? [String: Any] {
                view.updateArgs(params)
            }
        }

        return view
    }
}

class SwiftUIPlatformView: NSObject, FlutterPlatformView {
    private var hostingController: UIHostingController<AnyView>?

    init(frame: CGRect) {
        super.init()
        hostingController = UIHostingController(rootView: AnyView(Text("加载中...")))
        hostingController?.view.frame = frame
    }

    func view() -> UIView {
        return hostingController?.view ?? UIView()
    }

    func updateArgs(_ params: [String: Any]) {
        guard let flutterViewType = params["view_type"] as? String else {
            hostingController?.rootView = AnyView(Text("缺少 view_type"))
            return
        }

        switch flutterViewType {
        case "usdz_preview_view":
            if let path = params["path"] as? String {
                hostingController?.rootView = AnyView(USDZPreview(usdzPath: path))
            } else {
                hostingController?.rootView = AnyView(Text("缺少 path 参数"))
            }
        default:
            hostingController?.rootView = AnyView(Text("未知 SwiftUI View 类型"))
        }
    }
}
