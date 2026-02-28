import ARKit
import RealityKit
import SwiftUI
import SceneKit
import ModelIO
import MetalKit
import CoreImage // 用于图像处理

// MARK: - 使用 ARSCNView 的现代化扫描方案 (SceneKit)

@available(iOS 13.0, *)
final class SpaceScannerViewModel: NSObject, ObservableObject, ARSCNViewDelegate {
    private var sceneView: ARSCNView!
    private var meshAnchors: [UUID: ARAnchor] = [:]
    
    override init() {
        super.init()
        setupARView()
    }
    
    private func setupARView() {
        sceneView = ARSCNView(frame: .zero)
        sceneView.delegate = self
        
        // 自动光照
        sceneView.autoenablesDefaultLighting = true
    }
    
    func getSceneView() -> ARSCNView {
        return sceneView
    }
    
    func startScanning() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("❌ 设备不支持 LiDAR 网格重建")
            return
        }
        
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .automatic
        
        // 启用平面检测
        config.planeDetection = [.horizontal, .vertical]
        
        // 启用场景深度
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        print("✅ 开始扫描（使用 ARSCNView）")
    }
    
    // MARK: - ARSCNViewDelegate (可视化网格)
    
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        
        // 创建用于可视化的简化几何体（不带颜色，高性能）
        let geometry = createVisualizationGeometry(from: meshAnchor.geometry)
        
        let node = SCNNode(geometry: geometry)
        
        // 设置统一的材质颜色
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.6) // 半透明白色
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true // 确保双面可见
        
        // 可选：添加线框效果让结构更清晰
        // material.fillMode = .lines 
        
        geometry.materials = [material]
        
        return node
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        
        // 更新几何体
        // 直接创建新的 SCNGeometry 并替换
        // 这是一个高效的操作，因为 buffer 是共享的 Metal buffer
        let newGeometry = createVisualizationGeometry(from: meshAnchor.geometry)
        
        // 保持原来的材质
        let materials = node.geometry?.materials ?? []
        newGeometry.materials = materials
        
        // 如果没有材质（首次 update？），则重新创建
        if newGeometry.materials.isEmpty {
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.white.withAlphaComponent(0.6)
            material.lightingModel = .physicallyBased
            material.isDoubleSided = true
            newGeometry.materials = [material]
        }
        
        node.geometry = newGeometry
    }
    
    // 创建轻量级可视化几何体 (仅顶点和索引)
    private func createVisualizationGeometry(from mesh: ARMeshGeometry) -> SCNGeometry {
        let vertices = mesh.vertices
        
        let vertexSource = SCNGeometrySource(buffer: vertices.buffer,
                                             vertexFormat: vertices.format,
                                             semantic: .vertex,
                                             vertexCount: vertices.count,
                                             dataOffset: vertices.offset,
                                             dataStride: vertices.stride)
        
        let normals = mesh.normals
        let normalSource = SCNGeometrySource(buffer: normals.buffer,
                                             vertexFormat: normals.format,
                                             semantic: .normal,
                                             vertexCount: normals.count,
                                             dataOffset: normals.offset,
                                             dataStride: normals.stride)
        
        let faces = mesh.faces
        let facesData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        
        let element = SCNGeometryElement(data: facesData,
                                         primitiveType: .triangles,
                                         primitiveCount: faces.count,
                                         bytesPerIndex: faces.bytesPerIndex)
        
        return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    }
    
    func stopScanningAndExport() -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // 改为 .usdc 格式，MDLAsset 可以直接导出，且兼容 iOS 查看
        let fileURL = documentsURL.appendingPathComponent("scan_\(Date().timeIntervalSince1970).usdc")
        
        // 获取当前帧用于颜色采样
        let currentFrame = sceneView.session.currentFrame
        
        sceneView.session.pause()
        
        print("📋 准备导出场景")
        
        // 在后台导出
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 使用 RealityKit 导出场景
                try self.exportSceneToUSDZ(to: fileURL, frame: currentFrame)
                
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
    
    private func exportSceneToUSDZ(to url: URL, frame: ARFrame?) throws {
        if #available(iOS 14.0, *) {
            print("📊 开始导出场景...")
            
            // 获取所有网格锚点
            let allAnchors = sceneView.session.currentFrame?.anchors ?? []
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
            
            // 准备纹理图像
            var textureImage: UIImage?
            var cameraTransform: simd_float4x4?
            var cameraIntrinsics: simd_float3x3?
            var imageResolution: CGSize = .zero
            
            if let frame = frame {
                // 将 CVPixelBuffer 转换为 UIImage 用于纹理
                let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
                let context = CIContext()
                if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                    textureImage = UIImage(cgImage: cgImage)
                }
                
                cameraTransform = frame.camera.transform
                cameraIntrinsics = frame.camera.intrinsics
                imageResolution = CGSize(
                    width: CVPixelBufferGetWidth(frame.capturedImage),
                    height: CVPixelBufferGetHeight(frame.capturedImage)
                )
            }
            
            // 为每个网格创建 SCNNode
            for meshAnchor in meshAnchors {
                let mesh = meshAnchor.geometry
                let vertexCount = mesh.vertices.count
                let faceCount = mesh.faces.count
                
                totalVertices += vertexCount
                totalFaces += faceCount
                
                // 创建 SCNGeometry（带 UV 坐标）
                let geometry = createSCNGeometry(
                    from: meshAnchor, 
                    cameraTransform: cameraTransform,
                    cameraIntrinsics: cameraIntrinsics,
                    imageResolution: imageResolution
                )
                
                // 创建材质
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased 
                material.isDoubleSided = true
                
                // 设置纹理
                if let texture = textureImage {
                    material.diffuse.contents = texture
                } else {
                    material.diffuse.contents = UIColor.lightGray
                }
                
                // 设置材质属性
                material.metalness.contents = 0.0
                material.roughness.contents = 1.0 
                
                // 关键修正：将材质直接赋值给 SCNNode 而不是 SCNGeometry
                // 有时候 SceneKit/ModelIO 导出时，Geometry 级别的材质可能会被忽略或处理不当
                // 或者确保 Geometry 的 materials 数组被正确设置
                geometry.materials = [material] 
                
                // 创建节点
                let node = SCNNode(geometry: geometry)
                node.name = "Mesh_\(meshAnchor.identifier.uuidString.prefix(8))"
                // 确保节点也持有该材质（双重保险）
                node.geometry?.materials = [material]
                
                rootNode.addChildNode(node)
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
            
            // 使用 ModelIO 导出 USDC (支持纹理)
            let mdlAsset = MDLAsset(scnScene: scene)
            
            // 关键：确保 ModelIO 知道要打包纹理
            // 有时直接 export 可能会丢失 external textures
            // 这里我们尝试将 texture 写入文件系统，然后让 MDLAsset 引用它
            // 或者使用 SceneKit 的 write(to:options:)
            
            // 尝试使用 SceneKit 直接导出，SceneKit 对 USDZ 的支持可能比 MDLAsset 的默认导出更完整
            // 特别是内嵌纹理
             do {
                // SCNScene 的 write 方法在处理内嵌纹理方面通常更可靠
                // .checkConsistency = true 可以帮我们发现问题
                 let success = scene.write(to: url, options: [:], delegate: nil, progressHandler: nil)
                 if !success {
                     throw NSError(domain: "SpaceScanner", code: 5, userInfo: [NSLocalizedDescriptionKey: "SceneKit write failed"])
                 }
                 
                // 验证文件
                let fileExists = FileManager.default.fileExists(atPath: url.path)
                print("✅ SceneKit 导出完成")
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
    private func createSCNGeometry(
        from meshAnchor: ARMeshAnchor,
        cameraTransform: simd_float4x4?,
        cameraIntrinsics: simd_float3x3?,
        imageResolution: CGSize
    ) -> SCNGeometry {
        let mesh = meshAnchor.geometry
        let transform = meshAnchor.transform
        
        let vertexCount = mesh.vertices.count
        let vertexBuffer = mesh.vertices.buffer
        let vertexOffset = mesh.vertices.offset
        let vertexStride = mesh.vertices.stride
        
        var transformedVertices: [SCNVector3] = []
        var transformedNormals: [SCNVector3] = []
        var textureCoordinates: [CGPoint] = [] // 改用纹理坐标
        var indices: [UInt32] = []
        
        // 预分配内存
        transformedVertices.reserveCapacity(vertexCount)
        transformedNormals.reserveCapacity(vertexCount)
        textureCoordinates.reserveCapacity(vertexCount)
        
        // 1. 处理顶点和 UV 坐标
        let basePointer = vertexBuffer.contents().advanced(by: vertexOffset)
        
        for i in 0..<vertexCount {
            let vertexPointer = basePointer.advanced(by: i * vertexStride)
            let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            
            // 变换到世界坐标
            let worldVertex = transform * SIMD4<Float>(vertex, 1.0)
            let worldPos = SIMD3<Float>(worldVertex.x, worldVertex.y, worldVertex.z)
            transformedVertices.append(SCNVector3(worldPos.x, worldPos.y, worldPos.z))
            
            // 计算纹理坐标 (UV)
            var uv = CGPoint.zero
            
            if let camTransform = cameraTransform,
               let camIntrinsics = cameraIntrinsics {
                
                // 世界坐标 -> 相机坐标
                let cameraSpacePoint = simd_mul(simd_inverse(camTransform), SIMD4<Float>(worldPos, 1.0))
                
                // 点必须在相机前方 (Z < 0)
                if cameraSpacePoint.z < 0 {
                    // 投影到归一化图像平面
                    let z = -cameraSpacePoint.z
                    let x = cameraSpacePoint.x / z
                    let y = cameraSpacePoint.y / z
                    
                    // 应用相机内参矩阵投影到像素坐标
                    let fx = camIntrinsics[0][0]
                    let fy = camIntrinsics[1][1]
                    let cx = camIntrinsics[2][0]
                    let cy = camIntrinsics[2][1]
                    
                    let pixelX = x * fx + cx
                    let pixelY = y * fy + cy
                    
                    // 归一化到 [0, 1] 范围作为 UV
                    // 注意：Metal/SceneKit 的纹理坐标系 (0,0) 通常在左下角，而图像像素 (0,0) 在左上角
                    // 需要反转 Y 轴: 1.0 - (pixelY / height)
                    let u = CGFloat(pixelX) / imageResolution.width
                    let v = 1.0 - (CGFloat(pixelY) / imageResolution.height)
                    
                    uv = CGPoint(x: u, y: v)
                }
            }
            textureCoordinates.append(uv)
        }
        
        // 2. 处理法线
        let normalCount = mesh.normals.count
        let normalBuffer = mesh.normals.buffer
        let normalOffset = mesh.normals.offset
        let normalStride = mesh.normals.stride
        let normalBasePointer = normalBuffer.contents().advanced(by: normalOffset)
        
        let rotation = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        
        for i in 0..<normalCount {
            let normalPointer = normalBasePointer.advanced(by: i * normalStride)
            let normal = normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let worldNormal = rotation * normal
            transformedNormals.append(SCNVector3(worldNormal.x, worldNormal.y, worldNormal.z))
        }
        
        // 3. 处理索引
        let facesCount = mesh.faces.count
        let facesBuffer = mesh.faces.buffer
        let bytesPerIndex = mesh.faces.bytesPerIndex
        let facesBasePointer = facesBuffer.contents()
        
        indices.reserveCapacity(facesCount * 3)
        if bytesPerIndex == 2 {
            let p = facesBasePointer.assumingMemoryBound(to: UInt16.self)
            for i in 0..<(facesCount * 3) { indices.append(UInt32(p[i])) }
        } else {
            let p = facesBasePointer.assumingMemoryBound(to: UInt32.self)
            for i in 0..<(facesCount * 3) { indices.append(p[i]) }
        }
        
        // 4. 构建 SCNGeometrySource
        let vertexSource = SCNGeometrySource(vertices: transformedVertices)
        let normalSource = SCNGeometrySource(normals: transformedNormals)
        let texcoordSource = SCNGeometrySource(textureCoordinates: textureCoordinates) // 新增 UV Source
        
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        
        return SCNGeometry(sources: [vertexSource, normalSource, texcoordSource], elements: [element])
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
    let sceneView: ARSCNView
    
    func makeUIView(context: Context) -> ARSCNView {
        return sceneView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
