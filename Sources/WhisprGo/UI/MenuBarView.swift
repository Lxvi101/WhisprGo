import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                hero

                if let error = engine.lastError {
                    MenuErrorNotice(message: error)
                }

                if case let .downloading(progress) = engine.modelState {
                    DownloadProgress(progress: progress)
                }

                if !engine.permissions.isComplete {
                    SetupNotice(engine: engine)
                } else if engine.needsProviderKey {
                    APIKeyNotice(engine: engine)
                }

                controls

                dictationButton
            }
            .padding(16)

            RecentHistory(engine: engine)

            if let update = updates.availableUpdate {
                UpdateRow(update: update)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            Divider()

            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: 320)
        .tint(Signal.control)
        .onAppear {
            engine.refreshPermissions()
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            SignalField(phase: fieldPhase, levelMeter: engine.levelMeter)
                .frame(height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(engine.stateTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.6)
                    .id(engine.stateTitle)
                    .transition(.blurReplace)

                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Signal.textSecondary)
                        .lineLimit(2)
                        .id(hint)
                        .transition(.blurReplace)
                }
            }
            .animation(Signal.motion, value: engine.stateTitle)
            .animation(Signal.motion, value: hint)
        }
    }

    /// One line of guidance, shown only when it tells you what to do next.
    /// Setup, key, download, and error states have their own notices.
    private var hint: String? {
        guard engine.lastError == nil else { return nil }
        switch engine.activity {
        case .recording: return engine.stateDetail
        case .transcribing: return nil
        case .idle: return engine.canToggle ? engine.stateDetail : nil
        }
    }

    private var fieldPhase: SignalField.Phase {
        switch engine.activity {
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .idle: return engine.canToggle ? .idle : .attention
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            SignalSegmentedControl(
                options: DictationMode.allCases,
                selection: modeBinding
            ) { mode in
                Text(mode.title)
            }
            .disabled(engine.activity != .idle)

            if engine.dictationMode == .pro {
                ProProfilePicker()
            } else {
                HStack {
                    Text("Model")
                        .foregroundStyle(Signal.textSecondary)
                    Spacer()
                    Picker("Model", selection: modelBinding) {
                        Section("On device") {
                            ForEach(ModelCatalog.local) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                        Section("OpenAI") {
                            ForEach(ModelCatalog.cloud) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(!engine.canChangeModel)
                    .accessibilityLabel("Transcription model")
                }
                .font(.system(size: 12))
            }
        }
    }

    private var dictationButton: some View {
        let isRecording = engine.activity == .recording
        return Button(action: engine.toggleDictation) {
            HStack(spacing: 9) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
                    .contentTransition(.symbolEffect(.replace))
                Text(isRecording ? "Stop and Type" : "Start Dictating")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HotkeyCapsView(
                    shortcut: engine.hotkeyConfiguration[.toggleDictation],
                    compact: true,
                    inverted: true
                )
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(MonochromePrimaryButtonStyle())
        .disabled(!engine.canToggle)
        .opacity(engine.canToggle ? 1 : 0.35)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Settings", systemImage: "gearshape") {
                SettingsWindowController.shared.show(engine: engine)
            }
            Spacer()
            FooterButton(title: nil, systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .help("Quit WhisprGo")
            .accessibilityLabel("Quit WhisprGo")
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { engine.selectedModelID },
            set: { engine.selectModel($0) }
        )
    }

    private var modeBinding: Binding<DictationMode> {
        Binding(
            get: { engine.dictationMode },
            set: { engine.setDictationMode($0) }
        )
    }
}

private struct FooterButton: View {
    let title: String?
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                if let title {
                    Text(title)
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(isHovered ? Signal.text : Signal.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? Signal.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Signal.quick) { isHovered = hovering }
        }
    }
}

/// The last few dictations, one line each. Clicking a row copies its text.
private struct RecentHistory: View {
    @ObservedObject var engine: DictationEngine
    @ObservedObject private var history = DictationHistoryStore.shared

    private static let limit = 3

    var body: some View {
        let recent = Array(history.entries.prefix(Self.limit))
        Group {
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Recent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Signal.textSecondary)
                        Spacer()
                        Button("See All") {
                            SettingsWindowController.shared.show(engine: engine, tab: .history)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Signal.textSecondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                    // Refresh relative times once a minute while the menu is open.
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        VStack(spacing: 0) {
                            ForEach(recent) { entry in
                                RecentHistoryRow(entry: entry, now: timeline.date)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .animation(Signal.motion, value: recent.map(\.id))
        .onAppear {
            history.loadIfNeeded()
        }
    }
}

private struct RecentHistoryRow: View {
    let entry: DictationHistoryEntry
    let now: Date
    @State private var isHovered = false
    @State private var isCopied = false
    @State private var copyGeneration = 0

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 10) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.transcript.isEmpty ? Signal.textSecondary : Signal.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if isCopied {
                        Image(systemName: "checkmark")
                    } else if isHovered {
                        Image(systemName: "doc.on.doc")
                    } else {
                        Text(Self.age(of: entry.createdAt, now: now))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Signal.textSecondary)
                .frame(minWidth: 24, alignment: .trailing)
                .transition(.opacity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isHovered ? Signal.surfaceHover : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Signal.quick) { isHovered = hovering }
        }
        .help(entry.transcript.isEmpty ? text : HistoryText.preview(entry.transcript))
        .accessibilityLabel("Copy: \(text)")
    }

    private var text: String {
        if !entry.transcript.isEmpty { return entry.transcript }
        return entry.errorMessage ?? "No transcript"
    }

    private func copy() {
        guard !entry.transcript.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.transcript, forType: .string)

        copyGeneration &+= 1
        let generation = copyGeneration
        withAnimation(Signal.quick) { isCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard copyGeneration == generation else { return }
            withAnimation(Signal.quick) { isCopied = false }
        }
    }

    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

private struct UpdateRow: View {
    let update: AppUpdate

    var body: some View {
        Button {
            AutomaticUpdater.shared.checkForUpdates()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                Text("Update to \(update.version)")
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Install WhisprGo \(update.version)")
    }
}

private struct MenuErrorNotice: View {
    let message: String
    @State private var didCopy = false

    var body: some View {
        MinimalPanel(padding: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .medium))
                Text(message)
                    .font(.system(size: 12))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: copyDetails) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Signal.textSecondary)
                .help(didCopy ? "Copied" : "Copy error")
                .accessibilityLabel(didCopy ? "Error copied" : "Copy error")
            }
        }
    }

    private func copyDetails() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)
        didCopy = true
    }
}

private struct ProProfilePicker: View {
    @ObservedObject private var store = ProProfileStore.shared

    var body: some View {
        HStack {
            Text("Profile")
                .foregroundStyle(Signal.textSecondary)
            Spacer()
            Picker("Profile", selection: selection) {
                ForEach(store.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .font(.system(size: 12))
    }

    private var selection: Binding<UUID> {
        Binding(
            get: { store.selectedProfileID },
            set: { store.select($0) }
        )
    }
}

/// Download progress drawn as a row of dots, echoing the waveform mark.
struct DotProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, Int(proxy.size.width / 7))
            let filled = progress * Double(count)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    let fill = min(1, max(0, filled - Double(index)))
                    Circle()
                        .fill(Color.primary.opacity(0.15 + 0.85 * fill))
                        .frame(width: 4, height: 4)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 6)
        .animation(Signal.motion, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

private struct DownloadProgress: View {
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloading model")
                Spacer()
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(Signal.textSecondary)
                    .contentTransition(.numericText())
            }
            .font(.system(size: 12))
            DotProgressBar(progress: progress)
        }
    }
}

private struct SetupNotice: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        MinimalPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(missingPermissions)
                    .font(.system(size: 12))
                HStack(spacing: 6) {
                    Button("Allow") {
                        engine.requestPermissions()
                    }
                    .buttonStyle(SignalPillButtonStyle(prominent: true))
                    Button("Open Settings") {
                        if engine.permissions.microphone {
                            engine.openAccessibilitySettings()
                        } else {
                            engine.openMicrophoneSettings()
                        }
                    }
                    .buttonStyle(SignalPillButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var missingPermissions: String {
        switch (engine.permissions.microphone, engine.permissions.accessibility) {
        case (false, false): return "Allow Microphone and Accessibility access."
        case (false, true): return "Allow Microphone access."
        default: return "Allow Accessibility access."
        }
    }
}

private struct APIKeyNotice: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        MinimalPanel(padding: 12) {
            HStack(spacing: 10) {
                Text(
                    engine.dictationMode == .pro && engine.proModeEngine == .geminiTranscribe
                        ? "Add a Google API key."
                        : "Add an OpenAI API key."
                )
                .font(.system(size: 12))
                Spacer()
                Button("Add Key") {
                    SettingsWindowController.shared.show(engine: engine, tab: .providers)
                }
                .buttonStyle(SignalPillButtonStyle(prominent: true))
            }
        }
    }
}
