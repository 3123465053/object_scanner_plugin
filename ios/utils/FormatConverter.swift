//
//  FormatConverter.swift
//  object_scanner_plugin
//
//  格式转换工具

import Foundation
import ModelIO
import SceneKit
import Flutter
import ObjectiveC

struct FormatConverter {

    static let supportedFormats = [
        "obj", "stl", "ply", "usd", "usda", "usdc",
        "usdz", "dae", "scn",
        "abc",
        "glb", "gltf"
    ]

    // MARK: - 主入口

    static func convert(inputPath: String, outputFormat: String, result: @escaping FlutterResult) {
        let format = outputFormat.lowercased()

        guard supportedFormats.contains(format) else {
            result(["path": nil, "msg": "不支持的输出格式: \(outputFormat)"] as [String: Any?])
            return
        }
        guard FileManager.default.fileExists(atPath: inputPath) else {
            result(["path": nil, "msg": "输入文件不存在: \(inputPath)"] as [String: Any?])
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

                let scene = try loadScene(from: inputURL)
                let meshes = collectMeshData(from: scene.rootNode)
                guard !meshes.isEmpty else {
                    throw convError("输入文件中没有有效的 3D 几何数据")
                }

                let success: Bool
                switch format {
                case "glb":  success = try writeGLTF(meshes: meshes, to: outputURL, binary: true)
                case "gltf": success = try writeGLTF(meshes: meshes, to: outputURL, binary: false)
                case "obj":  success = try writeOBJ(meshes: meshes, to: outputURL)
                case "ply":  success = try writePLY(meshes: meshes, to: outputURL)
                case "stl":  success = try writeSTL(meshes: meshes, to: outputURL)
                // SceneKit 直接写：usdz, dae, scn
                case "usdz", "dae", "scn":
                    success = scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
                // USD 系列和 ABC：通过中间 USDC 文件 → MDLAsset 导出
                case "usd", "usda", "usdc", "abc":
                    success = try exportViaIntermediate(scene: scene, to: outputURL, format: format)
                default:
                    success = false
                }

                DispatchQueue.main.async {
                    result(success
                        ? ["path": outputURL.path, "msg": "success"]
                        : ["path": nil, "msg": "格式转换失败"] as [String: Any?])
                }
            } catch {
                DispatchQueue.main.async {
                    result(["path": nil, "msg": "格式转换异常: \(error.localizedDescription)"] as [String: Any?])
                }
            }
        }
    }

    // MARK: - 输入加载

    private static func loadScene(from url: URL) throws -> SCNScene {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "glb", "gltf":
            return try GLTFLoader.loadScene(from: url)
        case "scn":
            return try SCNScene(url: url, options: nil)
        case "dae":
            return try SCNScene(url: url, options: [.checkConsistency: true])
        default:
            let asset = MDLAsset(url: url)
            asset.loadTextures()
            return SCNScene(mdlAsset: asset)
        }
    }

    // MARK: - 几何数据收集

    struct MeshData {
        var positions:  [Float] = []   // xyz
        var normals:    [Float] = []   // xyz
        var texCoords:  [Float] = []   // uv
        var colors:     [Float] = []   // rgba (顶点颜色)
        var indices:    [UInt32] = []
        var diffuseR: Float = 0.7
        var diffuseG: Float = 0.7
        var diffuseB: Float = 0.7
        var metallic:  Float = 0.0
        var roughness: Float = 0.5
        var vertexCount: Int { positions.count / 3 }
    }

    /// 遍历 SCNScene 所有节点，提取几何数据 + 材质颜色 + 顶点颜色
    private static func collectMeshData(from root: SCNNode) -> [MeshData] {
        var result: [MeshData] = []

        func walk(_ node: SCNNode) {
            if let geo = node.geometry {
                var m = MeshData()
                if let s = geo.sources(for: .vertex).first   { extractFloats(s, 3, &m.positions) }
                if let s = geo.sources(for: .normal).first    { extractFloats(s, 3, &m.normals) }
                if let s = geo.sources(for: .texcoord).first  { extractFloats(s, 2, &m.texCoords) }
                if let s = geo.sources(for: .color).first     { extractFloats(s, 4, &m.colors) }
                for e in geo.elements { extractIndices(e, 0, &m.indices) }

                // 材质
                if let mat = geo.firstMaterial {
                    // diffuse 可能是 UIColor 或 UIImage
                    if let c = mat.diffuse.contents as? UIColor {
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        c.getRed(&r, green: &g, blue: &b, alpha: &a)
                        m.diffuseR = Float(r); m.diffuseG = Float(g); m.diffuseB = Float(b)
                    } else if mat.diffuse.contents is UIImage {
                        // 有纹理贴图但无法直接导出为颜色值
                        // 如果没有顶点颜色，尝试从纹理 + UV 烘焙顶点颜色
                        if m.colors.isEmpty && !m.texCoords.isEmpty {
                            m.colors = bakeVertexColorsFromTexture(
                                texture: mat.diffuse.contents as! UIImage,
                                texCoords: m.texCoords,
                                vertexCount: m.vertexCount
                            )
                        }
                        // 保持默认灰色作为 diffuse 基色
                    }
                    if let v = mat.metalness.contents as? NSNumber { m.metallic = v.floatValue }
                    if let v = mat.roughness.contents as? NSNumber { m.roughness = v.floatValue }
                }

                if m.vertexCount > 0 && !m.indices.isEmpty { result.append(m) }
            }
            node.childNodes.forEach { walk($0) }
        }
        walk(root)
        return result
    }

    /// 从纹理贴图 + UV 坐标烘焙出顶点颜色
    private static func bakeVertexColorsFromTexture(texture: UIImage, texCoords: [Float], vertexCount: Int) -> [Float] {
        guard let cgImage = texture.cgImage else { return [] }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return [] }

        // 将图像渲染到 RGBA 像素缓冲区
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixelData,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return [] }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 对每个顶点，根据 UV 坐标采样纹理颜色
        var colors: [Float] = []
        colors.reserveCapacity(vertexCount * 4)

        for i in 0..<vertexCount {
            let uvIdx = i * 2
            guard uvIdx + 1 < texCoords.count else {
                colors.append(contentsOf: [0.7, 0.7, 0.7, 1.0])
                continue
            }

            var u = texCoords[uvIdx]
            var v = texCoords[uvIdx + 1]

            // clamp UV to [0, 1]
            u = max(0, min(1, u))
            v = max(0, min(1, v))

            // UV → 像素坐标 (V 轴翻转: GLTF/SceneKit UV 原点在左下)
            let px = min(Int(u * Float(width - 1)), width - 1)
            let py = min(Int((1.0 - v) * Float(height - 1)), height - 1)

            let offset = (py * width + px) * bytesPerPixel
            let r = Float(pixelData[offset]) / 255.0
            let g = Float(pixelData[offset + 1]) / 255.0
            let b = Float(pixelData[offset + 2]) / 255.0
            let a = Float(pixelData[offset + 3]) / 255.0

            // 处理预乘 alpha
            if a > 0.001 {
                colors.append(contentsOf: [r / a, g / a, b / a, a])
            } else {
                colors.append(contentsOf: [r, g, b, a])
            }
        }

        return colors
    }

    // MARK: - 自定义 OBJ 导出器（带 .mtl 材质文件）

    private static func writeOBJ(meshes: [MeshData], to url: URL) throws -> Bool {
        let mtlName = url.deletingPathExtension().lastPathComponent + ".mtl"
        let mtlURL  = url.deletingLastPathComponent().appendingPathComponent(mtlName)

        var obj = "# ObjectScannerPlugin OBJ Export\nmtllib \(mtlName)\n\n"
        var mtl = "# ObjectScannerPlugin MTL Export\n\n"

        var vOff = 0, vnOff = 0, vtOff = 0

        for (i, m) in meshes.enumerated() {
            let matName = "material_\(i)"

            // MTL
            mtl += "newmtl \(matName)\n"
            mtl += "Ka 0.1 0.1 0.1\n"
            mtl += String(format: "Kd %.4f %.4f %.4f\n", m.diffuseR, m.diffuseG, m.diffuseB)
            mtl += "Ks 0.2 0.2 0.2\n"
            mtl += "Ns 50.0\nd 1.0\nillum 2\n\n"

            // OBJ
            obj += "o mesh_\(i)\nusemtl \(matName)\n"

            for v in 0..<m.vertexCount {
                let hasColor = m.colors.count / 4 > v
                if hasColor {
                    // OBJ 扩展：v x y z r g b
                    obj += String(format: "v %.6f %.6f %.6f %.4f %.4f %.4f\n",
                                  m.positions[v*3], m.positions[v*3+1], m.positions[v*3+2],
                                  m.colors[v*4], m.colors[v*4+1], m.colors[v*4+2])
                } else {
                    obj += String(format: "v %.6f %.6f %.6f\n",
                                  m.positions[v*3], m.positions[v*3+1], m.positions[v*3+2])
                }
            }
            let normCount = m.normals.count / 3
            for v in 0..<normCount {
                obj += String(format: "vn %.6f %.6f %.6f\n",
                              m.normals[v*3], m.normals[v*3+1], m.normals[v*3+2])
            }
            let uvCount = m.texCoords.count / 2
            for v in 0..<uvCount {
                obj += String(format: "vt %.6f %.6f\n",
                              m.texCoords[v*2], m.texCoords[v*2+1])
            }

            let hasN = normCount > 0
            let hasT = uvCount > 0
            let triCount = m.indices.count / 3
            for t in 0..<triCount {
                let a = Int(m.indices[t*3])
                let b = Int(m.indices[t*3+1])
                let c = Int(m.indices[t*3+2])
                let va = a + vOff + 1, vb = b + vOff + 1, vc = c + vOff + 1 // 1-indexed
                if hasT && hasN {
                    let ta = a + vtOff + 1, tb = b + vtOff + 1, tc = c + vtOff + 1
                    let na = a + vnOff + 1, nb = b + vnOff + 1, nc = c + vnOff + 1
                    obj += "f \(va)/\(ta)/\(na) \(vb)/\(tb)/\(nb) \(vc)/\(tc)/\(nc)\n"
                } else if hasN {
                    let na = a + vnOff + 1, nb = b + vnOff + 1, nc = c + vnOff + 1
                    obj += "f \(va)//\(na) \(vb)//\(nb) \(vc)//\(nc)\n"
                } else {
                    obj += "f \(va) \(vb) \(vc)\n"
                }
            }
            obj += "\n"
            vOff += m.vertexCount; vnOff += normCount; vtOff += uvCount
        }

        try obj.write(to: url, atomically: true, encoding: .utf8)
        try mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - 自定义 PLY 导出器（带顶点颜色）

    private static func writePLY(meshes: [MeshData], to url: URL) throws -> Bool {
        var allPos: [Float] = [], allNorm: [Float] = [], allColor: [Float] = []
        var allIdx: [UInt32] = []
        var vertexOffset: UInt32 = 0

        for m in meshes {
            allPos.append(contentsOf: m.positions)
            allNorm.append(contentsOf: m.normals)

            // 顶点颜色：优先用顶点颜色，否则用材质 diffuse 色填充
            if m.colors.count / 4 == m.vertexCount {
                allColor.append(contentsOf: m.colors)
            } else {
                for _ in 0..<m.vertexCount {
                    allColor.append(contentsOf: [m.diffuseR, m.diffuseG, m.diffuseB, 1.0])
                }
            }

            for idx in m.indices { allIdx.append(idx + vertexOffset) }
            vertexOffset += UInt32(m.vertexCount)
        }

        let totalVerts = allPos.count / 3
        let totalFaces = allIdx.count / 3
        let hasNormals = allNorm.count / 3 == totalVerts

        var header = "ply\nformat ascii 1.0\n"
        header += "element vertex \(totalVerts)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        if hasNormals {
            header += "property float nx\nproperty float ny\nproperty float nz\n"
        }
        header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\n"
        header += "element face \(totalFaces)\n"
        header += "property list uchar int vertex_indices\n"
        header += "end_header\n"

        var body = ""
        for i in 0..<totalVerts {
            let x = allPos[i*3], y = allPos[i*3+1], z = allPos[i*3+2]
            body += String(format: "%.6f %.6f %.6f", x, y, z)
            if hasNormals {
                body += String(format: " %.6f %.6f %.6f", allNorm[i*3], allNorm[i*3+1], allNorm[i*3+2])
            }
            let r = UInt8(clamping: Int(allColor[i*4] * 255))
            let g = UInt8(clamping: Int(allColor[i*4+1] * 255))
            let b = UInt8(clamping: Int(allColor[i*4+2] * 255))
            let a = UInt8(clamping: Int(allColor[i*4+3] * 255))
            body += " \(r) \(g) \(b) \(a)\n"
        }
        for i in 0..<totalFaces {
            body += "3 \(allIdx[i*3]) \(allIdx[i*3+1]) \(allIdx[i*3+2])\n"
        }

        try (header + body).write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - 自定义 STL 导出器（二进制 STL，无颜色）

    private static func writeSTL(meshes: [MeshData], to url: URL) throws -> Bool {
        var totalTriangles: UInt32 = 0
        for m in meshes { totalTriangles += UInt32(m.indices.count / 3) }

        var data = Data(count: 80) // 80 byte header (zeros)
        var triCount = totalTriangles
        data.append(Data(bytes: &triCount, count: 4))

        for m in meshes {
            let triN = m.indices.count / 3
            let hasNorms = m.normals.count / 3 == m.vertexCount
            for t in 0..<triN {
                let i0 = Int(m.indices[t*3])
                let i1 = Int(m.indices[t*3+1])
                let i2 = Int(m.indices[t*3+2])

                var nx: Float = 0, ny: Float = 0, nz: Float = 1
                if hasNorms {
                    nx = m.normals[i0*3]; ny = m.normals[i0*3+1]; nz = m.normals[i0*3+2]
                }
                data.append(floatBytes(nx)); data.append(floatBytes(ny)); data.append(floatBytes(nz))

                for idx in [i0, i1, i2] {
                    data.append(floatBytes(m.positions[idx*3]))
                    data.append(floatBytes(m.positions[idx*3+1]))
                    data.append(floatBytes(m.positions[idx*3+2]))
                }
                var attrByteCount: UInt16 = 0
                data.append(Data(bytes: &attrByteCount, count: 2))
            }
        }

        try data.write(to: url)
        return true
    }

    private static func floatBytes(_ v: Float) -> Data {
        var val = v
        return Data(bytes: &val, count: 4)
    }

    // MARK: - ModelIO 导出 (abc / usd 等) — 通过中间 USDC 文件

    /// 先用 SceneKit 写出临时 USDC，再用 MDLAsset 加载并导出目标格式
    /// 这样避免了 MDLAsset(scnScene:) 对程序化 SCNScene 的兼容性问题
    private static func exportViaIntermediate(scene: SCNScene, to url: URL, format: String) throws -> Bool {
        // 如果目标就是 usd/usda/usdc，直接用 SceneKit 写
        if ["usd", "usda", "usdc"].contains(format) {
            return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
        }

        // ABC 等格式：先写临时 USDC，再转换
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("temp_convert_\(UUID().uuidString).usdc")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 步骤1: SCNScene → USDC (SceneKit 原生支持，保留材质和几何)
        let writeOK = scene.write(to: tempURL, options: nil, delegate: nil, progressHandler: nil)
        guard writeOK else {
            throw convError("无法写入临时 USDC 文件")
        }

        // 步骤2: 从 USDC 加载为 MDLAsset
        let asset = MDLAsset(url: tempURL)
        asset.loadTextures()

        // 步骤3: 检查目标格式是否支持导出
        guard MDLAsset.canExportFileExtension(format) else {
            // ABC 可能不被 canExportFileExtension 支持，尝试用私有 API
            return try exportViaPrivateAPI(asset: asset, to: url)
        }

        try asset.export(to: url)
        return true
    }

    /// 使用 ObjC 私有 API 导出 MDLAsset
    private static func exportViaPrivateAPI(asset: MDLAsset, to url: URL) throws -> Bool {
        let sel = NSSelectorFromString("exportAssetToURL:error:")
        typealias ExportFn = @convention(c) (AnyObject, Selector, NSURL, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        guard let imp = class_getMethodImplementation(type(of: asset), sel) else {
            throw convError("MDLAsset exportAssetToURL 不可用，该格式可能不被当前 iOS 版本支持")
        }
        let fn = unsafeBitCast(imp, to: ExportFn.self)
        var error: NSError?
        let ok = fn(asset, sel, url as NSURL, &error)
        if let error = error { throw error }
        if !ok { throw convError("MDLAsset 导出失败") }
        return true
    }

    // MARK: - GLTF / GLB 导出器

    private static func writeGLTF(meshes: [MeshData], to outputURL: URL, binary: Bool) throws -> Bool {
        var binData = Data()
        var bufferViews: [[String: Any]] = []
        var accessors:   [[String: Any]] = []
        var gltfMeshes:  [[String: Any]] = []
        var gltfNodes:   [[String: Any]] = []
        var gltfMats:    [[String: Any]] = []
        var nodeIndices: [Int] = []

        func appendBuf(_ floats: [Float]) -> (Int, Int) {
            let off = binData.count
            floats.withUnsafeBytes { binData.append(contentsOf: $0) }
            while binData.count % 4 != 0 { binData.append(0x00) }
            return (off, binData.count - off)
        }
        func appendIdx(_ indices: [UInt32]) -> (Int, Int) {
            let off = binData.count
            indices.withUnsafeBytes { binData.append(contentsOf: $0) }
            while binData.count % 4 != 0 { binData.append(0x00) }
            return (off, binData.count - off)
        }
        func addBV(_ off: Int, _ len: Int, _ tgt: Int) -> Int {
            bufferViews.append(["buffer": 0, "byteOffset": off, "byteLength": len, "target": tgt])
            return bufferViews.count - 1
        }
        func addAC(_ bv: Int, _ ct: Int, _ cnt: Int, _ tp: String, _ extra: [String: Any] = [:]) -> Int {
            var a: [String: Any] = ["bufferView": bv, "componentType": ct, "count": cnt, "type": tp]
            extra.forEach { a[$0.key] = $0.value }
            accessors.append(a)
            return accessors.count - 1
        }

        for (i, m) in meshes.enumerated() {
            let matIdx = gltfMats.count
            gltfMats.append([
                "pbrMetallicRoughness": [
                    "baseColorFactor": [m.diffuseR, m.diffuseG, m.diffuseB, 1.0],
                    "metallicFactor": m.metallic,
                    "roughnessFactor": m.roughness
                ] as [String: Any],
                "doubleSided": true
            ])

            let (pO, pL) = appendBuf(m.positions)
            let (minP, maxP) = computeBounds(m.positions)
            let bvP = addBV(pO, pL, 34962)
            let acP = addAC(bvP, 5126, m.vertexCount, "VEC3",
                            ["min": [minP.x, minP.y, minP.z], "max": [maxP.x, maxP.y, maxP.z]])
            var attrs: [String: Int] = ["POSITION": acP]

            if !m.normals.isEmpty {
                let (o, l) = appendBuf(m.normals)
                attrs["NORMAL"] = addAC(addBV(o, l, 34962), 5126, m.normals.count/3, "VEC3")
            }
            if !m.texCoords.isEmpty {
                let (o, l) = appendBuf(m.texCoords)
                attrs["TEXCOORD_0"] = addAC(addBV(o, l, 34962), 5126, m.texCoords.count/2, "VEC2")
            }
            if m.colors.count / 4 == m.vertexCount {
                let (o, l) = appendBuf(m.colors)
                attrs["COLOR_0"] = addAC(addBV(o, l, 34962), 5126, m.colors.count/4, "VEC4")
            }

            let (iO, iL) = appendIdx(m.indices)
            let acI = addAC(addBV(iO, iL, 34963), 5125, m.indices.count, "SCALAR")

            gltfMeshes.append(["name": "Mesh_\(i)", "primitives": [
                ["attributes": attrs, "indices": acI, "mode": 4, "material": matIdx]
            ]])
            gltfNodes.append(["name": "Node_\(i)", "mesh": i])
            nodeIndices.append(i)
        }

        var bufEntry: [String: Any] = ["byteLength": binData.count]
        if !binary { bufEntry["uri"] = "data:application/octet-stream;base64," + binData.base64EncodedString() }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "ObjectScannerPlugin-iOS"],
            "scene": 0, "scenes": [["nodes": nodeIndices]],
            "nodes": gltfNodes, "meshes": gltfMeshes, "materials": gltfMats,
            "accessors": accessors, "bufferViews": bufferViews, "buffers": [bufEntry]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        if binary {
            try writeGLBContainer(json: jsonData, bin: binData, to: outputURL)
        } else {
            try jsonData.write(to: outputURL)
        }
        return true
    }

    private static func writeGLBContainer(json: Data, bin: Data, to url: URL) throws {
        var pJSON = json; while pJSON.count % 4 != 0 { pJSON.append(0x20) }
        var pBin = bin;   while pBin.count % 4 != 0 { pBin.append(0x00) }
        let total = 12 + 8 + pJSON.count + 8 + pBin.count
        var glb = Data(capacity: total)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { glb.append(contentsOf: $0) } }
        u32(0x46546C67); u32(2); u32(UInt32(total))
        u32(UInt32(pJSON.count)); u32(0x4E4F534A); glb.append(pJSON)
        u32(UInt32(pBin.count));  u32(0x004E4942); glb.append(pBin)
        try glb.write(to: url)
    }

    // MARK: - 工具

    /// 从 SCNGeometrySource 提取浮点分量
    /// 支持 float32、float64、以及非浮点类型（UInt8/UInt16 归一化到 [0,1]）
    private static func extractFloats(_ src: SCNGeometrySource, _ comps: Int, _ arr: inout [Float]) {
        let data = src.data, count = src.vectorCount, stride = src.dataStride
        let offset = src.dataOffset, bpc = src.bytesPerComponent
        data.withUnsafeBytes { ptr in
            for i in 0..<count {
                for c in 0..<comps {
                    let off = offset + i * stride + c * bpc
                    guard off + bpc <= data.count else { continue }
                    if src.usesFloatComponents {
                        if bpc == 4 { arr.append(ptr.load(fromByteOffset: off, as: Float.self)) }
                        else if bpc == 8 { arr.append(Float(ptr.load(fromByteOffset: off, as: Double.self))) }
                    } else {
                        // 非浮点分量：UInt8/UInt16 归一化到 [0,1]（常见于顶点颜色）
                        switch bpc {
                        case 1:
                            arr.append(Float(ptr.load(fromByteOffset: off, as: UInt8.self)) / 255.0)
                        case 2:
                            arr.append(Float(ptr.load(fromByteOffset: off, as: UInt16.self)) / 65535.0)
                        case 4:
                            // 可能是 Int32 等，尝试当 Float 读取
                            arr.append(ptr.load(fromByteOffset: off, as: Float.self))
                        default:
                            arr.append(0)
                        }
                    }
                }
            }
        }
    }

    private static func extractIndices(_ elem: SCNGeometryElement, _ base: UInt32, _ arr: inout [UInt32]) {
        let data = elem.data, bpi = elem.bytesPerIndex, count = elem.primitiveCount
        func idx(_ i: Int) -> UInt32 {
            data.withUnsafeBytes {
                switch bpi {
                case 1: return UInt32($0.load(fromByteOffset: i*bpi, as: UInt8.self))
                case 2: return UInt32($0.load(fromByteOffset: i*bpi, as: UInt16.self))
                case 4: return $0.load(fromByteOffset: i*bpi, as: UInt32.self)
                default: return 0
                }
            }
        }
        switch elem.primitiveType {
        case .triangles:
            for i in 0..<count*3 { arr.append(base + idx(i)) }
        case .triangleStrip:
            for i in 0..<count {
                let a = base+idx(i), b = base+idx(i+1), c = base+idx(i+2)
                arr.append(contentsOf: i%2==0 ? [a,b,c] : [b,a,c])
            }
        default: break
        }
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

    private static func convError(_ msg: String) -> NSError {
        NSError(domain: "FormatConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    static func getSupportedFormats() -> [String] { supportedFormats }
}
