import AVFoundation
import Foundation
import UIKit

enum VideoFrameCaptureError: LocalizedError {
    case fileMissing
    case generatorFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "视频原文件不存在，无法截取当前帧。"
        case .generatorFailed(let detail):
            return "截取视频帧失败：\(detail)"
        }
    }
}

enum VideoFrameCaptureHelper {
    /// Extract an uncompressed full-resolution UIImage frame compatible with iPadOS 15.4+.
    static func captureFrame(from url: URL, atSeconds seconds: Double) async throws -> UIImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VideoFrameCaptureError.fileMissing
        }
        let targetSec = max(0.0, seconds.isFinite ? seconds : 0.0)
        return try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let cmTime = CMTime(seconds: targetSec, preferredTimescale: 600)
            do {
                let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
                return UIImage(cgImage: cgImage)
            } catch {
                // Fallback with relaxed tolerance if exact keyframe seek fails on certain codecs
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                do {
                    let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
                    return UIImage(cgImage: cgImage)
                } catch {
                    throw VideoFrameCaptureError.generatorFailed(error.localizedDescription)
                }
            }
        }.value
    }
}
