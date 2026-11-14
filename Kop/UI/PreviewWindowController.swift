import AppKit
import PDFKit
import SwiftUI

@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PreviewWindowController()

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Reuses a single window so repeated previews do not stack up.
    func show(item: ClipboardEntry) {
        let fullItem = PersistenceManager.shared.fetchItem(id: item.id) ?? item
        let hosting = NSHostingController(rootView: PreviewContentView(item: fullItem))

        let window = (self.window as? PreviewWindow) ?? makeWindow()
        window.contentViewController = hosting
        window.title = fullItem.displayTitle.singleLine.isEmpty ? "Visualização" : fullItem.displayTitle.singleLine
        window.subtitle = fullItem.sourceAppName ?? ""
        if self.window == nil {
            window.setContentSize(NSSize(width: 760, height: 560))
            window.center()
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> PreviewWindow {
        let window = PreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 360, height: 260)
        window.delegate = self
        return window
    }

    /// The window is reused; drop the hosted item (and its payload) on close.
    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }
}

private final class PreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

private struct PreviewContentView: View {
    let item: ClipboardEntry

    var body: some View {
        Group {
            switch item.type {
            case .plainText, .fileURL:
                ScrollView {
                    Text(item.type == .fileURL ? (item.filePath ?? item.previewText) : item.previewText)
                        .font(.system(size: 13, design: item.type == .fileURL ? .monospaced : .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            case .richText:
                if let data = item.richTextData,
                   let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
                    RichTextView(attributedString: attributed)
                } else {
                    ScrollView {
                        Text(item.previewText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            case .image:
                if let image = ImageThumbnail.shared.originalOrThumbnail(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else {
                    placeholder("Sem pré-visualização disponível")
                }
            case .pdf:
                if item.binaryData != nil {
                    PDFPreviewView(data: item.binaryData)
                } else {
                    placeholder("PDF indisponível")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RichTextView: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributedString)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        (nsView.documentView as? NSTextView)?.textStorage?.setAttributedString(attributedString)
    }
}

private struct PDFPreviewView: NSViewRepresentable {
    let data: Data?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        if let data { view.document = PDFDocument(data: data) }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if let data { nsView.document = PDFDocument(data: data) }
    }
}
