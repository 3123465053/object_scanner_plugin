//  AppModel.swift
//  Pods

import SwiftUI
import RealityKit
import Combine
import SceneKit

@available(iOS 17.0, *)
@MainActor
class ObjectScanner: ObservableObject {
    @Published var session = ObjectCaptureSession()
    @Published var isReconstructing = false
    @Published var progress: Double = 0.0
    @Published var outputFile:String = "path"
    var scanFolder: URL?
    
    //初始化设置
    func prepareAndStart() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Scan-\(Date().timeIntervalSince1970)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        
        self.scanFolder = folder
        let config = ObjectCaptureSession.Configuration()
        // 必须设置 checkpointDirectory 才能进行本地重建
        session.start(imagesDirectory: folder, configuration: config)
    }

    // --- 手动结束捕获 ---
    func stopCaptureAndStartReconstruction() {
        // 1. 停止捕获
            session.finish()
            // 2. 关键：延迟或确保 UI 已经停止渲染相机画面
            // 在某些情况下，需要将 session 引用断开来释放 GPU
            // self.session = ObjectCaptureSession() // 或者在 AppModel 里设为可选型并置 nil
            
            isReconstructing = true
            
            Task {
                // 给系统一点时间回收相机资源（约 0.5 秒）
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self.runReconstruction()
            }
    }

    private func runReconstruction() async {
        guard let inputFolder = scanFolder else { return }
        let outputFile = inputFolder.appendingPathComponent("Model.usdz")
        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(at: inputFolder, includingPropertiesForKeys: nil) {
            print("文件夹内文件数量: \(contents.count)")
            // 如果数量为 0，说明 session.start 并没有成功写入数据
        }
        do {
            // 使用 .reduced 确保 iPhone 内存安全
            let request = PhotogrammetrySession.Request.modelFile(url: outputFile, detail: .reduced)
            let photogrammetrySession = try PhotogrammetrySession(input: inputFolder)
            
            try photogrammetrySession.process(requests: [request])
            
            for try await output in photogrammetrySession.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    self.progress = fraction
                case .requestComplete:
                    self.isReconstructing = false
                    print("✅ 重建成功: \(outputFile.path)")
                    self.outputFile = outputFile.path
                    // 这里可以添加逻辑去打开这个 .usdz 文件
                case .requestError(_, let error):
                    print("❌ 重建出错: \(error)")
                    self.isReconstructing = false
                    self.outputFile = ""
                default:
                    self.outputFile = ""
                    break
                }
            }
        } catch {
            print("重建初始化失败: \(error)")
            self.isReconstructing = false
        }
    }
}


@available(iOS 17.0, *)
struct ObjectScannerView: View {
    @StateObject private var objectScanner = ObjectScanner()
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            ObjectCaptureView(session: objectScanner.session)
                .ignoresSafeArea()
            
            VStack {
                if objectScanner.isReconstructing {
                    // 重建中的进度条
                    VStack {
                        ProgressView(value: objectScanner.progress)
                            .progressViewStyle(.linear)
                            .padding()
                        Text("正在生成 3D 模型: \(Int(objectScanner.progress * 100))%")
                        
                        
                    }
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .padding()
                } else {
                    Spacer()
                    
                    // 控制按钮
                    HStack(spacing: 40) {
                        if case .ready = objectScanner.session.state {
                            Button("开始捕捉") {
                                objectScanner.session.startCapturing()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        
                        // 只要在捕捉状态，就允许手动结束
                        else if case .capturing = objectScanner.session.state {
                            Button("结束并生成模型") {
                                objectScanner.stopCaptureAndStartReconstruction()
                            }
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        } else
                          {
                          Text("默认文本")
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear { objectScanner.prepareAndStart() }
        .onChange(of: objectScanner.outputFile) { oldValue, newValue in
            
          print(newValue)
             dismiss()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3){
                ObjectScannerPlugin.pendingResult?([
                    "path":newValue,
                    "msg":newValue.isEmpty ? "重建出错" : "success"
                ])
                // ⚠️ 一定要清空，防止重复调用
                ObjectScannerPlugin.pendingResult = nil
            }
        }
    }
}
