import AppKit
import SwiftUI

/// WhisprGo's visual language: monochrome, adaptive to light and dark
/// appearance, with the dot-matrix waveform as the only ornament.
enum Signal {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color.primary.opacity(0.04)
    static let surfaceHover = Color.primary.opacity(0.07)
    static let hairline = Color.primary.opacity(0.1)
    static let text = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.primary.opacity(0.35)
    /// Content drawn on top of a primary-colored fill.
    static let inverse = Color(nsColor: .windowBackgroundColor)
    /// Monochrome tint for native controls such as switches. Near-black in
    /// light mode; mid-gray in dark mode so a white switch knob stays visible.
    static let control = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.62, alpha: 1)
            : NSColor(white: 0.12, alpha: 1)
    })

    /// Critically damped: taps start at rest, so nothing here earns a bounce.
    static let motion = Animation.spring(response: 0.42, dampingFraction: 1)
    static let quick = Animation.spring(response: 0.28, dampingFraction: 1)
}

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

struct DottedSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Signal.textSecondary)
    }
}

struct MinimalPanel<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Signal.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Signal.hairline, lineWidth: 1)
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
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(filled ? Signal.inverse : Signal.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(filled ? Color.primary : Signal.surfaceHover))
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
            .font(.system(size: compact ? 10 : 11, weight: .medium, design: .rounded))
            .foregroundStyle(inverted ? Signal.inverse : Signal.text)
            .padding(.horizontal, compact ? 5 : 6)
            .frame(minWidth: compact ? 18 : 22, minHeight: compact ? 18 : 22)
            .background(
                inverted ? Signal.inverse.opacity(0.16) : Signal.surfaceHover,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }
}

struct DotSelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? Color.primary : Signal.textTertiary,
                    lineWidth: 1.2
                )
            Circle()
                .fill(Color.primary)
                .padding(4.5)
                .scaleEffect(isSelected ? 1 : 0.2)
                .opacity(isSelected ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .animation(Signal.quick, value: isSelected)
        .accessibilityHidden(true)
    }
}

/// The one filled, primary-colored call to action.
struct MonochromePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Signal.inverse)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Signal.quick, value: configuration.isPressed)
    }
}

/// Compact capsule buttons. Prominent buttons are filled with the primary color.
struct SignalPillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(prominent ? Signal.inverse : Signal.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                prominent
                    ? Color.primary.opacity(configuration.isPressed ? 0.8 : 1)
                    : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07),
                in: Capsule()
            )
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Signal.quick, value: configuration.isPressed)
    }
}

/// A segmented control whose selection pill slides between options.
struct SignalSegmentedControl<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    @ViewBuilder let label: (Value) -> Label
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(Signal.motion) { selection = option }
                } label: {
                    label(option)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Signal.text : Signal.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Signal.background)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Signal.surfaceHover, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
