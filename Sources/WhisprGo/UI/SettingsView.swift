import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case models
    case history
    case providers
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selection: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.selection) {
            GeneralSettingsPane(engine: engine)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.general)

            ModelSettingsPane(engine: engine)
                .tabItem { Label("Models", systemImage: "circle.grid.3x3") }
                .tag(SettingsTab.models)

            HistorySettingsPane(engine: engine)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)

            ProviderSettingsPane(engine: engine)
                .tabItem { Label("Providers", systemImage: "key") }
                .tag(SettingsTab.providers)
        }
        .tint(.primary)
        .scenePadding()
        .frame(width: 660, height: 520)
        .onAppear {
            engine.refreshPermissions()
        }
    }
}

private struct HistorySettingsPane: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject private var history = DictationHistoryStore.shared
    @State private var isConfirmingClear = false
    @State private var inspectedEntry: DictationHistoryEntry?

    var body: some View {
        SettingsPaneContainer(
            title: "History",
            subtitle: "Replay or re-run recent dictations"
        ) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Saved only on this Mac")
                            .font(.callout.weight(.medium))
                        Text("The latest 50 recordings are kept. Re-run uses your currently selected model and types the new result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    MinimalBadge("\(history.entries.count) / 50")
                    Button("Clear All", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .disabled(history.entries.isEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                if let error = history.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 9)
                }

                if history.entries.isEmpty {
                    HistoryEmptyState()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            ForEach(history.entries) { entry in
                                HistoryRow(
                                    entry: entry,
                                    isPlaying: history.playingEntryID == entry.id,
                                    isRerunning: history.rerunningEntryID == entry.id,
                                    canRerun: engine.canRerunHistory,
                                    onPlay: { history.togglePlayback(entry.id) },
                                    onRerun: { engine.rerunHistoryEntry(entry.id) },
                                    onInspect: { inspectedEntry = entry },
                                    onRemove: { history.remove(entry.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    }
                }
            }
        }
        .onAppear {
            history.loadIfNeeded()
        }
        .alert("Clear dictation history?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All Recordings", role: .destructive) {
                history.clear()
            }
        } message: {
            Text("This permanently removes every saved audio file and transcript from this Mac.")
        }
        .sheet(item: $inspectedEntry) { entry in
            TranscriptDetailView(entry: entry)
        }
    }
}

private struct HistoryEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            BrandWaveform()
                .frame(width: 120, height: 66)
                .opacity(0.52)
            Text("No dictations yet")
                .font(.headline)
            Text("Finished recordings will appear here after transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct HistoryRow: View {
    let entry: DictationHistoryEntry
    let isPlaying: Bool
    let isRerunning: Bool
    let canRerun: Bool
    let onPlay: () -> Void
    let onRerun: () -> Void
    let onInspect: () -> Void
    let onRemove: () -> Void
    @State private var isCopied = false
    @State private var copyGeneration = 0

    var body: some View {
        ZStack {
            Button(action: copyTranscript) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        isCopied
                            ? Color.green.opacity(0.13)
                            : Color.primary.opacity(0.018)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy full transcript")

            HStack(alignment: .top, spacing: 12) {
                Button(action: onPlay) {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.22), lineWidth: 1)
                            .frame(width: 34, height: 34)
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Stop recording" : "Play recording")

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(HistoryLabels.date(entry.createdAt))
                            .font(.caption.weight(.medium))
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(HistoryLabels.duration(entry.duration))
                            .font(.caption.monospacedDigit())
                        MinimalBadge("Audio")
                        if isCopied {
                            Label("Copied", systemImage: "checkmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.green)
                                .transition(.opacity)
                        }
                    }

                    Text(previewText)
                        .font(.callout)
                        .foregroundStyle(entry.transcript.isEmpty ? .secondary : .primary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 7) {
                        Text(entry.modelName)
                        if let latency = entry.latency {
                            Text("·")
                            Text("\(latency.formatted(.number.precision(.fractionLength(2))))s")
                                .monospacedDigit()
                        }
                        if entry.errorMessage != nil {
                            Text("·")
                            Text("Needs attention")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .trailing, spacing: 7) {
                    Button(action: onInspect) {
                        Label("Inspect", systemImage: "doc.text.magnifyingglass")
                    }

                    Button(action: onRerun) {
                        if isRerunning {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Running")
                            }
                        } else {
                            Label("Re-run & Type", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(!canRerun || isRerunning)

                    Button(role: .destructive, action: onRemove) {
                        Label("Delete", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    isCopied ? Color.green.opacity(0.55) : Color.primary.opacity(0.12),
                    lineWidth: 1
                )
        }
        .animation(.easeOut(duration: 0.16), value: isCopied)
    }

    private var fullText: String {
        if !entry.transcript.isEmpty { return entry.transcript }
        return entry.errorMessage ?? "No transcript was produced."
    }

    private var previewText: String {
        HistoryText.preview(fullText)
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullText, forType: .string)

        copyGeneration &+= 1
        let generation = copyGeneration
        isCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.25))
            guard copyGeneration == generation else { return }
            isCopied = false
        }
    }
}

enum HistoryText {
    static let previewCharacterLimit = 360

    static func preview(_ text: String) -> String {
        guard let boundary = text.index(
            text.startIndex,
            offsetBy: previewCharacterLimit,
            limitedBy: text.endIndex
        ), boundary != text.endIndex else {
            return text
        }
        return String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private struct TranscriptDetailView: View {
    let entry: DictationHistoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var isCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                BrandWaveform()
                    .frame(width: 76, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Full Transcript")
                        .font(.title3.weight(.medium))
                    Text("\(HistoryLabels.date(entry.createdAt))  ·  \(HistoryLabels.duration(entry.duration))  ·  \(entry.modelName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            DottedRule()
                .padding(.horizontal, 18)

            LargeSelectableTextView(text: fullText)
                .padding(18)

            HStack {
                if isCopied {
                    Label("Copied", systemImage: "checkmark")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                }
                Spacer()
                Button("Copy All", action: copyAll)
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private var fullText: String {
        if !entry.transcript.isEmpty { return entry.transcript }
        return entry.errorMessage ?? "No transcript was produced."
    }

    private func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullText, forType: .string)
        isCopied = true
    }
}

private struct LargeSelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text
        else { return }
        textView.string = text
    }
}

@MainActor
private enum HistoryLabels {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func date(_ value: Date) -> String {
        dateFormatter.string(from: value)
    }

    static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        SettingsPaneContainer(
            title: "General",
            subtitle: "Shortcuts, audio routing, and background behavior"
        ) {
            Form {
                Section {
                    LabeledContent("Push to talk") {
                        HStack(spacing: 7) {
                            MinimalKeyCap("fn")
                            Text("Hold")
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Hands-free toggle") {
                        HStack(spacing: 6) {
                            MinimalKeyCap("fn")
                            Text("+").foregroundStyle(.tertiary)
                            MinimalKeyCap("⇧")
                        }
                    }

                    Toggle("Add a space after each dictation", isOn: $engine.appendTrailingSpace)
                } header: {
                    DottedSectionLabel("Dictation")
                }

                Section {
                    Toggle(
                        "Launch WhisprGo at login",
                        isOn: Binding(
                            get: { engine.launchAtLogin },
                            set: { engine.setLaunchAtLogin($0) }
                        )
                    )
                    Text("WhisprGo stays available from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    DottedSectionLabel("Background")
                }

                Section {
                    Toggle(
                        "Use the Mac microphone instead of AirPods",
                        isOn: Binding(
                            get: { engine.preferBuiltInMicrophone },
                            set: { engine.setPreferBuiltInMicrophone($0) }
                        )
                    )
                    .disabled(engine.activity != .idle)

                    Text("On by default. Input is currently \(engine.microphoneRouteDescription), leaving AirPods available for high-quality playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    DottedSectionLabel("Audio Input")
                }

                Section {
                    Toggle(
                        "Keep microphone active between dictations",
                        isOn: Binding(
                            get: { engine.keepMicrophoneActive },
                            set: { engine.setKeepMicrophoneActive($0) }
                        )
                    )
                    .disabled(engine.activity != .idle)

                    Text("Off by default. When enabled, idle audio is discarded immediately and is never saved or transcribed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    DottedSectionLabel("Instant Response")
                }

                Section {
                    PermissionRow(title: "Microphone", isGranted: engine.permissions.microphone)
                    PermissionRow(title: "Accessibility", isGranted: engine.permissions.accessibility)

                    HStack {
                        Button("Request Permissions") {
                            engine.requestPermissions()
                        }
                        Button("Open Accessibility") {
                            engine.openAccessibilitySettings()
                        }
                        Button("Check Again") {
                            engine.refreshPermissions()
                        }
                    }
                } header: {
                    DottedSectionLabel("Permissions")
                }

                if let error = engine.lastError {
                    Section {
                        HStack(alignment: .top, spacing: 9) {
                            DotSelectionIndicator(isSelected: false)
                            Text(error)
                                .font(.callout)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct ModelSettingsPane: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        SettingsPaneContainer(
            title: "Models",
            subtitle: "Local-first by default, cloud-ready when you need it"
        ) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ModelSection(
                        title: "On Device",
                        subtitle: "Private, offline, and accelerated by Apple silicon.",
                        models: ModelCatalog.local,
                        engine: engine
                    )
                    ModelSection(
                        title: "OpenAI",
                        subtitle: "Uses your API key. Audio is sent only after you finish speaking.",
                        models: ModelCatalog.cloud,
                        engine: engine
                    )
                }
                .padding(18)
            }
        }
    }
}

private struct ModelSection: View {
    let title: String
    let subtitle: String
    let models: [TranscriptionModel]
    @ObservedObject var engine: DictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DottedSectionLabel(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(models) { model in
                ModelRow(model: model, engine: engine)
            }
        }
    }
}

private struct ModelRow: View {
    let model: TranscriptionModel
    @ObservedObject var engine: DictationEngine
    @State private var isConfirmingRemoval = false

    private var isSelected: Bool { engine.selectedModelID == model.id }
    private var isDownloaded: Bool {
        model.isLocal && engine.isModelDownloaded(model.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                engine.selectModel(model.id)
            } label: {
                HStack(spacing: 12) {
                    DotSelectionIndicator(isSelected: isSelected)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(model.name)
                                .font(.body.weight(.medium))
                            if model.recommended {
                                MinimalBadge("Default", filled: isSelected)
                            }
                        }
                        Text(model.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(model.sizeLabel ?? "API")
                            .font(.caption.monospacedDigit())
                        Text(status(for: model))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!engine.canChangeModel)
            .accessibilityLabel("\(model.name), \(status(for: model))")

            if isDownloaded {
                VStack(alignment: .trailing, spacing: 3) {
                    Button {
                        isConfirmingRemoval = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!engine.canRemoveDownloadedModel(model.id))

                    if isSelected {
                        Text("Switch model first")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .background(
            Color.primary.opacity(isSelected ? 0.055 : 0.012),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    Color.primary.opacity(isSelected ? 0.52 : 0.12),
                    lineWidth: 1
                )
        }
        .alert("Remove \(model.name)?", isPresented: $isConfirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Download", role: .destructive) {
                engine.removeDownloadedModel(model.id)
            }
        } message: {
            Text("This frees \(model.sizeLabel ?? "its downloaded data") of storage. Selecting it later downloads it again automatically.")
        }
    }

    private func status(for model: TranscriptionModel) -> String {
        if model.isLocal {
            if isSelected {
                switch engine.modelState {
                case let .downloading(progress):
                    return "Downloading \(Int(progress * 100))%"
                case .warming:
                    return "Loading"
                case .ready:
                    return "In use"
                case .failed:
                    return "Needs attention"
                case .starting:
                    return "Starting"
                case .needsAPIKey:
                    break
                }
            }
            return isDownloaded ? "Downloaded" : "Downloads on selection"
        }
        return engine.openAIKeyConfigured ? "Key configured" : "Key needed"
    }
}

private struct ProviderSettingsPane: View {
    @ObservedObject var engine: DictationEngine
    @State private var apiKey = ""
    @State private var didSave = false

    var body: some View {
        SettingsPaneContainer(
            title: "Providers",
            subtitle: "Optional cloud transcription, stored securely"
        ) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        BrandWaveform()
                            .frame(width: 74, height: 41)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("OpenAI")
                                .font(.headline)
                            Text(engine.openAIKeyConfigured ? "API key configured" : "No API key saved")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        MinimalBadge(
                            engine.openAIKeyConfigured ? "Ready" : "Optional",
                            filled: engine.openAIKeyConfigured
                        )
                    }
                }

                Section {
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)

                    HStack {
                        Button("Save in Keychain", action: save)
                            .buttonStyle(.borderedProminent)
                            .tint(.primary)
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if engine.openAIKeyConfigured {
                            Button("Remove Key", role: .destructive) {
                                if engine.saveOpenAIAPIKey("") {
                                    apiKey = ""
                                }
                            }
                        }

                        if didSave {
                            MinimalBadge("Saved", filled: true)
                        }
                    }
                } header: {
                    DottedSectionLabel("API Key")
                }

                Section {
                    Text("The key is stored in macOS Keychain. It is never written to preferences, logs, or source files. Local models never send audio over the network.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    DottedSectionLabel("Privacy")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func save() {
        if engine.saveOpenAIAPIKey(apiKey) {
            apiKey = ""
            didSave = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                didSave = false
            }
        }
    }
}

private struct SettingsPaneContainer<Content: View>: View {
    let title: String
    let subtitle: String
    private let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                BrandWaveform()
                    .frame(width: 76, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 20, weight: .medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 11)

            DottedRule()
                .padding(.horizontal, 20)

            content
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let isGranted: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 7) {
                DotSelectionIndicator(isSelected: isGranted)
                Text(isGranted ? "Allowed" : "Required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
