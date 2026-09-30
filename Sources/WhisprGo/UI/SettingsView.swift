import AppKit
import AVFoundation
import SwiftUI

enum SettingsTab: Hashable, CaseIterable {
    case general
    case models
    case profiles
    case history
    case providers

    var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .profiles: return "Profiles"
        case .history: return "History"
        case .providers: return "API Keys"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "waveform"
        case .profiles: return "text.quote"
        case .history: return "clock"
        case .providers: return "key"
        }
    }
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
        HStack(spacing: 0) {
            SettingsSidebar(selection: $navigation.selection)
                .frame(width: 184)

            Divider()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text(navigation.selection.title)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.4)
                    .padding(.horizontal, 24)
                    .padding(.top, 46)
                    .padding(.bottom, 6)
                    .id(navigation.selection)
                    .transition(.blurReplace)

                ZStack {
                    pane(for: navigation.selection)
                        .id(navigation.selection)
                        .transition(.blurReplace)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: .top)
            .animation(Signal.motion, value: navigation.selection)
        }
        .frame(width: 760, height: 560)
        .background(Signal.background)
        .tint(Signal.control)
        .onAppear {
            engine.refreshPermissions()
            engine.refreshMicrophoneRoutes()
        }
    }

    @ViewBuilder
    private func pane(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsPane(engine: engine)
        case .models: ModelSettingsPane(engine: engine)
        case .profiles: ProfileSettingsPane(engine: engine)
        case .history: HistorySettingsPane(engine: engine)
        case .providers: ProviderSettingsPane(engine: engine)
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @Namespace private var namespace

    var body: some View {
        VStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                item(tab)
            }
            Spacer()
            BrandWaveform()
                .frame(width: 34, height: 19)
                .foregroundStyle(Signal.textTertiary)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.03))
        .ignoresSafeArea()
    }

    private func item(_ tab: SettingsTab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(Signal.motion) { selection = tab }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(isSelected ? Signal.text : Signal.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Signal.surfaceHover)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HistorySettingsPane: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject private var history = DictationHistoryStore.shared
    @State private var isConfirmingClear = false
    @State private var inspectedEntry: DictationHistoryEntry?

    var body: some View {
        SettingsPaneContainer {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("\(history.entries.count) of 50")
                        .font(.system(size: 12))
                        .foregroundStyle(Signal.textSecondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Clear All", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .buttonStyle(SignalPillButtonStyle())
                    .disabled(history.entries.isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)

                if let error = history.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 9)
                }

                if history.entries.isEmpty {
                    HistoryEmptyState()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
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
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
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
                .frame(width: 88, height: 48)
                .foregroundStyle(Signal.textTertiary)
            Text("No dictations yet")
                .font(.system(size: 13))
                .foregroundStyle(Signal.textSecondary)
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
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Button(action: copyTranscript) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isCopied ? Signal.surfaceHover : Signal.surface)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy full transcript")

            HStack(alignment: .top, spacing: 12) {
                Button(action: onPlay) {
                    ZStack {
                        Circle()
                            .fill(isPlaying ? Color.primary : Signal.surfaceHover)
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isPlaying ? Signal.inverse : Signal.text)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 30, height: 30)
                    .animation(Signal.quick, value: isPlaying)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Stop recording" : "Play recording")

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(HistoryLabels.date(entry.createdAt))
                        Text(HistoryLabels.duration(entry.duration))
                            .monospacedDigit()
                        if isCopied {
                            Label("Copied", systemImage: "checkmark")
                                .foregroundStyle(Signal.text)
                                .transition(.blurReplace)
                        }
                    }

                    .font(.system(size: 11))
                    .foregroundStyle(Signal.textSecondary)

                    Text(previewText)
                        .font(.system(size: 13))
                        .foregroundStyle(entry.transcript.isEmpty ? .secondary : .primary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                }
                .help(entry.modelName)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 2) {
                    HistoryIconButton(
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        label: "Open full transcript",
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
                        label: "Delete",
                        action: onRemove
                    )
                }
                .opacity(isHovered || isRerunning ? 1 : 0)
            }
            .padding(12)
        }
        .onHover { hovering in
            withAnimation(Signal.quick) { isHovered = hovering }
        }
        .animation(Signal.quick, value: isCopied)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Signal.textSecondary)
                }
            }
            .frame(width: 26, height: 26)
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
            HStack {
                Text("\(HistoryLabels.date(entry.createdAt))  ·  \(HistoryLabels.duration(entry.duration))  ·  \(entry.modelName)")
                    .font(.system(size: 12))
                    .foregroundStyle(Signal.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 4)

            if let error = entry.errorMessage {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
            }

            LargeSelectableTextView(text: fullText)
                .padding(18)

            HStack(spacing: 8) {
                if isCopied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(Signal.textSecondary)
                        .transition(.blurReplace)
                }
                Spacer()
                Button("Copy All", action: copyAll)
                    .buttonStyle(SignalPillButtonStyle())
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(SignalPillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .animation(Signal.quick, value: isCopied)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
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
    @State private var recordingHotkey: HotkeyAction?
    @State private var hotkeyError: String?

    var body: some View {
        SettingsPaneContainer {
            Form {
                Section("Dictation") {
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

                    Picker(
                        "Pro engine",
                        selection: Binding(
                            get: { engine.proModeEngine },
                            set: { engine.setProModeEngine($0) }
                        )
                    ) {
                        ForEach(ProModeEngine.allCases) { proEngine in
                            Text(proEngine.title).tag(proEngine)
                        }
                    }
                    .disabled(engine.activity != .idle)
                    .help(engine.proModeEngine.detail)

                    Toggle(
                        "Use nearby text in Pro Mode",
                        isOn: Binding(
                            get: { engine.proContextEnabled },
                            set: { engine.setProContextEnabled($0) }
                        )
                    )
                    .disabled(engine.activity != .idle)
                    .help(proContextExplanation)

                    Toggle("Add a space after dictation", isOn: $engine.appendTrailingSpace)

                    if engine.isRetiredProModelDownloaded {
                        LabeledContent("Unused Gemma model (4.6 GB)") {
                            Button("Remove") {
                                engine.removeRetiredProModelDownload()
                            }
                            .disabled(engine.activity != .idle)
                        }
                    }
                }

                Section("Shortcuts") {
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
                        Label(hotkeyError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }

                    HStack {
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
                }

                Section("Microphone") {
                    LabeledContent("Current input") {
                        Text(engine.microphoneRouteDescription)
                            .multilineTextAlignment(.trailing)
                    }
                    .help("The Mac microphone is preferred. Bluetooth headset microphones are ignored. Allow an external microphone below to prefer it while connected.")

                    ForEach(externalMicrophoneRoutes) { route in
                        Toggle(
                            route.isBluetooth ? "\(route.name) (Bluetooth)" : "Prefer \(route.name)",
                            isOn: Binding(
                                get: {
                                    !route.isBluetooth
                                        && engine.allowedExternalMicrophoneUIDs.contains(route.uid)
                                },
                                set: { engine.setExternalMicrophoneAllowed(route, allowed: $0) }
                            )
                        )
                        .disabled(route.isBluetooth || engine.activity != .idle)
                        .help(route.isBluetooth ? "Bluetooth microphones are ignored." : route.transport.label)
                    }

                    ForEach(disconnectedMicrophoneUIDs, id: \.self) { uid in
                        LabeledContent("\(engine.knownExternalMicrophoneNames[uid] ?? "External microphone") (disconnected)") {
                            Button("Forget") {
                                engine.removeDisconnectedMicrophoneException(uid)
                            }
                            .disabled(engine.activity != .idle)
                        }
                    }

                    Toggle(
                        "Keep microphone ready",
                        isOn: Binding(
                            get: { engine.keepMicrophoneActive },
                            set: { engine.setKeepMicrophoneActive($0) }
                        )
                    )
                    .disabled(engine.activity != .idle)
                    .help("Faster start. Idle audio is discarded immediately and is never saved or transcribed.")

                    HStack {
                        Spacer()
                        Button("Refresh Devices") {
                            engine.refreshMicrophoneRoutes()
                        }
                    }
                }

                Section("System") {
                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { engine.launchAtLogin },
                            set: { engine.setLaunchAtLogin($0) }
                        )
                    )
                    PermissionRow(
                        title: "Microphone",
                        isGranted: engine.permissions.microphone,
                        open: allowMicrophone
                    )
                    PermissionRow(
                        title: "Accessibility",
                        isGranted: engine.permissions.accessibility,
                        open: allowAccessibility
                    )
                }

                if let error = engine.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onDisappear {
            if recordingHotkey != nil {
                cancelHotkeyRecording()
            }
        }
    }

    private func allowMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            engine.requestPermissions()
        } else {
            engine.openMicrophoneSettings()
        }
    }

    private func allowAccessibility() {
        // Prompting first adds WhisprGo to the Accessibility list.
        engine.requestPermissions()
        engine.openAccessibilitySettings()
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

    private var externalMicrophoneRoutes: [AudioInputRoute] {
        engine.microphoneRoutes.filter { !$0.isBuiltIn }
    }

    private var disconnectedMicrophoneUIDs: [String] {
        let connected = Set(engine.microphoneRoutes.map(\.uid))
        return engine.allowedExternalMicrophoneUIDs
            .subtracting(connected)
            .sorted { (engine.knownExternalMicrophoneNames[$0] ?? $0)
                < (engine.knownExternalMicrophoneNames[$1] ?? $1) }
    }

    private var proContextExplanation: String {
        switch engine.proModeEngine {
        case .instruct:
            return "Accessibility text is read once after recording starts and sent with the raw transcript to Instruct Pro for names, tone, formatting, and cursor continuity. Fast Mode never reads this context, and screenshots are never captured."
        case .geminiTranscribe:
            return "Accessibility text is read once after recording starts. Relevant names and technical terms are sent to Gemini as vocabulary hints. Fast Mode never reads this context, and screenshots are never captured."
        }
    }
}

private struct ProfileSettingsPane: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject private var store = ProProfileStore.shared
    @State private var draftName = ""
    @State private var draftPrompt = ""

    var body: some View {
        SettingsPaneContainer {
            HStack(spacing: 0) {
                profileList
                    .frame(width: 180)

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
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.profiles) { profile in
                        Button {
                            select(profile.id)
                        } label: {
                            HStack {
                                Text(profile.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .font(.system(
                                size: 13,
                                weight: profile.id == store.selectedProfileID ? .semibold : .regular
                            ))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                            .background(
                                profile.id == store.selectedProfileID
                                    ? Signal.surfaceHover
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .animation(Signal.quick, value: store.selectedProfileID)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 4) {
                Button {
                    saveDraftIfPossible()
                    _ = store.create()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New profile")
                .accessibilityLabel("New profile")

                Button(role: .destructive) {
                    store.remove(store.selectedProfileID)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(store.profiles.count <= 1)
                .help("Delete profile")
                .accessibilityLabel("Delete selected profile")
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Profile name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draftPrompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(7)

                if draftPrompt.isEmpty {
                    Text(profilePlaceholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 15)
                        .allowsHitTesting(false)
                }
            }
            .background(
                Signal.surface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Signal.hairline, lineWidth: 1)
            }
            .frame(maxHeight: .infinity)
            .help(profileGuidance)

            HStack(spacing: 10) {
                Text(profileCounter)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Signal.textTertiary)
                    .contentTransition(.numericText())

                Spacer()

                Button("Save", action: saveDraftIfPossible)
                    .buttonStyle(SignalPillButtonStyle(prominent: true))
                    .disabled(!isDirty || cleanDraftName.isEmpty)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var cleanDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var profileGuidance: String {
        switch engine.proModeEngine {
        case .instruct:
            return "Instruct Pro applies these trusted writing instructions after transcription. Nearby text can also guide names, tone, formatting, and how the text continues at the cursor."
        case .geminiTranscribe:
            return "Enter names, product terms, acronyms, or short phrases separated by commas or new lines. Gemini uses up to 100 terms from this profile plus nearby text."
        }
    }

    private var profilePlaceholder: String {
        switch engine.proModeEngine {
        case .instruct:
            return "Writing instructions, e.g. Keep emails concise and warm."
        case .geminiTranscribe:
            return "Names and terms, one per line"
        }
    }

    private var profileCounter: String {
        switch engine.proModeEngine {
        case .instruct:
            return "\(draftPrompt.count) / 12,000"
        case .geminiTranscribe:
            return "\(GeminiVocabulary.terms(profileText: draftPrompt, context: nil).count) / 100 terms"
        }
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
        SettingsPaneContainer {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ModelSection(
                        title: "On device",
                        models: ModelCatalog.local,
                        engine: engine
                    )
                    ModelSection(
                        title: "OpenAI",
                        models: ModelCatalog.cloud,
                        engine: engine
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
    }
}

private struct ModelSection: View {
    let title: String
    let models: [TranscriptionModel]
    @ObservedObject var engine: DictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DottedSectionLabel(title)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    if index > 0 {
                        Divider().padding(.leading, 40)
                    }
                    ModelRow(model: model, engine: engine)
                }
            }
            .background(Signal.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Signal.hairline, lineWidth: 1)
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
        HStack(spacing: 8) {
            Button {
                engine.selectModel(model.id)
            } label: {
                HStack(spacing: 12) {
                    DotSelectionIndicator(isSelected: isSelected)
                    Text(model.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Spacer()
                    if let status {
                        Text(status)
                            .foregroundStyle(Signal.textSecondary)
                    }
                    Text(model.sizeLabel ?? "API")
                        .monospacedDigit()
                        .foregroundStyle(Signal.textTertiary)
                }
                .font(.system(size: 12))
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!engine.canChangeModel)
            .help(model.detail)
            .accessibilityLabel("\(model.name)\(status.map { ", \($0)" } ?? "")")

            Button {
                isConfirmingRemoval = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Signal.textSecondary)
            }
            .buttonStyle(.borderless)
            .disabled(!isDownloaded || !engine.canRemoveDownloadedModel(model.id))
            .opacity(isDownloaded ? 1 : 0)
            .help(isSelected ? "Switch to another model to remove this one" : "Remove download")
            .accessibilityHidden(!isDownloaded)
            .padding(.trailing, 12)
        }
        .animation(Signal.motion, value: isSelected)
        .alert("Remove \(model.name)?", isPresented: $isConfirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Download", role: .destructive) {
                engine.removeDownloadedModel(model.id)
            }
        } message: {
            Text("This frees \(model.sizeLabel ?? "its downloaded data") of storage. Selecting it later downloads it again automatically.")
        }
    }

    /// Only states worth reading; "downloads on selection" is the default.
    private var status: String? {
        if model.isLocal {
            if isSelected {
                switch engine.modelState {
                case let .downloading(progress):
                    return "\(Int(progress * 100))%"
                case .warming, .starting:
                    return "Loading"
                case .failed:
                    return "Needs attention"
                case .ready, .needsAPIKey:
                    return nil
                }
            }
            return isDownloaded ? "Downloaded" : nil
        }
        return engine.openAIKeyConfigured ? nil : "Needs key"
    }
}

private struct ProviderSettingsPane: View {
    @ObservedObject var engine: DictationEngine
    @State private var googleAPIKey = ""
    @State private var openAIAPIKey = ""
    @State private var savedProvider: String?

    var body: some View {
        SettingsPaneContainer {
            Form {
                Section("Google Gemini") {
                    ProviderKeyRow(
                        placeholder: "Paste from Google AI Studio",
                        key: $googleAPIKey,
                        isConfigured: engine.googleAPIKeyConfigured,
                        didSave: savedProvider == "google",
                        onSave: saveGoogleKey,
                        onRemove: {
                            if engine.saveGoogleAPIKey("") { googleAPIKey = "" }
                        }
                    )
                }

                Section("OpenAI") {
                    ProviderKeyRow(
                        placeholder: "Paste from OpenAI",
                        key: $openAIAPIKey,
                        isConfigured: engine.openAIKeyConfigured,
                        didSave: savedProvider == "openai",
                        onSave: saveOpenAIKey,
                        onRemove: {
                            if engine.saveOpenAIAPIKey("") { openAIAPIKey = "" }
                        }
                    )
                }

                Section {
                    Text("Keys are stored in macOS Keychain. Fast Mode with a local model stays on this Mac. Instruct Pro sends its transcript and enabled nearby text to OpenAI. Gemini Pro uploads the recording to Google with vocabulary hints and requests deletion afterwards. WhisprGo never captures screenshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Privacy")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func saveGoogleKey() {
        if engine.saveGoogleAPIKey(googleAPIKey) {
            googleAPIKey = ""
            showSaved("google")
        }
    }

    private func saveOpenAIKey() {
        if engine.saveOpenAIAPIKey(openAIAPIKey) {
            openAIAPIKey = ""
            showSaved("openai")
        }
    }

    private func showSaved(_ provider: String) {
        savedProvider = provider
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if savedProvider == provider {
                savedProvider = nil
            }
        }
    }
}

private struct ProviderKeyRow: View {
    let placeholder: String
    @Binding var key: String
    let isConfigured: Bool
    let didSave: Bool
    let onSave: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SecureField(
                "API key",
                text: $key,
                prompt: Text(isConfigured ? "Saved in Keychain" : placeholder)
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(onSave)

            if didSave {
                Image(systemName: "checkmark")
                    .foregroundStyle(Signal.textSecondary)
                    .transition(.blurReplace)
                    .accessibilityLabel("Saved")
            }

            if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Save", action: onSave)
            } else if isConfigured {
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
        .animation(Signal.quick, value: didSave)
    }
}

/// The pane body beneath the shell's title.
private struct SettingsPaneContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct PermissionRow: View {
    let title: String
    let isGranted: Bool
    let open: () -> Void

    var body: some View {
        LabeledContent(title) {
            if isGranted {
                Image(systemName: "checkmark")
                    .foregroundStyle(Signal.textSecondary)
                    .accessibilityLabel("Allowed")
            } else {
                Button("Allow…", action: open)
            }
        }
    }
}
