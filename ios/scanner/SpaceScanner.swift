import ARKit
import RealityKit
import SwiftUI
import SceneKit
import ModelIO
import MetalKit
import CoreImage

// MARK: - 空间扫描 (SceneKit + LiDAR)

private struct CameraSnapshot {
    let imageData: Data
    let cameraTransform: simd_float4x4
    let fx: Float, fy: Float, cx: Float, cy: Float
    let imageWidth: Int, imageHeight: Int
}

private struct MeshEdge: Hashable {
    let first: UInt32
    let second: UInt32

    init(_ lhs: UInt32, _ rhs: UInt32) {
        first = min(lhs, rhs)
        second = max(lhs, rhs)
    }
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
    private let stateLock = NSLock()
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var lastGeometryUpdate: [UUID: TimeInterval] = [:]
    private var globalSnapshots: [CameraSnapshot] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let snapshotQueue = DispatchQueue(label: "com.object-scanner.space-snapshots", qos: .utility)
    private let exportQueue = DispatchQueue(label: "com.object-scanner.space-export", qos: .userInitiated)
    private var lastSnapshotTime: TimeInterval = 0
    private var lastSnapshotTransform: simd_float4x4?
    private var snapshotCaptureScheduled = false
    private var isScanning = false
    private var isExporting = false
    private var scanGeneration = UUID()

    private let snapshotInterval: TimeInterval = 0.65
    private let maxSnapshots = 36
    private let snapshotMaxDimension: CGFloat = 1280
    private let minimumSnapshotTranslation: Float = 0.08
    private let minimumSnapshotRotation: Float = 7.0 * .pi / 180.0
    private let geometryUpdateInterval: TimeInterval = 0.25

    private lazy var previewMaterial: SCNMaterial = {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.0, green: 0.88, blue: 0.72, alpha: 1.0)
        material.transparency = 0.72
        material.blendMode = .alpha
        material.lightingModel = .constant
        material.isDoubleSided = true
        return material
    }()

    override init() {
        super.init()
        setupARView()
    }

    private func setupARView() {
        sceneView = ARSCNView(frame: .zero)
        sceneView.delegate = self
        sceneView.autoenablesDefaultLighting = false
        sceneView.preferredFramesPerSecond = 30
        sceneView.antialiasingMode = .none
    }

    func getSceneView() -> ARSCNView { return sceneView }

    func startScanning() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("❌ 设备不支持 LiDAR 网格重建")
            return
        }

        stateLock.lock()
        meshAnchors.removeAll(keepingCapacity: true)
        lastGeometryUpdate.removeAll(keepingCapacity: true)
        globalSnapshots.removeAll(keepingCapacity: true)
        lastSnapshotTime = 0
        lastSnapshotTransform = nil
        snapshotCaptureScheduled = false
        isScanning = true
        isExporting = false
        scanGeneration = UUID()
        stateLock.unlock()

        let config = ARWorldTrackingConfiguration()
        // Classification, plane detection, sceneDepth and environment texturing were not
        // consumed by the exporter, but each adds continuous work during a scan.
        config.sceneReconstruction = .mesh
        let thirtyFPSFormats = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter { $0.framesPerSecond == 30 }
        let boundedFormats = thirtyFPSFormats.filter {
            $0.imageResolution.width * $0.imageResolution.height <= 1920 * 1440
        }
        if let thirtyFPSFormat = (boundedFormats.isEmpty ? thirtyFPSFormats : boundedFormats)
            .max(by: {
                $0.imageResolution.width * $0.imageResolution.height <
                $1.imageResolution.width * $1.imageResolution.height
            }) {
            config.videoFormat = thirtyFPSFormat
        }
        sceneView.delegate = self
        sceneView.isPlaying = true
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        print("✅ 开始扫描")
    }

    // MARK: - ARSCNViewDelegate

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        let now = ProcessInfo.processInfo.systemUptime

        stateLock.lock()
        guard isScanning else {
            stateLock.unlock()
            return nil
        }
        meshAnchors[meshAnchor.identifier] = meshAnchor
        lastGeometryUpdate[meshAnchor.identifier] = now
        stateLock.unlock()

        let geo = createVisualizationGeometry(from: meshAnchor.geometry)
        let node = SCNNode(geometry: geo)
        geo.materials = [previewMaterial]
        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        let now = ProcessInfo.processInfo.systemUptime

        stateLock.lock()
        guard isScanning else {
            stateLock.unlock()
            return
        }
        meshAnchors[meshAnchor.identifier] = meshAnchor
        let thermalMultiplier: Double = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? 2.0 : 1.0
        let lastUpdate = lastGeometryUpdate[meshAnchor.identifier] ?? 0
        let shouldRefreshGeometry = now - lastUpdate >= geometryUpdateInterval * thermalMultiplier
        if shouldRefreshGeometry {
            lastGeometryUpdate[meshAnchor.identifier] = now
        }
        stateLock.unlock()

        guard shouldRefreshGeometry else { return }
        let newGeo = createVisualizationGeometry(from: meshAnchor.geometry)
        newGeo.materials = [previewMaterial]
        node.geometry = newGeo
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        stateLock.lock()
        meshAnchors.removeValue(forKey: meshAnchor.identifier)
        lastGeometryUpdate.removeValue(forKey: meshAnchor.identifier)
        stateLock.unlock()
    }

    // Only schedule a keyframe after meaningful camera movement. JPEG compression runs
    // away from the renderer thread so preview frames do not stall.
    func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let frame = sceneView.session.currentFrame else { return }
        guard reserveSnapshotCapture(for: frame, at: time) else { return }

        let generation: UUID
        stateLock.lock()
        generation = scanGeneration
        stateLock.unlock()

        snapshotQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.makeSnapshot(from: frame, requireNormalTracking: true)
            self.stateLock.lock()
            if let snapshot,
               self.scanGeneration == generation,
               (self.isScanning || self.isExporting) {
                self.storeSnapshot(snapshot)
            }
            if self.scanGeneration == generation {
                self.snapshotCaptureScheduled = false
            }
            self.stateLock.unlock()
        }
    }

    private func reserveSnapshotCapture(for frame: ARFrame, at time: TimeInterval) -> Bool {
        guard case .normal = frame.camera.trackingState else { return false }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard isScanning, !snapshotCaptureScheduled else { return false }

        let thermalInterval: TimeInterval
        switch ProcessInfo.processInfo.thermalState {
        case .serious: thermalInterval = snapshotInterval * 1.5
        case .critical: thermalInterval = snapshotInterval * 2.5
        default: thermalInterval = snapshotInterval
        }
        guard time - lastSnapshotTime >= thermalInterval else { return false }

        if let previous = lastSnapshotTransform {
            let movement = Self.poseDifference(previous, frame.camera.transform)
            guard movement.translation >= minimumSnapshotTranslation ||
                    movement.rotation >= minimumSnapshotRotation else { return false }
        }

        lastSnapshotTime = time
        lastSnapshotTransform = frame.camera.transform
        snapshotCaptureScheduled = true
        return true
    }

    private func makeSnapshot(from frame: ARFrame, requireNormalTracking: Bool) -> CameraSnapshot? {
        if requireNormalTracking {
            guard case .normal = frame.camera.trackingState else { return nil }
        }

        return autoreleasepool {
            let pixelBuffer = frame.capturedImage
            let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            guard sourceWidth > 0, sourceHeight > 0 else { return nil }

            let scale = min(1.0, snapshotMaxDimension / max(sourceWidth, sourceHeight))
            let targetWidth = max(1, Int((sourceWidth * scale).rounded()))
            let targetHeight = max(1, Int((sourceHeight * scale).rounded()))
            let scaleX = CGFloat(targetWidth) / sourceWidth
            let scaleY = CGFloat(targetHeight) / sourceHeight
            let image = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            guard let cgImage = ciContext.createCGImage(image, from: image.extent),
                  let imageData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.86) else {
                return nil
            }

            let intrinsics = frame.camera.intrinsics
            return CameraSnapshot(
                imageData: imageData,
                cameraTransform: frame.camera.transform,
                fx: intrinsics[0][0] * Float(scaleX),
                fy: intrinsics[1][1] * Float(scaleY),
                cx: intrinsics[2][0] * Float(scaleX),
                cy: intrinsics[2][1] * Float(scaleY),
                imageWidth: targetWidth,
                imageHeight: targetHeight
            )
        }
    }

    // Must be called while stateLock is held. Once full, replace the most
    // redundant camera pose so late parts of a long scan still receive texture.
    private func storeSnapshot(_ snapshot: CameraSnapshot) {
        guard globalSnapshots.count >= maxSnapshots else {
            globalSnapshots.append(snapshot)
            return
        }

        let newNearest = globalSnapshots
            .map { Self.poseDistance($0.cameraTransform, snapshot.cameraTransform) }
            .min() ?? 0

        var redundantIndex = 0
        var redundantDistance = Float.greatestFiniteMagnitude
        for index in globalSnapshots.indices {
            var nearest = Float.greatestFiniteMagnitude
            for otherIndex in globalSnapshots.indices where otherIndex != index {
                nearest = min(nearest, Self.poseDistance(
                    globalSnapshots[index].cameraTransform,
                    globalSnapshots[otherIndex].cameraTransform
                ))
            }
            if nearest < redundantDistance {
                redundantDistance = nearest
                redundantIndex = index
            }
        }

        if newNearest > redundantDistance * 1.1 {
            globalSnapshots[redundantIndex] = snapshot
        }
    }

    private static func poseDifference(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> (translation: Float, rotation: Float) {
        let lhsPosition = SIMD3<Float>(lhs.columns.3.x, lhs.columns.3.y, lhs.columns.3.z)
        let rhsPosition = SIMD3<Float>(rhs.columns.3.x, rhs.columns.3.y, rhs.columns.3.z)
        let lhsForward = simd_normalize(-SIMD3<Float>(lhs.columns.2.x, lhs.columns.2.y, lhs.columns.2.z))
        let rhsForward = simd_normalize(-SIMD3<Float>(rhs.columns.2.x, rhs.columns.2.y, rhs.columns.2.z))
        let cosine = max(-1, min(1, simd_dot(lhsForward, rhsForward)))
        return (simd_distance(lhsPosition, rhsPosition), acos(cosine))
    }

    private static func poseDistance(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> Float {
        let difference = poseDifference(lhs, rhs)
        return difference.translation + difference.rotation * 0.35
    }

    // MARK: - 可视化几何体（实时预览用，轻量）

    private func createVisualizationGeometry(from mesh: ARMeshGeometry) -> SCNGeometry {
        let vSrc = SCNGeometrySource(buffer: mesh.vertices.buffer, vertexFormat: mesh.vertices.format,
                                      semantic: .vertex, vertexCount: mesh.vertices.count,
                                      dataOffset: mesh.vertices.offset, dataStride: mesh.vertices.stride)
        let nSrc = SCNGeometrySource(buffer: mesh.normals.buffer, vertexFormat: mesh.normals.format,
                                      semantic: .normal, vertexCount: mesh.normals.count,
                                      dataOffset: mesh.normals.offset, dataStride: mesh.normals.stride)
        let indexByteCount = mesh.faces.count * mesh.faces.indexCountPerPrimitive * mesh.faces.bytesPerIndex
        let fData = Data(bytes: mesh.faces.buffer.contents(), count: indexByteCount)
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

        let anchors: [ARMeshAnchor]
        let generation: UUID
        stateLock.lock()
        guard isScanning, !isExporting else {
            stateLock.unlock()
            return nil
        }
        isScanning = false
        isExporting = true
        anchors = Array(meshAnchors.values)
        generation = scanGeneration
        stateLock.unlock()

        sceneView.session.pause()
        sceneView.isPlaying = false
        sceneView.delegate = nil

        // This task waits for an in-flight keyframe compression on the same serial
        // queue, then adds the final camera pose before taking an immutable export copy.
        snapshotQueue.async { [self] in
            let finalSnapshot = makeSnapshot(from: frame, requireNormalTracking: false)

            stateLock.lock()
            if let finalSnapshot, scanGeneration == generation {
                storeSnapshot(finalSnapshot)
            }
            let snapshots = globalSnapshots
            globalSnapshots.removeAll()
            meshAnchors.removeAll()
            lastGeometryUpdate.removeAll()
            snapshotCaptureScheduled = false
            isExporting = false
            scanGeneration = UUID()
            stateLock.unlock()

            print("📋 导出: \(anchors.count) 个网格, \(snapshots.count) 个快照")

            exportQueue.async {
                do {
                    try Self.exportScene(to: fileURL, anchors: anchors, snapshots: snapshots)
                    Self.completePendingResult(["path": fileURL.path, "msg": "success"])
                } catch {
                    print("❌ 导出失败: \(error)")
                    Self.completePendingResult([
                        "path": "",
                        "msg": "导出失败: \(error.localizedDescription)"
                    ])
                }
            }
        }
        return fileURL
    }

    func cancelScanning() {
        sceneView.session.pause()
        sceneView.isPlaying = false
        sceneView.delegate = nil
        sceneView.scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }

        var shouldCompleteCancellation = false
        stateLock.lock()
        if isScanning && !isExporting {
            shouldCompleteCancellation = true
            isScanning = false
            scanGeneration = UUID()
            meshAnchors.removeAll()
            lastGeometryUpdate.removeAll()
            globalSnapshots.removeAll()
        }
        stateLock.unlock()

        if shouldCompleteCancellation {
            Self.completePendingResult(["path": NSNull(), "msg": "已取消"])
        }
    }

    private static func completePendingResult(_ payload: [String: Any]) {
        DispatchQueue.main.async {
            let result = ObjectScannerPlugin.pendingResult
            ObjectScannerPlugin.pendingResult = nil
            result?(payload)
        }
    }

    private static func exportScene(to url: URL, anchors: [ARMeshAnchor], snapshots: [CameraSnapshot]) throws {
        guard #available(iOS 14.0, *) else {
            throw NSError(domain: "SpaceScanner", code: 2, userInfo: [NSLocalizedDescriptionKey: "需要 iOS 14.0+"])
        }
        guard !anchors.isEmpty else {
            throw NSError(domain: "SpaceScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有网格数据"])
        }

        // 预计算所有快照的投影器（只算一次 simd_inverse）
        let projectors = snapshots.map { SnapProjector($0) }
        let snapshotMaterials: [SCNMaterial?] = snapshots.map { snapshot in
            guard let image = UIImage(data: snapshot.imageData) else { return nil }
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.isDoubleSided = true
            material.metalness.contents = 0.0
            material.roughness.contents = 1.0
            material.diffuse.contents = image
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            material.diffuse.magnificationFilter = .linear
            material.diffuse.minificationFilter = .linear
            material.diffuse.mipFilter = .linear
            material.diffuse.maxAnisotropy = 8
            return material
        }
        let grayMaterial = SCNMaterial()
        grayMaterial.lightingModel = .physicallyBased
        grayMaterial.isDoubleSided = true
        grayMaterial.diffuse.contents = UIColor(white: 0.65, alpha: 1.0)

        let scene = SCNScene()
        let rootNode = SCNNode()
        rootNode.name = "RootNode"

        var totalTexturedFaces = 0
        var totalGrayFaces = 0

        for meshAnchor in anchors {
            let node = createTexturedNode(
                from: meshAnchor,
                projectors: projectors,
                snapshotMaterials: snapshotMaterials,
                grayMaterial: grayMaterial,
                texturedFaces: &totalTexturedFaces,
                grayFaces: &totalGrayFaces
            )
            rootNode.addChildNode(node)
        }

        scene.rootNode.addChildNode(rootNode)

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
    private static func createTexturedNode(from meshAnchor: ARMeshAnchor,
                                           projectors: [SnapProjector],
                                           snapshotMaterials: [SCNMaterial?],
                                           grayMaterial: SCNMaterial,
                                           texturedFaces: inout Int,
                                           grayFaces: inout Int) -> SCNNode {
        let mesh = meshAnchor.geometry
        let transform = meshAnchor.transform
        let vertexCount = min(mesh.vertices.count, mesh.normals.count)
        guard vertexCount > 0,
              mesh.faces.indexCountPerPrimitive == 3,
              mesh.faces.bytesPerIndex == 2 || mesh.faces.bytesPerIndex == 4 else {
            return SCNNode(geometry: SCNGeometry())
        }

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

        // 对原始 LiDAR 顶点做限幅 Taubin 平滑。边界点只沿边界移动，内部点
        // 只参考法线接近的邻点，因此不会把墙角抹圆，也不会明显收缩模型。
        worldVerts = smoothMeshVertices(
            positions: worldVerts,
            normals: worldNormals,
            indices: origIndices
        )

        // 3) 计算每个面的几何信息，并从全部快照中选择最佳纹理。
        var faceCenters = [SIMD3<Float>](repeating: .zero, count: faceCount)
        var faceNormals = [SIMD3<Float>](repeating: .zero, count: faceCount)
        var validFaces = [Bool](repeating: false, count: faceCount)
        var faceAssignment = [Int](repeating: -2, count: faceCount)
        var faceBestScores = [Float](repeating: 0, count: faceCount)

        func projectionScore(face: Int, snapshot: Int) -> Float {
            guard validFaces[face], snapshotMaterials[snapshot] != nil else { return 0 }

            let i0 = Int(origIndices[face * 3])
            let i1 = Int(origIndices[face * 3 + 1])
            let i2 = Int(origIndices[face * 3 + 2])
            let wp0 = worldVerts[i0]
            let wp1 = worldVerts[i1]
            let wp2 = worldVerts[i2]
            let proj = projectors[snapshot]

            let cameraOffset = proj.camPosition - faceCenters[face]
            let cameraDistance = simd_length(cameraOffset)
            guard cameraDistance > 0.05 else { return 0 }
            let facing = abs(simd_dot(faceNormals[face], cameraOffset / cameraDistance))
            guard facing >= 0.18,
                  let p0 = proj.project(wp0),
                  let p1 = proj.project(wp1),
                  let p2 = proj.project(wp2) else { return 0 }

            let halfW = proj.imgW * 0.5
            let halfH = proj.imgH * 0.5
            func centerScore(_ point: (Float, Float)) -> Float {
                let dx = (point.0 - halfW) / halfW
                let dy = (point.1 - halfH) / halfH
                return max(0, 1.0 - sqrt(dx * dx + dy * dy) * 0.5)
            }

            let framingScore = (centerScore(p0) + centerScore(p1) + centerScore(p2)) / 3.0
            let distanceScore = 1.0 / (1.0 + max(0, cameraDistance - 0.4) * 0.12)
            return facing * facing * framingScore * distanceScore
        }

        for f in 0..<faceCount {
            let i0 = Int(origIndices[f * 3])
            let i1 = Int(origIndices[f * 3 + 1])
            let i2 = Int(origIndices[f * 3 + 2])
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }

            let wp0 = worldVerts[i0]
            let wp1 = worldVerts[i1]
            let wp2 = worldVerts[i2]

            // 面法线
            let edge1 = wp1 - wp0
            let edge2 = wp2 - wp0
            let crossProduct = simd_cross(edge1, edge2)
            let len = simd_length(crossProduct)
            guard len > 1e-8 else { continue } // 退化三角形
            let averagedNormal = worldNormals[i0] + worldNormals[i1] + worldNormals[i2]
            let averagedNormalLength = simd_length(averagedNormal)
            let faceNormal = averagedNormalLength > 1e-6
                ? averagedNormal / averagedNormalLength
                : crossProduct / len
            faceCenters[f] = (wp0 + wp1 + wp2) / 3.0
            faceNormals[f] = faceNormal
            validFaces[f] = true

            var bestSnapIdx = -1
            var bestScore: Float = 0

            for si in 0..<projectors.count {
                let score = projectionScore(face: f, snapshot: si)
                if score > bestScore {
                    bestScore = score
                    bestSnapIdx = si
                }
            }

            faceAssignment[f] = bestSnapIdx
            faceBestScores[f] = bestScore
        }
        let initialTextureCount = Set(faceAssignment.filter { $0 >= 0 }).count

        // 4) 通过共享边建立面邻接关系，再做连续化。只有法线接近且候选
        // 纹理质量没有明显下降时才传播标签，避免跨墙角涂抹纹理。
        var faceNeighbors = [[Int]](repeating: [], count: faceCount)
        var edgeOwners: [MeshEdge: Int] = [:]
        edgeOwners.reserveCapacity(faceCount * 2)

        for face in 0..<faceCount where validFaces[face] {
            let i0 = origIndices[face * 3]
            let i1 = origIndices[face * 3 + 1]
            let i2 = origIndices[face * 3 + 2]
            for edge in [MeshEdge(i0, i1), MeshEdge(i1, i2), MeshEdge(i2, i0)] {
                if let neighbor = edgeOwners[edge] {
                    faceNeighbors[face].append(neighbor)
                    faceNeighbors[neighbor].append(face)
                } else {
                    edgeOwners[edge] = face
                }
            }
        }

        for _ in 0..<4 {
            let previousAssignments = faceAssignment
            var didChange = false

            for face in 0..<faceCount where validFaces[face] && faceBestScores[face] > 0 {
                let compatibleNeighbors = faceNeighbors[face].filter {
                    abs(simd_dot(faceNormals[face], faceNormals[$0])) >= 0.8
                }
                guard !compatibleNeighbors.isEmpty else { continue }

                var candidates = [previousAssignments[face]]
                for neighbor in compatibleNeighbors {
                    let label = previousAssignments[neighbor]
                    if label >= 0, !candidates.contains(label) {
                        candidates.append(label)
                    }
                }

                var selectedLabel = previousAssignments[face]
                var selectedScore = -Float.greatestFiniteMagnitude
                for label in candidates where label >= 0 {
                    let dataScore = projectionScore(face: face, snapshot: label)
                    guard dataScore >= faceBestScores[face] * 0.55 else { continue }

                    let matchingNeighbors = compatibleNeighbors.reduce(into: 0) { count, neighbor in
                        if previousAssignments[neighbor] == label { count += 1 }
                    }
                    let continuity = Float(matchingNeighbors) / Float(compatibleNeighbors.count)
                    let combinedScore = dataScore / faceBestScores[face] + continuity * 0.85
                    if combinedScore > selectedScore {
                        selectedScore = combinedScore
                        selectedLabel = label
                    }
                }

                if selectedLabel != previousAssignments[face] {
                    faceAssignment[face] = selectedLabel
                    didChange = true
                }
            }

            if !didChange { break }
        }

        // 对连续平面做更强的主纹理归并。大平面优先使用覆盖面数最多的
        // 关键帧，次选帧只负责主帧确实看不到的区域，避免三角形马赛克。
        var visitedFaces = [Bool](repeating: false, count: faceCount)
        for seed in 0..<faceCount where validFaces[seed] && !visitedFaces[seed] {
            var component: [Int] = []
            var queue = [seed]
            visitedFaces[seed] = true
            var cursor = 0

            while cursor < queue.count {
                let face = queue[cursor]
                cursor += 1
                component.append(face)

                for neighbor in faceNeighbors[face]
                where validFaces[neighbor] && !visitedFaces[neighbor] &&
                      abs(simd_dot(faceNormals[face], faceNormals[neighbor])) >= 0.9 {
                    visitedFaces[neighbor] = true
                    queue.append(neighbor)
                }
            }

            guard component.count >= 6 else { continue }
            var labelCounts: [Int: Int] = [:]
            for face in component where faceAssignment[face] >= 0 {
                labelCounts[faceAssignment[face], default: 0] += 1
            }
            let dominantLabels = labelCounts
                .sorted { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
                }
                .prefix(3)
                .map(\.key)

            guard !dominantLabels.isEmpty else { continue }
            for face in component where faceBestScores[face] > 0 {
                for (rank, label) in dominantLabels.enumerated() {
                    let score = projectionScore(face: face, snapshot: label)
                    let minimumRatio: Float = rank == 0 ? 0.58 : 0.68
                    if score >= faceBestScores[face] * minimumRatio {
                        faceAssignment[face] = label
                        break
                    }
                }
            }
        }

        let finalTextureCount = Set(faceAssignment.filter { $0 >= 0 }).count
        print(
            "🧩 网格 \(meshAnchor.identifier.uuidString.prefix(8)) 纹理连续化: " +
            "\(initialTextureCount) → \(finalTextureCount) 个纹理帧"
        )

        // 5) 按快照分组
        var snapFaces = [Int: [Int]]()  // snapIndex -> [faceIndex]
        var grayFaceList = [Int]()

        for f in 0..<faceCount {
            let si = faceAssignment[f]
            if si >= 0 {
                snapFaces[si, default: []].append(f)
            } else if si == -1 {
                grayFaceList.append(f)
            }
        }

        // 6) 构建几何体：每个快照一个 element + material
        var allVerts = [SCNVector3]()
        var allNormals = [SCNVector3]()
        var allUVs = [CGPoint]()
        var elements = [SCNGeometryElement]()
        var materials = [SCNMaterial]()
        allVerts.reserveCapacity(faceCount * 3)
        allNormals.reserveCapacity(faceCount * 3)
        allUVs.reserveCapacity(faceCount * 3)

        // 有纹理的面
        for (si, faces) in snapFaces {
            guard let material = snapshotMaterials[si] else { continue }
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
            materials.append(material)

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
            materials.append(grayMaterial)

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

    private static func smoothMeshVertices(positions: [SIMD3<Float>],
                                           normals: [SIMD3<Float>],
                                           indices: [UInt32]) -> [SIMD3<Float>] {
        guard positions.count == normals.count, indices.count >= 3 else { return positions }

        var edgeUseCounts: [MeshEdge: Int] = [:]
        edgeUseCounts.reserveCapacity(indices.count)
        for index in stride(from: 0, to: indices.count - 2, by: 3) {
            let edges = [
                MeshEdge(indices[index], indices[index + 1]),
                MeshEdge(indices[index + 1], indices[index + 2]),
                MeshEdge(indices[index + 2], indices[index])
            ]
            for edge in edges {
                edgeUseCounts[edge, default: 0] += 1
            }
        }

        var neighbors = [[Int]](repeating: [], count: positions.count)
        var boundaryNeighbors = [[Int]](repeating: [], count: positions.count)
        for (edge, useCount) in edgeUseCounts {
            let first = Int(edge.first)
            let second = Int(edge.second)
            guard first < positions.count, second < positions.count else { continue }
            neighbors[first].append(second)
            neighbors[second].append(first)
            if useCount == 1 {
                boundaryNeighbors[first].append(second)
                boundaryNeighbors[second].append(first)
            }
        }

        func smoothingPass(_ source: [SIMD3<Float>], factor: Float) -> [SIMD3<Float>] {
            var result = source
            for vertex in source.indices {
                let candidates = boundaryNeighbors[vertex].isEmpty
                    ? neighbors[vertex]
                    : boundaryNeighbors[vertex]
                guard !candidates.isEmpty else { continue }

                var average = SIMD3<Float>.zero
                var count: Float = 0
                for neighbor in candidates
                where abs(simd_dot(normals[vertex], normals[neighbor])) >= 0.82 {
                    average += source[neighbor]
                    count += 1
                }
                guard count > 0 else { continue }

                var delta = average / count - source[vertex]
                let distance = simd_length(delta)
                let maximumStep: Float = boundaryNeighbors[vertex].isEmpty ? 0.015 : 0.01
                if distance > maximumStep {
                    delta *= maximumStep / distance
                }
                result[vertex] = source[vertex] + delta * factor
            }
            return result
        }

        var smoothed = positions
        for _ in 0..<2 {
            smoothed = smoothingPass(smoothed, factor: 0.45)
            smoothed = smoothingPass(smoothed, factor: -0.47)
        }
        return smoothed
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

            VStack {
                HStack {
                    Button(action: {
                        viewModel.cancelScanning()
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(L10n.cancel)
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

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
        .onDisappear { viewModel.cancelScanning() }
    }
}

@available(iOS 14.0, *)
struct ARViewContainer: UIViewRepresentable {
    let sceneView: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { return sceneView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.session.pause()
        uiView.isPlaying = false
        uiView.delegate = nil
    }
}
