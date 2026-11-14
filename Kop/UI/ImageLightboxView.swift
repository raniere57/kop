import AppKit
import SwiftUI

/// Full-size image shown over the list. Arrow keys, two-finger scroll and the
/// buttons all work without leaving the panel.
struct ImageLightboxView: View {
    let item: ClipboardEntry
    /// Decoded once per item by the view model; nil means undecodable.
    let image: NSImage?
    let position: (index: Int, total: Int)?
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // Tapping the backdrop collapses, matching Esc.
            Color.black.opacity(0.62)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            VStack(spacing: 10) {
                imageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)

                toolbar
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                // Never blow small images past 100%: upscaling only adds blur.
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
                // Swallow taps so clicking the image does not close it.
                .onTapGesture {}
        } else {
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 28, weight: .light))
                Text("Imagem indisponível")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            navigationButton(systemName: "chevron.up", help: "Imagem anterior (↑)", action: onPrevious)
            navigationButton(systemName: "chevron.down", help: "Próxima imagem (↓)", action: onNext)

            if let position {
                Text("\(position.index) de \(position.total)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer(minLength: 0)

            Text(item.sourceAppName ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)

            actionButton("Copiar", systemName: "doc.on.doc", help: "Copiar (⌘C)", action: onCopy)
            actionButton("Colar", systemName: "arrow.down.doc", help: "Colar (↵)", action: onPaste)
            navigationButton(systemName: "xmark", help: "Fechar (Esc)", action: onClose)
        }
    }

    private func navigationButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 26)
                .background(chipBackground)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func actionButton(_ title: String, systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(chipBackground)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var chipBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.16))
    }
}

/// Turns a stream of scroll events into discrete previous/next steps.
/// A single trackpad flick emits dozens of small deltas, so they are
/// accumulated and rate-limited into one step.
final class ScrollStepper {
    private static let threshold: CGFloat = 28
    private static let cooldown: TimeInterval = 0.22

    private var accumulated: CGFloat = 0
    private var lastStep: Date = .distantPast

    enum Step {
        case previous
        case next
    }

    func step(for event: NSEvent) -> Step? {
        // Ignore inertia so one flick never runs through the whole history.
        guard event.momentumPhase == [] else { return nil }
        if event.phase == .began { accumulated = 0 }
        guard event.scrollingDeltaY != 0 else { return nil }

        if event.hasPreciseScrollingDeltas {
            accumulated += event.scrollingDeltaY
            guard abs(accumulated) >= Self.threshold else { return nil }
        } else {
            accumulated = event.scrollingDeltaY
        }

        guard Date().timeIntervalSince(lastStep) >= Self.cooldown else { return nil }
        lastStep = Date()
        let goesUp = accumulated > 0
        accumulated = 0
        return goesUp ? .previous : .next
    }
}
