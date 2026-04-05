import Foundation

enum ClipboardItemType: String, Codable, CaseIterable {
    case plainText
    case richText
    case image
    case fileURL
    case pdf
}

struct ClipboardEntry: Identifiable, Equatable {
    let id: Int64
    let type: ClipboardItemType
    let textContent: String?
    let richTextData: Data?
    let binaryData: Data?
    let filePath: String?
    let thumbnailPath: String?
    let sourceAppName: String?
    let sourceBundleIdentifier: String?
    let createdAt: Date
    let updatedAt: Date
    let isFavorite: Bool
    let fingerprint: String

    var previewText: String {
        switch type {
        case .plainText:
            return textContent ?? ""
        case .richText:
            if let textContent, !textContent.isEmpty {
                return textContent
            }
            return "Rich text"
        case .image:
            return "Imagem"
        case .fileURL:
            return filePath ?? "Arquivo"
        case .pdf:
            return filePath ?? "Documento PDF"
        }
    }
}

struct ClipboardCapture {
    let type: ClipboardItemType
    let textContent: String?
    let richTextData: Data?
    let binaryData: Data?
    let filePath: String?
    let thumbnailPath: String?
    let sourceAppName: String?
    let sourceBundleIdentifier: String?
    let fingerprint: String
    let createdAt: Date
}
