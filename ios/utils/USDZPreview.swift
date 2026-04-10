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
        default:
            let asset = MDLAsset(url: url)
            asset.loadTextures()
            loaded = SCNScene(mdlAsset: asset)
        }

        guard let scene = loaded else {
            print("⚠️ 模型加载失败: \(path)")
            return
        }

        // 根据文件格式选择不同的材质修复策略
        Model.fixMaterials(scene.rootNode, ext: ext)
        self.scene = scene
    }

    /// 根据格式修复材质
    private static func fixMaterials(_ node: SCNNode, ext: String) {
        if let geo = node.geometry {
            switch ext {
            case "ply":
                // PLY 顶点颜色是 sRGB 值，但 SceneKit 当作线性值处理后又做 linear→sRGB 转换
                // 导致双重 gamma（颜色偏浅）。用 shader modifier 反转多余的 gamma。
                let gammaFix: [SCNShaderModifierEntryPoint: String] = [
                    .fragment: "_output.color.rgb = pow(_output.color.rgb, float3(2.2));"
                ]
                for mat in geo.materials {
                    mat.lightingModel = .constant
                    mat.diffuse.contents = UIColor.white
                    mat.shaderModifiers = gammaFix
                    mat.isDoubleSided = true
                }
                if geo.materials.isEmpty {
                    let mat = SCNMaterial()
                    mat.lightingModel = .constant
                    mat.diffuse.contents = UIColor.white
                    mat.shaderModifiers = gammaFix
                    mat.isDoubleSided = true
                    geo.materials = [mat]
                }
            case "stl":
                // STL 无颜色，给个默认材质
                let mat = SCNMaterial()
                mat.lightingModel = .physicallyBased
                mat.diffuse.contents = UIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0)
                mat.metalness.contents = 0.1
                mat.roughness.contents = 0.6
                mat.isDoubleSided = true
                geo.materials = [mat]
            default:
                // 其他格式：修复缺失材质
                if geo.materials.isEmpty {
                    geo.materials = [defaultMaterial()]
                } else {
                    var needsFix = true
                    for mat in geo.materials {
                        if mat.diffuse.contents != nil { needsFix = false; break }
                    }
                    if needsFix { geo.materials = [defaultMaterial()] }
                }
                for mat in geo.materials { mat.isDoubleSided = true }
            }
        }
        for child in node.childNodes { fixMaterials(child, ext: ext) }
    }

    private static func defaultMaterial() -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .blinn
        mat.diffuse.contents = UIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0)
        mat.specular.contents = UIColor(white: 0.2, alpha: 1.0)
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

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(white: 0.3, alpha: 1.0)
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
