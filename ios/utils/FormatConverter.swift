//
//  FormatConverter.swift
//  object_scanner_plugin
//
//  格式转换工具 - 将 USDZ 文件转换为其他3D格式

import Foundation
import ModelIO
import SceneKit
import Flutter

struct FormatConverter {

    // 支持的输出格式
    static let supportedFormats = ["obj", "stl", "ply", "usd", "usda", "usdc"]

    /// 转换3D模型格式
    /// - Parameters:
    ///   - inputPath: 输入文件路径 (USDZ/USD等)
    ///   - outputFormat: 目标格式 ("obj", "stl", "ply", "usd", "usda", "usdc")
    ///   - result: Flutter回调
    static func convert(inputPath: String, outputFormat: String, result: @escaping FlutterResult) {
        let format = outputFormat.lowercased()

        // 检查格式是否支持
        guard supportedFormats.contains(format) else {
            result([
                "path": nil,
                "msg": "不支持的格式: \(outputFormat)，支持的格式: \(supportedFormats.joined(separator: ", "))"
            ] as [String : Any?])
            return
        }

        // 检查输入文件是否存在
        guard FileManager.default.fileExists(atPath: inputPath) else {
            result([
                "path": nil,
                "msg": "输入文件不存在: \(inputPath)"
            ] as [String : Any?])
            return
        }

        // 在后台线程执行转换
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let inputURL = URL(fileURLWithPath: inputPath)

                // 使用 ModelIO 加载模型
                let asset = MDLAsset(url: inputURL)
                asset.loadTextures()

                // 生成输出路径
                let fileName = (inputURL.deletingPathExtension().lastPathComponent)
                let outputFileName = "\(fileName)_converted.\(format)"
                let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let outputURL = documentsDir.appendingPathComponent(outputFileName)

                // 如果已存在则删除旧文件
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }

                // 检查 MDLAsset 是否能导出该格式
                let canExport = MDLAsset.canExportFileExtension(format)
                guard canExport else {
                    DispatchQueue.main.async {
                        result([
                            "path": nil,
                            "msg": "当前设备不支持导出 \(format) 格式"
                        ] as [String : Any?])
                    }
                    return
                }

                // 执行导出
                let success = asset.export(to: outputURL)

                DispatchQueue.main.async {
                    if success {
                        result([
                            "path": outputURL.path,
                            "msg": "success"
                        ])
                    } else {
                        result([
                            "path": nil,
                            "msg": "格式转换失败"
                        ] as [String : Any?])
                    }
                }

            } catch {
                DispatchQueue.main.async {
                    result([
                        "path": nil,
                        "msg": "格式转换异常: \(error.localizedDescription)"
                    ] as [String : Any?])
                }
            }
        }
    }

    /// 获取支持的格式列表
    static func getSupportedFormats() -> [String] {
        return supportedFormats
    }
}
