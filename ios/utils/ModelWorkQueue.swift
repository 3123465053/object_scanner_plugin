import Foundation

/// SceneKit / ModelIO 都会在加载时产生较大的临时缓冲区。转换和预览共用同一
/// 串行队列，避免两个模型同时解码导致瞬时内存翻倍。
enum ModelWorkQueue {
    static let shared = DispatchQueue(
        label: "com.objectscanner.model-work",
        qos: .userInitiated
    )
}
