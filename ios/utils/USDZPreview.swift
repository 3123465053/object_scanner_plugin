import SwiftUI
import SceneKit
import SceneKit.ModelIO
import Combine

class Model: ObservableObject {
    @Published var scene: SCNScene?
    @Published var isLoading = true
    @Published var errorMsg: String? = nil

    init(usdzPath: String) {
        loadAsync(path: usdzPath)
    }

    private func loadAsync(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async { [weak self] in
                self?.errorMsg = "文件不存在"
                self?.isLoading = false
            }
            return
        }

        let ext = url.pathExtension.lowercased()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded: SCNScene?

            switch ext {
            case "glb", "gltf":
                loaded = try? GLTFLoader.loadScene(from: url)

            case "scn":
                loaded = try? SCNScene(url: url, options: nil)

            case "obj":
                // MDLAsset 加载几何体；纹理由 applyOBJTextures 手动处理
                // （MDLAsset.loadTextures → SCNScene 转换会丢失纹理，原因不明）
                let asset = MDLAsset(url: url)
                loaded = SCNScene(mdlAsset: asset)
                if let scene = loaded {
                    Model.applyOBJTextures(scene: scene, objURL: url)
                }

            default:
                let asset = MDLAsset(url: url)
                asset.loadTextures()
                loaded = SCNScene(mdlAsset: asset)
            }

            guard let scene = loaded else {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMsg = "模型加载失败"
                    self?.isLoading = false
                }
                return
            }

            Model.fixMaterials(scene.rootNode, ext: ext)

            DispatchQueue.main.async { [weak self] in
                self?.scene = scene
                self?.isLoading = false
            }
        }
    }

    // MARK: - OBJ 纹理手动加载

    /// 按 MTL 的 newmtl → map_Kd 映射恢复 OBJ 材质。
    private static func applyOBJTextures(scene: SCNScene, objURL: URL) {
        let directory = objURL.deletingLastPathComponent()
        let mtlURL = directory.appendingPathComponent(
            objURL.deletingPathExtension().lastPathComponent + ".mtl"
        )
        guard let contents = try? String(contentsOf: mtlURL, encoding: .utf8) else {
            print("OBJ 预览：无法读取 MTL，path=\(mtlURL.path)")
            return
        }

        var texturePaths: [String: String] = [:]
        var currentMaterial: String?
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("newmtl ") {
                currentMaterial = String(trimmed.dropFirst(7))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("map_kd "),
                      let materialName = currentMaterial {
                let relativePath = String(trimmed.dropFirst(7))
                    .trimmingCharacters(in: .whitespaces)
                if !relativePath.isEmpty {
                    texturePaths[materialName] = relativePath
                }
            }
        }

        guard !texturePaths.isEmpty else {
            print("OBJ 预览：MTL 中没有 map_Kd")
            return
        }

        var allMaterials: [SCNMaterial] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            allMaterials.append(contentsOf: node.geometry?.materials ?? [])
        }

        var imageCache: [String: UIImage] = [:]
        var assignedCount = 0
        for (index, material) in allMaterials.enumerated() {
            let generatedName = "mat_\(index)"
            let materialName = material.name.flatMap { texturePaths[$0] == nil ? nil : $0 }
                ?? (texturePaths[generatedName] == nil ? nil : generatedName)
            guard let materialName,
                  let relativePath = texturePaths[materialName] else {
                material.isDoubleSided = true
                continue
            }

            let image: UIImage?
            if let cached = imageCache[relativePath] {
                image = cached
            } else {
                let loaded = UIImage(contentsOfFile: directory.appendingPathComponent(relativePath).path)
                if let loaded { imageCache[relativePath] = loaded }
                image = loaded
            }
            if let image {
                material.diffuse.contents = image
                assignedCount += 1
            }
            material.isDoubleSided = true
        }
        print("OBJ 预览：按 MTL 映射恢复 \(assignedCount)/\(allMaterials.count) 个材质")
    }

    // MARK: - 材质修复

    private static func fixMaterials(_ node: SCNNode, ext: String) {
        if let geo = node.geometry {
            switch ext {
            case "ply":
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
                let mat = SCNMaterial()
                mat.lightingModel = .physicallyBased
                mat.diffuse.contents = UIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0)
                mat.metalness.contents = 0.1
                mat.roughness.contents = 0.6
                mat.isDoubleSided = true
                geo.materials = [mat]

            default:
                if geo.materials.isEmpty {
                    geo.materials = [defaultMaterial()]
                } else {
                    // 已有纹理（map 或 UIImage）则不覆盖；全空才替换
                    let hasContent = geo.materials.contains {
                        $0.diffuse.contents != nil
                    }
                    if !hasContent { geo.materials = [defaultMaterial()] }
                }
                for mat in geo.materials { mat.isDoubleSided = true }
            }

            for material in geo.materials {
                material.diffuse.magnificationFilter = .linear
                material.diffuse.minificationFilter = .linear
                material.diffuse.mipFilter = .linear
                material.diffuse.maxAnisotropy = 8
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

// MARK: - SceneView

struct SceneView: UIViewRepresentable {
    var scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
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

// MARK: - USDZPreview

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

            } else if let err = model.errorMsg {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                }

            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.4)
                    Text("加载中…")
                        .foregroundColor(Color.white.opacity(0.6))
                        .font(.caption)
                }
            }
        }
    }
}
