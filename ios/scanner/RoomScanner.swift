import RoomPlan
import RealityKit
import ARKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - RoomController (基于官方文档的实现)
@available(iOS 16.0, *)
class RoomController: NSObject, ObservableObject, RoomCaptureViewDelegate, NSCoding {
    
    static let instance = RoomController()
    
    var captureView: RoomCaptureView
    var sessionConfig: RoomCaptureSession.Configuration = RoomCaptureSession.Configuration()
    
    @Published var finalResult: CapturedRoom?
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var scanningProgress: String = ""
    
    override init() {
        captureView = RoomCaptureView(frame: .zero)
        super.init()
        captureView.delegate = self
        print("🎯 RoomController 初始化完成")
    }
    
    // MARK: - NSCoding 协议实现
    required init?(coder: NSCoder) {
        // 我们不支持从 NSCoder 初始化，因为这是一个单例
        return nil
    }
    
    func encode(with coder: NSCoder) {
        // 我们不需要编码这个对象，因为它是单例
    }
    
    // MARK: - RoomCaptureViewDelegate 方法
    
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        print("📋 shouldPresent 被调用")
        if let error = error {
            DispatchQueue.main.async {
                self.errorMessage = "处理数据时出错: \(error.localizedDescription)"
            }
            return false
        }
        return true
    }
    
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        print("✅ didPresent 被调用")
        DispatchQueue.main.async {
            self.isScanning = false
            self.scanningProgress = ""
            
            if let error = error {
                self.errorMessage = "扫描完成但有错误: \(error.localizedDescription)"
            } else {
                self.finalResult = processedResult
                self.scanningProgress = "✅ 扫描完成！"
                self.exportRoom(processedResult)
            }
        }
    }
    
    // MARK: - 会话控制方法
    
    func startSession() {
        print("🚀 开始扫描会话")
        
        // 检查设备支持
        guard RoomCaptureSession.isSupported else {
            DispatchQueue.main.async {
                self.errorMessage = "❌ 设备不支持 RoomPlan"
            }
            return
        }
        
        // 检查相机权限
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard cameraStatus == .authorized else {
            DispatchQueue.main.async {
                self.errorMessage = "❌ 需要相机权限"
            }
            return
        }
        
        DispatchQueue.main.async {
            self.errorMessage = nil
            self.isScanning = true
            self.scanningProgress = "正在启动扫描..."
            
            // 启动扫描会话
            self.captureView.captureSession.run(configuration: self.sessionConfig)
            self.scanningProgress = "扫描进行中..."
            print("✅ 扫描会话已启动")
        }
    }
    
    func stopSession() {
        print("🛑 停止扫描会话")
        captureView.captureSession.stop()
        
        DispatchQueue.main.async {
            self.scanningProgress = "正在处理扫描结果..."
        }
    }
    
    // MARK: - 导出功能
    
    private func exportRoom(_ capturedRoom: CapturedRoom) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = docs.appendingPathComponent("room_\(timestamp).usdz")
        
        do {
            try capturedRoom.export(to: url)
            print("✅ 房间导出成功: \(url)")
            DispatchQueue.main.async {
                self.scanningProgress = "✅ 已导出到: \(url.lastPathComponent)"
            }
        } catch {
            print("❌ 导出失败: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "导出失败: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - RoomCaptureView SwiftUI 包装器
@available(iOS 16.0, *)
struct RoomCaptureViewRepresentable: UIViewRepresentable {
    
    let roomController = RoomController.instance
    
    func makeUIView(context: Context) -> RoomCaptureView {
        print("🎥 创建 RoomCaptureView")
        return roomController.captureView
    }
    
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        print("🔄 更新 RoomCaptureView")
    }
}

// MARK: - 主扫描界面
@available(iOS 16.0, *)
struct RoomScannerView: View {
    
    @ObservedObject var roomController = RoomController.instance
    @State private var showingPermissionAlert = false
    @State private var showingInfoAlert = false
    
    var body: some View {
  
        ZStack(alignment:.topLeading) {
                // 扫描区域
                scanningArea
                
                // 底部控制区域
                bottomControls
            }
            .ignoresSafeArea()
            .onAppear {
                checkPermissions()
                // 页面出现时自动开始扫描（如果权限已授予）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if RoomCaptureSession.isSupported && 
                       AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                        roomController.startSession()
                    }
                }
            }
            
        }
    
    
    private var scanningArea: some View {
        ZStack {
            if RoomCaptureSession.isSupported {
                RoomCaptureViewRepresentable()
                    .onAppear {
                        print("📱 RoomCaptureViewRepresentable 出现")
                        // 自动开始扫描
                        roomController.startSession()
                    }
            } else {
                // 不支持设备的占位视图
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    
                    Text("设备不支持 RoomPlan")
                        .font(.title3)
                        .foregroundColor(.white)
                    
                    Text("需要支持 LiDAR 的设备\n(iPhone 12 Pro 及以上)")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.3))
            }
        }
    }
    
    private var bottomControls: some View {
        VStack(spacing: 16) {
            Spacer()
            HStack(spacing: 20) {
                if roomController.isScanning {
                    Button("完成扫描") {
                        roomController.stopSession()
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.red)
                    .cornerRadius(25)
                } else {
                    // 扫描完成后显示重新扫描按钮
                    Button("重新扫描") {
                        roomController.startSession()
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(25)
                    .disabled(!RoomCaptureSession.isSupported)
                }
            }
            
            // 扫描结果信息
            if let result = roomController.finalResult {
                VStack(spacing: 4) {
                    
                    Text("检测到 \(result.walls.count) 面墙，\(result.objects.count) 个物体")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
    
    }
    
    // MARK: - 辅助方法
    
    private func checkPermissions() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch cameraStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted {
                    DispatchQueue.main.async {
                        self.showingPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showingPermissionAlert = true
        case .authorized:
            break
        @unknown default:
            break
        }
    }
    
    private func openSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }
}

// MARK: - 不支持设备的视图
@available(iOS 16.0, *)
struct UnsupportedDeviceView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 80))
                .foregroundColor(.orange)
            
            Text("设备不支持")
                .font(.title)
                .foregroundColor(.red)
            
            Text("此设备不支持 LiDAR 技术")
                .font(.body)
                .multilineTextAlignment(.center)
            
            Text("需要 iPhone 12 Pro 或更新的设备")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding()
    }
}

// MARK: - 设备检查视图构建器
@available(iOS 16.0, *)
@ViewBuilder
func checkDeviceView() -> some View {
    if RoomCaptureSession.isSupported {
        RoomScannerView()
    } else {
        UnsupportedDeviceView()
    }
}

// MARK: - 预览
@available(iOS 16.0, *)
struct RoomScannerView_Previews: PreviewProvider {
    static var previews: some View {
        checkDeviceView()
    }
}
