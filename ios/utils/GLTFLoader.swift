//
//  GLTFLoader.swift
//  object_scanner_plugin
//
//  自定义 GLB/GLTF 解析器，将 GLTF 2.0 文件加载为 SCNScene
//  支持：几何体、PBR 材质（纯色 + 纹理贴图）、顶点颜色
//

import Foundation
import SceneKit
import ImageIO

struct GLTFLoader {

    /// GLB 的 bufferView 偏移是相对 BIN chunk 的。保留原始 mmap Data，并单独
    /// 记录 chunk 起点，既避免整块复制，也保证所有读取都使用从 0 开始的相对偏移。
    private struct BinaryBuffer {
        let data: Data
        let baseOffset: Int
        let length: Int

        func absoluteOffset(relativeOffset: Int, byteLength: Int) -> Int? {
            guard relativeOffset >= 0,
                  byteLength >= 0,
                  relativeOffset <= length,
                  byteLength <= length - relativeOffset else { return nil }
            return baseOffset + relativeOffset
        }
    }

    /// 解析 GLB 或 GLTF 文件，返回 SCNScene
    static func loadScene(from url: URL) throws -> SCNScene {
        // .mappedIfSafe：大文件使用 mmap，避免将整个文件拷贝到堆内存
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let ext = url.pathExtension.lowercased()

        let jsonObj: [String: Any]
        let binaryBuffer: BinaryBuffer

        if ext == "glb" {
            (jsonObj, binaryBuffer) = try parseGLBContainer(data)
        } else {
            jsonObj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            binaryBuffer = try loadBuffer(json: jsonObj, baseURL: url.deletingLastPathComponent())
        }

        return try buildScene(
            json: jsonObj,
            binaryBuffer: binaryBuffer,
            baseURL: url.deletingLastPathComponent()
        )
    }

    // MARK: - GLB 容器解析

    private static func parseGLBContainer(_ data: Data) throws -> ([String: Any], BinaryBuffer) {
        guard data.count >= 12 else { throw err("GLB 文件太小") }
        let magic: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x46546C67 else { throw err("无效的 GLB magic") }

        let jsonChunkLen = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
        let jsonStart = 20
        guard jsonStart + jsonChunkLen <= data.count else { throw err("JSON chunk 越界") }
        // JSON chunk 通常很小，复制后得到从 0 开始的 Data，交给解析器更稳妥。
        let jsonData = data.subdata(in: jsonStart..<(jsonStart + jsonChunkLen))
        let jsonObj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] ?? [:]

        var binaryBuffer = BinaryBuffer(data: data, baseOffset: 0, length: 0)
        let binChunkStart = jsonStart + jsonChunkLen
        if binChunkStart + 8 <= data.count {
            let binChunkLen = Int(data.withUnsafeBytes { $0.load(fromByteOffset: binChunkStart, as: UInt32.self) })
            let binStart = binChunkStart + 8
            if binStart + binChunkLen <= data.count {
                binaryBuffer = BinaryBuffer(
                    data: data,
                    baseOffset: binStart,
                    length: binChunkLen
                )
            }
        }

        return (jsonObj, binaryBuffer)
    }

    // MARK: - GLTF buffer 加载

    private static func loadBuffer(json: [String: Any], baseURL: URL) throws -> BinaryBuffer {
        guard let buffers = json["buffers"] as? [[String: Any]],
              let first = buffers.first,
              let uri = first["uri"] as? String else {
            return BinaryBuffer(data: Data(), baseOffset: 0, length: 0)
        }

        if uri.hasPrefix("data:"), let range = uri.range(of: ";base64,") {
            let data = Data(base64Encoded: String(uri[range.upperBound...])) ?? Data()
            return BinaryBuffer(data: data, baseOffset: 0, length: data.count)
        }
        let data = try Data(
            contentsOf: baseURL.appendingPathComponent(uri),
            options: .mappedIfSafe
        )
        return BinaryBuffer(data: data, baseOffset: 0, length: data.count)
    }

    // MARK: - 构建 SCNScene

    private static func buildScene(json: [String: Any],
                                   binaryBuffer: BinaryBuffer,
                                   baseURL: URL) throws -> SCNScene {
        let scene = SCNScene()
        guard let meshes = json["meshes"] as? [[String: Any]],
              let accessorsArr = json["accessors"] as? [[String: Any]],
              let bufferViews = json["bufferViews"] as? [[String: Any]] else {
            throw err("GLTF 缺少 meshes/accessors/bufferViews")
        }

        // 先解析图像和纹理，再解析材质
        let images = loadImages(
            json: json,
            bufferViews: bufferViews,
            binaryBuffer: binaryBuffer,
            baseURL: baseURL
        )
        let materials = parseMaterials(json, images: images)

        for (meshIdx, mesh) in meshes.enumerated() {
            guard let primitives = mesh["primitives"] as? [[String: Any]] else { continue }

            for prim in primitives {
                guard let attrs = prim["attributes"] as? [String: Int] else { continue }
                guard let posIdx = attrs["POSITION"], posIdx < accessorsArr.count else { continue }

                let positions = try readVec3(
                    accessorsArr[posIdx],
                    bufferViews: bufferViews,
                    binaryBuffer: binaryBuffer
                )
                guard !positions.isEmpty else { continue }

                var sources: [SCNGeometrySource] = [SCNGeometrySource(vertices: positions)]

                if let normIdx = attrs["NORMAL"], normIdx < accessorsArr.count,
                   let normals = try? readVec3(
                       accessorsArr[normIdx],
                       bufferViews: bufferViews,
                       binaryBuffer: binaryBuffer
                   ),
                   !normals.isEmpty {
                    sources.append(SCNGeometrySource(normals: normals))
                }

                if let texIdx = attrs["TEXCOORD_0"], texIdx < accessorsArr.count {
                    let uvs = try readVec2(
                        accessorsArr[texIdx],
                        bufferViews: bufferViews,
                        binaryBuffer: binaryBuffer
                    )
                    if !uvs.isEmpty {
                        sources.append(SCNGeometrySource(textureCoordinates: uvs))
                    }
                }

                // 顶点颜色
                if let colIdx = attrs["COLOR_0"], colIdx < accessorsArr.count {
                    let colors = try readVertexColors(
                        accessorsArr[colIdx],
                        bufferViews: bufferViews,
                        binaryBuffer: binaryBuffer
                    )
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
                    let idxArray = try readScalar(
                        accessorsArr[indicesIdx],
                        bufferViews: bufferViews,
                        binaryBuffer: binaryBuffer
                    )
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
    /// 返回 [UIImage?]（保留索引，nil 表示该图像加载失败），避免 compactMap 导致索引错位
    /// 支持: bufferView 引用（GLB 内嵌）、data URI（base64）、外部文件 URI
    private static func loadImages(json: [String: Any],
                                   bufferViews: [[String: Any]],
                                   binaryBuffer: BinaryBuffer,
                                   baseURL: URL) -> [UIImage?] {
        guard let imagesArr = json["images"] as? [[String: Any]] else { return [] }

        return imagesArr.map { imgJson -> UIImage? in
            // 方式1: bufferView 引用（GLB 内嵌图像）
            if let bvIdx = imgJson["bufferView"] as? Int, bvIdx < bufferViews.count {
                let bv = bufferViews[bvIdx]
                let offset = bv["byteOffset"] as? Int ?? 0
                let length = bv["byteLength"] as? Int ?? 0
                guard let absoluteOffset = binaryBuffer.absoluteOffset(
                    relativeOffset: offset,
                    byteLength: length
                ) else { return nil }
                // 只复制当前压缩图片，而不是复制整个 BIN。原始 Data 的索引从 0
                // 开始，因此这里不会再触发 mmap 切片的 subdata 越界。
                let imageData = binaryBuffer.data.subdata(
                    in: absoluteOffset..<(absoluteOffset + length)
                )
                return decodeImage(from: imageData)
            }

            // 方式2: URI
            if let uri = imgJson["uri"] as? String {
                // data URI (base64)
                if uri.hasPrefix("data:"), let range = uri.range(of: ";base64,") {
                    if let data = Data(base64Encoded: String(uri[range.upperBound...])) {
                        return decodeImage(from: data)
                    }
                    return nil
                }
                // 外部文件
                let fileURL = baseURL.appendingPathComponent(uri)
                if let data = try? Data(contentsOf: fileURL) {
                    return decodeImage(from: data)
                }
            }

            return nil
        }
    }

    /// 健壮的图像解码，针对大尺寸纹理进行内存优化：
    /// - 超过 maxDimension 的图像使用 CGImageSourceCreateThumbnailAtIndex，
    ///   该 API 直接解码到目标尺寸，**不会**先解码全分辨率图像到内存
    ///   （4096×4096 WebP → 峰值仅 ~16MB 而非 67MB）
    /// - 对 VP8X Extended WebP（带 Alpha）比 UIImage(data:) 更可靠
    private static func decodeImage(from data: Data, maxDimension: Int = 2048) -> UIImage? {
        let baseOpts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldAllowFloat:       false
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, baseOpts as CFDictionary),
              CGImageSourceGetCount(src) > 0 else {
            // ImageIO 不支持该格式时回退 UIImage
            return UIImage(data: data)
        }

        // 读取原始尺寸，决定是否需要降采样
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let origW = props?[kCGImagePropertyPixelWidth]  as? Int ?? 0
        let origH = props?[kCGImagePropertyPixelHeight] as? Int ?? 0

        if max(origW, origH) > maxDimension {
            // Thumbnail API：内部直接解码到目标尺寸，内存峰值 = 目标尺寸，不经过全分辨率
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize:          maxDimension,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform:   true,
                kCGImageSourceShouldCacheImmediately:         false
            ]
            if let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
                return UIImage(cgImage: cgImg)
            }
        }

        // 正常尺寸：直接解码
        if let cgImg = CGImageSourceCreateImageAtIndex(src, 0, baseOpts as CFDictionary) {
            return UIImage(cgImage: cgImg)
        }
        return UIImage(data: data) // 最终兜底
    }

    // MARK: - 材质解析（支持纹理贴图）

    private static func parseMaterials(_ json: [String: Any], images: [UIImage?]) -> [SCNMaterial] {
        guard let mats = json["materials"] as? [[String: Any]] else { return [] }

        // 解析 textures 数组：texture → image 的映射
        let texturesArr = json["textures"] as? [[String: Any]] ?? []
        let samplersArr = json["samplers"] as? [[String: Any]] ?? []

        return mats.map { matJson in
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.isDoubleSided = true

            if let pbr = matJson["pbrMetallicRoughness"] as? [String: Any] {
                // 优先使用纹理贴图
                if let baseColorTex = pbr["baseColorTexture"] as? [String: Any],
                   let texIdx = baseColorTex["index"] as? Int,
                   texIdx < texturesArr.count,
                   let imgIdx = textureImageIndex(texturesArr[texIdx]),
                   imgIdx < images.count,
                   let image = images[imgIdx] {           // 解包 UIImage?，nil 则跳过
                    mat.diffuse.contents = image
                    configureSampling(
                        for: mat.diffuse,
                        texture: texturesArr[texIdx],
                        samplers: samplersArr
                    )
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
                   let imgIdx = textureImageIndex(texturesArr[texIdx]),
                   imgIdx < images.count,
                   let image = images[imgIdx] {           // 解包 UIImage?
                    // GLTF: G 通道 = roughness, B 通道 = metallic
                    // SceneKit 不能直接拆分通道，设置到 metalness 贴图
                    mat.metalness.contents = image
                    mat.roughness.contents = image
                    configureSampling(
                        for: mat.metalness,
                        texture: texturesArr[texIdx],
                        samplers: samplersArr
                    )
                    configureSampling(
                        for: mat.roughness,
                        texture: texturesArr[texIdx],
                        samplers: samplersArr
                    )
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
               let imgIdx = textureImageIndex(texturesArr[texIdx]),
               imgIdx < images.count,
               let image = images[imgIdx] {
                mat.normal.contents = image
                configureSampling(
                    for: mat.normal,
                    texture: texturesArr[texIdx],
                    samplers: samplersArr
                )
            }

            // emissive
            if let emissiveTex = matJson["emissiveTexture"] as? [String: Any],
               let texIdx = emissiveTex["index"] as? Int,
               texIdx < texturesArr.count,
               let imgIdx = textureImageIndex(texturesArr[texIdx]),
               imgIdx < images.count,
               let image = images[imgIdx] {
                mat.emission.contents = image
                configureSampling(
                    for: mat.emission,
                    texture: texturesArr[texIdx],
                    samplers: samplersArr
                )
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
               let imgIdx = textureImageIndex(texturesArr[texIdx]),
               imgIdx < images.count,
               let image = images[imgIdx] {
                mat.ambientOcclusion.contents = image
                configureSampling(
                    for: mat.ambientOcclusion,
                    texture: texturesArr[texIdx],
                    samplers: samplersArr
                )
            }

            return mat
        }
    }

    /// EXT_texture_webp 把图像索引放在 extension.source 中；该字段也可能是
    /// 唯一来源。其他压缩扩展需要独立解码器，不能在这里按普通图片处理。
    private static func textureImageIndex(_ texture: [String: Any]) -> Int? {
        if let extensions = texture["extensions"] as? [String: Any],
           let webP = extensions["EXT_texture_webp"] as? [String: Any],
           let source = webP["source"] as? Int {
            return source
        }
        return texture["source"] as? Int
    }

    private static func configureSampling(for property: SCNMaterialProperty,
                                          texture: [String: Any],
                                          samplers: [[String: Any]]) {
        let sampler: [String: Any]
        if let index = texture["sampler"] as? Int, index >= 0, index < samplers.count {
            sampler = samplers[index]
        } else {
            sampler = [:]
        }

        func wrapMode(_ value: Int) -> SCNWrapMode {
            switch value {
            case 33071: return .clamp
            case 33648: return .mirror
            default: return .repeat
            }
        }

        property.wrapS = wrapMode(sampler["wrapS"] as? Int ?? 10497)
        property.wrapT = wrapMode(sampler["wrapT"] as? Int ?? 10497)
        property.magnificationFilter = (sampler["magFilter"] as? Int ?? 9729) == 9728
            ? .nearest
            : .linear

        switch sampler["minFilter"] as? Int ?? 9987 {
        case 9728:
            property.minificationFilter = .nearest
            property.mipFilter = .none
        case 9729:
            property.minificationFilter = .linear
            property.mipFilter = .none
        case 9984:
            property.minificationFilter = .nearest
            property.mipFilter = .nearest
        case 9985:
            property.minificationFilter = .linear
            property.mipFilter = .nearest
        case 9986:
            property.minificationFilter = .nearest
            property.mipFilter = .linear
        default:
            property.minificationFilter = .linear
            property.mipFilter = .linear
        }
    }

    // MARK: - Accessor 读取

    private static func readVec3(_ accessor: [String: Any],
                                 bufferViews: [[String: Any]],
                                 binaryBuffer: BinaryBuffer) throws -> [SCNVector3] {
        guard let bvIdx = accessor["bufferView"] as? Int,
              let count = accessor["count"] as? Int,
              let compType = accessor["componentType"] as? Int,
              bvIdx < bufferViews.count else { return [] }

        let bv = bufferViews[bvIdx]
        let byteOffset = (bv["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let byteStride = bv["byteStride"] as? Int ?? 0

        var result: [SCNVector3] = []
        result.reserveCapacity(count)

        binaryBuffer.data.withUnsafeBytes { ptr in
            for i in 0..<count {
                let stride = byteStride > 0 ? byteStride : compSize(compType) * 3
                guard let off = binaryBuffer.absoluteOffset(
                    relativeOffset: byteOffset + i * stride,
                    byteLength: compSize(compType) * 3
                ) else { continue }
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

    private static func readVec2(_ accessor: [String: Any],
                                 bufferViews: [[String: Any]],
                                 binaryBuffer: BinaryBuffer) throws -> [CGPoint] {
        guard let bvIdx = accessor["bufferView"] as? Int,
              let count = accessor["count"] as? Int,
              let compType = accessor["componentType"] as? Int,
              bvIdx < bufferViews.count else { return [] }

        let bv = bufferViews[bvIdx]
        let byteOffset = (bv["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let byteStride = bv["byteStride"] as? Int ?? 0

        var result: [CGPoint] = []
        result.reserveCapacity(count)

        binaryBuffer.data.withUnsafeBytes { ptr in
            for i in 0..<count {
                let stride = byteStride > 0 ? byteStride : compSize(compType) * 2
                guard let off = binaryBuffer.absoluteOffset(
                    relativeOffset: byteOffset + i * stride,
                    byteLength: compSize(compType) * 2
                ) else { continue }
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

    private static func readScalar(_ accessor: [String: Any],
                                   bufferViews: [[String: Any]],
                                   binaryBuffer: BinaryBuffer) throws -> [UInt32] {
        guard let bvIdx = accessor["bufferView"] as? Int,
              let count = accessor["count"] as? Int,
              let compType = accessor["componentType"] as? Int,
              bvIdx < bufferViews.count else { return [] }

        let bv = bufferViews[bvIdx]
        let byteOffset = (bv["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)

        var result: [UInt32] = []
        result.reserveCapacity(count)

        binaryBuffer.data.withUnsafeBytes { ptr in
            for i in 0..<count {
                guard let off = binaryBuffer.absoluteOffset(
                    relativeOffset: byteOffset + i * compSize(compType),
                    byteLength: compSize(compType)
                ) else { continue }
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
    private static func readVertexColors(_ accessor: [String: Any],
                                         bufferViews: [[String: Any]],
                                         binaryBuffer: BinaryBuffer) throws -> [Float] {
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

        binaryBuffer.data.withUnsafeBytes { ptr in
            for i in 0..<count {
                let stride = byteStride > 0 ? byteStride : compSize(compType) * components
                var r: Float = 1, g: Float = 1, b: Float = 1, a: Float = 1

                switch compType {
                case 5126: // FLOAT
                    if let off = binaryBuffer.absoluteOffset(
                        relativeOffset: byteOffset + i * stride,
                        byteLength: components * 4
                    ) {
                        r = ptr.load(fromByteOffset: off, as: Float.self)
                        g = ptr.load(fromByteOffset: off + 4, as: Float.self)
                        b = ptr.load(fromByteOffset: off + 8, as: Float.self)
                        if components == 4 { a = ptr.load(fromByteOffset: off + 12, as: Float.self) }
                    }
                case 5121: // UNSIGNED_BYTE (normalized)
                    if let off = binaryBuffer.absoluteOffset(
                        relativeOffset: byteOffset + i * stride,
                        byteLength: components
                    ) {
                        r = Float(ptr.load(fromByteOffset: off, as: UInt8.self)) / 255.0
                        g = Float(ptr.load(fromByteOffset: off + 1, as: UInt8.self)) / 255.0
                        b = Float(ptr.load(fromByteOffset: off + 2, as: UInt8.self)) / 255.0
                        if components == 4 { a = Float(ptr.load(fromByteOffset: off + 3, as: UInt8.self)) / 255.0 }
                    }
                case 5123: // UNSIGNED_SHORT (normalized)
                    if let off = binaryBuffer.absoluteOffset(
                        relativeOffset: byteOffset + i * stride,
                        byteLength: components * 2
                    ) {
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
