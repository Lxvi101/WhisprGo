import AppKit
import SwiftUI

@MainActor
enum BrandAssets {
    static let menuBarIcon: NSImage = {
        let image = loadImage(
            named: "MenuBarIconTemplate",
            extension: "png",
            developmentPath: "Packaging/MenuBarIconTemplate.png"
        ) ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
        image.size = NSSize(width: 25, height: 13)
        image.isTemplate = true
        return image
    }()

    static let waveformMark: NSImage = {
        let image = loadImage(
            named: "WaveformMark",
            extension: "png",
            developmentPath: "Packaging/WaveformMark.png"
        ) ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }()

    static func loadFullLogo() -> NSImage? {
        loadImage(
            named: "WhisprGo",
            extension: "svg",
            developmentPath: "Assets/WhisprGo.svg"
        )
    }

    private static func loadImage(
        named name: String,
        extension fileExtension: String,
        developmentPath: String
    ) -> NSImage? {
        if let bundledURL = Bundle.main.url(forResource: name, withExtension: fileExtension),
           let image = NSImage(contentsOf: bundledURL) {
            return image
        }

        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(developmentPath)
        return NSImage(contentsOf: developmentURL)
    }
}

struct BrandWaveform: View {
    var body: some View {
        Image(nsImage: BrandAssets.waveformMark)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(950.0 / 520.0, contentMode: .fit)
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
    }
}

struct DottedRule: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<9, id: \.self) { index in
                Circle()
                    .fill(Color.primary.opacity(index == 4 ? 0.34 : 0.14))
                    .frame(width: index == 4 ? 3 : 2, height: index == 4 ? 3 : 2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct DottedSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2.5) {
                Circle().frame(width: 3, height: 3)
                Circle().frame(width: 3, height: 3)
                Circle().frame(width: 3, height: 3)
            }
            .foregroundStyle(.secondary)
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

struct MinimalPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
    }
}

struct MinimalBadge: View {
    let text: String
    var filled = false

    init(_ text: String, filled: Bool = false) {
        self.text = text
        self.filled = filled
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(filled ? Color(nsColor: .textBackgroundColor) : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(filled ? Color.primary : Color.clear)
            }
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(filled ? 0 : 0.18), lineWidth: 1)
            }
    }
}

struct MinimalKeyCap: View {
    let text: String
    var inverted = false
    var compact = false

    init(_ text: String, inverted: Bool = false, compact: Bool = false) {
        self.text = text
        self.inverted = inverted
        self.compact = compact
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospaced())
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                inverted
                    ? Color(nsColor: .textBackgroundColor).opacity(0.15)
                    : Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        inverted
                            ? Color(nsColor: .textBackgroundColor).opacity(0.25)
                            : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
            }
    }
}

struct DotSelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(isSelected ? 0.8 : 0.22), lineWidth: 1.2)
                .frame(width: 16, height: 16)
            if isSelected {
                Circle()
                    .fill(Color.primary)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

struct MonochromePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: .textBackgroundColor))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.78 : 0.96),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
