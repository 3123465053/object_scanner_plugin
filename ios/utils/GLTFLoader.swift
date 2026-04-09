//
//  GLTFLoader.swift
//  object_scanner_plugin
//
//  自定义 GLB/GLTF 解析器，将 GLTF 2.0 文件加载为 SCNScene
//  支持：几何体、PBR 材质（纯色 + 纹理贴图）、顶点颜色
//

import Foundation
import SceneKit

struct GLTFLoader {

    /// 解析 GLB 或 GLTF 文件，返回 SCNScene
    static func loadScene(from url: URL) throws -> SCNScene {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        let jsonObj: [String: Any]
        let binData: Data

        if ext == "glb" {
            (jsonObj, binData) = try parseGLBContainer(data)
        } else {
            jsonObj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            binData = try loadBuffer(json: jsonObj, baseURL: url.deletingLastPathComponent())
        }

        return try buildScene(json: jsonObj, binData: binData, baseURL: url.deletingLastPathComponent())
    }

    // MARK: - GLB 容器解析

    private static func parseGLBContainer(_ data: Data) throws -> ([String: Any], Data) {
        guard data.count >= 12 else { throw err("GLB 文件太小") }
        let magic: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x46546C67 else { throw err("无效的 GLB magic") }

        let jsonChunkLen = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
        let jsonStart = 20
        guard jsonStart + jsonChunkLen <= data.count else { throw err("JSON chunk 越界") }
        let jsonData = data.subdata(in: jsonStart..<(jsonStart + jsonChunkLen))
        let jsonObj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] ?? [:]

        var binData = Data()
        let binChunkStart = jsonStart + jsonChunkLen
        if binChunkStart + 8 <= data.count {
            let binChunkLen = Int(data.withUnsafeBytes { $0.load(fromByteOffset: binChunkStart, as: UInt32.self) })
            let binStart = binChunkStart + 8
            if binStart + binChunkLen <= data.count {
                binData = data.subdata(in: binStart..<(binStart + binChunkLen))
            }
        }

        return (jsonObj, binData)
    }

    // MARK: - GLTF buffer 加载

    private static func loadBuffer(json: [String: Any], baseURL: URL) throws -> Data {
        guard let buffers = json["buffers"] as? [[String: Any]],
              let first = buffers.first,
              let uri = first["uri"] as? String else { return Data() }

        if uri.hasPrefix("data:"), let range = uri.range(of: ";base64,") {
            return Data(base64Encoded: String(uri[range.upperBound...])) ?? Data()
        }
        return try Data(contentsOf: baseURL.appendingPathComponent(uri))
    }

    // MARK: - 构建 SCNScene

    private static func buildScene(json: [String: Any], binData: Data, baseURL: URL) throws -> SCNScene {
        let scene = SCNScene()
        guard let meshes = json["meshes"] as? [[String: Any]],
              let accessorsArr = json["accessors"] as? [[String: Any]],
              let bufferViews = json["bufferViews"] as? [[String: Any]] else {
            throw err("GLTF 缺少 meshes/accessors/bufferViews")
        }

        // 先解析图像和纹理，再解析材质
        let images = loadImages(json: json, bufferViews: bufferViews, binData: binData, baseURL: baseURL)
        let materials = parseMaterials(json, images: images)

        for (meshIdx, mesh) in meshes.enumerated() {
            guard let primitives = mesh["primitives"] as? [[String: Any]] else { continue }

            for prim in primitives {
                guard let attrs = prim["attributes"] as? [String: Int] else { continue }
                guard let posIdx = attrs["POSITION"], posIdx < accessorsArr.count else { continue }

                let positions = try readVec3(accessorsArr[posIdx], bufferViews: bufferViews, binData: binData)
                guard !positions.isEmpty else { continue }

                var sources: [SCNGeometrySource] = [SCNGeometrySource(vertices: positions)]

                if let normIdx = attrs["NORMAL"], normIdx < accessorsArr.count,
                   let normals = try? readVec3(accessorsArr[normIdx], bufferViews: bufferViews, binData: binData),
                   !normals.isEmpty {
                    sources.append(SCNGeometrySource(normals: normals))
                }

                if let texIdx = attrs["TEXCOORD_0"], texIdx < accessorsArr.count {
                    let uvs = try readVec2(accessorsArr[texIdx], bufferViews: bufferViews, binData: binData)
                    if !uvs.isEmpty {
                        sources.append(SCNGeometrySource(textureCoordinates: uvs))
                    }
                }

                // 顶点颜色
                if let colIdx = attrs["COLOR_0"], colIdx < accessorsArr.count {
                    let colors = try readVertexColors(accessorsArr[colIdx], bufferViews: bufferViews, binData: binData)
                    if !colors.isEmpty {
                        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<Float>.size)
                        let colorSource = SCNGeometrySource(
                            data: colorData,
                            semantic: .color,
                            vectorCount: colors.count / 4,
                            usesFloatComponents: true,
                            componentsPerVector: 4,
                            bytesPerComponent: MemoryLayout<Float>.size,
                            dataOffset: 0,
                            dataStride: MemoryLayout<Float>.size * 4
                        )
                        sources.append(colorSource)
                    }
                }

                var elements: [SCNGeometryElement] = []
                if let indicesIdx = prim["indices"] as? Int, indicesIdx < accessorsArr.count {
                    let idxArray = try readScalar(accessorsArr[indicesIdx], bufferViews: bufferViews, binData: binData)
                    if !idxArray.isEmpty {
                        elements.append(SCNGeometryElement(indices: idxArray, primitiveType: .triangles))
                    }
                } else {
                    let idxArray = (0..<UInt32(positions.count)).map { $0 }
                    elements.append(SCNGeometryElement(indices: idxArray, primitiveType: .triangles))
                }

                let geometry = SCNGeometry(sources: sources, elements: elements)

                // 材质
                if let matIdx = prim["material"] as? Int, matIdx < materials.count {
                    geometry.materials = [materials[matIdx]]
                } else {
                    let mat = SCNMaterial()
                    mat.lightingModel = .physicallyBased
                    mat.diffuse.contents = UIColor(white: 0.8, alpha: 1.0)
                    mat.isDoubleSided = true
                    geometry.materials = [mat]
                }

                let node = SCNNode(geometry: geometry)
                node.name = (mesh["name"] as? String) ?? "mesh_\(meshIdx)"
                scene.rootNode.addChildNode(node)
            }
        }

        return scene
    }

    // MARK: - 图像加载（从 GLTF images 数组提取纹理图片）

    /// 从 GLTF JSON 的 images 数组中加载所有图像
    /// 支持: bufferView 引用（GLB 内嵌）、data URI（base64）、外部文件 URI
    private static func loadImages(json: [String: Any],
                                   bufferViews: [[String: Any]],
                                   binData: Data,
                                   baseURL: URL) -> [UIImage] {
        guard let imagesArr = json["images"] as? [[String: Any]] else { return [] }

        return imagesArr.compactMap { imgJson -> UIImage? in
            // 方式1: bufferView 引用（GLB 内嵌图像）
            if let bvIdx = imgJson["bufferView"] as? Int, bvIdx < bufferViews.count {
                let bv = bufferViews[bvIdx]
                let offset = bv["byteOffset"] as? Int ?? 0
                let length = bv["byteLength"] as? Int ?? 0
                guard offset + length <= binData.count else { return nil }
                let imageData = binData.subdata(in: offset..<(offset + length))
                return UIImage(data: imageData)
            }

            // 方式2: URI
            if let uri = imgJson["uri"] as? String {
                // data URI (base64)
                if uri.hasPrefix("data:"), let range = uri.range(of: ";base64,") {
                    if let data = Data(base64Encoded: String(uri[range.upperBound...])) {
                        return UIImage(data: data)
                    }
                    return nil
                }
                // 外部文件
                let fileURL = baseURL.appendingPathComponent(uri)
                if let data = try? Data(contentsOf: fileURL) {
                    return UIImage(data: data)
                }
            }

            return nil
        }
    }

    // MARK: - 材质解析（支持纹理贴图）

    private static func parseMaterials(_ json: [String: Any], images: [UIImage]) -> [SCNMaterial] {
        guard let mats = json["materials"] as? [[String: Any]] else { return [] }

        // 解析 textures 数组：texture → image 的映射
        let texturesArr = json["textures"] as? [[String: Any]] ?? []

        return mats.map { matJson in
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.isDoubleSided = true

            if let pbr = matJson["pbrMetallicRoughness"] as? [String: Any] {
                // 优先使用纹理贴图
                if let baseColorTex = pbr["baseColorTexture"] as? [String: Any],
                   let texIdx = baseColorTex["index"] as? Int,
                   texIdx < texturesArr.count,
                   let imgIdx = texturesArr[texIdx]["source"] as? Int,
                   imgIdx < images.count {
                    mat.diffuse.contents = images[imgIdx]
                    // 如果同时有 baseColorFactor，用作色调调制（乘法混合）
                    // SceneKit 不直接支持乘法混合，但设置 multiply 可以近似
                    if let factor = pbr["baseColorFactor"] as? [NSNumber], factor.count >= 4 {
                        mat.multiply.contents = UIColor(
                            red: CGFloat(factor[0].floatValue),
                            green: CGFloat(factor[1].floatValue),
                            blue: CGFloat(factor[2].floatValue),
                            alpha: CGFloat(factor[3].floatValue)
                        )
                    }
                } else if let baseColor = pbr["baseColorFactor"] as? [NSNumber], baseColor.count >= 4 {
                    // 纯色
                    mat.diffuse.contents = UIColor(
                        red: CGFloat(baseColor[0].floatValue),
                        green: CGFloat(baseColor[1].floatValue),
                        blue: CGFloat(baseColor[2].floatValue),
                        alpha: CGFloat(baseColor[3].floatValue)
                    )
                }

                // metallicRoughnessTexture
                if let mrTex = pbr["metallicRoughnessTexture"] as? [String: Any],
                   let texIdx = mrTex["index"] as? Int,
                   texIdx < texturesArr.count,
                   let imgIdx = texturesArr[texIdx]["source"] as? Int,
                   imgIdx < images.count {
                    // GLTF: G 通道 = roughness, B 通道 = metallic
                    // SceneKit 不能直接拆分通道，设置到 metalness 贴图
                    mat.metalness.contents = images[imgIdx]
                    mat.roughness.contents = images[imgIdx]
                } else {
                    if let metallic = pbr["metallicFactor"] as? NSNumber {
                        mat.metalness.contents = metallic.floatValue
                    }
                    if let roughness = pbr["roughnessFactor"] as? NSNumber {
                        mat.roughness.contents = roughness.floatValue
                    }
                }
            }

            // normalTexture
            if let normalTex = matJson["normalTexture"] as? [String: Any],
               let texIdx = normalTex["index"] as? Int,
               texIdx < texturesArr.count,
               let imgIdx = texturesArr[texIdx]["source"] as? Int,
               imgIdx < images.count {
                mat.normal.contents = images[imgIdx]
            }

            // emissive
            if let emissiveTex = matJson["emissiveTexture"] as? [String: Any],
               let texIdx = emissiveTex["index"] as? Int,
               texIdx < texturesArr.count,
               let imgIdx = texturesArr[texIdx]["source"] as? Int,
               imgIdx < images.count {
                mat.emission.contents = images[imgIdx]
            } else if let emissive = matJson["emissiveFactor"] as? [NSNumber], emissive.count >= 3 {
                mat.emission.contents = UIColor(
                    red: CGFloat(emissive[0].floatValue),
                    green: CGFloat(emissive[1].floatValue),
                    blue: CGFloat(emissive[2].floatValue),
                    alpha: 1.0
                )
            }

            // occlusionTexture
            if let occTex = matJson["occlusionTexture"] as? [String: Any],
               let texIdx = occTex["index"] as? Int,
               texIdx < texturesArr.count,
               let imgIdx = texturesArr[texIdx]["source"] as? Int,
               imgIdx < images.count {
                mat.ambientOcclusion.contents = images[imgIdx]
            }

            return mat
        }
    }

    // MARK: - Accessor 读取

    private static func readVec3(_ accessor: [String: Any], bufferViews: [[String: Any]], binData: Data) throws -> [SCNVector3] {
        guard let bvIdx = accessor["bufferView"] as? Int,
              let count = accessor["count"] as? Int,
              let compType = accessor["componentType"] as? Int,
              bvIdx < bufferViews.count else { return [] }

        let bv = bufferViews[bvIdx]
        let byteOffset = (bv["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let byteStride = bv["byteStride"] as? Int ?? 0

        var result: [SCNVector3] = []
        result.reserveCapacity(count)

        binData.withUnsafeBytes { ptr in
            for i in 0..<count {
                let stride = byteStride > 0 ? byteStride : compSize(compType) * 3
                let off = byteOffset + i * stride
                guard off + compSize(compType) * 3 <= binData.count else { continue }
                let x: Float, y: Float, z: Float
                switch compType {
                case 5126:
                    x = ptr.load(fromByteOffset: off, as: Float.self)
                    y = ptr.load(fromByteOffset: off + 4, as: Float.self)
                    z = ptr.load(fromByteOffset: off + 8, as: Float.self)
                default: x = 0; y = 0; z = 0
                }
                result.append(SCNVector3(x, y, z))
            }
        }
        return result
    }

    private static func readVec2(_ accessor: [String: Any], bufferViews: [[String: Any]], binData: Data) throws -> [CGPoint] {
        guard let bvIdx = accessor["bufferView"] as? Int,
              let count = accessor["count"] as? Int,
              let compType = accessor["componentType"] as? Int,
              bvIdx < bufferViews.count else { return [] }

        let bv = bufferViews[bvIdx]
        let byteOffset = (bv["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let byteStride = bv["byteStride"] as? Int ?? 0

        var result: [CGPoint] = []
        result.reserveCapacity(count)

        binData.withUnsafeBytes { ptr in
            for i in 0..<count {
                let stride = byteStride > 0 ? byteStride : compSize(compType) * 2
                let off = byteOffset + i * stride
                guard off + compSize(compType) * 2 <= binData.count else { continue }
                switch compType {
                case 5126:
                    let u = ptr.load(fromByteOffset: off, as: Float.self)
                    let v = ptr.load(fromByteOffset: off + 4, as: Float.self)
                    result.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
                default: break
                }
            }
        }
        return result
    }

    private static func readScalar(_ accessor: [String: Any], bufferViews: [[String: Any]], binData: Data) throws -> [UInt32] {
        guard let bvIdx = accessor["bufferView"] as? Int,
              let count = accessor["count"] as? Int,
              let compType = accessor["componentType"] as? Int,
              bvIdx < bufferViews.count else { return [] }

        let bv = bufferViews[bvIdx]
        let byteOffset = (bv["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)

        var result: [UInt32] = []
        result.reserveCapacity(count)

        binData.withUnsafeBytes { ptr in
            for i in 0..<count {
                let off = byteOffset + i * compSize(compType)
                guard off + compSize(compType) <= binData.count else { continue }
                switch compType {
                case 5121: result.append(UInt32(ptr.load(fromByteOffset: off, as: UInt8.self)))
                case 5123: result.append(UInt32(ptr.load(fromByteOffset: off, as: UInt16.self)))
                case 5125: result.append(ptr.load(fromByteOffset: off, as: UInt32.self))
                default: break
                }
            }
        }
        return result
    }

    /// 读取顶点颜色（VEC3 或 VEC4，归一化 UNSIGNED_BYTE/SHORT 或 FLOAT）
    private static func readVertexColors(_ accessor: [String: Any], bufferViews: [[String: Any]], binData: Data) throws -> [Float] {
        guard let bvIdx = accessor["bufferView"] as? Int,
              let count = accessor["count"] as? Int,
              let compType = accessor["componentType"] as? Int,
              bvIdx < bufferViews.count else { return [] }

        let type = accessor["type"] as? String ?? "VEC4"
        let components = type == "VEC3" ? 3 : 4

        let bv = bufferViews[bvIdx]
        let byteOffset = (bv["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let byteStride = bv["byteStride"] as? Int ?? 0

        var result: [Float] = []
        result.reserveCapacity(count * 4)

        binData.withUnsafeBytes { ptr in
            for i in 0..<count {
                let stride = byteStride > 0 ? byteStride : compSize(compType) * components
                let off = byteOffset + i * stride
                var r: Float = 1, g: Float = 1, b: Float = 1, a: Float = 1

                switch compType {
                case 5126: // FLOAT
                    if off + components * 4 <= binData.count {
                        r = ptr.load(fromByteOffset: off, as: Float.self)
                        g = ptr.load(fromByteOffset: off + 4, as: Float.self)
                        b = ptr.load(fromByteOffset: off + 8, as: Float.self)
                        if components == 4 { a = ptr.load(fromByteOffset: off + 12, as: Float.self) }
                    }
                case 5121: // UNSIGNED_BYTE (normalized)
                    if off + components <= binData.count {
                        r = Float(ptr.load(fromByteOffset: off, as: UInt8.self)) / 255.0
                        g = Float(ptr.load(fromByteOffset: off + 1, as: UInt8.self)) / 255.0
                        b = Float(ptr.load(fromByteOffset: off + 2, as: UInt8.self)) / 255.0
                        if components == 4 { a = Float(ptr.load(fromByteOffset: off + 3, as: UInt8.self)) / 255.0 }
                    }
                case 5123: // UNSIGNED_SHORT (normalized)
                    if off + components * 2 <= binData.count {
                        r = Float(ptr.load(fromByteOffset: off, as: UInt16.self)) / 65535.0
                        g = Float(ptr.load(fromByteOffset: off + 2, as: UInt16.self)) / 65535.0
                        b = Float(ptr.load(fromByteOffset: off + 4, as: UInt16.self)) / 65535.0
                        if components == 4 { a = Float(ptr.load(fromByteOffset: off + 6, as: UInt16.self)) / 65535.0 }
                    }
                default: break
                }
                result.append(contentsOf: [r, g, b, a])
            }
        }
        return result
    }

    private static func compSize(_ compType: Int) -> Int {
        switch compType {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return 4
        }
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "GLTFLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
