import AppKit
import SwiftUI

/// The current on-device generation, presented as side-by-side cards.
struct FeaturedModelCards: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                DottedSectionLabel("On device")
                Spacer()
                Text("Private. Runs entirely on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(Signal.textTertiary)
            }
            .padding(.horizontal, 4)

            HStack(alignment: .top, spacing: 12) {
                ForEach(ModelCatalog.featured) { model in
                    FeaturedModelCard(model: model, engine: engine)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FeaturedModelCard: View {
    let model: TranscriptionModel
    @ObservedObject var engine: DictationEngine
    @State private var isHovered = false
    @State private var isConfirmingRemoval = false
    @State private var removableSize: String?

    private var isSelected: Bool { engine.selectedModelID == model.id }
    private var isDownloaded: Bool { engine.isModelDownloaded(model.id) }
    private var highlights: TranscriptionModel.Highlights? { model.highlights }

    var body: some View {
        Button {
            engine.selectModel(model.id)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let highlights {
                    LanguageDotField(
                        lit: highlights.languageCount,
                        total: ModelCatalog.featured.compactMap(\.highlights?.languageCount).max() ?? 25,
                        isActive: isSelected
                    )
                    .frame(height: 14)
                    stats(highlights)
                }
                status
                    .frame(height: 16, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected || isHovered ? Signal.surfaceHover : Signal.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(0.85) : Signal.hairline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!engine.canChangeModel)
        .onHover { hovering in
            withAnimation(Signal.quick) { isHovered = hovering }
        }
        .animation(Signal.motion, value: isSelected)
        .help(model.detail)
        .contextMenu {
            Button("Remove Download…", role: .destructive) { confirmRemoval() }
                .disabled(!engine.canRemoveDownloadedModel(model.id))
        }
        .alert("Remove \(model.name)?", isPresented: $isConfirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Download", role: .destructive) {
                engine.removeDownloadedModel(model.id)
            }
        } message: {
            Text("This frees \(removableSize ?? "its downloaded data") of storage. Selecting it later downloads it again automatically.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay(alignment: .bottomTrailing) {
            if isDownloaded && !isSelected {
                Button(action: confirmRemoval) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Signal.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!engine.canRemoveDownloadedModel(model.id))
                .help("Remove download to free up space")
                .accessibilityLabel("Remove \(model.name) download")
                .padding(8)
                .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if model.id == ModelCatalog.defaultModelID {
                        MinimalBadge("Default", filled: isSelected)
                    }
                }
                .frame(height: 22)
                Text(highlights?.tagline ?? model.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Signal.textSecondary)
            }
            Spacer(minLength: 0)
            DotSelectionIndicator(isSelected: isSelected)
        }
    }

    private func stats(_ highlights: TranscriptionModel.Highlights) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ModelStat(
                value: "\(highlights.languageCount)",
                label: highlights.languageCount == 1 ? "language" : "languages"
            )
            ModelStat(
                value: String(format: "%.1f%%", highlights.englishWordErrorRate),
                label: "English errors"
            )
            .help("Average word error rate on the Open ASR Leaderboard's seven English test sets. Lower is better.")
            ModelStat(value: model.sizeLabel ?? "", label: "download")
        }
    }

    @ViewBuilder
    private var status: some View {
        if isSelected {
            switch engine.modelState {
            case let .downloading(progress):
                HStack(spacing: 8) {
                    DotProgressBar(progress: progress)
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Signal.textSecondary)
                }
            case .warming, .starting:
                statusText("Preparing model", systemImage: "circle.dotted")
            case .ready, .needsAPIKey:
                statusText("Selected", systemImage: "checkmark")
            case .failed:
                statusText("Needs attention", systemImage: "exclamationmark.circle")
            }
        } else if isDownloaded {
            statusText("Downloaded", systemImage: "arrow.down.circle")
        } else {
            statusText("Downloads when selected", systemImage: nil)
        }
    }

    private func statusText(_ text: String, systemImage: String?) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(isSelected ? Signal.text : Signal.textTertiary)
        .transition(.opacity)
    }

    private var accessibilityLabel: String {
        var parts = [model.name]
        if let highlights {
            parts.append("\(highlights.languageCount) \(highlights.languageCount == 1 ? "language" : "languages")")
            parts.append(String(format: "%.1f percent English word error rate", highlights.englishWordErrorRate))
        }
        if let size = model.sizeLabel { parts.append("\(size) download") }
        if isDownloaded, !isSelected { parts.append("downloaded") }
        return parts.joined(separator: ", ")
    }

    private func confirmRemoval() {
        removableSize = ModelCache.downloadedBytes(for: model.id).map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        isConfirmingRemoval = true
    }
}

private struct ModelStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Signal.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One dot per supported language, drawn in the brand's dot-matrix style.
/// Selecting a card sweeps a highlight across its lit dots.
private struct LanguageDotField: View {
    let lit: Int
    let total: Int
    let isActive: Bool

    @State private var sweep: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let spacing = size.width / CGFloat(total)
            let radius = min(spacing * 0.28, size.height * 0.32)
            for index in 0..<total {
                let center = CGPoint(x: spacing * (CGFloat(index) + 0.5), y: size.height / 2)
                let isLit = index < lit
                let wave = max(0, 1 - abs(sweep * Double(total + 6) - Double(index) - 3) / 3)
                let opacity = isLit
                    ? (isActive ? 0.85 : 0.5) + 0.15 * wave
                    : 0.12
                let grow = isLit ? 1 + 0.35 * wave : 1
                let rect = CGRect(
                    x: center.x - radius * grow,
                    y: center.y - radius * grow,
                    width: radius * 2 * grow,
                    height: radius * 2 * grow
                )
                context.fill(Path(ellipseIn: rect), with: .color(.primary.opacity(opacity)))
            }
        }
        .onChange(of: isActive) { _, active in
            guard active, !reduceMotion else { return }
            sweep = 0
            withAnimation(.easeInOut(duration: 0.9)) { sweep = 1 }
        }
        .accessibilityHidden(true)
    }
}

/// Older on-device engines, collapsed unless one is in use.
struct LegacyModelsSection<Rows: View>: View {
    let isInUse: Bool
    @ViewBuilder let rows: () -> Rows
    @State private var isExpanded: Bool

    init(isInUse: Bool, @ViewBuilder rows: @escaping () -> Rows) {
        self.isInUse = isInUse
        self.rows = rows
        _isExpanded = State(initialValue: isInUse)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Signal.motion) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    DottedSectionLabel("Legacy")
                    Text("Parakeet and Whisper")
                        .font(.system(size: 11))
                        .foregroundStyle(Signal.textTertiary)
                    if isInUse && !isExpanded {
                        MinimalBadge("In use")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Signal.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Legacy models")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    rows()
                    Text("Still supported. Phonon 2.5 is more accurate and a smaller download.")
                        .font(.system(size: 11))
                        .foregroundStyle(Signal.textTertiary)
                        .padding(.horizontal, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct PhononAttribution: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Phonon 2.5 by")
            // A plain button, not Link: Link draws through AppKit and shows
            // as a placeholder wherever SwiftUI renders offscreen.
            Button("Fermion Research") {
                NSWorkspace.shared.open(URL(string: "https://huggingface.co/FermionResearch/Phonon-2.5")!)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Signal.textSecondary)
            .underline()
            .help("Open Phonon 2.5 on Hugging Face")
            Text("· based on NVIDIA Parakeet TDT 0.6B v3 · CC BY 4.0")
        }
        .font(.system(size: 10))
        .foregroundStyle(Signal.textTertiary)
        .tint(Signal.textSecondary)
        .padding(.horizontal, 4)
    }
}
