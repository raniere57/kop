import AppKit
import PDFKit
import QuickLook
import SwiftUI

final class PreviewWindowController: NSWindowController {
    static let shared = PreviewWindowController()

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(item: ClipboardEntry) {
        let rootView = PreviewContentView(item: item)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 760, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Visualização"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PreviewContentView: View {
    let item: ClipboardEntry

    var body: some View {
        Group {
            switch item.type {
            case .plainText, .fileURL:
                ScrollView {
                    Text(item.previewText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            case .richText:
                if let data = item.richTextData, let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
                    RichTextView(attributedString: attributed)
                } else {
                    Text(item.previewText).padding()
                }
            case .image:
                if let image = ImageThumbnail.shared.originalOrThumbnail(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else {
                    Text("Sem preview disponível").padding()
                }
            case .pdf:
                PDFPreviewView(data: item.binaryData)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RichTextView: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textStorage?.setAttributedString(attributedString)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

private struct PDFPreviewView: NSViewRepresentable {
    let data: Data?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        if let data {
            view.document = PDFDocument(data: data)
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if let data {
            nsView.document = PDFDocument(data: data)
        }
    }
}
