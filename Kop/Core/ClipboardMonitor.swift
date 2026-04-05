import AppKit
import Carbon
import CryptoKit
import Foundation
import UniformTypeIdentifiers

final class ClipboardMonitor {
    private let persistence: PersistenceManager
    private let preferences: PreferencesStore
    private let pasteboard = NSPasteboard.general
    private let queue = DispatchQueue(label: "kop.clipboard.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int

    private(set) var isPaused = false

    init(persistence: PersistenceManager, preferences: PreferencesStore) {
        self.persistence = persistence
        self.preferences = preferences
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.7, repeating: .milliseconds(700))
        timer.setEventHandler { [weak self] in
            self?.pollPasteboard()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        lastChangeCount = pasteboard.changeCount
    }

    private func pollPasteboard() {
        guard !isPaused else { return }
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let item = pasteboard.pasteboardItems?.first else { return }
        let sourceApp = NSWorkspace.shared.frontmostApplication

        if shouldIgnoreSensitiveContent(from: sourceApp) {
            return
        }

        if let capture = capture(item: item, sourceApp: sourceApp) {
            persistence.save(capture, historyLimit: preferences.historyLimit)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
            }
        }
    }

    private func shouldIgnoreSensitiveContent(from app: NSRunningApplication?) -> Bool {
        let appName = app?.localizedName?.lowercased() ?? ""
        let sensitiveApps = ["1password", "bitwarden", "keychain", "lastpass", "keeper"]
        guard sensitiveApps.contains(where: appName.contains) else {
            return false
        }

        switch preferences.sensitiveCaptureBehavior {
        case .save:
            return false
        case .ignore:
            return true
        case .ask:
            let semaphore = DispatchSemaphore(value: 0)
            var shouldSave = false
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Salvar item sensível?"
                alert.informativeText = "Kop detectou conteúdo copiado de \(app?.localizedName ?? "um app sensível")."
                alert.addButton(withTitle: "Salvar")
                alert.addButton(withTitle: "Ignorar")
                shouldSave = alert.runModal() == .alertFirstButtonReturn
                semaphore.signal()
            }
            semaphore.wait()
            return !shouldSave
        }
    }

    private func capture(item: NSPasteboardItem, sourceApp: NSRunningApplication?) -> ClipboardCapture? {
        let now = Date()
        let sourceAppName = sourceApp?.localizedName
        let sourceBundleIdentifier = sourceApp?.bundleIdentifier

        if let fileURLString = item.string(forType: .fileURL),
           preferences.captureFilesEnabled,
           let url = URL(string: fileURLString) {
            let path = url.path
            let fingerprint = digest("\(ClipboardItemType.fileURL.rawValue):\(path)")
            return ClipboardCapture(
                type: .fileURL,
                textContent: path,
                richTextData: nil,
                binaryData: nil,
                filePath: path,
                thumbnailPath: nil,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                fingerprint: fingerprint,
                createdAt: now
            )
        }

        if let pdfData = item.data(forType: .pdf) {
            let fingerprint = digestData(prefix: ClipboardItemType.pdf.rawValue, data: pdfData)
            return ClipboardCapture(
                type: .pdf,
                textContent: "PDF",
                richTextData: nil,
                binaryData: pdfData,
                filePath: nil,
                thumbnailPath: nil,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                fingerprint: fingerprint,
                createdAt: now
            )
        }

        if preferences.captureImagesEnabled {
            let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
            for type in imageTypes {
                if let data = item.data(forType: type) {
                    let imageStore = data.count > 10_000_000 ? nil : data
                    let thumbnailPath = ImageThumbnail.shared.persistThumbnail(for: data)
                    let fingerprint = digestData(prefix: ClipboardItemType.image.rawValue, data: data)
                    return ClipboardCapture(
                        type: .image,
                        textContent: nil,
                        richTextData: nil,
                        binaryData: imageStore,
                        filePath: nil,
                        thumbnailPath: thumbnailPath,
                        sourceAppName: sourceAppName,
                        sourceBundleIdentifier: sourceBundleIdentifier,
                        fingerprint: fingerprint,
                        createdAt: now
                    )
                }
            }
        }

        if let rtfData = item.data(forType: .rtf) {
            let plainText = NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string
            let fingerprint = digestData(prefix: ClipboardItemType.richText.rawValue, data: rtfData)
            return ClipboardCapture(
                type: .richText,
                textContent: plainText,
                richTextData: rtfData,
                binaryData: nil,
                filePath: nil,
                thumbnailPath: nil,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                fingerprint: fingerprint,
                createdAt: now
            )
        }

        if let htmlData = item.data(forType: .html) {
            let plainText = String(data: htmlData, encoding: .utf8)?
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let fingerprint = digestData(prefix: ClipboardItemType.richText.rawValue, data: htmlData)
            return ClipboardCapture(
                type: .richText,
                textContent: plainText,
                richTextData: htmlData,
                binaryData: nil,
                filePath: nil,
                thumbnailPath: nil,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                fingerprint: fingerprint,
                createdAt: now
            )
        }

        if let text = item.string(forType: .string), !text.isEmpty {
            let fingerprint = digest("\(ClipboardItemType.plainText.rawValue):\(text)")
            return ClipboardCapture(
                type: .plainText,
                textContent: text,
                richTextData: nil,
                binaryData: nil,
                filePath: nil,
                thumbnailPath: nil,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                fingerprint: fingerprint,
                createdAt: now
            )
        }

        return nil
    }

    private func digest(_ string: String) -> String {
        let data = Data(string.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func digestData(prefix: String, data: Data) -> String {
        var combined = Data(prefix.utf8)
        combined.append(data)
        return SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined()
    }
}
