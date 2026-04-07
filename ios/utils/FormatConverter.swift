//
//  FormatConverter.swift
//  object_scanner_plugin
//
//  格式转换工具 - 将 3D 文件转换为其他格式
//
//  支持的输出格式:
//    ModelIO:   obj, stl, ply, usd, usda, usdc, abc
//    SceneKit:  usdz, dae, scn
//    自定义:     glb, gltf
//
//  支持的输入格式 (ModelIO 可读取):
//    usdz, usd, usda, usdc, obj, stl, ply, abc, fbx
//
//  不支持的格式 (无 iOS 原生 API):
//    stp/step, igs/iges, x_t, 3dxml, 3mf, jt, ifc, pdf3d, solidworks
//    fbx 输出 (Autodesk 未提供 iOS 导出 SDK)

import Foundation
import ModelIO
import SceneKit
import Flutter

struct FormatConverter {

    // 支持的输出格式
    static let supportedFormats = [
        "obj", "stl", "ply", "usd", "usda", "usdc",  // ModelIO
        "usdz", "dae", "scn",                           // SceneKit
        "abc",                                           // ModelIO (Alembic)
        "glb", "gltf"                                    // 自定义 GLTF 导出器
    ]

    private static let sceneKitFormats: Set<String> = ["usdz", "dae", "scn"]
    private static let gltfFormats: Set<String> = ["glb", "gltf"]

    // MARK: - 主入口

    /// 转换3D模型格式
    /// - Parameters:
    ///   - inputPath: 输入文件路径，支持 usdz/usd/obj/stl/ply/abc/fbx 等
    ///   - outputFormat: 目标格式（见 supportedFormats）
    ///   - result: Flutter 回调，返回 {"path": String?, "msg": String}
    static func convert(inputPath: String, outputFormat: String, result: @escaping FlutterResult) {
        let format = outputFormat.lowercased()

        guard supportedFormats.contains(format) else {
            result([
                "path": nil,
                "msg": "不支持的输出格式: \(outputFormat)。支持: \(supportedFormats.joined(separator: ", "))"
            ] as [String: Any?])
            return
        }

        guard FileManager.default.fileExists(atPath: inputPath) else {
            result([
                "path": nil,
                "msg": "输入文件不存在: \(inputPath)"
            ] as [String: Any?])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let inputURL = URL(fileURLWithPath: inputPath)
                let fileName = inputURL.deletingPathExtension().lastPathComponent
                let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let outputURL = documentsDir.appendingPathComponent("\(fileName)_converted.\(format)")

                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }

                let success: Bool
                if gltfFormats.contains(format) {
                    success = try convertToGLTF(inputURL: inputURL, outputURL: outputURL, isBinary: format == "glb")
                } else if sceneKitFormats.contains(format) {
                    success = try convertWithSceneKit(inputURL: inputURL, outputURL: outputURL)
                } else {
                    success = try convertWithModelIO(inputURL: inputURL, outputURL: outputURL, format: format)
                }

                DispatchQueue.main.async {
                    if success {
                        result(["path": outputURL.path, "msg": "success"])
                    } else {
                        result(["path": nil, "msg": "格式转换失败，请检查输入文件是否有效"] as [String: Any?])
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    result(["path": nil, "msg": "格式转换异常: \(error.localizedDescription)"] as [String: Any?])
                }
            }
        }
    }

    // MARK: - ModelIO 转换 (obj / stl / ply / usd / usda / usdc / abc)

    private static func convertWithModelIO(inputURL: URL, outputURL: URL, format: String) throws -> Bool {
        let asset = MDLAsset(url: inputURL)
        asset.loadTextures()
        guard MDLAsset.canExportFileExtension(format) else {
            return false
        }
        try (asset as MDLAsset).export(to: outputURL)
        return true
    }

    // MARK: - SceneKit 转换 (usdz / dae / scn)

    private static func convertWithSceneKit(inputURL: URL, outputURL: URL) throws -> Bool {
        let mdlAsset = MDLAsset(url: inputURL)
        mdlAsset.loadTextures()
        let scene = SCNScene(mdlAsset: mdlAsset)
        return scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
    }

    // MARK: - 自定义 GLTF / GLB 导出器

    /// 将任意 MDLAsset 支持的输入文件导出为 GLB（二进制 GLTF 2.0）或 GLTF（JSON + base64 内嵌）
    private static func convertToGLTF(inputURL: URL, outputURL: URL, isBinary: Bool) throws -> Bool {
        let mdlAsset = MDLAsset(url: inputURL)
        mdlAsset.loadTextures()
        let scene = SCNScene(mdlAsset: mdlAsset)
        return try buildGLTF(from: scene.rootNode, outputURL: outputURL, isBinary: isBinary)
    }

    private static func buildGLTF(from rootNode: SCNNode, outputURL: URL, isBinary: Bool) throws -> Bool {
        // ── 1. 遍历场景节点，提取几何数据 ──────────────────────────────
        var positions:  [Float]  = []
        var normals:    [Float]  = []
        var texCoords:  [Float]  = []
        var indices:    [UInt32] = []

        func processNode(_ node: SCNNode) {
            if let geometry = node.geometry {
                let baseVertex = UInt32(positions.count / 3)

                if let src = geometry.sources(for: .vertex).first {
                    extractFloats(from: src, components: 3, into: &positions)
                }
                if let src = geometry.sources(for: .normal).first {
                    extractFloats(from: src, components: 3, into: &normals)
                }
                if let src = geometry.sources(for: .texcoord).first {
                    extractFloats(from: src, components: 2, into: &texCoords)
                }
                for element in geometry.elements {
                    extractIndices(from: element, baseVertex: baseVertex, into: &indices)
                }
            }
            node.childNodes.forEach { processNode($0) }
        }
        processNode(rootNode)

        guard !positions.isEmpty && !indices.isEmpty else { return false }

        // ── 2. 构建二进制缓冲区 ────────────────────────────────────────
        var binData = Data()

        func appendFloatBuffer(_ arr: [Float]) -> (offset: Int, length: Int) {
            let off = binData.count
            arr.withUnsafeBytes { binData.append(contentsOf: $0) }
            return (off, binData.count - off)
        }
        func appendUInt32Buffer(_ arr: [UInt32]) -> (offset: Int, length: Int) {
            let off = binData.count
            arr.withUnsafeBytes { binData.append(contentsOf: $0) }
            return (off, binData.count - off)
        }

        let (posOff, posLen) = appendFloatBuffer(positions)
        let normResult  = normals.isEmpty   ? nil : appendFloatBuffer(normals)
        let texResult   = texCoords.isEmpty ? nil : appendFloatBuffer(texCoords)
        let (idxOff, idxLen) = appendUInt32Buffer(indices)

        // ── 3. 构建 GLTF JSON ──────────────────────────────────────────
        var bufferViews: [[String: Any]] = []
        var accessors:   [[String: Any]] = []

        /// 添加 BufferView，target: 34962 = ARRAY_BUFFER, 34963 = ELEMENT_ARRAY_BUFFER
        func addBV(offset: Int, length: Int, target: Int) -> Int {
            bufferViews.append(["buffer": 0, "byteOffset": offset, "byteLength": length, "target": target])
            return bufferViews.count - 1
        }
        func addAC(bv: Int, componentType: Int, count: Int, type: String, extra: [String: Any] = [:]) -> Int {
            var ac: [String: Any] = ["bufferView": bv, "componentType": componentType, "count": count, "type": type]
            extra.forEach { ac[$0.key] = $0.value }
            accessors.append(ac)
            return accessors.count - 1
        }

        // 计算位置包围盒（GLTF 规范要求 position accessor 必须有 min/max）
        let (minPos, maxPos) = computeBounds(positions)

        let bvPos = addBV(offset: posOff, length: posLen, target: 34962)
        let acPos = addAC(bv: bvPos, componentType: 5126 /* FLOAT */, count: positions.count / 3, type: "VEC3", extra: [
            "min": [minPos.x, minPos.y, minPos.z],
            "max": [maxPos.x, maxPos.y, maxPos.z]
        ])
        var attrs: [String: Int] = ["POSITION": acPos]

        if let (nOff, nLen) = normResult {
            let bv = addBV(offset: nOff, length: nLen, target: 34962)
            attrs["NORMAL"] = addAC(bv: bv, componentType: 5126, count: normals.count / 3, type: "VEC3")
        }
        if let (tOff, tLen) = texResult {
            let bv = addBV(offset: tOff, length: tLen, target: 34962)
            attrs["TEXCOORD_0"] = addAC(bv: bv, componentType: 5126, count: texCoords.count / 2, type: "VEC2")
        }

        let bvIdx = addBV(offset: idxOff, length: idxLen, target: 34963)
        let acIdx = addAC(bv: bvIdx, componentType: 5125 /* UNSIGNED_INT */, count: indices.count, type: "SCALAR")

        var bufferEntry: [String: Any] = ["byteLength": binData.count]
        if !isBinary {
            // GLTF 文本格式：将二进制数据内嵌为 base64 data URI
            bufferEntry["uri"] = "data:application/octet-stream;base64," + binData.base64EncodedString()
        }

        let gltfJSON: [String: Any] = [
            "asset":       ["version": "2.0", "generator": "ObjectScannerPlugin-iOS"],
            "scene":       0,
            "scenes":      [["name": "Scene", "nodes": [0]]],
            "nodes":       [["name": "Mesh", "mesh": 0]],
            "meshes":      [["name": "Mesh", "primitives": [
                ["attributes": attrs, "indices": acIdx, "mode": 4 /* TRIANGLES */]
            ]]],
            "accessors":   accessors,
            "bufferViews": bufferViews,
            "buffers":     [bufferEntry]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: gltfJSON, options: [.sortedKeys])

        // ── 4. 写入文件 ────────────────────────────────────────────────
        if isBinary {
            try writeGLB(jsonData: jsonData, binData: binData, to: outputURL)
        } else {
            try jsonData.write(to: outputURL)
        }
        return true
    }

    /// 按照 GLTF 2.0 规范写出 GLB 容器格式
    private static func writeGLB(jsonData: Data, binData: Data, to outputURL: URL) throws {
        // GLB chunk 数据必须 4 字节对齐
        // JSON chunk 用空格 (0x20) 填充，BIN chunk 用 0x00 填充
        var paddedJSON = jsonData
        while paddedJSON.count % 4 != 0 { paddedJSON.append(0x20) }
        var paddedBin = binData
        while paddedBin.count % 4 != 0 { paddedBin.append(0x00) }

        let totalLen = 12 + 8 + paddedJSON.count + 8 + paddedBin.count
        var glb = Data(capacity: totalLen)

        func u32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { glb.append(contentsOf: $0) }
        }

        // File header
        u32(0x46546C67)          // magic: "glTF"
        u32(2)                   // version: 2
        u32(UInt32(totalLen))    // total byte length

        // Chunk 0: JSON
        u32(UInt32(paddedJSON.count))
        u32(0x4E4F534A)          // chunkType: "JSON"
        glb.append(paddedJSON)

        // Chunk 1: BIN
        u32(UInt32(paddedBin.count))
        u32(0x004E4942)          // chunkType: "BIN\0"
        glb.append(paddedBin)

        try glb.write(to: outputURL)
    }

    // MARK: - 几何数据提取工具

    /// 从 SCNGeometrySource 提取浮点分量（兼容 float32 / float64 / 交错 stride）
    private static func extractFloats(from source: SCNGeometrySource, components: Int, into array: inout [Float]) {
        let data    = source.data
        let count   = source.vectorCount
        let stride  = source.dataStride
        let offset  = source.dataOffset
        let bpc     = source.bytesPerComponent
        let useFloat = source.usesFloatComponents

        data.withUnsafeBytes { ptr in
            for i in 0..<count {
                for c in 0..<components {
                    let byteOffset = offset + i * stride + c * bpc
                    guard byteOffset + bpc <= data.count else { continue }
                    guard useFloat else { continue }
                    switch bpc {
                    case 4:
                        array.append(ptr.load(fromByteOffset: byteOffset, as: Float.self))
                    case 8:
                        array.append(Float(ptr.load(fromByteOffset: byteOffset, as: Double.self)))
                    default:
                        break
                    }
                }
            }
        }
    }

    /// 从 SCNGeometryElement 提取三角形索引，支持 triangles 和 triangleStrip
    private static func extractIndices(from element: SCNGeometryElement, baseVertex: UInt32, into array: inout [UInt32]) {
        let data  = element.data
        let bpi   = element.bytesPerIndex
        let count = element.primitiveCount

        func idx(_ i: Int) -> UInt32 {
            data.withUnsafeBytes { ptr -> UInt32 in
                let off = i * bpi
                switch bpi {
                case 1: return UInt32(ptr.load(fromByteOffset: off, as: UInt8.self))
                case 2: return UInt32(ptr.load(fromByteOffset: off, as: UInt16.self))
                case 4: return ptr.load(fromByteOffset: off, as: UInt32.self)
                default: return 0
                }
            }
        }

        switch element.primitiveType {
        case .triangles:
            // 每个 primitive = 3 个索引
            for i in 0..<count * 3 {
                array.append(baseVertex + idx(i))
            }
        case .triangleStrip:
            // Triangle strip：奇偶行交替翻转以保持一致绕向
            for i in 0..<count {
                let a = baseVertex + idx(i)
                let b = baseVertex + idx(i + 1)
                let c = baseVertex + idx(i + 2)
                if i % 2 == 0 {
                    array.append(contentsOf: [a, b, c])
                } else {
                    array.append(contentsOf: [b, a, c])
                }
            }
        default:
            break
        }
    }

    /// 计算顶点位置包围盒，供 GLTF accessor min/max 使用
    private static func computeBounds(_ positions: [Float]) -> (min: (x: Float, y: Float, z: Float),
                                                                 max: (x: Float, y: Float, z: Float)) {
        var minX = Float.greatestFiniteMagnitude,  minY = minX, minZ = minX
        var maxX = -Float.greatestFiniteMagnitude, maxY = maxX, maxZ = maxX
        let count = positions.count / 3
        for i in 0..<count {
            let x = positions[i * 3], y = positions[i * 3 + 1], z = positions[i * 3 + 2]
            minX = Swift.min(minX, x); minY = Swift.min(minY, y); minZ = Swift.min(minZ, z)
            maxX = Swift.max(maxX, x); maxY = Swift.max(maxY, y); maxZ = Swift.max(maxZ, z)
        }
        return (min: (minX, minY, minZ), max: (maxX, maxY, maxZ))
    }

    // MARK: - 公开工具

    static func getSupportedFormats() -> [String] {
        return supportedFormats
    }
}
