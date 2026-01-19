import ARKit
import SceneKit
import SwiftUI

@available(iOS 13.4, *)
final class SpaceScannerViewModel: NSObject, ObservableObject, ARSessionDelegate {
    var meshNodes: [UUID: SCNNode] = [:]
    let arView: ARSCNView = {
        let v = ARSCNView()
        v.scene = SCNScene()
        v.automaticallyUpdatesLighting = true
        return v
    }()

    override init() {
        super.init()
        arView.session.delegate = self
    }

    func startScanning() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("❌ 不支持 LiDAR Mesh")
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .automatic

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stopScanningAndExport() -> URL? {
            // 1️⃣ 停止 AR 会话
            arView.session.pause()

            // 2️⃣ 合并所有 MeshNode
            let rootNode = SCNNode()
            for node in meshNodes.values {
                rootNode.addChildNode(node.clone())
            }

            let scene = SCNScene()
            scene.rootNode.addChildNode(rootNode)

            // 3️⃣ 导出 USDZ 文件到临时目录
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("scan.usdz")

            do {
                try scene.write(to: fileURL, options: nil, delegate: nil, progressHandler: nil)
                print("✅ USDZ 导出完成: \(fileURL.path)")
                DispatchQueue.main.async {
                    ObjectScannerPlugin.pendingResult?([
                        "path":fileURL.path,
                        "msg": "success"
                    ])
                }
                return fileURL
            } catch {
                print("❌ 导出失败: \(error)")
                DispatchQueue.main.async {
                    ObjectScannerPlugin.pendingResult?([
                        "path":"",
                        "msg": "导出失败"
                    ])
                }
                return nil
            }
        }

    // MARK: - didAdd（创建 Mesh）

    @available(iOS 13.4, *)
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for meshAnchor in anchors.compactMap({ $0 as? ARMeshAnchor }) {
            if #available(iOS 14.0, *) {
                let node = SCNNode(geometry: makeGeometry(from: meshAnchor))
                    node.name = meshAnchor.identifier.uuidString

                    meshNodes[meshAnchor.identifier] = node
                    arView.scene.rootNode.addChildNode(node)
            } else {
                // Fallback on earlier versions
            }
          
        }
    }

    // MARK: - didUpdate（更新 Mesh）

    @available(iOS 13.4, *)
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for meshAnchor in anchors.compactMap({ $0 as? ARMeshAnchor }) {

            guard let node = meshNodes[meshAnchor.identifier] else { continue }

                   // 更新 geometry
            if #available(iOS 14.0, *) {
                node.geometry = makeGeometry(from: meshAnchor)
            } else {
                // Fallback on earlier versions
            }
        }
    }

    // MARK: - Mesh → SceneKit

    @available(iOS 14.0, *)
    private func makeGeometry(from anchor: ARMeshAnchor) -> SCNGeometry {
        let mesh = anchor.geometry

        let vertexSource = SCNGeometrySource(
            buffer: mesh.vertices.buffer,
            vertexFormat: mesh.vertices.format,
            semantic: .vertex,
            vertexCount: mesh.vertices.count,
            dataOffset: mesh.vertices.offset,
            dataStride: mesh.vertices.stride
        )

        let normalSource = SCNGeometrySource(
            buffer: mesh.normals.buffer,
            vertexFormat: mesh.normals.format,
            semantic: .normal,
            vertexCount: mesh.normals.count,
            dataOffset: mesh.normals.offset,
            dataStride: mesh.normals.stride
        )

        let element = SCNGeometryElement(
            buffer: mesh.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: mesh.faces.count,
            bytesPerIndex: mesh.faces.bytesPerIndex
        )

        let geo = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])

        let material = SCNMaterial()
        material.fillMode = .fill
        material.diffuse.contents = UIColor.green.withAlphaComponent(0.35)
        material.isDoubleSided = true
        material.lightingModel = .constant
        geo.materials = [material]

        return geo
    }
    
    // MARK: - 导出 3D 模型（USDZ）
    func exportScene(to url: URL, completion: @escaping (Bool) -> Void) {
           // 合并所有 MeshNode
           let rootNode = SCNNode()
           for node in meshNodes.values {
               rootNode.addChildNode(node.clone())
           }

           let scene = SCNScene()
           scene.rootNode.addChildNode(rootNode)

           // 导出 USDZ
           do {
               try scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
               completion(true)
           } catch {
               print("❌ 导出失败: \(error)")
               completion(false)
           }
       }
}


@available(iOS 13.4, *)
struct ARViewContainer: UIViewRepresentable {
    let viewModel: SpaceScannerViewModel
    func makeUIView(context: Context) -> ARSCNView { viewModel.arView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

@available(iOS 15.0, *)
struct SpaceScanView: View {

    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var vm = SpaceScannerViewModel()
    @State private var exportedPath: String?

    var body: some View {
        ZStack(alignment: .bottom) {

            ARViewContainer(viewModel: vm)
                .ignoresSafeArea()
                .onAppear {
                    vm.startScanning()   // ✅ 进入页面立即扫描
                }

            HStack(spacing: 20) {

                Button("停止并导出") {
                    if let url = vm.stopScanningAndExport() {
                        exportedPath = url.path
                        dismiss()
                    }
                }
                .padding()
                .background(Color.red.opacity(0.8))
                .cornerRadius(10)
            }
            .padding(.bottom, 30)

//            if let path = exportedPath {
//                Text("USDZ 导出路径:\n\(path)")
//                    .font(.footnote)
//                    .foregroundColor(.white)
//                    .padding()
//                    .background(Color.black.opacity(0.5))
//                    .cornerRadius(10)
//                    .padding(.bottom, 100)
//            }
        }
    }
}

