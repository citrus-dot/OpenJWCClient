import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// 背景图降采样重编码（design D-13 红线 3）：widget extension 进程内存上限 ~30MB，
/// 用户相册原图（数 MB-数十 MB）直接存会导致渲染解码吃内存 + 加载慢。
/// 选图时降采样（目标边长 ≤1280px）+ 重编码 JPEG（quality ≈0.75，产物 ≤ 数百 KB）再存 App Group 容器。
/// Android 端 `saveBackgroundImage` 仅 copyTo 原图——iOS 此处优于上游。
public enum WidgetImageProcessor {
    /// 默认目标边长上限（px）。
    public static let defaultMaxDimension: CGFloat = 1280
    /// 默认 JPEG 压缩质量。
    public static let defaultQuality: Double = 0.75

    /// 降采样 + 重编码 JPEG。
    /// - Parameters:
    ///   - imageData: 原图数据（任意 CGImageSource 支持的格式）。
    ///   - maxDimension: 长边上限（等比缩放，只缩不放）。
    ///   - quality: JPEG 质量 0...1。
    /// - Returns: JPEG 数据；原图无法解码时返回 nil。
    public static func downsampleAndEncode(
        imageData: Data,
        maxDimension: CGFloat = WidgetImageProcessor.defaultMaxDimension,
        quality: Double = WidgetImageProcessor.defaultQuality
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return nil
        }
        // 缩略图管线：解码即缩（不解全尺寸位图，内存峰值受控）
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    /// 解码图像尺寸（不产出位图，读元数据）。
    public static func pixelSize(of imageData: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }
}
