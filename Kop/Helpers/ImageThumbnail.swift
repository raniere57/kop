import AppKit
import CryptoKit
import Foundation

final class ImageThumbnail {
    static let shared = ImageThumbnail()

    private let cacheDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("Kop/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func persistThumbnail(for data: Data) -> String? {
        guard let image = NSImage(data: data) else { return nil }
        let size = NSSize(width: 160, height: 160)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        thumbnail.unlockFocus()

        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let filename = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".png"
        let url = cacheDirectory.appendingPathComponent(filename)
        try? pngData.write(to: url)
        return url.path
    }

    func thumbnailImage(for item: ClipboardEntry) -> NSImage? {
        guard let path = item.thumbnailPath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    func originalOrThumbnail(for item: ClipboardEntry) -> NSImage? {
        if let data = item.binaryData, let image = NSImage(data: data) {
            return image
        }
        return thumbnailImage(for: item)
    }
}
