import ARKit
import RealityKit
import SwiftUI
import SceneKit
import ModelIO
import MetalKit
import CoreImage

// MARK: - 空间扫描 (SceneKit + LiDAR)

private struct CameraSnapshot {
    let image: CGImage
    let cameraTransform: simd_float4x4
    let fx: Float, fy: Float, cx: Float, cy: Float
    let imageWidth: Int, imageHeight: Int
}

// 预计算的快照缓存（避免重复 simd_inverse）
private struct SnapProjector {
    let camInverse: simd_float4x4
    let camPosition: SIMD3<Float>
    let fx: Float, fy: Float, cx: Float, cy: Float
    let imgW: Float, imgH: Float
    let marginX: Float, marginY: Float

    init(_ snap: CameraSnapshot) {
        camInverse = simd_inverse(snap.cameraTransform)
        camPosition = SIMD3<Float>(snap.cameraTransform.columns.3.x,
                                    snap.cameraTransform.columns.3.y,
                                    snap.cameraTransform.columns.3.z)
        fx = snap.fx; fy = snap.fy; cx = snap.cx; cy = snap.cy
        imgW = Float(snap.imageWidth)
        imgH = Float(snap.imageHeight)
        marginX = imgW * 0.05
        marginY = imgH * 0.05
    }

    /// 投影一个世界坐标点，返回 (pixelX, pixelY) 或 nil（不在有效区域内）
    func project(_ worldPos: SIMD3<Float>) -> (Float, Float)? {
        let camPt = simd_mul(camInverse, SIMD4<Float>(worldPos, 1.0))
        guard camPt.z < -0.1 else { return nil }
        let z = -camPt.z
        let px = (camPt.x / z) * fx + cx
        let py = (camPt.y / z) * fy + cy
        guard px >= marginX && px < imgW - marginX &&
              py >= marginY && py < imgH - marginY else { return nil }
        return (px, py)
    }
}

@available(iOS 13.0, *)
final class SpaceScannerViewModel: NSObject, ObservableObject, ARSCNViewDelegate {
    private var sceneView: ARSCNView!
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]

    private var globalSnapshots: [CameraSnapshot] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastSnapshotTime: TimeInterval = 0
    private let snapshotInterval: TimeInterval = 0.3
    private let maxSnapshots = 50

    override init() {
        super.init()
        setupARView()
    }

    private func setupARView() {
        sceneView = ARSCNView(frame: .zero)
        sceneView.delegate = self
        sceneView.autoenablesDefaultLighting = true
    }

    func getSceneView() -> ARSCNView { return sceneView }

    func startScanning() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("❌ 设备不支持 LiDAR 网格重建")
            return
        }
        meshAnchors.removeAll()
        globalSnapshots.removeAll()
        lastSnapshotTime = 0

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.environmentTexturing = .automatic
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        print("✅ 开始扫描")
    }

    // MARK: - ARSCNViewDelegate

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        meshAnchors[meshAnchor.identifier] = meshAnchor
        let geo = createVisualizationGeometry(from: meshAnchor.geometry)
        let node = SCNNode(geometry: geo)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.white.withAlphaComponent(0.6)
        mat.lightingModel = .physicallyBased
        mat.isDoubleSided = true
        geo.materials = [mat]
        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        meshAnchors[meshAnchor.identifier] = meshAnchor
        let newGeo = createVisualizationGeometry(from: meshAnchor.geometry)
        newGeo.materials = node.geometry?.materials ?? []
        if newGeo.materials.isEmpty {
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.white.withAlphaComponent(0.6)
            mat.lightingModel = .physicallyBased; mat.isDoubleSided = true
            newGeo.materials = [mat]
        }
        node.geometry = newGeo
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {}

    // 定期保存全分辨率相机快照
    func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard time - lastSnapshotTime >= snapshotInterval else { return }
        guard let frame = sceneView.session.currentFrame else { return }
        captureSnapshot(from: frame)
        lastSnapshotTime = time
    }

    private func captureSnapshot(from frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let intrinsics = frame.camera.intrinsics
        let snap = CameraSnapshot(
            image: cgImage,
            cameraTransform: frame.camera.transform,
            fx: intrinsics[0][0], fy: intrinsics[1][1],
            cx: intrinsics[2][0], cy: intrinsics[2][1],
            imageWidth: cgImage.width, imageHeight: cgImage.height
        )
        if globalSnapshots.count >= maxSnapshots {
            globalSnapshots.removeFirst()
        }
        globalSnapshots.append(snap)
    }

    // MARK: - 可视化几何体（实时预览用，轻量）

    private func createVisualizationGeometry(from mesh: ARMeshGeometry) -> SCNGeometry {
        let vSrc = SCNGeometrySource(buffer: mesh.vertices.buffer, vertexFormat: mesh.vertices.format,
                                      semantic: .vertex, vertexCount: mesh.vertices.count,
                                      dataOffset: mesh.vertices.offset, dataStride: mesh.vertices.stride)
        let nSrc = SCNGeometrySource(buffer: mesh.normals.buffer, vertexFormat: mesh.normals.format,
                                      semantic: .normal, vertexCount: mesh.normals.count,
                                      dataOffset: mesh.normals.offset, dataStride: mesh.normals.stride)
        let fData = Data(bytes: mesh.faces.buffer.contents(), count: mesh.faces.buffer.length)
        let elem = SCNGeometryElement(data: fData, primitiveType: .triangles,
                                       primitiveCount: mesh.faces.count, bytesPerIndex: mesh.faces.bytesPerIndex)
        return SCNGeometry(sources: [vSrc, nSrc], elements: [elem])
    }

    // MARK: - 导出

    func stopScanningAndExport() -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsURL.appendingPathComponent("scan_\(Date().timeIntervalSince1970).usdc")

        guard let frame = sceneView.session.currentFrame else {
            print("❌ 无法获取当前帧"); return nil
        }
        captureSnapshot(from: frame)

        let anchors = Array(meshAnchors.values)
        let snapshots = globalSnapshots
        sceneView.session.pause()

        print("📋 导出: \(anchors.count) 个网格, \(snapshots.count) 个快照")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.exportScene(to: fileURL, anchors: anchors, snapshots: snapshots)
                DispatchQueue.main.async {
                    ObjectScannerPlugin.pendingResult?(["path": fileURL.path, "msg": "success"])
                }
            } catch {
                print("❌ 导出失败: \(error)")
                DispatchQueue.main.async {
                    ObjectScannerPlugin.pendingResult?(["path": "", "msg": "导出失败: \(error.localizedDescription)"])
                }
            }
        }
        return fileURL
    }

    private func exportScene(to url: URL, anchors: [ARMeshAnchor], snapshots: [CameraSnapshot]) throws {
        guard #available(iOS 14.0, *) else {
            throw NSError(domain: "SpaceScanner", code: 2, userInfo: [NSLocalizedDescriptionKey: "需要 iOS 14.0+"])
        }
        guard !anchors.isEmpty else {
            throw NSError(domain: "SpaceScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有网格数据"])
        }

        // 预计算所有快照的投影器（只算一次 simd_inverse）
        let projectors = snapshots.map { SnapProjector($0) }

        let scene = SCNScene()
        let rootNode = SCNNode()
        rootNode.name = "RootNode"

        var totalTexturedFaces = 0
        var totalGrayFaces = 0

        for meshAnchor in anchors {
            let node = createTexturedNode(from: meshAnchor, snapshots: snapshots, projectors: projectors,
                                           texturedFaces: &totalTexturedFaces, grayFaces: &totalGrayFaces)
            rootNode.addChildNode(node)
        }

        scene.rootNode.addChildNode(rootNode)

        let light = SCNNode()
        light.light = SCNLight()
        light.light!.type = .ambient
        light.light!.color = UIColor.white
        light.light!.intensity = 1000
        scene.rootNode.addChildNode(light)

        print("📦 有纹理: \(totalTexturedFaces) 面, 无纹理: \(totalGrayFaces) 面")

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        guard scene.write(to: url, options: [:], delegate: nil, progressHandler: nil) else {
            throw NSError(domain: "SpaceScanner", code: 5, userInfo: [NSLocalizedDescriptionKey: "导出失败"])
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "SpaceScanner", code: 3, userInfo: [NSLocalizedDescriptionKey: "文件不存在"])
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            print("✅ 导出完成: \(String(format: "%.2f", Double(size)/1024/1024)) MB")
        }
    }

    // MARK: - 核心：为每个面搜索全部快照，选最佳的

    @available(iOS 14.0, *)
    private func createTexturedNode(from meshAnchor: ARMeshAnchor, snapshots: [CameraSnapshot],
                                     projectors: [SnapProjector],
                                     texturedFaces: inout Int, grayFaces: inout Int) -> SCNNode {
        let mesh = meshAnchor.geometry
        let transform = meshAnchor.transform
        let vertexCount = mesh.vertices.count

        let rotation = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )

        // 1) 提取世界坐标
        var worldVerts = [SIMD3<Float>]()
        var worldNormals = [SIMD3<Float>]()
        worldVerts.reserveCapacity(vertexCount)
        worldNormals.reserveCapacity(vertexCount)

        let vBase = mesh.vertices.buffer.contents().advanced(by: mesh.vertices.offset)
        let nBase = mesh.normals.buffer.contents().advanced(by: mesh.normals.offset)
        for i in 0..<vertexCount {
            let v = vBase.advanced(by: i * mesh.vertices.stride).assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let w = transform * SIMD4<Float>(v, 1.0)
            worldVerts.append(SIMD3<Float>(w.x, w.y, w.z))
            let n = nBase.advanced(by: i * mesh.normals.stride).assumingMemoryBound(to: SIMD3<Float>.self).pointee
            worldNormals.append(rotation * n)
        }

        // 2) 提取索引
        var origIndices = [UInt32]()
        let faceCount = mesh.faces.count
        let fBase = mesh.faces.buffer.contents()
        origIndices.reserveCapacity(faceCount * 3)
        if mesh.faces.bytesPerIndex == 2 {
            let p = fBase.assumingMemoryBound(to: UInt16.self)
            for i in 0..<(faceCount * 3) { origIndices.append(UInt32(p[i])) }
        } else {
            let p = fBase.assumingMemoryBound(to: UInt32.self)
            for i in 0..<(faceCount * 3) { origIndices.append(p[i]) }
        }

        // 3) 对每个面搜索全部快照，选最佳（要求 3 个顶点全部可见）
        //    faceAssignment[f] = 快照索引，-1 表示无合适快照
        var faceAssignment = [Int](repeating: -1, count: faceCount)

        for f in 0..<faceCount {
            let i0 = Int(origIndices[f * 3])
            let i1 = Int(origIndices[f * 3 + 1])
            let i2 = Int(origIndices[f * 3 + 2])

            let wp0 = worldVerts[i0]
            let wp1 = worldVerts[i1]
            let wp2 = worldVerts[i2]

            // 面法线
            let edge1 = wp1 - wp0
            let edge2 = wp2 - wp0
            let crossProduct = simd_cross(edge1, edge2)
            let len = simd_length(crossProduct)
            guard len > 1e-8 else { continue } // 退化三角形
            let faceNormal = crossProduct / len
            let faceCenter = (wp0 + wp1 + wp2) / 3.0

            var bestSnapIdx = -1
            var bestScore: Float = 0

            for si in 0..<projectors.count {
                let proj = projectors[si]

                // 法线朝向检查：面必须朝向相机
                let viewDir = simd_normalize(proj.camPosition - faceCenter)
                let facing = simd_dot(faceNormal, viewDir)
                if facing < 0.2 { continue } // 太斜，跳过

                // 3 个顶点必须全部在图像有效区域内
                guard let p0 = proj.project(wp0),
                      let p1 = proj.project(wp1),
                      let p2 = proj.project(wp2) else { continue }

                // 计算居中程度（越靠中心畸变越小）
                let halfW = proj.imgW * 0.5
                let halfH = proj.imgH * 0.5
                var centerScore: Float = 0
                for (px, py) in [p0, p1, p2] {
                    let dx = (px - halfW) / halfW
                    let dy = (py - halfH) / halfH
                    centerScore += 1.0 - sqrt(dx * dx + dy * dy) * 0.5
                }
                centerScore /= 3.0

                let score = facing * centerScore
                if score > bestScore {
                    bestScore = score
                    bestSnapIdx = si
                }
            }

            faceAssignment[f] = bestSnapIdx
        }

        // 4) 按快照分组
        var snapFaces = [Int: [Int]]()  // snapIndex -> [faceIndex]
        var grayFaceList = [Int]()

        for f in 0..<faceCount {
            let si = faceAssignment[f]
            if si >= 0 {
                snapFaces[si, default: []].append(f)
            } else {
                grayFaceList.append(f)
            }
        }

        // 5) 构建几何体：每个快照一个 element + material
        var allVerts = [SCNVector3]()
        var allNormals = [SCNVector3]()
        var allUVs = [CGPoint]()
        var elements = [SCNGeometryElement]()
        var materials = [SCNMaterial]()

        // 有纹理的面
        for (si, faces) in snapFaces {
            let snap = snapshots[si]
            let proj = projectors[si]

            var groupIndices = [UInt32]()
            groupIndices.reserveCapacity(faces.count * 3)

            for f in faces {
                let vertBase = UInt32(allVerts.count)
                for k in 0..<3 {
                    let vi = Int(origIndices[f * 3 + k])
                    let wp = worldVerts[vi]
                    let wn = worldNormals[vi]
                    allVerts.append(SCNVector3(wp.x, wp.y, wp.z))
                    allNormals.append(SCNVector3(wn.x, wn.y, wn.z))

                    // 投影 UV（这里一定能投影成功，因为 faceAssignment 已验证）
                    if let (px, py) = proj.project(wp) {
                        let u = CGFloat(px / proj.imgW)
                        let v = CGFloat(1.0 - py / proj.imgH)
                        allUVs.append(CGPoint(x: u, y: v))
                    } else {
                        allUVs.append(CGPoint(x: 0.5, y: 0.5))
                    }
                }
                groupIndices.append(vertBase)
                groupIndices.append(vertBase + 1)
                groupIndices.append(vertBase + 2)
            }

            elements.append(SCNGeometryElement(indices: groupIndices, primitiveType: .triangles))

            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.isDoubleSided = true
            mat.metalness.contents = 0.0
            mat.roughness.contents = 1.0
            mat.diffuse.contents = UIImage(cgImage: snap.image)
            mat.diffuse.wrapS = .clamp
            mat.diffuse.wrapT = .clamp
            materials.append(mat)

            texturedFaces += faces.count
        }

        // 无纹理的面（灰色）
        if !grayFaceList.isEmpty {
            var grayIndices = [UInt32]()
            grayIndices.reserveCapacity(grayFaceList.count * 3)

            for f in grayFaceList {
                let vertBase = UInt32(allVerts.count)
                for k in 0..<3 {
                    let vi = Int(origIndices[f * 3 + k])
                    let wp = worldVerts[vi]
                    let wn = worldNormals[vi]
                    allVerts.append(SCNVector3(wp.x, wp.y, wp.z))
                    allNormals.append(SCNVector3(wn.x, wn.y, wn.z))
                    allUVs.append(CGPoint(x: 0, y: 0))
                }
                grayIndices.append(vertBase)
                grayIndices.append(vertBase + 1)
                grayIndices.append(vertBase + 2)
            }

            elements.append(SCNGeometryElement(indices: grayIndices, primitiveType: .triangles))

            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.isDoubleSided = true
            mat.diffuse.contents = UIColor(white: 0.75, alpha: 1.0)
            materials.append(mat)

            grayFaces += grayFaceList.count
        }

        guard !elements.isEmpty else {
            let node = SCNNode(geometry: SCNGeometry())
            return node
        }

        let geo = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: allVerts),
                SCNGeometrySource(normals: allNormals),
                SCNGeometrySource(textureCoordinates: allUVs)
            ],
            elements: elements
        )
        geo.materials = materials

        let node = SCNNode(geometry: geo)
        node.name = "Mesh_\(meshAnchor.identifier.uuidString.prefix(8))"
        return node
    }
}

// MARK: - SwiftUI Views

@available(iOS 14.0, *)
struct SpaceScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SpaceScannerViewModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(sceneView: viewModel.getSceneView())
                .ignoresSafeArea()
                .onAppear { viewModel.startScanning() }

            VStack(spacing: 12) {
                Text(L10n.moveToScan)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)

                Button(action: {
                    if let _ = viewModel.stopScanningAndExport() { dismiss() }
                }) {
                    Text(L10n.stopAndExport)
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(10)
                }
            }
            .padding(.bottom, 40)
        }
    }
}

@available(iOS 14.0, *)
struct ARViewContainer: UIViewRepresentable {
    let sceneView: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { return sceneView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
