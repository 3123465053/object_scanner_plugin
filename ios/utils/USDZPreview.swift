import SwiftUI
import SceneKit
import SceneKit.ModelIO
import Combine

// 用来读取模型数据
class Model: ObservableObject {
    @Published var scene: SCNScene?

    init(usdzPath: String) {
        load3dModel(path: usdzPath)
    }

    private func load3dModel(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("⚠️ USDZ 文件不存在: \(url.path)")
            return
        }

        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let scene = SCNScene(mdlAsset: asset)
        self.scene = scene
    }
}

// 显示模型，设置灯光、相机
struct SceneView: UIViewRepresentable {
    var scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.autoenablesDefaultLighting = true
        sceneView.allowsCameraControl = true
        sceneView.scene = scene
        // 深色背景，与 Flutter 详情页匹配
        sceneView.backgroundColor = UIColor(red: 10/255, green: 12/255, blue: 24/255, alpha: 1) // 0xFF0A0C18
        return sceneView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = scene
    }
}

// 主视图，动态加载 USDZ
struct USDZPreview: View {
    @StateObject var model: Model

    init(usdzPath: String) {
        _model = StateObject(wrappedValue: Model(usdzPath: usdzPath))
    }

    var body: some View {
        ZStack {
            Color(red: 10/255, green: 12/255, blue: 24/255)
                .ignoresSafeArea()

            if let scene = model.scene {
                SceneView(scene: scene)
            } else {
                Text("⚠️ 模型加载失败")
                    .foregroundColor(.red)
            }
        }
    }
}
