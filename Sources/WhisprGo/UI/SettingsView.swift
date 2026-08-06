import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case models
    case profiles
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

            ProfileSettingsPane(engine: engine)
                .tabItem { Label("Profiles", systemImage: "text.badge.star") }
                .tag(SettingsTab.profiles)

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
                        .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .topLeading)
                        .clipped()
                        .layoutPriority(1)

                    HStack(spacing: 7) {
                        Text(entry.modelName)
                        if let latency = entry.latency {
                            Text("·")
                            Text("\(latency.formatted(.number.precision(.fractionLength(2))))s")
                                .monospacedDigit()
                        }
                        if let error = entry.errorMessage {
                            Text("·")
                            Text(error)
                                .help(error)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 6) {
                    HistoryIconButton(
                        systemImage: "doc.text.magnifyingglass",
                        label: "Inspect full transcript",
                        action: onInspect
                    )
                    HistoryIconButton(
                        systemImage: "arrow.clockwise",
                        label: "Re-run and type",
                        isBusy: isRerunning,
                        isDisabled: !canRerun || isRerunning,
                        action: onRerun
                    )
                    HistoryIconButton(
                        systemImage: "trash",
                        label: "Delete recording",
                        isDestructive: true,
                        action: onRemove
                    )
                }
                .frame(width: 28)
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

private struct HistoryIconButton: View {
    let systemImage: String
    let label: String
    var isBusy = false
    var isDisabled = false
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isDestructive ? Color.red.opacity(0.82) : Color.primary)
                }
            }
            .frame(width: 27, height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
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

            if let error = entry.errorMessage {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }

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
    @State private var isConfirmingLocalCleanup = false
    @State private var isConfirmingLocalRemoval = false
    @State private var recordingHotkey: HotkeyAction?
    @State private var hotkeyError: String?

    var body: some View {
        SettingsPaneContainer(
            title: "General",
            subtitle: "Processing, shortcuts, audio routing, and background behavior"
        ) {
            Form {
                Section {
                    Picker(
                        "Mode",
                        selection: Binding(
                            get: { engine.dictationMode },
                            set: { engine.setDictationMode($0) }
                        )
                    ) {
                        ForEach(DictationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(engine.activity != .idle)

                    Text(engine.dictationModeDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Use nearby text as context in Pro Mode",
                        isOn: Binding(
                            get: { engine.proContextEnabled },
                            set: { engine.setProContextEnabled($0) }
                        )
                    )
                    .disabled(engine.activity != .idle)

                    Text("Accessibility text is read once after recording starts. Fast Mode never reads or sends context. Screenshots are never captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if engine.dictationMode == .pro {
                        LabeledContent("Last context capture") {
                            Text(
                                engine.proContextEnabled
                                    ? (engine.lastContextSummary ?? "Not captured yet")
                                    : "Turned off"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    DottedSectionLabel("Processing")
                }

                Section {
                    Picker(
                        "Cleanup provider",
                        selection: Binding(
                            get: { engine.proCleanupProvider },
                            set: { provider in
                                if provider == .local,
                                   engine.proCleanupProvider != .local {
                                    isConfirmingLocalCleanup = true
                                } else {
                                    engine.setProCleanupProvider(provider)
                                }
                            }
                        )
                    ) {
                        ForEach(ProCleanupProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(engine.activity != .idle)

                    Text(engine.proCleanupProvider.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if engine.proCleanupProvider == .local {
                        LabeledContent(LocalProModel.displayName) {
                            Text(localModelStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if case let .downloading(progress) = engine.localProModelState {
                            ProgressView(value: progress)
                                .accessibilityLabel("Downloading local cleanup model")
                        }

                        Label(
                            "Uses \(LocalProModel.diskUsageLabel) of storage and \(LocalProModel.memoryUsageLabel) while loaded.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)

                        Text("WhisprGo keeps it loaded throughout Pro Mode. After you leave Pro Mode, it unloads after \(LocalProModel.unloadDelayLabel) of inactivity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Link("View MLX model", destination: LocalProModel.mlxSourceURL)
                            Link("Original GGUF", destination: LocalProModel.sourceURL)

                            if case .failed = engine.localProModelState {
                                Button("Try Again") {
                                    engine.prepareLocalProModel()
                                }
                            }
                        }
                    } else if engine.isLocalProModelDownloaded {
                        HStack {
                            Text("Local Gemma download")
                            Spacer()
                            Text(LocalProModel.diskUsageLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button("Remove Download", role: .destructive) {
                                isConfirmingLocalRemoval = true
                            }
                            .disabled(!engine.canRemoveLocalProModel)
                        }
                    }
                } header: {
                    DottedSectionLabel("Pro Cleanup")
                }

                Section {
                    ForEach(HotkeyAction.allCases) { action in
                        HotkeyRecorderRow(
                            action: action,
                            shortcut: engine.hotkeyConfiguration[action],
                            isRecording: recordingHotkey == action,
                            onStart: { beginRecording(action) },
                            onCancel: cancelHotkeyRecording,
                            onCapture: { save($0, for: action) }
                        )
                        .disabled(engine.activity != .idle)
                    }

                    if let hotkeyError {
                        Label(hotkeyError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Text("Changes take effect immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Defaults") {
                            cancelHotkeyRecording()
                            engine.resetHotkeys()
                            hotkeyError = nil
                        }
                        .disabled(
                            engine.hotkeyConfiguration == .default || engine.activity != .idle
                        )
                    }
                } header: {
                    DottedSectionLabel("Shortcuts")
                } footer: {
                    Text("Click a shortcut, then press the new combination. Press Escape to cancel. Ordinary typing keys need a modifier.")
                }

                Section {
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
        .onDisappear {
            if recordingHotkey != nil {
                cancelHotkeyRecording()
            }
        }
        .alert("Use local Pro cleanup beta?", isPresented: $isConfirmingLocalCleanup) {
            Button("Cancel", role: .cancel) {}
            Button(engine.isLocalProModelDownloaded ? "Use Beta" : "Download Beta & Use") {
                engine.setProCleanupProvider(.local)
            }
        } message: {
            Text("This beta uses Gemma 4 E2B. It needs \(LocalProModel.diskUsageLabel) of storage and may use \(LocalProModel.memoryUsageLabel) while Pro Mode is active. The model and cleanup text stay on this Mac.")
        }
        .alert("Remove local cleanup model?", isPresented: $isConfirmingLocalRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Download", role: .destructive) {
                engine.removeLocalProModelDownload()
            }
        } message: {
            Text("This frees \(LocalProModel.diskUsageLabel) of storage. Choosing On Device (Beta) again downloads the model automatically.")
        }
    }

    private func beginRecording(_ action: HotkeyAction) {
        if recordingHotkey == nil {
            guard engine.beginRecordingHotkey() else { return }
        }
        recordingHotkey = action
        hotkeyError = nil
    }

    private func cancelHotkeyRecording() {
        guard recordingHotkey != nil else { return }
        recordingHotkey = nil
        hotkeyError = nil
        engine.endRecordingHotkey()
    }

    private func save(_ shortcut: HotkeyShortcut, for action: HotkeyAction) {
        if let validationMessage = shortcut.validationMessage {
            hotkeyError = validationMessage
            return
        }
        if let conflict = engine.setHotkey(shortcut, for: action) {
            hotkeyError = "That shortcut is already used for \(conflict.title.lowercased())."
            return
        }
        recordingHotkey = nil
        hotkeyError = nil
        engine.endRecordingHotkey()
    }

    private var localModelStatus: String {
        switch engine.localProModelState {
        case .notDownloaded: return "Waiting to download"
        case let .downloading(progress): return "Downloading \(Int(progress * 100))%"
        case .loading: return "Loading with MLX"
        case .ready: return "Loaded for Pro Mode"
        case .downloaded: return "Downloaded · unloaded"
        case .failed: return "Needs attention"
        }
    }
}

private struct ProfileSettingsPane: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject private var store = ProProfileStore.shared
    @State private var draftName = ""
    @State private var draftPrompt = ""

    var body: some View {
        SettingsPaneContainer(
            title: "Pro Profiles",
            subtitle: "Custom cleanup rules for different kinds of writing"
        ) {
            HStack(spacing: 0) {
                profileList
                    .frame(width: 190)

                Divider()

                profileEditor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform:loadSelectedProfile)
        .onChange(of: store.selectedProfileID) { _, _ in
            loadSelectedProfile()
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            DottedSectionLabel("Profiles")

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.profiles) { profile in
                        Button {
                            select(profile.id)
                        } label: {
                            HStack(spacing: 9) {
                                DotSelectionIndicator(
                                    isSelected: profile.id == store.selectedProfileID
                                )
                                Text(profile.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                            .background(
                                Color.primary.opacity(
                                    profile.id == store.selectedProfileID ? 0.06 : 0
                                ),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Button {
                    saveDraftIfPossible()
                    _ = store.create()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(role: .destructive) {
                    store.remove(store.selectedProfileID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(store.profiles.count <= 1)
                .help("Delete profile")
                .accessibilityLabel("Delete selected profile")
            }
        }
        .padding(16)
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                DottedSectionLabel("Selected Profile")
                Spacer()
                MinimalBadge("Pro only")
            }

            TextField("Profile name", text: $draftName)
                .textFieldStyle(.roundedBorder)

            Text("Custom instructions")
                .font(.callout.weight(.medium))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draftPrompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(7)

                if draftPrompt.isEmpty {
                    Text("Example: Keep emails concise and warm. Preserve greetings and sign-offs.")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 15)
                        .allowsHitTesting(false)
                }
            }
            .background(
                Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
            .frame(minHeight: 190)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cycle while in Pro Mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HotkeyCapsView(
                        shortcut: engine.hotkeyConfiguration[.cycleProfile],
                        compact: true
                    )
                }

                Spacer()

                Text("\(draftPrompt.count) / 12,000")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Button("Save Profile", action: saveDraftIfPossible)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .disabled(!isDirty || cleanDraftName.isEmpty)
            }
        }
        .padding(18)
    }

    private var cleanDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDirty: Bool {
        let profile = store.selectedProfile
        return cleanDraftName != profile.name || draftPrompt != profile.prompt
    }

    private func select(_ id: UUID) {
        guard id != store.selectedProfileID else { return }
        saveDraftIfPossible()
        store.select(id)
    }

    private func loadSelectedProfile() {
        let profile = store.selectedProfile
        draftName = profile.name
        draftPrompt = profile.prompt
    }

    private func saveDraftIfPossible() {
        guard !cleanDraftName.isEmpty else { return }
        store.update(
            id: store.selectedProfileID,
            name: cleanDraftName,
            prompt: draftPrompt
        )
        loadSelectedProfile()
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
            subtitle: "Cloud transcription and Pro Mode, stored securely"
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
                    Text("The key is stored in macOS Keychain. Fast Mode with a local model sends nothing to OpenAI. Pro Mode sends the raw transcript and, when enabled, bounded Accessibility text to GPT-5.6 Luna only when OpenAI is selected as the cleanup provider. The On Device beta keeps both on this Mac. WhisprGo never captures screenshots.")
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
