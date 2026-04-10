//
//  FormatConverter.swift
//  object_scanner_plugin
//
//  格式转换工具

import Foundation
import ModelIO
import SceneKit
import Flutter
import CoreImage

struct FormatConverter {

    static let supportedFormats = [
        "obj", "stl", "ply", "usd", "usda", "usdc",
        "usdz", "scn",
        "glb", "gltf"
    ]

    // MARK: - 主入口

    static func convert(inputPath: String, outputFormat: String, result: @escaping FlutterResult) {
        let format = outputFormat.lowercased()

        guard supportedFormats.contains(format) else {
            result(["path": nil, "msg": "不支持的输出格式: \(outputFormat)。支持: \(supportedFormats.joined(separator: ", "))"] as [String: Any?])
            return
        }
        guard FileManager.default.fileExists(atPath: inputPath) else {
            result(["path": nil, "msg": "输入文件不存在: \(inputPath)"] as [String: Any?])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let inputURL = URL(fileURLWithPath: inputPath)
                let inputExt = inputURL.pathExtension.lowercased()
                let fileName = inputURL.deletingPathExtension().lastPathComponent
                let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let outputURL = documentsDir.appendingPathComponent("\(fileName)_converted.\(format)")

                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }

                let scene = try loadScene(from: inputURL)

                let success: Bool
                switch format {
                // SceneKit 原生写入（保留材质纹理，之前验证可用）
                case "usdz", "usdc", "usda", "usd", "scn":
                    success = scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)

                // GLB/GLTF 自定义导出器
                case "glb", "gltf":
                    let meshes = collectMeshData(from: scene.rootNode)
                    guard !meshes.isEmpty else { throw convError("无有效几何数据") }
                    success = try writeGLTF(meshes: meshes, to: outputURL, binary: format == "glb")

                // OBJ/STL：先写临时 USDZ（保留纹理）→ 再用 MDLAsset 导出
                case "obj", "stl":
                    success = try convertViaTempUSDZ(scene: scene, outputURL: outputURL, format: format)

                // PLY：自定义导出（MDLAsset 不导出顶点颜色，需手动从纹理烘焙）
                case "ply":
                    success = try writePLY(scene: scene, to: outputURL)

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

    // MARK: - 通过临时 USDZ 中转导出

    /// SCNScene → 临时 USDZ（内嵌纹理）→ MDLAsset.export 到目标格式
    private static func convertViaTempUSDZ(scene: SCNScene, outputURL: URL, format: String) throws -> Bool {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("temp_\(UUID().uuidString).usdz")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 步骤1: SCNScene → USDZ（SceneKit 会将纹理打包进 USDZ）
        guard scene.write(to: tempURL, options: nil, delegate: nil, progressHandler: nil) else {
            throw convError("无法创建临时 USDZ")
        }

        // 步骤2: 从 USDZ 加载 MDLAsset（纹理完整保留）
        let asset = MDLAsset(url: tempURL)
        asset.loadTextures()

        guard MDLAsset.canExportFileExtension(format) else {
            throw convError("不支持导出 \(format) 格式")
        }

        // 步骤3: MDLAsset 导出到目标格式
        try asset.export(to: outputURL)

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attrs?[.size] as? Int64 ?? 0
        return size > 0
    }

    // MARK: - 输入加载

    private static func loadScene(from url: URL) throws -> SCNScene {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "glb", "gltf":
            return try GLTFLoader.loadScene(from: url)
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

        func processNode(_ node: SCNNode) {
            guard let geo = node.geometry else {
                node.childNodes.forEach { processNode($0) }
                return
            }

            var positions: [Float] = []
            var normals: [Float] = []
            var texCoords: [Float] = []
            var colors: [Float] = []
            var indices: [UInt32] = []

            if let s = geo.sources(for: .vertex).first   { extractFloats(s, 3, &positions) }
            if let s = geo.sources(for: .normal).first    { extractFloats(s, 3, &normals) }
            if let s = geo.sources(for: .texcoord).first  { extractFloats(s, 2, &texCoords) }
            if let s = geo.sources(for: .color).first     { extractFloats(s, 4, &colors) }
            for e in geo.elements { extractIndices(e, 0, &indices) }

            let vtxCount = positions.count / 3
            guard vtxCount > 0, !indices.isEmpty else {
                node.childNodes.forEach { processNode($0) }
                return
            }

            allPos.append(contentsOf: positions)
            allNorm.append(contentsOf: normals)

            // 顶点颜色来源优先级: 已有顶点颜色 > 纹理烘焙 > 材质颜色 > 默认灰
            if colors.count / 4 == vtxCount {
                // 已有顶点颜色（float → UInt8）
                for i in 0..<vtxCount {
                    allColor.append(UInt8(clamping: Int(colors[i*4] * 255)))
                    allColor.append(UInt8(clamping: Int(colors[i*4+1] * 255)))
                    allColor.append(UInt8(clamping: Int(colors[i*4+2] * 255)))
                }
            } else if let mat = geo.firstMaterial,
                      let texture = extractImage(from: mat.diffuse.contents),
                      !texCoords.isEmpty,
                      let (pixels, tw, th) = textureToRGBA(texture) {
                // 从纹理+UV 烘焙
                for i in 0..<vtxCount {
                    let uvIdx = i * 2
                    if uvIdx + 1 < texCoords.count {
                        let u = max(0, min(1, texCoords[uvIdx]))
                        let v = max(0, min(1, texCoords[uvIdx + 1]))
                        let px = min(Int(u * Float(tw - 1)), tw - 1)
                        let py = min(Int(v * Float(th - 1)), th - 1)
                        let off = (py * tw + px) * 4
                        allColor.append(pixels[off])     // R
                        allColor.append(pixels[off + 1]) // G
                        allColor.append(pixels[off + 2]) // B
                    } else {
                        allColor.append(contentsOf: [180, 180, 180])
                    }
                }
            } else if let mat = geo.firstMaterial, let c = mat.diffuse.contents as? UIColor {
                // 纯色材质
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                let rb = UInt8(clamping: Int(r * 255))
                let gb = UInt8(clamping: Int(g * 255))
                let bb = UInt8(clamping: Int(b * 255))
                for _ in 0..<vtxCount {
                    allColor.append(contentsOf: [rb, gb, bb])
                }
            } else {
                // 默认灰色
                for _ in 0..<vtxCount {
                    allColor.append(contentsOf: [180, 180, 180])
                }
            }

            for idx in indices { allIdx.append(idx + vertexOffset) }
            vertexOffset += UInt32(vtxCount)

            node.childNodes.forEach { processNode($0) }
        }
        processNode(scene.rootNode)

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
        var vertexCount: Int { positions.count / 3 }
    }

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

                if let mat = geo.firstMaterial {
                    if let img = extractImage(from: mat.diffuse.contents) {
                        m.diffuseTexture = img
                    } else if let c = mat.diffuse.contents as? UIColor {
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        c.getRed(&r, green: &g, blue: &b, alpha: &a)
                        m.diffuseR = Float(r); m.diffuseG = Float(g); m.diffuseB = Float(b)
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
        var binData = Data()
        var bufferViews: [[String: Any]] = []
        var accessors:   [[String: Any]] = []
        var gltfMeshes:  [[String: Any]] = []
        var gltfNodes:   [[String: Any]] = []
        var gltfMats:    [[String: Any]] = []
        var gltfImages:  [[String: Any]] = []
        var gltfTextures:[[String: Any]] = []
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
        func appendRaw(_ data: Data) -> (Int, Int) {
            let off = binData.count
            binData.append(data)
            while binData.count % 4 != 0 { binData.append(0x00) }
            return (off, binData.count - off)
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

        for (i, m) in meshes.enumerated() {
            let matIdx = gltfMats.count
            var pbrDict: [String: Any] = [
                "metallicFactor": m.metallic,
                "roughnessFactor": m.roughness
            ]

            if let tex = m.diffuseTexture, let pngData = tex.pngData() {
                let (imgOff, imgLen) = appendRaw(pngData)
                let imgBV = addBVPlain(imgOff, imgLen)
                let imgIdx = gltfImages.count
                gltfImages.append(["bufferView": imgBV, "mimeType": "image/png"])
                let texIdx = gltfTextures.count
                gltfTextures.append(["source": imgIdx])
                pbrDict["baseColorTexture"] = ["index": texIdx]
            } else {
                pbrDict["baseColorFactor"] = [m.diffuseR, m.diffuseG, m.diffuseB, 1.0]
            }

            gltfMats.append(["pbrMetallicRoughness": pbrDict, "doubleSided": true])

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

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "ObjectScannerPlugin-iOS"],
            "scene": 0, "scenes": [["nodes": nodeIndices]],
            "nodes": gltfNodes, "meshes": gltfMeshes, "materials": gltfMats,
            "accessors": accessors, "bufferViews": bufferViews, "buffers": [bufEntry]
        ]
        if !gltfImages.isEmpty { json["images"] = gltfImages }
        if !gltfTextures.isEmpty { json["textures"] = gltfTextures }

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
