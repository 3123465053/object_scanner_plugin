import SwiftUI
import SceneKit
import SceneKit.ModelIO
import Combine

class Model: ObservableObject {
    @Published var scene: SCNScene?

    init(usdzPath: String) {
        load3dModel(path: usdzPath)
    }

    private func load3dModel(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("⚠️ 文件不存在: \(url.path)")
            return
        }

        let ext = url.pathExtension.lowercased()
        var loaded: SCNScene?

        switch ext {
        case "glb", "gltf":
            loaded = try? GLTFLoader.loadScene(from: url)
        case "scn":
            loaded = try? SCNScene(url: url, options: nil)
        case "dae":
            loaded = try? SCNScene(url: url, options: [.checkConsistency: true])
        default:
            let asset = MDLAsset(url: url)
            asset.loadTextures()
            loaded = SCNScene(mdlAsset: asset)
        }

        guard let scene = loaded else {
            print("⚠️ 模型加载失败: \(path)")
            return
        }

        // 确保所有 geometry 都有可见材质
        Model.fixMaterials(scene.rootNode)
        self.scene = scene
    }

    /// 递归修复缺失/不可见的材质
    private static func fixMaterials(_ node: SCNNode) {
        if let geo = node.geometry {
            // 情况1: 没有材质
            if geo.materials.isEmpty {
                geo.materials = [Model.defaultMaterial()]
            } else {
                // 情况2: 材质都无有效 diffuse 内容
                var needsFix = true
                for mat in geo.materials {
                    if mat.diffuse.contents != nil {
                        needsFix = false
                        break
                    }
                }
                if needsFix {
                    geo.materials = [Model.defaultMaterial()]
                }
            }

            // 确保所有材质双面渲染
            for mat in geo.materials {
                mat.isDoubleSided = true
            }
        }
        for child in node.childNodes {
            fixMaterials(child)
        }
    }

    private static func defaultMaterial() -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .blinn
        mat.diffuse.contents = UIColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1.0)
        mat.specular.contents = UIColor(white: 0.3, alpha: 1.0)
        mat.isDoubleSided = true
        return mat
    }
}

struct SceneView: UIViewRepresentable {
    var scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.scene = scene
        view.backgroundColor = UIColor(red: 10/255, green: 12/255, blue: 24/255, alpha: 1)

        // 补充环境光
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(white: 0.5, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = scene
    }
}

struct USDZPreview: View {
    @StateObject var model: Model

    init(usdzPath: String) {
        _model = StateObject(wrappedValue: Model(usdzPath: usdzPath))
    }

    var body: some View {
        ZStack {
            Color(red: 10/255, green: 12/255, blue: 24/255).ignoresSafeArea()
            if let scene = model.scene {
                SceneView(scene: scene)
            } else {
                Text("⚠️ 模型加载失败").foregroundColor(.red)
            }
        }
    }
}
