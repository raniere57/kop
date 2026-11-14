import AppKit
import SwiftUI

struct ClipboardItemRow: View {
    let item: ClipboardEntry
    let isSelected: Bool
    var shortcutIndex: Int?
    var onToggleFavorite: () -> Void
    var onExpandImage: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 11) {
            thumbnail
                .frame(width: 40, height: 40)
                // Inner gesture wins over the row's, so clicking the picture
                // expands instead of pasting.
                .onTapGesture { if item.type == .image { onExpandImage() } }
                .help(item.type == .image ? "Clique para expandir" : "")

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: item.customTitle == nil ? .regular : .semibold))
                    .lineLimit(item.customTitle == nil ? 2 : 1)
                    .truncationMode(.tail)

                if let secondary = item.secondaryPreviewText {
                    Text(secondary.singleLine)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                metadata
            }

            Spacer(minLength: 4)
            trailingAccessories
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.55 : 0), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    private var displayTitle: String {
        item.customTitle?.isEmpty == false ? item.displayTitle : item.previewText.singleLine
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                isSelected
                    ? Color.accentColor.opacity(0.18)
                    : Color.primary.opacity(isHovering ? 0.08 : 0.04)
            )
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            if let appIcon = AppIconFetcher.icon(for: item.sourceBundleIdentifier, appName: item.sourceAppName) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text(item.sourceAppName ?? "Origem desconhecida")
                .lineLimit(1)
            Text("·")
            Text(RelativeDateTimeFormatter.kop.localizedString(for: item.updatedAt, relativeTo: Date()))
                .lineLimit(1)
            if let badge = item.typeBadge, badge != displayTitle {
                Text("·")
                Text(badge)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var trailingAccessories: some View {
        HStack(spacing: 6) {
            if let shortcutIndex, !isHovering {
                Text("⌘\(shortcutIndex)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(item.isFavorite || isHovering ? 1 : 0)
            .help(item.isFavorite ? "Remover favorito" : "Favoritar")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.type {
        case .image:
            if let image = ImageThumbnail.shared.thumbnailImage(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                fallbackIcon("photo")
            }
        case .fileURL:
            if let path = item.filePath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackIcon("doc")
            }
        case .pdf:
            fallbackIcon("doc.richtext")
        case .richText:
            fallbackIcon("textformat")
        case .plainText:
            fallbackIcon("text.alignleft")
        }
    }

    private func fallbackIcon(_ systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private extension ClipboardEntry {
    var typeBadge: String? {
        switch type {
        case .plainText, .richText: return nil
        case .image: return "Imagem"
        case .fileURL: return "Arquivo"
        case .pdf: return "PDF"
        }
    }
}

extension String {
    /// Collapses newlines/tabs so multi-line snippets stay on one row.
    var singleLine: String {
        split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

private extension RelativeDateTimeFormatter {
    static let kop: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        formatter.locale = .kop
        return formatter
    }()
}

extension Locale {
    /// The UI is written in Brazilian Portuguese; dates and sizes must match
    /// it regardless of the system language.
    static let kop = Locale(identifier: "pt_BR")
}
