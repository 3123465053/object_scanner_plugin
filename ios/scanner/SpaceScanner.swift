import ARKit
import RealityKit
import SwiftUI
import SceneKit
import ModelIO
import MetalKit

// MARK: - 使用 RealityKit 的现代化扫描方案

@available(iOS 13.0, *)
final class SpaceScannerViewModel: NSObject, ObservableObject {
    private var arView: ARView!
    private var meshAnchors: [UUID: ARAnchor] = [:]
    private var lastFrame: ARFrame?
    
    override init() {
        super.init()
        setupARView()
    }
    
    private func setupARView() {
        arView = ARView(frame: .zero)
        arView.session.delegate = self
        
        // 启用网格可视化（显示扫描的网格）
        if #available(iOS 13.4, *) {
            arView.debugOptions.insert(.showSceneUnderstanding)
        }
        
        // 启用环境光遮蔽等效果
        arView.environment.sceneUnderstanding.options = [.occlusion, .receivesLighting]
    }
    
    func getARView() -> ARView {
        return arView
    }
    
    func startScanning() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("❌ 设备不支持 LiDAR 网格重建")
            return
        }
        
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .automatic
        
        // 启用平面检测（有助于提高质量）
        config.planeDetection = [.horizontal, .vertical]
        
        // 启用场景深度（如果支持）
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        // 启用场景理解网格显示
        if #available(iOS 13.4, *) {
            arView.debugOptions.insert(.showSceneUnderstanding)
        }
        
        print("✅ 开始扫描（网格可视化已启用）")
    }
    
    func stopScanningAndExport() -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsURL.appendingPathComponent("scan_\(Date().timeIntervalSince1970).usdz")
        
        arView.session.pause()
        
        print("📋 准备导出场景")
        
        // 在后台导出
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 使用 RealityKit 导出场景
                try self.exportSceneToUSDZ(to: fileURL)
                
                DispatchQueue.main.async {
                    ObjectScannerPlugin.pendingResult?([
                        "path": fileURL.path,
                        "msg": "success"
                    ])
                }
            } catch {
                print("❌ 导出失败: \(error)")
                DispatchQueue.main.async {
                    ObjectScannerPlugin.pendingResult?([
                        "path": "",
                        "msg": "导出失败: \(error.localizedDescription)"
                    ])
                }
            }
        }
        
        return fileURL
    }
    
    private func exportSceneToUSDZ(to url: URL) throws {
        if #available(iOS 14.0, *) {
            print("📊 开始导出场景...")
            
            // 获取所有网格锚点
            let allAnchors = arView.session.currentFrame?.anchors ?? []
            let meshAnchors = allAnchors.compactMap { $0 as? ARMeshAnchor }
            
            guard !meshAnchors.isEmpty else {
                throw NSError(domain: "SpaceScanner", code: 1, 
                            userInfo: [NSLocalizedDescriptionKey: "没有捕获到网格数据，请确保设备支持LiDAR并移动设备扫描物体"])
            }
            
            print("📦 找到 \(meshAnchors.count) 个网格锚点")
            
            // 使用 SceneKit 创建场景
            let scene = SCNScene()
            let rootNode = SCNNode()
            rootNode.name = "RootNode"
            
            var totalVertices = 0
            var totalFaces = 0
            
            // 获取最后一帧用于纹理
            let textureFrame = lastFrame
            var textureImage: UIImage?
            
            if let frame = textureFrame {
                textureImage = createTextureImage(from: frame)
                print("📷 纹理图像已创建: \(textureImage?.size.width ?? 0) x \(textureImage?.size.height ?? 0)")
            } else {
                print("⚠️ 没有相机帧，将使用默认颜色")
            }
            
            // 为每个网格创建 SCNNode
            for meshAnchor in meshAnchors {
                let mesh = meshAnchor.geometry
                let vertexCount = mesh.vertices.count
                let faceCount = mesh.faces.count
                
                totalVertices += vertexCount
                totalFaces += faceCount
                
                print("🔨 处理网格: \(vertexCount) 顶点, \(faceCount) 面")
                
                // 创建 SCNGeometry（带UV坐标）
                let geometry = createSCNGeometry(from: meshAnchor, frame: textureFrame)
                
                // 创建材质（使用纹理）
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                material.isDoubleSided = true
                
                if let texture = textureImage {
                    material.diffuse.contents = texture
                } else {
                    material.diffuse.contents = UIColor(white: 0.8, alpha: 1.0)
                }
                material.metalness.contents = 0.0
                material.roughness.contents = 0.5
                
                geometry.materials = [material]
                
                // 创建节点（变换已经应用到顶点，所以节点使用单位矩阵）
                let node = SCNNode(geometry: geometry)
                node.name = "Mesh_\(meshAnchor.identifier.uuidString.prefix(8))"
                // 不再设置 transform，因为顶点已经是世界坐标
                rootNode.addChildNode(node)
                
                print("  ✓ 添加到场景")
            }
            
            scene.rootNode.addChildNode(rootNode)
            
            // 添加环境光
            let ambientLight = SCNNode()
            ambientLight.light = SCNLight()
            ambientLight.light!.type = .ambient
            ambientLight.light!.color = UIColor.white
            ambientLight.light!.intensity = 1000
            scene.rootNode.addChildNode(ambientLight)
            
            print("📦 总计: \(totalVertices) 顶点, \(totalFaces) 面")
            print("📦 场景节点数: \(rootNode.childNodes.count)")
            print("💾 导出 USDZ 文件到: \(url.path)")
            
            // 确保目录存在
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            
            // 删除已存在的文件
            try? FileManager.default.removeItem(at: url)
            
            // 使用 SceneKit 导出 USDZ
            do {
                try scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
                
                // 验证文件
                let fileExists = FileManager.default.fileExists(atPath: url.path)
                print("✅ 导出完成")
                print("   文件路径: \(url.path)")
                print("   文件存在: \(fileExists)")
                
                if fileExists {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let fileSize = attributes[.size] as? Int64 {
                        let sizeMB = Double(fileSize) / 1024.0 / 1024.0
                        print("   文件大小: \(fileSize) 字节 (\(String(format: "%.2f", sizeMB)) MB)")
                        
                        if fileSize < 1000 {
                            print("⚠️ 警告：文件太小(\(fileSize)字节)，可能为空")
                            throw NSError(domain: "SpaceScanner", code: 4, 
                                        userInfo: [NSLocalizedDescriptionKey: "导出的文件太小，可能没有包含有效数据"])
                        }
                    }
                } else {
                    throw NSError(domain: "SpaceScanner", code: 3, 
                                userInfo: [NSLocalizedDescriptionKey: "文件导出后不存在"])
                }
            } catch {
                print("❌ 导出失败: \(error)")
                print("   错误详情: \(error.localizedDescription)")
                throw error
            }
        } else {
            throw NSError(domain: "SpaceScanner", code: 2, 
                        userInfo: [NSLocalizedDescriptionKey: "需要 iOS 14.0 或更高版本"])
        }
    }
    
    @available(iOS 14.0, *)
    private func createSCNGeometry(from meshAnchor: ARMeshAnchor, frame: ARFrame?) -> SCNGeometry {
        let mesh = meshAnchor.geometry
        let transform = meshAnchor.transform
        
        // 手动复制顶点数据（应用变换）
        let vertexCount = mesh.vertices.count
        let vertexBuffer = mesh.vertices.buffer
        let vertexOffset = mesh.vertices.offset
        let vertexStride = mesh.vertices.stride
        
        var transformedVertices: [SCNVector3] = []
        var texcoords: [SIMD2<Float>] = []
        transformedVertices.reserveCapacity(vertexCount)
        texcoords.reserveCapacity(vertexCount)
        
        let basePointer = vertexBuffer.contents().advanced(by: vertexOffset)
        
        // 获取相机参数用于UV计算
        var cameraTransform: simd_float4x4?
        var cameraIntrinsics: simd_float3x3?
        var imageWidth: Float = 1920
        var imageHeight: Float = 1440
        
        if let frame = frame {
            cameraTransform = frame.camera.transform
            cameraIntrinsics = frame.camera.intrinsics
            imageWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))
            imageHeight = Float(CVPixelBufferGetHeight(frame.capturedImage))
        }
        
        for i in 0..<vertexCount {
            let vertexPointer = basePointer.advanced(by: i * vertexStride)
            let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            
            // 应用变换矩阵，将局部坐标转换为世界坐标
            let worldVertex = transform * SIMD4<Float>(vertex, 1.0)
            let worldPos = SIMD3<Float>(worldVertex.x, worldVertex.y, worldVertex.z)
            transformedVertices.append(SCNVector3(worldPos.x, worldPos.y, worldPos.z))
            
            // 计算UV坐标
            var uv = SIMD2<Float>(0.5, 0.5) // 默认中心
            
            if let camTransform = cameraTransform,
               let camIntrinsics = cameraIntrinsics {
                // 将世界坐标转换为相机坐标
                let cameraSpacePoint = simd_mul(simd_inverse(camTransform), SIMD4<Float>(worldPos, 1.0))
                
                // 如果点在相机前方
                if cameraSpacePoint.z > 0 {
                    let x = cameraSpacePoint.x / cameraSpacePoint.z
                    let y = cameraSpacePoint.y / cameraSpacePoint.z
                    
                    let fx = camIntrinsics[0][0]
                    let fy = camIntrinsics[1][1]
                    let cx = camIntrinsics[2][0]
                    let cy = camIntrinsics[2][1]
                    
                    let pixelX = fx * x + cx
                    let pixelY = fy * y + cy
                    
                    // 转换为UV坐标 [0, 1]
                    let u = pixelX / imageWidth
                    let v = pixelY / imageHeight
                    
                    uv = SIMD2<Float>(
                        max(0, min(1, u)),
                        max(0, min(1, v))
                    )
                }
            }
            
            texcoords.append(uv)
        }
        
        // 手动复制法线数据（应用旋转）
        let normalCount = mesh.normals.count
        let normalBuffer = mesh.normals.buffer
        let normalOffset = mesh.normals.offset
        let normalStride = mesh.normals.stride
        
        var transformedNormals: [SCNVector3] = []
        transformedNormals.reserveCapacity(normalCount)
        
        let normalBasePointer = normalBuffer.contents().advanced(by: normalOffset)
        
        // 提取旋转矩阵（3x3）
        let rotation = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        
        for i in 0..<normalCount {
            let normalPointer = normalBasePointer.advanced(by: i * normalStride)
            let normal = normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            
            // 只应用旋转到法线
            let worldNormal = rotation * normal
            transformedNormals.append(SCNVector3(worldNormal.x, worldNormal.y, worldNormal.z))
        }
        
        // 手动复制面索引数据
        let facesCount = mesh.faces.count
        let facesBuffer = mesh.faces.buffer
        let bytesPerIndex = mesh.faces.bytesPerIndex
        
        var indices: [UInt32] = []
        indices.reserveCapacity(facesCount * 3)
        
        let facesBasePointer = facesBuffer.contents()
        
        if bytesPerIndex == 2 {
            let uint16Pointer = facesBasePointer.assumingMemoryBound(to: UInt16.self)
            for i in 0..<(facesCount * 3) {
                indices.append(UInt32(uint16Pointer[i]))
            }
        } else {
            let uint32Pointer = facesBasePointer.assumingMemoryBound(to: UInt32.self)
            for i in 0..<(facesCount * 3) {
                indices.append(uint32Pointer[i])
            }
        }
        
        // 创建顶点源
        let vertexData = Data(bytes: transformedVertices, count: transformedVertices.count * MemoryLayout<SCNVector3>.stride)
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector3>.stride
        )
        
        // 创建法线源
        let normalData = Data(bytes: transformedNormals, count: transformedNormals.count * MemoryLayout<SCNVector3>.stride)
        let normalSource = SCNGeometrySource(
            data: normalData,
            semantic: .normal,
            vectorCount: normalCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector3>.stride
        )
        
        // 创建UV坐标源
        let texcoordData = Data(bytes: texcoords, count: texcoords.count * MemoryLayout<SIMD2<Float>>.stride)
        let texcoordSource = SCNGeometrySource(
            data: texcoordData,
            semantic: .texcoord,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
        
        // 创建几何元素
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: facesCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        
        return SCNGeometry(sources: [vertexSource, normalSource, texcoordSource], elements: [element])
    }
    
    // 从 ARFrame 创建纹理图像
    private func createTextureImage(from frame: ARFrame) -> UIImage? {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        // 旋转图像以匹配设备方向
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }
    
}

// MARK: - ARSessionDelegate

@available(iOS 13.0, *)
extension SpaceScannerViewModel: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 保存最新帧用于颜色提取
        lastFrame = frame
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        if #available(iOS 14.0, *) {
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    let mesh = meshAnchor.geometry
                    print("✅ 添加网格: \(mesh.vertices.count) 顶点, \(mesh.faces.count) 面")
                    meshAnchors[anchor.identifier] = anchor
                }
            }
            
            if meshAnchors.count % 5 == 0 && !meshAnchors.isEmpty {
                print("📊 当前已捕获 \(meshAnchors.count) 个网格")
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        if #available(iOS 14.0, *) {
            for anchor in anchors {
                if anchor is ARMeshAnchor {
                    meshAnchors[anchor.identifier] = anchor
                }
            }
        }
    }
    
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        if #available(iOS 14.0, *) {
            for anchor in anchors {
                if anchor is ARMeshAnchor {
                    meshAnchors.removeValue(forKey: anchor.identifier)
                }
            }
        }
    }
}

// MARK: - SwiftUI Views

@available(iOS 14.0, *)
struct SpaceScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SpaceScannerViewModel()
    
    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(arView: viewModel.getARView())
                .ignoresSafeArea()
                .onAppear {
                    viewModel.startScanning()
                }
            
            VStack(spacing: 12) {
                Text("慢慢移动设备扫描物体")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                
                Button(action: {
                    if let _ = viewModel.stopScanningAndExport() {
                        dismiss()
                    }
                }) {
                    Text("停止并导出")
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
    let arView: ARView
    
    func makeUIView(context: Context) -> ARView {
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
}
