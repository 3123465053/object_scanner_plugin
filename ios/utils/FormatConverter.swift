//
//  FormatConverter.swift
//  object_scanner_plugin
//
//  格式转换工具

import Foundation
import CryptoKit
import ModelIO
import SceneKit
import Flutter
import CoreImage

/// SceneKit / ModelIO 都会在加载时产生较大的临时缓冲区。转换和预览共用同一
/// 串行队列，避免两个模型同时解码导致瞬时内存翻倍。
enum ModelWorkQueue {
    static let shared = DispatchQueue(
        label: "com.objectscanner.model-work",
        qos: .userInitiated
    )
}

struct FormatConverter {

    static let supportedFormats = [
        "obj", "stl", "ply", "usd", "usda", "usdc",
        "usdz", "scn",
        "glb", "gltf"
    ]

    // 转换和预览共享串行队列，避免同时解码两个大模型导致内存峰值翻倍。
    private static let conversionQueue = ModelWorkQueue.shared

    // MARK: - 主入口

    static func convert(inputPath: String, outputFormat: String, result: @escaping FlutterResult) {
        let format = outputFormat.lowercased()

        guard supportedFormats.contains(format) else {
            result(["path": NSNull(), "msg": "不支持的输出格式: \(outputFormat)。支持: \(supportedFormats.joined(separator: ", "))"] as [String: Any])
            return
        }
        guard FileManager.default.fileExists(atPath: inputPath) else {
            result(["path": NSNull(), "msg": "输入文件不存在: \(inputPath)"] as [String: Any])
            return
        }

        conversionQueue.async {
            autoreleasepool {
              do {
                let inputURL = URL(fileURLWithPath: inputPath)
                let fileName = inputURL.deletingPathExtension().lastPathComponent
                let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

                // 每种格式独立子目录：避免 obj/mtl、usd/texture 等外挂文件互相覆盖，
                // 也方便导出时整包打 zip
                let outputDir = documentsDir.appendingPathComponent("\(fileName)_\(format)")
                if FileManager.default.fileExists(atPath: outputDir.path) {
                    try FileManager.default.removeItem(at: outputDir)
                }
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)
                let outputURL = outputDir.appendingPathComponent("\(fileName).\(format)")

                // 转换完成后立即释放场景。缓存完整 SCNScene 会让预览加载时仍保留
                // 上一次转换的几何和纹理，峰值内存很容易翻倍。
                let scene = try _loadSceneFresh(from: inputURL)

                let success: Bool
                switch format {
                // SceneKit 原生写入
                // ★ scene.write() 可能在内部修改 mat.diffuse.contents（UIImage → 内部纹理句柄），
                //   先保存再还原，确保缓存的 SCNScene 对后续格式仍有效
                case "usdz", "scn":
                    success = sceneWritePreserving(scene: scene, to: outputURL)

                // USD/USDA/USDC 必须把内存纹理先落盘，再由 SceneKit 直接写出。
                // ModelIO 对 USDZ 二次导出会丢失 UsdPreviewSurface 材质网络。
                case "usdc", "usda", "usd":
                    success = try sceneWriteWithExternalTextures(scene: scene, to: outputURL)

                // GLB/GLTF 自定义导出器
                case "glb", "gltf":
                    let meshes = collectMeshData(from: scene.rootNode)
                    guard !meshes.isEmpty else { throw convError("无有效几何数据") }
                    success = try writeGLTF(meshes: meshes, to: outputURL, binary: format == "glb")

                // OBJ：直接从 MeshData 写（含纹理），跳过 scene.write() 避免性能瓶颈
                case "obj":
                    let meshes = collectMeshData(from: scene.rootNode)
                    guard !meshes.isEmpty else { throw convError("无有效几何数据") }
                    success = try writeOBJ(meshes: meshes, to: outputURL)

                // STL：直接写二进制 STL（最快，无需 USDZ 中转）
                case "stl":
                    let meshes = collectMeshData(from: scene.rootNode)
                    guard !meshes.isEmpty else { throw convError("无有效几何数据") }
                    success = try writeSTLBinary(meshes: meshes, to: outputURL)

                // PLY：自定义导出（MDLAsset 不导出顶点颜色，需手动从纹理烘焙）
                case "ply":
                    success = try writePLY(scene: scene, to: outputURL)

                default:
                    success = false
                }

                DispatchQueue.main.async {
                    if success {
                        result(["path": outputURL.path, "msg": "success"] as [String: Any])
                    } else {
                        result(["path": NSNull(), "msg": "格式转换失败"] as [String: Any])
                    }
                }
              } catch {
                DispatchQueue.main.async {
                    result(["path": NSNull(), "msg": "格式转换异常: \(error.localizedDescription)"] as [String: Any])
                }
              }
            }
        }
    }

    // MARK: - USD 导出

    /// SceneKit 的 USD 导出器只会为文件 URL 建立纹理引用。这里先把所有可解码的
    /// diffuse 纹理写到临时目录，再通过 SCNSceneExportDestinationURL 让导出器把
    /// 资源复制到目标目录并生成正确的相对路径。
    private static func sceneWriteWithExternalTextures(scene: SCNScene, to outputURL: URL) throws -> Bool {
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usd_textures_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var savedContents: [(SCNMaterial, Any?)] = []
        var visitedMaterials = Set<ObjectIdentifier>()
        var textureCount = 0

        scene.rootNode.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] {
                let key = ObjectIdentifier(material)
                guard visitedMaterials.insert(key).inserted,
                      let image = extractImage(from: material.diffuse.contents),
                      let encoded = encodeTexture(image) else { continue }

                let (data, mimeType) = encoded
                let ext = mimeType == "image/png" ? "png" : "jpg"
                let fileName = "texture_\(String(format: "%03d", textureCount)).\(ext)"
                let textureURL = stagingDir
                    .appendingPathComponent(fileName)
                do {
                    try data.write(to: textureURL, options: .atomic)
                    savedContents.append((material, material.diffuse.contents))
                    material.diffuse.contents = textureURL
                    textureCount += 1
                } catch {
                    continue
                }
            }
        }

        defer {
            for (material, originalContents) in savedContents {
                material.diffuse.contents = originalContents
            }
            try? FileManager.default.removeItem(at: stagingDir)
        }

        var exportError: Error?
        let options: [String: Any] = [SCNSceneExportDestinationURL: outputURL]
        let success = scene.write(
            to: outputURL,
            options: options,
            delegate: nil
        ) { _, error, _ in
            if let error { exportError = error }
        }

        if let exportError { throw exportError }
        guard success else { throw convError("SceneKit 写入 USD 失败") }

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        guard size > 0 else { throw convError("USD 输出文件为空") }

        if textureCount > 0 {
            let outputDir = outputURL.deletingLastPathComponent()
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
            let enumerator = FileManager.default.enumerator(
                at: outputDir,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
            let imageExtensions = Set(["png", "jpg", "jpeg"])
            var hasExportedTexture = false
            while let resourceURL = enumerator?.nextObject() as? URL {
                if imageExtensions.contains(resourceURL.pathExtension.lowercased()) {
                    hasExportedTexture = true
                    break
                }
            }
            guard hasExportedTexture else {
                throw convError("USD 已生成，但纹理资源未写出")
            }
        }

        return true
    }

    // MARK: - 输入加载

    /// 真正从磁盘加载（不经过缓存）
    private static func _loadSceneFresh(from url: URL) throws -> SCNScene {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "glb", "gltf":
            return try GLTFLoader.loadScene(from: url)
        case "obj":
            let asset = MDLAsset(url: url)
            let scene = SCNScene(mdlAsset: asset)
            Model.applyOBJTextures(scene: scene, objURL: url)
            return scene
        case "scn":
            return try SCNScene(url: url, options: nil)
        default:
            let asset = MDLAsset(url: url)
            asset.loadTextures()
            return SCNScene(mdlAsset: asset)
        }
    }

    // MARK: - PLY 自定义导出器（从纹理烘焙顶点颜色）

    /// 遍历 SCNScene 所有网格，从纹理+UV 烘焙顶点颜色，输出 binary PLY
    private static func writePLY(scene: SCNScene, to url: URL) throws -> Bool {
        var allPos: [Float] = []
        var allNorm: [Float] = []
        var allColor: [UInt8] = []  // RGB per vertex (3 bytes)
        var allIdx: [UInt32] = []
        var vertexOffset: UInt32 = 0
        let meshes = collectMeshData(from: scene.rootNode)
        var textureCache: [ObjectIdentifier: (pixels: [UInt8], width: Int, height: Int)] = [:]

        for mesh in meshes {
            let vertexCount = mesh.vertexCount
            guard vertexCount > 0, !mesh.indices.isEmpty else { continue }
            allPos.append(contentsOf: mesh.positions)
            allNorm.append(contentsOf: mesh.normals)

            // collectMeshData 已按 geometry element 拆分，每个子网格只对应一个材质。
            if mesh.colors.count / 4 == vertexCount {
                for index in 0..<vertexCount {
                    allColor.append(UInt8(clamping: Int(mesh.colors[index * 4] * 255)))
                    allColor.append(UInt8(clamping: Int(mesh.colors[index * 4 + 1] * 255)))
                    allColor.append(UInt8(clamping: Int(mesh.colors[index * 4 + 2] * 255)))
                }
            } else if let texture = mesh.diffuseTexture,
                      mesh.texCoords.count / 2 == vertexCount {
                let key = ObjectIdentifier(texture)
                let decoded: (pixels: [UInt8], width: Int, height: Int)?
                if let cached = textureCache[key] {
                    decoded = cached
                } else if let value = textureToRGBA(texture) {
                    textureCache[key] = value
                    decoded = value
                } else {
                    decoded = nil
                }

                if let decoded {
                    for index in 0..<vertexCount {
                        let u = max(0, min(1, mesh.texCoords[index * 2]))
                        let v = max(0, min(1, mesh.texCoords[index * 2 + 1]))
                        let x = min(Int(u * Float(decoded.width - 1)), decoded.width - 1)
                        let y = min(Int(v * Float(decoded.height - 1)), decoded.height - 1)
                        let offset = (y * decoded.width + x) * 4
                        allColor.append(decoded.pixels[offset])
                        allColor.append(decoded.pixels[offset + 1])
                        allColor.append(decoded.pixels[offset + 2])
                    }
                } else {
                    for _ in 0..<vertexCount { allColor.append(contentsOf: [180, 180, 180]) }
                }
            } else {
                let red = UInt8(clamping: Int(mesh.diffuseR * 255))
                let green = UInt8(clamping: Int(mesh.diffuseG * 255))
                let blue = UInt8(clamping: Int(mesh.diffuseB * 255))
                for _ in 0..<vertexCount { allColor.append(contentsOf: [red, green, blue]) }
            }

            for index in mesh.indices { allIdx.append(index + vertexOffset) }
            vertexOffset += UInt32(vertexCount)
        }

        let totalVerts = allPos.count / 3
        let totalFaces = allIdx.count / 3
        guard totalVerts > 0 else { return false }
        let hasNormals = allNorm.count / 3 == totalVerts

        // 写 binary PLY
        var header = "ply\nformat binary_little_endian 1.0\n"
        header += "element vertex \(totalVerts)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        if hasNormals { header += "property float nx\nproperty float ny\nproperty float nz\n" }
        header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        header += "element face \(totalFaces)\n"
        header += "property list uchar int vertex_indices\n"
        header += "end_header\n"

        var data = Data()
        data.append(header.data(using: .ascii)!)

        for i in 0..<totalVerts {
            var x = allPos[i*3], y = allPos[i*3+1], z = allPos[i*3+2]
            data.append(Data(bytes: &x, count: 4))
            data.append(Data(bytes: &y, count: 4))
            data.append(Data(bytes: &z, count: 4))
            if hasNormals {
                var nx = allNorm[i*3], ny = allNorm[i*3+1], nz = allNorm[i*3+2]
                data.append(Data(bytes: &nx, count: 4))
                data.append(Data(bytes: &ny, count: 4))
                data.append(Data(bytes: &nz, count: 4))
            }
            data.append(contentsOf: [allColor[i*3], allColor[i*3+1], allColor[i*3+2]])
        }
        for i in 0..<totalFaces {
            var count: UInt8 = 3
            var i0 = Int32(allIdx[i*3]), i1 = Int32(allIdx[i*3+1]), i2 = Int32(allIdx[i*3+2])
            data.append(Data(bytes: &count, count: 1))
            data.append(Data(bytes: &i0, count: 4))
            data.append(Data(bytes: &i1, count: 4))
            data.append(Data(bytes: &i2, count: 4))
        }

        try data.write(to: url)
        return true
    }

    /// CGContext 渲染到已知格式的像素缓冲区（iOS 原生 BGRA，格式保证正确）
    /// 亮度差异由预览端 shader modifier 修正，这里只负责提取正确的 RGB 值
    private static func textureToRGBA(_ image: UIImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let cgImage = image.cgImage else { return nil }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        let bytesPerRow = w * 4
        var bgraData = [UInt8](repeating: 0, count: h * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        // iOS 原生格式: byteOrder32Little + noneSkipFirst = BGRX（无预乘）
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = CGContext(
            data: &bgraData, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // BGRX → RGBA：B在offset+0, G在offset+1, R在offset+2, X在offset+3
        var rgbaData = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let s = i * 4
            rgbaData[s]     = bgraData[s + 2] // R
            rgbaData[s + 1] = bgraData[s + 1] // G
            rgbaData[s + 2] = bgraData[s]     // B
            rgbaData[s + 3] = 255
        }

        return (rgbaData, w, h)
    }

    // MARK: - GLB / GLTF 自定义导出器（内嵌纹理）

    struct MeshData {
        var positions:  [Float] = []
        var normals:    [Float] = []
        var texCoords:  [Float] = []
        var colors:     [Float] = []
        var indices:    [UInt32] = []
        var diffuseR: Float = 0.7
        var diffuseG: Float = 0.7
        var diffuseB: Float = 0.7
        var metallic:  Float = 0.0
        var roughness: Float = 0.5
        var diffuseTexture: UIImage? = nil
        var textureWrapS: SCNWrapMode = .repeat
        var textureWrapT: SCNWrapMode = .repeat
        var vertexCount: Int { positions.count / 3 }
    }

    private struct MeshVertexKey: Hashable {
        let position: UInt32
        let normal: UInt32
        let texCoord: UInt32
        let color: UInt32
    }

    private struct MeshSourceData {
        let values: [Float]
        let components: Int
        let vectorCount: Int
        let indexChannel: Int
    }

    private static func collectMeshData(from root: SCNNode) -> [MeshData] {
        var result: [MeshData] = []
        var imageCache: [ObjectIdentifier: UIImage] = [:]

        func walk(_ node: SCNNode) {
            if let geo = node.geometry {
                let positionSource = geo.sources(for: .vertex).first
                let normalSource = geo.sources(for: .normal).first
                let colorSource = geo.sources(for: .color).first
                let textureSources = geo.sources(for: .texcoord)
                guard let positionData = meshSourceData(
                    for: positionSource,
                    components: 3,
                    in: geo
                ) else {
                    node.childNodes.forEach { walk($0) }
                    return
                }

                let normalData = meshSourceData(for: normalSource, components: 3, in: geo)
                let colorData = meshSourceData(for: colorSource, components: 4, in: geo)
                let worldTransform = node.simdWorldTransform
                let linearTransform = simd_float3x3(
                    SIMD3<Float>(worldTransform.columns.0.x, worldTransform.columns.0.y, worldTransform.columns.0.z),
                    SIMD3<Float>(worldTransform.columns.1.x, worldTransform.columns.1.y, worldTransform.columns.1.z),
                    SIMD3<Float>(worldTransform.columns.2.x, worldTransform.columns.2.y, worldTransform.columns.2.z)
                )
                let determinant = simd_determinant(linearTransform)
                let normalTransform = abs(determinant) > 1e-8
                    ? simd_transpose(simd_inverse(linearTransform))
                    : linearTransform

                // SceneKit 按 elementIndex % materials.count 映射材质。每个 element
                // 必须单独导出；合并后套 firstMaterial 会让所有面重复第一张贴图。
                for (elementIndex, element) in geo.elements.enumerated() {
                    var mesh = MeshData()
                    let material: SCNMaterial?
                    if !geo.materials.isEmpty {
                        material = geo.materials[elementIndex % geo.materials.count]
                    } else {
                        material = nil
                    }

                    let mappingChannel = max(0, material?.diffuse.mappingChannel ?? 0)
                    let textureSource = mappingChannel < textureSources.count
                        ? textureSources[mappingChannel]
                        : textureSources.first
                    let textureData = meshSourceData(for: textureSource, components: 2, in: geo)

                    var channelIndices: [Int: [UInt32]] = [:]
                    func indices(for channel: Int) -> [UInt32] {
                        if let cached = channelIndices[channel] { return cached }
                        let decoded = extractIndices(element, channel: channel)
                        channelIndices[channel] = decoded
                        return decoded
                    }

                    let positionIndices = indices(for: positionData.indexChannel)
                    guard positionIndices.count >= 3 else { continue }

                    func validIndices(for source: MeshSourceData?) -> [UInt32]? {
                        guard let source else { return nil }
                        let sourceIndices = indices(for: source.indexChannel)
                        guard sourceIndices.count == positionIndices.count,
                              sourceIndices.allSatisfy({ Int($0) < source.vectorCount }) else {
                            return nil
                        }
                        return sourceIndices
                    }

                    let normalIndices = validIndices(for: normalData)
                    let textureIndices = validIndices(for: textureData)
                    let colorIndices = validIndices(for: colorData)
                    var remappedIndices: [MeshVertexKey: UInt32] = [:]
                    remappedIndices.reserveCapacity(positionIndices.count)
                    let textureTransform = material?.diffuse.contentsTransform ?? SCNMatrix4Identity

                    func compactIndex(at corner: Int) -> UInt32? {
                        let positionIndex = positionIndices[corner]
                        guard Int(positionIndex) < positionData.vectorCount else { return nil }

                        let normalIndex = normalIndices?[corner] ?? UInt32.max
                        let textureIndex = textureIndices?[corner] ?? UInt32.max
                        let colorIndex = colorIndices?[corner] ?? UInt32.max
                        let key = MeshVertexKey(
                            position: positionIndex,
                            normal: normalIndex,
                            texCoord: textureIndex,
                            color: colorIndex
                        )
                        if let existing = remappedIndices[key] { return existing }

                        let positionOffset = Int(positionIndex) * positionData.components
                        let position = SIMD4<Float>(
                            positionData.values[positionOffset],
                            positionData.values[positionOffset + 1],
                            positionData.values[positionOffset + 2],
                            1
                        )
                        let transformedPosition = simd_mul(worldTransform, position)
                        let newIndex = UInt32(mesh.vertexCount)
                        remappedIndices[key] = newIndex
                        mesh.positions.append(contentsOf: [
                            transformedPosition.x,
                            transformedPosition.y,
                            transformedPosition.z
                        ])

                        if let normalData, normalIndex != UInt32.max {
                            let offset = Int(normalIndex) * normalData.components
                            let normal = SIMD3<Float>(
                                normalData.values[offset],
                                normalData.values[offset + 1],
                                normalData.values[offset + 2]
                            )
                            let transformedNormal = simd_mul(normalTransform, normal)
                            let length = simd_length(transformedNormal)
                            let normalized = length > 1e-8 ? transformedNormal / length : transformedNormal
                            mesh.normals.append(contentsOf: [normalized.x, normalized.y, normalized.z])
                        }

                        if let textureData, textureIndex != UInt32.max {
                            let offset = Int(textureIndex) * textureData.components
                            let u = textureData.values[offset]
                            let v = textureData.values[offset + 1]
                            mesh.texCoords.append(contentsOf: transformTextureCoordinate(
                                u: u,
                                v: v,
                                by: textureTransform
                            ))
                        }

                        if let colorData, colorIndex != UInt32.max {
                            let offset = Int(colorIndex) * colorData.components
                            mesh.colors.append(contentsOf: colorData.values[offset..<(offset + 4)])
                        }
                        return newIndex
                    }

                    for offset in stride(from: 0, to: positionIndices.count - 2, by: 3) {
                        let corners = determinant < 0
                            ? [offset, offset + 2, offset + 1]
                            : [offset, offset + 1, offset + 2]
                        let triangle = corners.compactMap(compactIndex)
                        if triangle.count == 3 {
                            mesh.indices.append(contentsOf: triangle)
                        }
                    }

                    if let material {
                        if let image = cachedImage(
                            for: material,
                            cache: &imageCache
                        ) {
                            mesh.diffuseTexture = image
                        } else if let color = material.diffuse.contents as? UIColor {
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                            color.getRed(&r, green: &g, blue: &b, alpha: &a)
                            mesh.diffuseR = Float(r)
                            mesh.diffuseG = Float(g)
                            mesh.diffuseB = Float(b)
                        }
                        if let value = material.metalness.contents as? NSNumber {
                            mesh.metallic = value.floatValue
                        }
                        if let value = material.roughness.contents as? NSNumber {
                            mesh.roughness = value.floatValue
                        }
                        mesh.textureWrapS = material.diffuse.wrapS
                        mesh.textureWrapT = material.diffuse.wrapT
                    }

                    if mesh.vertexCount > 0 && !mesh.indices.isEmpty {
                        result.append(mesh)
                    }
                }
            }
            node.childNodes.forEach { walk($0) }
        }
        walk(root)
        return result
    }

    private static func meshSourceData(for source: SCNGeometrySource?,
                                       components: Int,
                                       in geometry: SCNGeometry) -> MeshSourceData? {
        guard let source else { return nil }
        var values: [Float] = []
        extractFloats(source, components, &values)
        guard values.count == source.vectorCount * components else { return nil }

        let sourceIndex = geometry.sources.firstIndex { $0 === source }
        let channel = sourceIndex.flatMap { index -> Int? in
            guard let channels = geometry.geometrySourceChannels, index < channels.count else { return nil }
            return channels[index].intValue
        } ?? 0
        return MeshSourceData(
            values: values,
            components: components,
            vectorCount: source.vectorCount,
            indexChannel: max(0, channel)
        )
    }

    private static func transformTextureCoordinate(u: Float,
                                                   v: Float,
                                                   by transform: SCNMatrix4) -> [Float] {
        let transformedU = u * transform.m11 + v * transform.m21 + transform.m41
        let transformedV = u * transform.m12 + v * transform.m22 + transform.m42
        return [transformedU, transformedV]
    }

    private static func cachedImage(for material: SCNMaterial,
                                    cache: inout [ObjectIdentifier: UIImage]) -> UIImage? {
        let key = ObjectIdentifier(material)
        if let cached = cache[key] { return cached }
        guard let image = extractImage(from: material.diffuse.contents) else { return nil }
        cache[key] = image
        return image
    }

    private static func extractImage(from contents: Any?) -> UIImage? {
        guard let contents = contents else { return nil }

        if let img = contents as? UIImage { return img }
        if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            return UIImage(cgImage: contents as! CGImage)
        }
        if let mdlTex = contents as? MDLTexture,
           let cgImg = mdlTex.imageFromTexture()?.takeUnretainedValue() {
            return UIImage(cgImage: cgImg)
        }
        if let path = contents as? String {
            if let img = UIImage(contentsOfFile: path) { return img }
        }
        if let url = contents as? URL, let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        }
        if let ciImg = contents as? CIImage {
            let ctx = CIContext()
            if let cgImg = ctx.createCGImage(ciImg, from: ciImg.extent) {
                return UIImage(cgImage: cgImg)
            }
        }
        return nil
    }

    private static func writeGLTF(meshes: [MeshData], to outputURL: URL, binary: Bool) throws -> Bool {
        let tempBinURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gltf_bin_\(UUID().uuidString).tmp")
        _ = FileManager.default.createFile(atPath: tempBinURL.path, contents: nil)
        let binHandle = try FileHandle(forWritingTo: tempBinURL)
        var binHandleClosed = false
        defer {
            if !binHandleClosed { try? binHandle.close() }
            try? FileManager.default.removeItem(at: tempBinURL)
        }

        var binLength = 0
        var bufferViews: [[String: Any]] = []
        var accessors:   [[String: Any]] = []
        var gltfMeshes:  [[String: Any]] = []
        var gltfNodes:   [[String: Any]] = []
        var gltfMats:    [[String: Any]] = []
        var gltfImages:  [[String: Any]] = []
        var gltfTextures:[[String: Any]] = []
        var gltfSamplers:[[String: Any]] = []
        var nodeIndices: [Int] = []
        var imageByObject: [ObjectIdentifier: Int] = [:]
        var imageByDigest: [Data: Int] = [:]
        var samplerByKey: [String: Int] = [:]
        var textureByKey: [String: Int] = [:]

        func writeData(_ data: Data) throws {
            try binHandle.write(contentsOf: data)
            binLength += data.count
        }

        // FileHandle 仍接收 Data，但每次最多创建 1 MB 临时块，避免把数百 MB
        // 的 Float/UInt32 数组再完整复制一份到连续 Data 缓冲区。
        func writeRawBuffer(_ buffer: UnsafeRawBufferPointer) throws {
            guard let baseAddress = buffer.baseAddress, !buffer.isEmpty else { return }
            let chunkSize = 1024 * 1024
            var offset = 0
            while offset < buffer.count {
                let count = min(chunkSize, buffer.count - offset)
                try autoreleasepool {
                    let chunk = Data(bytes: baseAddress.advanced(by: offset), count: count)
                    try writeData(chunk)
                }
                offset += count
            }
        }

        func alignBinaryBuffer() throws {
            let padding = (4 - binLength % 4) % 4
            if padding > 0 { try writeData(Data(repeating: 0, count: padding)) }
        }

        func appendBuf(_ floats: [Float]) throws -> (Int, Int) {
            let offset = binLength
            try floats.withUnsafeBytes { try writeRawBuffer($0) }
            let length = binLength - offset
            try alignBinaryBuffer()
            return (offset, length)
        }

        func appendIdx(_ indices: [UInt32]) throws -> (Int, Int) {
            let offset = binLength
            try indices.withUnsafeBytes { try writeRawBuffer($0) }
            let length = binLength - offset
            try alignBinaryBuffer()
            return (offset, length)
        }

        func appendRaw(_ data: Data) throws -> (Int, Int) {
            let offset = binLength
            try writeData(data)
            // 返回真实长度（不含后续 4 字节对齐填充）
            // PNG/JPEG 解码器对 bufferView 末尾的零填充字节敏感，会导致图片读取失败→黑色材质
            try alignBinaryBuffer()
            return (offset, data.count)
        }
        func addBV(_ off: Int, _ len: Int, _ tgt: Int) -> Int {
            bufferViews.append(["buffer": 0, "byteOffset": off, "byteLength": len, "target": tgt])
            return bufferViews.count - 1
        }
        func addBVPlain(_ off: Int, _ len: Int) -> Int {
            bufferViews.append(["buffer": 0, "byteOffset": off, "byteLength": len])
            return bufferViews.count - 1
        }
        func addAC(_ bv: Int, _ ct: Int, _ cnt: Int, _ tp: String, _ extra: [String: Any] = [:]) -> Int {
            var a: [String: Any] = ["bufferView": bv, "componentType": ct, "count": cnt, "type": tp]
            extra.forEach { a[$0.key] = $0.value }
            accessors.append(a)
            return accessors.count - 1
        }
        func gltfWrapMode(_ mode: SCNWrapMode) -> Int {
            switch mode {
            case .repeat: return 10497
            case .mirror: return 33648
            default: return 33071
            }
        }
        func samplerIndex(wrapS: SCNWrapMode, wrapT: SCNWrapMode) -> Int {
            let s = gltfWrapMode(wrapS)
            let t = gltfWrapMode(wrapT)
            let key = "\(s):\(t)"
            if let existing = samplerByKey[key] { return existing }
            let index = gltfSamplers.count
            gltfSamplers.append([
                "magFilter": 9729,
                "minFilter": 9987,
                "wrapS": s,
                "wrapT": t
            ])
            samplerByKey[key] = index
            return index
        }
        func imageIndex(for image: UIImage) throws -> Int? {
            let objectKey = ObjectIdentifier(image)
            if let existing = imageByObject[objectKey] { return existing }
            guard let (bytes, mimeType) = encodeTexture(image) else { return nil }
            let digest = Data(SHA256.hash(data: bytes))
            if let existing = imageByDigest[digest] {
                imageByObject[objectKey] = existing
                return existing
            }

            let (offset, length) = try appendRaw(bytes)
            let bufferView = addBVPlain(offset, length)
            let index = gltfImages.count
            gltfImages.append(["bufferView": bufferView, "mimeType": mimeType])
            imageByObject[objectKey] = index
            imageByDigest[digest] = index
            return index
        }
        func addTexture(for image: UIImage,
                        wrapS: SCNWrapMode,
                        wrapT: SCNWrapMode) throws -> Int? {
            guard let imageIndex = try imageIndex(for: image) else { return nil }
            let samplerIndex = samplerIndex(wrapS: wrapS, wrapT: wrapT)
            let key = "\(imageIndex):\(samplerIndex)"
            if let existing = textureByKey[key] { return existing }
            let index = gltfTextures.count
            gltfTextures.append(["source": imageIndex, "sampler": samplerIndex])
            textureByKey[key] = index
            return index
        }

        for (i, m) in meshes.enumerated() {
            let matIdx = gltfMats.count
            var pbrDict: [String: Any] = [
                "metallicFactor": m.metallic,
                "roughnessFactor": m.roughness
            ]

            if let texture = m.diffuseTexture,
               let textureIndex = try addTexture(
                for: texture,
                wrapS: m.textureWrapS,
                wrapT: m.textureWrapT
               ) {
                pbrDict["baseColorTexture"] = ["index": textureIndex]
            } else {
                pbrDict["baseColorFactor"] = [m.diffuseR, m.diffuseG, m.diffuseB, 1.0]
            }

            gltfMats.append(["pbrMetallicRoughness": pbrDict, "doubleSided": true])

            let (pO, pL) = try appendBuf(m.positions)
            let (minP, maxP) = computeBounds(m.positions)
            let bvP = addBV(pO, pL, 34962)
            let acP = addAC(bvP, 5126, m.vertexCount, "VEC3",
                            ["min": [minP.x, minP.y, minP.z], "max": [maxP.x, maxP.y, maxP.z]])
            var attrs: [String: Int] = ["POSITION": acP]

            if !m.normals.isEmpty {
                let (o, l) = try appendBuf(m.normals)
                attrs["NORMAL"] = addAC(addBV(o, l, 34962), 5126, m.normals.count/3, "VEC3")
            }
            if !m.texCoords.isEmpty {
                let (o, l) = try appendBuf(m.texCoords)
                attrs["TEXCOORD_0"] = addAC(addBV(o, l, 34962), 5126, m.texCoords.count/2, "VEC2")
            }
            if m.colors.count / 4 == m.vertexCount {
                let (o, l) = try appendBuf(m.colors)
                attrs["COLOR_0"] = addAC(addBV(o, l, 34962), 5126, m.colors.count/4, "VEC4")
            }

            let (iO, iL) = try appendIdx(m.indices)
            let acI = addAC(addBV(iO, iL, 34963), 5125, m.indices.count, "SCALAR")

            gltfMeshes.append(["name": "Mesh_\(i)", "primitives": [
                ["attributes": attrs, "indices": acI, "mode": 4, "material": matIdx]
            ]])
            gltfNodes.append(["name": "Node_\(i)", "mesh": i])
            nodeIndices.append(i)
        }

        var bufEntry: [String: Any] = ["byteLength": binLength]
        let externalBinURL = outputURL.deletingPathExtension().appendingPathExtension("bin")
        if !binary { bufEntry["uri"] = externalBinURL.lastPathComponent }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "ObjectScannerPlugin-iOS"],
            "scene": 0, "scenes": [["nodes": nodeIndices]],
            "nodes": gltfNodes, "meshes": gltfMeshes, "materials": gltfMats,
            "accessors": accessors, "bufferViews": bufferViews, "buffers": [bufEntry]
        ]
        if !gltfImages.isEmpty { json["images"] = gltfImages }
        if !gltfTextures.isEmpty { json["textures"] = gltfTextures }
        if !gltfSamplers.isEmpty { json["samplers"] = gltfSamplers }

        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try binHandle.close()
        binHandleClosed = true

        if binary {
            try writeGLBContainer(
                json: jsonData,
                binURL: tempBinURL,
                binLength: binLength,
                to: outputURL
            )
        } else {
            try? FileManager.default.removeItem(at: externalBinURL)
            try FileManager.default.moveItem(at: tempBinURL, to: externalBinURL)
            try jsonData.write(to: outputURL)
        }
        return true
    }

    private static func writeGLBContainer(json: Data,
                                          binURL: URL,
                                          binLength: Int,
                                          to url: URL) throws {
        var paddedJSON = json
        while paddedJSON.count % 4 != 0 { paddedJSON.append(0x20) }
        let paddedBinLength = binLength + (4 - binLength % 4) % 4
        let total = 12 + 8 + paddedJSON.count + 8 + paddedBinLength
        guard total <= Int(UInt32.max),
              paddedJSON.count <= Int(UInt32.max),
              paddedBinLength <= Int(UInt32.max) else {
            throw convError("GLB 超过 4 GB 格式上限")
        }

        try? FileManager.default.removeItem(at: url)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: url)
        defer { try? outputHandle.close() }

        func writeUInt32(_ value: UInt32) throws {
            var littleEndian = value.littleEndian
            let data = withUnsafeBytes(of: &littleEndian) { Data($0) }
            try outputHandle.write(contentsOf: data)
        }

        try writeUInt32(0x46546C67)
        try writeUInt32(2)
        try writeUInt32(UInt32(total))
        try writeUInt32(UInt32(paddedJSON.count))
        try writeUInt32(0x4E4F534A)
        try outputHandle.write(contentsOf: paddedJSON)
        try writeUInt32(UInt32(paddedBinLength))
        try writeUInt32(0x004E4942)

        let inputHandle = try FileHandle(forReadingFrom: binURL)
        defer { try? inputHandle.close() }
        var finished = false
        while !finished {
            try autoreleasepool {
                let chunk = try inputHandle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty {
                    finished = true
                } else {
                    try outputHandle.write(contentsOf: chunk)
                }
            }
        }

        let padding = paddedBinLength - binLength
        if padding > 0 {
            try outputHandle.write(contentsOf: Data(repeating: 0, count: padding))
        }
    }

    // MARK: - 工具

    private static func extractFloats(_ src: SCNGeometrySource, _ comps: Int, _ arr: inout [Float]) {
        let data = src.data, count = src.vectorCount, stride = src.dataStride
        let offset = src.dataOffset, bpc = src.bytesPerComponent
        arr.reserveCapacity(arr.count + count * comps)  // 预留容量，避免百万次追加反复扩容
        data.withUnsafeBytes { ptr in
            for i in 0..<count {
                for c in 0..<comps {
                    guard c < src.componentsPerVector else {
                        arr.append(src.semantic == .color && c == 3 ? 1 : 0)
                        continue
                    }
                    let off = offset + i * stride + c * bpc
                    guard off + bpc <= data.count else {
                        arr.append(0)
                        continue
                    }
                    if src.usesFloatComponents {
                        if bpc == 4 { arr.append(ptr.load(fromByteOffset: off, as: Float.self)) }
                        else if bpc == 8 { arr.append(Float(ptr.load(fromByteOffset: off, as: Double.self))) }
                        else { arr.append(0) }
                    } else {
                        switch bpc {
                        case 1: arr.append(Float(ptr.load(fromByteOffset: off, as: UInt8.self)) / 255.0)
                        case 2: arr.append(Float(ptr.load(fromByteOffset: off, as: UInt16.self)) / 65535.0)
                        default: arr.append(0)
                        }
                    }
                }
            }
        }
    }

    private static func extractIndices(_ element: SCNGeometryElement, channel requestedChannel: Int) -> [UInt32] {
        let primitiveCount = element.primitiveCount
        guard primitiveCount > 0 else { return [] }

        let range = element.primitiveRange
        let rangeStart = range.location == NSNotFound ? 0 : min(range.location, primitiveCount)
        let rangeCount = range.location == NSNotFound
            ? primitiveCount
            : min(range.length, primitiveCount - rangeStart)
        guard rangeCount > 0 else { return [] }

        let channelCount = max(1, element.indicesChannelCount)
        let channel = min(max(0, requestedChannel), channelCount - 1)
        let bytesPerIndex = element.bytesPerIndex
        let data = element.data

        func rawIndex(at storedIndex: Int) -> UInt32? {
            if data.isEmpty { return UInt32(storedIndex) }
            let byteOffset = storedIndex * bytesPerIndex
            guard bytesPerIndex == 1 || bytesPerIndex == 2 || bytesPerIndex == 4,
                  byteOffset >= 0,
                  byteOffset + bytesPerIndex <= data.count else {
                return nil
            }
            return data.withUnsafeBytes { bytes in
                switch bytesPerIndex {
                case 1:
                    return UInt32(bytes.load(fromByteOffset: byteOffset, as: UInt8.self))
                case 2:
                    return UInt32(bytes.load(fromByteOffset: byteOffset, as: UInt16.self))
                case 4:
                    return bytes.load(fromByteOffset: byteOffset, as: UInt32.self)
                default:
                    return nil
                }
            }
        }

        func channelIndex(logicalIndex: Int,
                          logicalCount: Int,
                          headerCount: Int = 0) -> UInt32? {
            let storedIndex: Int
            if channelCount == 1 {
                storedIndex = headerCount + logicalIndex
            } else if element.hasInterleavedIndicesChannels {
                storedIndex = headerCount + logicalIndex * channelCount + channel
            } else {
                storedIndex = headerCount + channel * logicalCount + logicalIndex
            }
            return rawIndex(at: storedIndex)
        }

        var result: [UInt32] = []
        result.reserveCapacity(rangeCount * 3)

        switch element.primitiveType {
        case .triangles:
            let logicalCount = primitiveCount * 3
            let first = rangeStart * 3
            let end = first + rangeCount * 3
            for logicalIndex in first..<end {
                if let index = channelIndex(logicalIndex: logicalIndex, logicalCount: logicalCount) {
                    result.append(index)
                }
            }

        case .triangleStrip:
            let logicalCount = primitiveCount + 2
            for primitive in rangeStart..<(rangeStart + rangeCount) {
                guard let first = channelIndex(logicalIndex: primitive, logicalCount: logicalCount),
                      let second = channelIndex(logicalIndex: primitive + 1, logicalCount: logicalCount),
                      let third = channelIndex(logicalIndex: primitive + 2, logicalCount: logicalCount) else {
                    continue
                }
                result.append(contentsOf: primitive.isMultiple(of: 2)
                    ? [first, second, third]
                    : [second, first, third])
            }

        case .polygon:
            var polygonSizes: [Int] = []
            polygonSizes.reserveCapacity(primitiveCount)
            for primitive in 0..<primitiveCount {
                guard let size = rawIndex(at: primitive) else { return [] }
                polygonSizes.append(Int(size))
            }
            let logicalCount = polygonSizes.reduce(0, +)
            var logicalOffset = polygonSizes.prefix(rangeStart).reduce(0, +)
            for primitive in rangeStart..<(rangeStart + rangeCount) {
                let size = polygonSizes[primitive]
                guard size >= 3,
                      let first = channelIndex(
                        logicalIndex: logicalOffset,
                        logicalCount: logicalCount,
                        headerCount: primitiveCount
                      ) else {
                    logicalOffset += size
                    continue
                }
                for corner in 1..<(size - 1) {
                    guard let second = channelIndex(
                        logicalIndex: logicalOffset + corner,
                        logicalCount: logicalCount,
                        headerCount: primitiveCount
                    ), let third = channelIndex(
                        logicalIndex: logicalOffset + corner + 1,
                        logicalCount: logicalCount,
                        headerCount: primitiveCount
                    ) else {
                        continue
                    }
                    result.append(contentsOf: [first, second, third])
                }
                logicalOffset += size
            }

        default:
            break
        }
        return result
    }

    private static func computeBounds(_ p: [Float]) -> (min: (x:Float,y:Float,z:Float), max: (x:Float,y:Float,z:Float)) {
        var mnX=Float.greatestFiniteMagnitude, mnY=mnX, mnZ=mnX
        var mxX = -mnX, mxY = -mnX, mxZ = -mnX
        for i in 0..<(p.count/3) {
            mnX=Swift.min(mnX,p[i*3]); mnY=Swift.min(mnY,p[i*3+1]); mnZ=Swift.min(mnZ,p[i*3+2])
            mxX=Swift.max(mxX,p[i*3]); mxY=Swift.max(mxY,p[i*3+1]); mxZ=Swift.max(mxZ,p[i*3+2])
        }
        return ((mnX,mnY,mnZ),(mxX,mxY,mxZ))
    }

    // MARK: - 直接 OBJ 导出（绕过 USDZ 中转）

    /// 直接从 MeshData 写 OBJ + MTL + 纹理文件，使用流式分块写入（512KB 块）避免大内存积压
    private static func writeOBJ(meshes: [MeshData], to outputURL: URL) throws -> Bool {
        let dir      = outputURL.deletingLastPathComponent()
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        let mtlURL   = dir.appendingPathComponent("\(baseName).mtl")

        // 创建 OBJ / MTL 文件
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: mtlURL.path,    contents: nil)
        let objHandle = try FileHandle(forWritingTo: outputURL)
        let mtlHandle = try FileHandle(forWritingTo: mtlURL)
        defer { objHandle.closeFile(); mtlHandle.closeFile() }

        // 流式写缓冲（512KB 阈值后刷新，减少 syscall 次数）
        var objBuf = ""; objBuf.reserveCapacity(600_000)
        var mtlBuf = ""; mtlBuf.reserveCapacity(4_096)

        // ★★ 关键：手动跟踪累积字节数。
        //    绝不能用 objBuf.count！Swift 的 String.count 是 O(n)（遍历 grapheme），
        //    在数百万次 append 中调用会退化成 O(n²)，直接卡死。
        var objPending = 0

        func flushOBJ() {
            if !objBuf.isEmpty {
                objHandle.write(Data(objBuf.utf8))
                objBuf.removeAll(keepingCapacity: true)  // 保留已分配容量
                objPending = 0
            }
        }
        func appendOBJ(_ s: String) {
            objBuf += s
            objPending += s.utf8.count                   // 只数刚追加的小串，O(len(s))
            if objPending > 524_288 { flushOBJ() }
        }
        func appendMTL(_ s: String) { mtlBuf += s }

        appendOBJ("# Generated by ObjectScannerPlugin\nmtllib \(baseName).mtl\n")
        appendMTL("# Generated by ObjectScannerPlugin\n")

        var vertexBase = 1  // OBJ 索引从 1 开始

        // 纹理去重：UIImage 是引用类型，ObjectIdentifier 代表实例地址
        // GLB 的多个子网格往往共享同一个 UIImage 实例；不去重会重复编码 N 次 JPEG
        var texCache: [ObjectIdentifier: String] = [:]
        var texFileCount = 0

        for (i, m) in meshes.enumerated() {
            let matName = "mat_\(i)"

            // ---- 导出纹理文件（去重：同一 UIImage 实例只写一次）----
            var texFileName: String? = nil
            if let tex = m.diffuseTexture {
                let key = ObjectIdentifier(tex)
                if let cached = texCache[key] {
                    texFileName = cached           // 直接复用，不重复编码
                } else if let (texData, ext) = encodeTextureForFile(tex) {
                    let fn = "\(baseName)_tex\(texFileCount).\(ext)"
                    let texURL = dir.appendingPathComponent(fn)
                    if (try? texData.write(to: texURL)) != nil {
                        texFileName = fn
                        texCache[key] = fn
                        texFileCount += 1
                    }
                }
            }

            // ---- MTL ----
            // ★ Kd 必须在 map_Kd 之前：MDLAsset 把同一 semantic 的最后一条当最终值，
            //   若 Kd(white) 写在 map_Kd 之后，会覆盖纹理引用 → 预览全白
            appendMTL("newmtl \(matName)\nKa 0.000 0.000 0.000\n")
            if let fn = texFileName {
                appendMTL("Kd 1.000 1.000 1.000\nmap_Kd \(fn)\n")  // Kd → 再写 map_Kd
            } else {
                appendMTL("Kd \(m.diffuseR) \(m.diffuseG) \(m.diffuseB)\n")
            }
            appendMTL("Ks 0.000 0.000 0.000\nillum 2\n\n")

            // ---- 顶点坐标 ----
            let vc = m.vertexCount
            for vi in 0..<vc {
                let b = vi * 3
                appendOBJ("v \(m.positions[b]) \(m.positions[b+1]) \(m.positions[b+2])\n")
            }

            // ---- 纹理坐标（★ GLTF V=0 在顶部，OBJ V=0 在底部，需要翻转 V = 1 - v）----
            let hasUV = !m.texCoords.isEmpty
            if hasUV {
                for vi in 0..<vc {
                    let b = vi * 2
                    appendOBJ("vt \(m.texCoords[b]) \(1.0 - m.texCoords[b+1])\n")
                }
            }

            // ---- 法线 ----
            let hasNorm = !m.normals.isEmpty
            if hasNorm {
                for vi in 0..<vc {
                    let b = vi * 3
                    appendOBJ("vn \(m.normals[b]) \(m.normals[b+1]) \(m.normals[b+2])\n")
                }
            }

            // ---- 面索引 ----
            appendOBJ("usemtl \(matName)\ng mesh_\(i)\n")
            let faceCount = m.indices.count / 3
            for fi in 0..<faceCount {
                let base = fi * 3
                let a = Int(m.indices[base])   + vertexBase
                let b = Int(m.indices[base+1]) + vertexBase
                let c = Int(m.indices[base+2]) + vertexBase
                if hasUV && hasNorm {
                    appendOBJ("f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n")
                } else if hasUV {
                    appendOBJ("f \(a)/\(a) \(b)/\(b) \(c)/\(c)\n")
                } else if hasNorm {
                    appendOBJ("f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n")
                } else {
                    appendOBJ("f \(a) \(b) \(c)\n")
                }
            }
            vertexBase += vc
        }

        flushOBJ()
        if let d = mtlBuf.data(using: .utf8) { mtlHandle.write(d) }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        return (attrs?[.size] as? Int64 ?? 0) > 0
    }

    // MARK: - 直接二进制 STL 导出

    /// 直接从 MeshData 写二进制 STL（最快，无中间格式）
    private static func writeSTLBinary(meshes: [MeshData], to url: URL) throws -> Bool {
        let totalTriangles = meshes.reduce(0) { $0 + $1.indices.count / 3 }
        guard totalTriangles > 0 else { return false }

        // 预分配：80（header）+ 4（count）+ N×50（每三角形）
        let totalBytes = 84 + totalTriangles * 50
        var buf = [UInt8](repeating: 0, count: totalBytes)

        // Header（80 字节，写可读标记）
        let tag = Array("STL by ObjectScannerPlugin".utf8)
        for i in 0..<min(tag.count, 80) { buf[i] = tag[i] }

        // Triangle count（little-endian UInt32）
        withUnsafeBytes(of: UInt32(totalTriangles).littleEndian) {
            for i in 0..<4 { buf[80+i] = $0[i] }
        }

        var off = 84
        for m in meshes {
            let pos     = m.positions
            let indices = m.indices
            let fc      = indices.count / 3

            for fi in 0..<fc {
                let base = fi * 3
                let vi0 = Int(indices[base])   * 3
                let vi1 = Int(indices[base+1]) * 3
                let vi2 = Int(indices[base+2]) * 3
                guard vi0+2 < pos.count, vi1+2 < pos.count, vi2+2 < pos.count else {
                    off += 50; continue
                }
                let x0=pos[vi0], y0=pos[vi0+1], z0=pos[vi0+2]
                let x1=pos[vi1], y1=pos[vi1+1], z1=pos[vi1+2]
                let x2=pos[vi2], y2=pos[vi2+1], z2=pos[vi2+2]

                // 计算面法线（叉积）
                let ux=x1-x0, uy=y1-y0, uz=z1-z0
                let vx=x2-x0, vy=y2-y0, vz=z2-z0
                var nx=uy*vz-uz*vy, ny=uz*vx-ux*vz, nz=ux*vy-uy*vx
                let ln=sqrtf(nx*nx+ny*ny+nz*nz)
                if ln > 1e-8 { nx/=ln; ny/=ln; nz/=ln }

                // 写 12 个 float32 + 2 字节属性 = 50 字节
                func wf(_ f: Float) {
                    withUnsafeBytes(of: f.bitPattern.littleEndian) {
                        buf[off] = $0[0]; buf[off+1] = $0[1]
                        buf[off+2] = $0[2]; buf[off+3] = $0[3]
                    }
                    off += 4
                }
                wf(nx); wf(ny); wf(nz)
                wf(x0); wf(y0); wf(z0)
                wf(x1); wf(y1); wf(z1)
                wf(x2); wf(y2); wf(z2)
                off += 2  // attribute byte count = 0
            }
        }

        try Data(buf).write(to: url)
        return true
    }

    /// 将 UIImage 编码为适合写入磁盘的图像文件（OBJ 纹理专用）
    /// 返回 (Data, 扩展名)，编码失败返回 nil
    private static func encodeTextureForFile(_ image: UIImage) -> (Data, String)? {
        let hasAlpha: Bool
        if let cg = image.cgImage {
            let ai = cg.alphaInfo
            hasAlpha = ai != .none && ai != .noneSkipFirst && ai != .noneSkipLast
        } else { hasAlpha = false }
        if !hasAlpha, let d = image.jpegData(compressionQuality: 0.92) { return (d, "jpg") }
        if let d = image.pngData() { return (d, "png") }
        if let d = image.jpegData(compressionQuality: 0.85) { return (d, "jpg") }
        return nil
    }

    /// 将 UIImage 编码为适合嵌入 GLTF 的字节：
    /// - 无 Alpha 或透明度不重要时优先使用 JPEG（更小、内存压力更低）
    /// - 有 Alpha 时使用 PNG
    /// 返回 (Data, mimeType)，编码失败返回 nil
    private static func encodeTexture(_ image: UIImage) -> (Data, String)? {
        let hasAlpha: Bool
        if let cgImg = image.cgImage {
            let ai = cgImg.alphaInfo
            hasAlpha = ai != .none && ai != .noneSkipFirst && ai != .noneSkipLast
        } else {
            hasAlpha = false
        }

        if !hasAlpha {
            // JPEG：对大尺寸贴图内存友好，文件更小
            if let data = image.jpegData(compressionQuality: 0.92) {
                return (data, "image/jpeg")
            }
        }
        // 含 Alpha 或 JPEG 编码失败时用 PNG
        if let data = image.pngData() {
            return (data, "image/png")
        }
        // 最后兜底：降质 JPEG
        if let data = image.jpegData(compressionQuality: 0.85) {
            return (data, "image/jpeg")
        }
        return nil
    }

    /// scene.write() 前保存所有材质的 diffuse.contents，写完后还原。
    /// SceneKit 在序列化时可能把 UIImage 替换为内部纹理句柄，
    /// 若不还原，缓存的 SCNScene 在下一次 collectMeshData 时会丢失纹理。
    @discardableResult
    private static func sceneWritePreserving(scene: SCNScene, to url: URL) -> Bool {
        // 保存
        var saved: [(SCNMaterial, Any?)] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            for mat in node.geometry?.materials ?? [] {
                saved.append((mat, mat.diffuse.contents))
            }
        }
        // 写入
        let ok = scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
        // 还原（无论成功失败）
        for (mat, original) in saved {
            mat.diffuse.contents = original
        }
        return ok
    }

    private static func convError(_ msg: String) -> NSError {
        NSError(domain: "FormatConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    static func getSupportedFormats() -> [String] { supportedFormats }
}
