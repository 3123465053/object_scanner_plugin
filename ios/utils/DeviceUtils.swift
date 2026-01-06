//
//  File.swift
//  object_scanner_plugin
//
//  Created by 杨棒 on 2026/1/6.
//

import Foundation
import AVFoundation

struct DeviceUtils {
    //打开或者关闭手电筒
  
  static  func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else {
            print("设备不支持手电筒")
            return
        }

        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            print("手电筒配置失败: \(error)")
        }
    }

}
