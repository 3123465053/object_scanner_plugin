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

    /// 直接从目录中找纹理文件赋给 SCNMaterial，完全不依赖 MDLAsset 的纹理加载。
    ///
    /// 方案说明：
    ///   - 方案A（按名称）：解析 MTL → textureMap[matName]=image → 按 mat.name 匹配
    ///     问题：MDLAsset→SCNScene 转换后 mat.name 常为 nil，导致全部匹配失败
    ///   - 方案B（按文件名规律，本方案）：
    ///     我们自己生成的 OBJ 纹理命名固定为 <baseName>_tex0.jpg / _tex1.jpg ...
    ///     直接扫描这些文件，按顺序赋给场景中所有材质，不依赖材质名称
    private static func applyOBJTextures(scene: SCNScene, objURL: URL) {
        let dir      = objURL.deletingLastPathComponent()
        let baseName = objURL.deletingPathExtension().lastPathComponent

        // ── 1. 按命名规律收集纹理（_tex0.jpg, _tex1.jpg, ...）──
        var textures: [UIImage] = []
        var idx = 0
        while true {
            let jpg = dir.appendingPathComponent("\(baseName)_tex\(idx).jpg").path
            let png = dir.appendingPathComponent("\(baseName)_tex\(idx).png").path
            if let img = UIImage(contentsOfFile: jpg) ?? UIImage(contentsOfFile: png) {
                textures.append(img)
                idx += 1
            } else {
                break
            }
        }

        // 方案B 找不到时降级方案A：解析 MTL 获取任意纹理
        if textures.isEmpty {
            textures = loadTexturesFromMTL(dir: dir, objURL: objURL)
        }

        guard !textures.isEmpty else {
            print("OBJ 预览：未找到纹理文件，dir=\(dir.path)")
            return
        }

        // ── 2. 收集场景所有材质 ──
        var allMaterials: [SCNMaterial] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            allMaterials.append(contentsOf: node.geometry?.materials ?? [])
        }

        // ── 3. 赋值：只有一种纹理时全部用同一张，多种时按索引循环 ──
        let single = textures[0]
        for (i, mat) in allMaterials.enumerated() {
            mat.diffuse.contents = textures.count == 1 ? single : textures[i % textures.count]
            mat.isDoubleSided   = true
        }
        print("OBJ 预览：赋纹理 \(textures.count) 张 → \(allMaterials.count) 个材质")
    }

    /// 降级方案：解析 MTL 文件收集所有 map_Kd 引用的图片（去重）
    private static func loadTexturesFromMTL(dir: URL, objURL: URL) -> [UIImage] {
        guard let fh = try? FileHandle(forReadingFrom: objURL) else { return [] }
        let header = fh.readData(ofLength: 4096); fh.closeFile()
        guard let headerStr = String(data: header, encoding: .utf8) else { return [] }

        var mtlFileName: String? = nil
        for line in headerStr.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("mtllib ") {
                mtlFileName = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let mtlFile = mtlFileName,
              let mtlStr = try? String(contentsOf: dir.appendingPathComponent(mtlFile),
                                       encoding: .utf8) else { return [] }

        var result: [UIImage] = []
        var seen = Set<String>()
        for line in mtlStr.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix("map_kd "),
                  let texFile = t.components(separatedBy: .whitespaces).last,
                  !texFile.isEmpty, !texFile.hasPrefix("-"),
                  !seen.contains(texFile) else { continue }
            seen.insert(texFile)
            if let img = UIImage(contentsOfFile: dir.appendingPathComponent(texFile).path) {
                result.append(img)
            }
        }
        return result
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
