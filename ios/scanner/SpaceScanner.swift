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
    let depthValues: [Float16]?
    let depthConfidence: [UInt8]?
    let depthWidth: Int, depthHeight: Int
}

private struct SnapshotDepth {
    let values: [Float16]
    let confidence: [UInt8]?
    let width: Int
    let height: Int
}

private struct ProjectedPoint {
    let x: Float
    let y: Float
    let depth: Float
}

private struct TextureSurfaceSample {
    let center: SIMD3<Float>
    let normal: SIMD3<Float>
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
    let depthValues: [Float16]?
    let depthConfidence: [UInt8]?
    let depthWidth: Int, depthHeight: Int

    var hasDepth: Bool {
        guard depthWidth > 0, depthHeight > 0, let depthValues else { return false }
        return depthValues.count == depthWidth * depthHeight
    }

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
        depthValues = snap.depthValues
        depthConfidence = snap.depthConfidence
        depthWidth = snap.depthWidth
        depthHeight = snap.depthHeight
    }

    func projectedPoint(_ worldPos: SIMD3<Float>) -> ProjectedPoint? {
        let camPt = simd_mul(camInverse, SIMD4<Float>(worldPos, 1.0))
        guard camPt.z < -0.1 else { return nil }
        let depth = -camPt.z
        let px = (camPt.x / depth) * fx + cx
        let py = (camPt.y / depth) * fy + cy
        guard px >= marginX && px < imgW - marginX &&
              py >= marginY && py < imgH - marginY else { return nil }
        return ProjectedPoint(x: px, y: py, depth: depth)
    }

    /// 投影一个世界坐标点，返回图像像素坐标；构建 UV 时使用。
    func project(_ worldPos: SIMD3<Float>) -> (Float, Float)? {
        guard let point = projectedPoint(worldPos) else { return nil }
        return (point.x, point.y)
    }

    /// 使用深度图中 3x3 邻域的中位数，降低 LiDAR 单像素噪声和物体边缘抖动。
    private func observedDepth(at point: ProjectedPoint) -> Float? {
        guard hasDepth, let depthValues else { return nil }
        let centerX = min(max(Int(point.x / imgW * Float(depthWidth)), 0), depthWidth - 1)
        let centerY = min(max(Int(point.y / imgH * Float(depthHeight)), 0), depthHeight - 1)

        func samples(minimumConfidence: UInt8?) -> [Float] {
            var result: [Float] = []
            result.reserveCapacity(9)
            for y in max(0, centerY - 1)...min(depthHeight - 1, centerY + 1) {
                for x in max(0, centerX - 1)...min(depthWidth - 1, centerX + 1) {
                    let index = y * depthWidth + x
                    if let minimumConfidence,
                       let depthConfidence,
                       depthConfidence.count == depthValues.count,
                       depthConfidence[index] < minimumConfidence {
                        continue
                    }
                    let value = Float(depthValues[index])
                    if value.isFinite, value > 0.08, value < 12 {
                        result.append(value)
                    }
                }
            }
            return result
        }

        var values = samples(minimumConfidence: 1)
        if values.isEmpty { values = samples(minimumConfidence: nil) }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    func depthVisibilityScore(_ point: ProjectedPoint) -> Float {
        guard let measuredDepth = observedDepth(at: point) else { return 1 }
        // ARKit 的最终网格与拍摄瞬间的深度图存在少量时序误差。使用双向
        // 容差拦截明显错层，同时给稳定表面留出足够的纹理覆盖空间。
        let tolerance = max(0.04, measuredDepth * 0.02)
        let difference = abs(point.depth - measuredDepth)
        guard difference <= tolerance else { return 0 }
        return max(0.1, 1.0 - difference / tolerance)
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

    private let snapshotInterval: TimeInterval = 0.75
    private let maxSnapshots = 24
    private let snapshotMaxDimension: CGFloat = 1280
    private let minimumSnapshotTranslation: Float = 0.14
    private let minimumSnapshotRotation: Float = 11.0 * .pi / 180.0
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
        config.sceneReconstruction = .mesh
        // 深度图用于导出阶段的遮挡判断，避免前景物体纹理穿透到后方表面。
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = .sceneDepth
        }
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
            let depth = Self.captureDepth(from: frame)

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
                imageHeight: targetHeight,
                depthValues: depth?.values,
                depthConfidence: depth?.confidence,
                depthWidth: depth?.width ?? 0,
                depthHeight: depth?.height ?? 0
            )
        }
    }

    private static func captureDepth(from frame: ARFrame) -> SnapshotDepth? {
        guard let depthData = frame.sceneDepth ?? frame.smoothedSceneDepth else { return nil }
        let depthMap = depthData.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let rowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let source = baseAddress.assumingMemoryBound(to: Float32.self)
        var values = [Float16](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceRow = source.advanced(by: y * rowStride)
            let targetOffset = y * width
            for x in 0..<width {
                let value = sourceRow[x]
                if value.isFinite, value > 0.08, value < 12 {
                    values[targetOffset + x] = Float16(value)
                }
            }
        }

        var confidence: [UInt8]? = nil
        if let confidenceMap = depthData.confidenceMap,
           CVPixelBufferGetWidth(confidenceMap) == width,
           CVPixelBufferGetHeight(confidenceMap) == height,
           CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) == kCVReturnSuccess {
            defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            if let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap) {
                let confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
                let sourceConfidence = confidenceBase.assumingMemoryBound(to: UInt8.self)
                var copied = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    let row = sourceConfidence.advanced(by: y * confidenceStride)
                    copied.replaceSubrange((y * width)..<((y + 1) * width), with: UnsafeBufferPointer(
                        start: row,
                        count: width
                    ))
                }
                confidence = copied
            }
        }

        return SnapshotDepth(values: values, confidence: confidence, width: width, height: height)
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

        // 先按整个场景的可见覆盖率筛选少量共同关键帧。所有 ARMeshAnchor
        // 共用这组候选，避免每个网格块各选各的照片。
        let allProjectors = snapshots.map { SnapProjector($0) }
        let selectedSnapshotIndices = selectTextureSnapshotIndices(
            anchors: anchors,
            projectors: allProjectors,
            maximumCount: 16
        )
        let selectedSnapshots = selectedSnapshotIndices.map { snapshots[$0] }
        let projectors = selectedSnapshotIndices.map { allProjectors[$0] }
        let depthSnapshotCount = projectors.reduce(into: 0) { count, projector in
            if projector.hasDepth { count += 1 }
        }
        print("🎞️ 纹理关键帧: \(snapshots.count) → \(projectors.count)")
        print("📐 深度快照: \(depthSnapshotCount)/\(projectors.count)")
        let snapshotMaterials: [SCNMaterial?] = selectedSnapshots.map { snapshot in
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
        let scene = SCNScene()
        let rootNode = SCNNode()
        rootNode.name = "RootNode"

        var totalTexturedFaces = 0
        var totalHiddenFaces = 0

        for meshAnchor in anchors {
            let node = createTexturedNode(
                from: meshAnchor,
                projectors: projectors,
                snapshotMaterials: snapshotMaterials,
                texturedFaces: &totalTexturedFaces,
                hiddenFaces: &totalHiddenFaces
            )
            rootNode.addChildNode(node)
        }

        scene.rootNode.addChildNode(rootNode)

        print("📦 有纹理: \(totalTexturedFaces) 面, 已隐藏: \(totalHiddenFaces) 面")

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

    private static func selectTextureSnapshotIndices(anchors: [ARMeshAnchor],
                                                     projectors: [SnapProjector],
                                                     maximumCount: Int) -> [Int] {
        guard !projectors.isEmpty else { return [] }
        guard projectors.count > maximumCount else { return Array(projectors.indices) }

        let samples = textureSurfaceSamples(from: anchors)
        guard !samples.isEmpty else {
            return evenlySpacedSnapshotIndices(count: projectors.count, maximumCount: maximumCount)
        }

        var scores = [[Float]](
            repeating: [Float](repeating: 0, count: samples.count),
            count: projectors.count
        )
        for snapshot in projectors.indices {
            let projector = projectors[snapshot]
            let halfWidth = projector.imgW * 0.5
            let halfHeight = projector.imgH * 0.5

            for sampleIndex in samples.indices {
                let sample = samples[sampleIndex]
                let cameraOffset = projector.camPosition - sample.center
                let distance = simd_length(cameraOffset)
                guard distance > 0.05 else { continue }

                let facing = simd_dot(sample.normal, cameraOffset / distance)
                guard facing >= 0.2,
                      let point = projector.projectedPoint(sample.center) else { continue }

                let depthScore = projector.hasDepth
                    ? projector.depthVisibilityScore(point)
                    : 1
                guard depthScore > 0 else { continue }

                let dx = (point.x - halfWidth) / halfWidth
                let dy = (point.y - halfHeight) / halfHeight
                let framing = max(0, 1.0 - sqrt(dx * dx + dy * dy) * 0.5)
                scores[snapshot][sampleIndex] = facing * facing * framing * depthScore
            }
        }

        var selected: [Int] = []
        var currentCoverage = [Float](repeating: 0, count: samples.count)
        while selected.count < maximumCount {
            var bestSnapshot = -1
            var bestGain: Float = 0

            for snapshot in projectors.indices where !selected.contains(snapshot) {
                var gain: Float = 0
                for sample in samples.indices {
                    gain += max(0, scores[snapshot][sample] - currentCoverage[sample])
                }
                if gain > bestGain {
                    bestGain = gain
                    bestSnapshot = snapshot
                }
            }

            guard bestSnapshot >= 0, bestGain > 0.001 else { break }
            selected.append(bestSnapshot)
            for sample in samples.indices {
                currentCoverage[sample] = max(
                    currentCoverage[sample],
                    scores[bestSnapshot][sample]
                )
            }
        }

        return selected.isEmpty
            ? evenlySpacedSnapshotIndices(count: projectors.count, maximumCount: maximumCount)
            : selected
    }

    private static func evenlySpacedSnapshotIndices(count: Int, maximumCount: Int) -> [Int] {
        guard count > 0, maximumCount > 0 else { return [] }
        guard count > maximumCount else { return Array(0..<count) }
        guard maximumCount > 1 else { return [count - 1] }

        return (0..<maximumCount).map { index in
            Int((Double(index) * Double(count - 1) / Double(maximumCount - 1)).rounded())
        }
    }

    private static func textureSurfaceSamples(from anchors: [ARMeshAnchor]) -> [TextureSurfaceSample] {
        var samples: [TextureSurfaceSample] = []

        for anchor in anchors {
            let mesh = anchor.geometry
            let vertexCount = mesh.vertices.count
            let faceCount = mesh.faces.count
            guard vertexCount > 0,
                  faceCount > 0,
                  mesh.faces.indexCountPerPrimitive == 3,
                  mesh.faces.bytesPerIndex == 2 || mesh.faces.bytesPerIndex == 4 else { continue }

            let transform = anchor.transform
            let vertexBase = mesh.vertices.buffer.contents().advanced(by: mesh.vertices.offset)
            let faceBase = mesh.faces.buffer.contents()
            let sampleStep = max(1, faceCount / 220)

            func vertex(at index: Int) -> SIMD3<Float>? {
                guard index >= 0, index < vertexCount else { return nil }
                let local = vertexBase
                    .advanced(by: index * mesh.vertices.stride)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                    .pointee
                let world = transform * SIMD4<Float>(local, 1)
                return SIMD3<Float>(world.x, world.y, world.z)
            }

            for face in stride(from: 0, to: faceCount, by: sampleStep) {
                let baseIndex = face * 3
                let indices: (Int, Int, Int)
                if mesh.faces.bytesPerIndex == 2 {
                    let pointer = faceBase.assumingMemoryBound(to: UInt16.self)
                    indices = (
                        Int(pointer[baseIndex]),
                        Int(pointer[baseIndex + 1]),
                        Int(pointer[baseIndex + 2])
                    )
                } else {
                    let pointer = faceBase.assumingMemoryBound(to: UInt32.self)
                    indices = (
                        Int(pointer[baseIndex]),
                        Int(pointer[baseIndex + 1]),
                        Int(pointer[baseIndex + 2])
                    )
                }

                guard let first = vertex(at: indices.0),
                      let second = vertex(at: indices.1),
                      let third = vertex(at: indices.2) else { continue }
                let crossProduct = simd_cross(second - first, third - first)
                let length = simd_length(crossProduct)
                guard length > 1e-8 else { continue }

                samples.append(TextureSurfaceSample(
                    center: (first + second + third) / 3,
                    normal: crossProduct / length
                ))
            }
        }

        return samples
    }

    // MARK: - 核心：为每个面搜索全部快照，选最佳的

    @available(iOS 14.0, *)
    private static func createTexturedNode(from meshAnchor: ARMeshAnchor,
                                           projectors: [SnapProjector],
                                           snapshotMaterials: [SCNMaterial?],
                                           texturedFaces: inout Int,
                                           hiddenFaces: inout Int) -> SCNNode {
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
            let facing = simd_dot(faceNormals[face], cameraOffset / cameraDistance)
            guard facing >= 0.18,
                  let p0 = proj.projectedPoint(wp0),
                  let p1 = proj.projectedPoint(wp1),
                  let p2 = proj.projectedPoint(wp2),
                  let center = proj.projectedPoint(faceCenters[face]) else { return 0 }

            var depthScore: Float = 1
            if proj.hasDepth {
                let centerDepthScore = proj.depthVisibilityScore(center)
                guard centerDepthScore > 0 else { return 0 }
                let vertexDepthScores = [p0, p1, p2].map(proj.depthVisibilityScore)
                let visibleVertexCount = vertexDepthScores.filter { $0 > 0 }.count
                guard visibleVertexCount >= 2 else { return 0 }
                depthScore = (centerDepthScore * 2 + vertexDepthScores.reduce(0, +)) / 5
            }

            let halfW = proj.imgW * 0.5
            let halfH = proj.imgH * 0.5
            func centerScore(_ point: ProjectedPoint) -> Float {
                let dx = (point.x - halfW) / halfW
                let dy = (point.y - halfH) / halfH
                return max(0, 1.0 - sqrt(dx * dx + dy * dy) * 0.5)
            }

            let framingScore = (centerScore(p0) + centerScore(p1) + centerScore(p2)) / 3.0
            let distanceScore = 1.0 / (1.0 + max(0, cameraDistance - 0.4) * 0.12)
            return facing * facing * framingScore * distanceScore * (0.5 + depthScore * 0.5)
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
            // 使用三角形绕序确定朝向。不能取绝对值，否则背面的照片也会
            // 被投到当前面上，薄物体和显示器附近最容易出现重复影像。
            let faceNormal = crossProduct / len
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
        let bestFaceAssignments = faceAssignment

        // 4) 通过共享边建立面邻接关系。纹理必须按连续表面选择，不能让
        // 每个三角形独立挑照片，否则轻微的网格误差会被放大成重复影像。
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

        // 每个连续表面优先使用少量主视图。主视图无法覆盖时，退回该面
        // 自己经过深度校验的最佳帧，避免为了消除接缝而制造大片灰面。
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
                      simd_dot(faceNormals[face], faceNormals[neighbor]) >= 0.72 {
                    visitedFaces[neighbor] = true
                    queue.append(neighbor)
                }
            }

            guard component.count >= 4 else { continue }
            var labelCounts: [Int: Int] = [:]
            for face in component where faceAssignment[face] >= 0 {
                labelCounts[faceAssignment[face], default: 0] += 1
            }
            let candidateLabels = labelCounts
                .sorted { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
                }
                .prefix(12)
                .map(\.key)

            var labelSupports: [(label: Int, support: Float)] = []
            labelSupports.reserveCapacity(candidateLabels.count)
            for label in candidateLabels {
                var support: Float = 0
                for face in component where faceBestScores[face] > 0 {
                    let score = projectionScore(face: face, snapshot: label)
                    if score > 0 {
                        let relativeScore = score / faceBestScores[face]
                        support += min(Float(1), relativeScore)
                    }
                }
                labelSupports.append((label: label, support: support))
            }
            labelSupports.sort { lhs, rhs in
                lhs.support == rhs.support ? lhs.label < rhs.label : lhs.support > rhs.support
            }
            let dominantLabels = labelSupports.prefix(4).map { $0.label }

            guard !dominantLabels.isEmpty else { continue }
            let minimumRatios: [Float] = [0.28, 0.36, 0.44, 0.52]
            for face in component where faceBestScores[face] > 0 {
                var selectedLabel: Int? = nil
                for (rank, label) in dominantLabels.enumerated() {
                    let score = projectionScore(face: face, snapshot: label)
                    if score >= faceBestScores[face] * minimumRatios[rank] {
                        selectedLabel = label
                        break
                    }
                }
                faceAssignment[face] = selectedLabel ?? bestFaceAssignments[face]
            }
        }

        // 让主视图沿着连续表面传播，并清除孤立的小纹理岛。
        for _ in 0..<6 {
            let previousAssignments = faceAssignment
            var didChange = false

            for face in 0..<faceCount where validFaces[face] && faceBestScores[face] > 0 {
                let compatibleNeighbors = faceNeighbors[face].filter {
                    simd_dot(faceNormals[face], faceNormals[$0]) >= 0.72
                }
                guard !compatibleNeighbors.isEmpty else { continue }

                var candidates: [Int] = []
                let currentLabel = previousAssignments[face]
                if currentLabel >= 0 { candidates.append(currentLabel) }
                for neighbor in compatibleNeighbors {
                    let label = previousAssignments[neighbor]
                    if label >= 0, !candidates.contains(label) {
                        candidates.append(label)
                    }
                }

                var selectedLabel = currentLabel
                var selectedScore = -Float.greatestFiniteMagnitude
                for label in candidates {
                    let dataScore = projectionScore(face: face, snapshot: label)
                    guard dataScore >= faceBestScores[face] * 0.22 else { continue }

                    let matchingNeighbors = compatibleNeighbors.reduce(into: 0) { count, neighbor in
                        if previousAssignments[neighbor] == label { count += 1 }
                    }
                    let continuity = Float(matchingNeighbors) / Float(compatibleNeighbors.count)
                    let combinedScore = dataScore / faceBestScores[face] + continuity * 1.8
                    if combinedScore > selectedScore {
                        selectedScore = combinedScore
                        selectedLabel = label
                    }
                }

                if selectedLabel != currentLabel {
                    faceAssignment[face] = selectedLabel
                    didChange = true
                }
            }

            if !didChange { break }
        }

        let islandAssignments = faceAssignment
        visitedFaces = [Bool](repeating: false, count: faceCount)
        for seed in 0..<faceCount where validFaces[seed] && !visitedFaces[seed] {
            let islandLabel = islandAssignments[seed]
            guard islandLabel >= 0 else {
                visitedFaces[seed] = true
                continue
            }

            var island: [Int] = []
            var queue = [seed]
            visitedFaces[seed] = true
            var cursor = 0
            var adjacentLabelCounts: [Int: Int] = [:]

            while cursor < queue.count {
                let face = queue[cursor]
                cursor += 1
                island.append(face)

                for neighbor in faceNeighbors[face]
                where validFaces[neighbor] &&
                      simd_dot(faceNormals[face], faceNormals[neighbor]) >= 0.72 {
                    let neighborLabel = islandAssignments[neighbor]
                    if neighborLabel == islandLabel, !visitedFaces[neighbor] {
                        visitedFaces[neighbor] = true
                        queue.append(neighbor)
                    } else if neighborLabel >= 0, neighborLabel != islandLabel {
                        adjacentLabelCounts[neighborLabel, default: 0] += 1
                    }
                }
            }

            guard island.count < 12,
                  let replacementLabel = adjacentLabelCounts.max(by: { lhs, rhs in
                      lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
                  })?.key else { continue }

            for face in island where faceBestScores[face] > 0 {
                let replacementScore = projectionScore(face: face, snapshot: replacementLabel)
                if replacementScore >= faceBestScores[face] * 0.24 {
                    faceAssignment[face] = replacementLabel
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
        var hiddenFaceList = [Int]()

        for f in 0..<faceCount {
            let si = faceAssignment[f]
            if si >= 0 {
                snapFaces[si, default: []].append(f)
            } else if si == -1 {
                hiddenFaceList.append(f)
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

        // 没有可靠纹理的面不写入导出几何，预览时直接显示背景。
        hiddenFaces += hiddenFaceList.count

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
