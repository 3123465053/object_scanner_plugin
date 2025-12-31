import SwiftUI
import RealityKit
import Combine
import SceneKit

//扫描单个物体
@available(iOS 17.0, *)
@MainActor
class ObjectScanner: ObservableObject {
    @Published var session = ObjectCaptureSession()
    @Published var isReconstructing = false
    @Published var progress: Double = 0.0
    @Published var outputFile:String = "path"
    var scanFolder: URL?
    // ⭐️ 关键：保存重建会话 （用来取消重建的）
       private var photogrammetrySession: PhotogrammetrySession?
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
        
        isReconstructing = true
        
        Task {
            // 给系统一点时间回收相机资源（约 0.5 秒）
            try? await Task.sleep(nanoseconds: 500_000_000)
            //结束后就从简
            await self.runReconstruction()
        }
    }
    
    //开始重建
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
            let session = try PhotogrammetrySession(input: inputFolder)
            
            self.photogrammetrySession = session
             
            try session.process(requests: [request])
            
            for try await output in session.outputs {
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
                    break
                }
            }
        } catch {
            print("重建初始化失败: \(error)")
            self.isReconstructing = false
            self.outputFile = ""
        }
    }
    
    //取消重建
    func cancelReconstruction() {
        guard isReconstructing else { return }

        print("⛔️ 取消模型重建")
        photogrammetrySession?.cancel()
        photogrammetrySession = nil
        isReconstructing = false
    }

}


@available(iOS 17.0, *)
struct ObjectScannerView: View {
    @StateObject private var objectScanner = ObjectScanner()
    @Environment(\.dismiss) private var dismiss
    
    @State var showProgressView:Bool = false
    
    var body: some View {
        ZStack {
            ObjectCaptureView(session: objectScanner.session)
                .ignoresSafeArea()
            
            
            VStack {
                //没有在重建的时候显示
                if  !objectScanner.isReconstructing{
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
                } else {
                    Text("")
                }
                
            }
        }
        //生命周期函数 开始时执行
        .onAppear { objectScanner.prepareAndStart() }
        .onChange(of: objectScanner.isReconstructing, { _, newValue in
            if newValue {
                showProgressView = true
            }
        })
        .onChange(of: objectScanner.outputFile) { oldValue, newValue in
            print("dsafddssds");
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
        .onChange(of: showProgressView, { oldValue, newValue in
            //之前是显示的底部弹窗进度条 现在不显示 则说明是关闭了弹窗
            if oldValue && !newValue {
                objectScanner.cancelReconstruction();
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3){
                    ObjectScannerPlugin.pendingResult?([
                        "path":"",
                        "msg":"重建取消"
                    ])
                    // ⚠️ 一定要清空，防止重复调用
                    ObjectScannerPlugin.pendingResult = nil
                }}
        })
        .sheet(isPresented: $showProgressView) {
            GenerateProgressView(progress: $objectScanner.progress)
        }
    }
}

@available(iOS 15.0, *)
struct GenerateProgressView:View {
    
    @Binding var progress:Double
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack(alignment:.topLeading) {
            
            VStack{
                Spacer()
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding()
                Text("正在生成 3D 模型: \(Int(progress * 100))%")
                Text("(关闭会停止模型生成)")
                Spacer()
            }
            .interactiveDismissDisabled(true)  //为true 不能通过手势下拉的方式关闭弹窗
            Button("关闭"){
                dismiss()
            }
            .glassIfAvailable()
            .padding()
        }
    }
}

//液态玻璃效果是否可用
extension View {
    @ViewBuilder
    func glassIfAvailable() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.automatic)
        }
    }
}
