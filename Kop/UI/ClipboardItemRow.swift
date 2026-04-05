import AppKit
import SwiftUI

struct ClipboardItemRow: View {
    let item: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(item.previewText)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let appIcon = AppIconFetcher.icon(for: item.sourceBundleIdentifier, appName: item.sourceAppName) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    Text(item.sourceAppName ?? "Origem desconhecida")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(RelativeDateTimeFormatter.kop.localizedString(for: item.updatedAt, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.type {
        case .image:
            if let image = ImageThumbnail.shared.thumbnailImage(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                fallbackIcon(systemName: "photo")
            }
        case .fileURL:
            if let path = item.filePath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 34, height: 34)
            } else {
                fallbackIcon(systemName: "doc")
            }
        case .pdf:
            fallbackIcon(systemName: "doc.richtext")
        case .richText:
            fallbackIcon(systemName: "text.alignleft")
        case .plainText:
            fallbackIcon(systemName: "doc.on.doc")
        }
    }

    private func fallbackIcon(systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 42, height: 42)
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private extension RelativeDateTimeFormatter {
    static let kop: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()
}
