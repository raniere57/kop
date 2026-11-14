import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Folders Kop owns on disk. Everything Kop writes lives here — never on the
/// user's Desktop.
enum KopStorage {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = base.appendingPathComponent("Kop", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let images: URL = subdirectory("Images")
    static let thumbnails: URL = subdirectory("Thumbnails")

    static func isManaged(_ path: String) -> Bool {
        path.hasPrefix(images.path) || path.hasPrefix(thumbnails.path)
    }

    private static func subdirectory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

func kopDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct ClipboardImagePayload {
    let filePath: String
    let pngData: Data
}

enum ClipboardImageBridge {
    /// Builds a payload that can be pasted both as an image and as a file.
    /// Generated PNGs are written to Kop's own storage so nothing pollutes the
    /// user's folders, and the file name is content-addressed so repeated
    /// copies of the same image reuse one file.
    static func preparePayload(
        imageData: Data?,
        preferredFilePath: String?,
        fallbackThumbnailPath: String? = nil
    ) -> ClipboardImagePayload? {
        autoreleasepool {
            guard let sourceData = imageData
                ?? loadImageData(fromFilePath: preferredFilePath)
                ?? loadImageData(fromFilePath: fallbackThumbnailPath),
                  let pngData = normalizedPNGData(from: sourceData) else {
                return nil
            }

            if let preferredFilePath, FileManager.default.fileExists(atPath: preferredFilePath) {
                return ClipboardImagePayload(filePath: preferredFilePath, pngData: pngData)
            }
            guard let exportedPath = exportPNG(pngData) else { return nil }
            return ClipboardImagePayload(filePath: exportedPath, pngData: pngData)
        }
    }

    /// Writes an image into Kop's storage and returns its path. Used for
    /// payloads too large to keep inline in the database.
    static func storeImageFile(_ data: Data) -> String? {
        guard let pngData = normalizedPNGData(from: data) else { return nil }
        return exportPNG(pngData)
    }

    static func publish(_ payload: ClipboardImagePayload, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        let fileURL = URL(fileURLWithPath: payload.filePath)
        item.setData(payload.pngData, forType: .png)
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setString(payload.filePath, forType: .string)

        pasteboard.clearContents()
        _ = pasteboard.writeObjects([item])
    }

    private static func normalizedPNGData(from data: Data) -> Data? {
        if isPNGData(data) { return data }
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func exportPNG(_ pngData: Data) -> String? {
        let url = KopStorage.images.appendingPathComponent("\(kopDigest(pngData)).png")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        do {
            try pngData.write(to: url, options: .atomic)
            return url.path
        } catch {
            NSLog("[Kop] Falha ao exportar imagem: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadImageData(fromFilePath filePath: String?) -> Data? {
        guard let filePath, FileManager.default.fileExists(atPath: filePath) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: filePath))
    }

    private static func isPNGData(_ data: Data) -> Bool {
        data.count >= 8 && Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10]
    }
}

final class ImageThumbnail {
    static let shared = ImageThumbnail()

    private static let maxPixelSize = 256
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
    }

    /// Downsamples via ImageIO (no full decode of the original) preserving the
    /// aspect ratio, and stores the result content-addressed.
    func persistThumbnail(for data: Data) -> String? {
        autoreleasepool {
            let url = KopStorage.thumbnails.appendingPathComponent("\(kopDigest(data)).png")
            if FileManager.default.fileExists(atPath: url.path) { return url.path }

            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let destination = CGImageDestinationCreateWithURL(
                      url as CFURL,
                      UTType.png.identifier as CFString,
                      1,
                      nil
                  ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return url.path
        }
    }

    func thumbnailImage(for item: ClipboardEntry) -> NSImage? {
        if let path = item.thumbnailPath, let image = thumbnailImage(atPath: path) {
            return image
        }
        // Rows captured before thumbnails moved into Kop's storage (or whose
        // cached file was wiped) still have the original image on disk.
        guard let path = item.filePath else { return nil }
        return thumbnailImage(atPath: path)
    }

    func thumbnailImage(atPath path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOfFile: path)
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    /// Best available representation, largest first. The cached list thumbnail
    /// is downsampled to 128px, so it is only used as a last resort and is read
    /// from disk at its own full size.
    func originalOrThumbnail(for item: ClipboardEntry) -> NSImage? {
        if let data = item.binaryData, let image = NSImage(data: data) {
            return image
        }
        if let path = item.filePath, FileManager.default.fileExists(atPath: path),
           let image = NSImage(contentsOfFile: path) {
            return image
        }
        if let path = item.thumbnailPath, let image = NSImage(contentsOfFile: path) {
            return image
        }
        return nil
    }

    /// Removes files Kop generated for paths that no history row references
    /// anymore. Files the user owns (outside Kop's storage) are never touched.
    func removeOrphanFiles(paths: [String], stillReferenced: Set<String>) {
        for path in paths where KopStorage.isManaged(path) && !stillReferenced.contains(path) {
            cache.removeObject(forKey: path as NSString)
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
