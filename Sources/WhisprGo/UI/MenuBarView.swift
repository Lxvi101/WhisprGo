import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 17)
                .padding(.bottom, 13)

            DottedRule()
                .padding(.horizontal, 18)

            VStack(alignment: .leading, spacing: 12) {
                modePanel

                modelPanel

                ShortcutGuide(engine: engine)

                if let error = engine.lastError {
                    MenuErrorNotice(message: error)
                }

                if case let .downloading(progress) = engine.modelState {
                    DownloadProgress(progress: progress)
                }

                if !engine.permissions.isComplete {
                    SetupNotice(engine: engine)
                } else if engine.needsOpenAIKey {
                    APIKeyNotice(engine: engine)
                }

                dictationButton

                if let latency = engine.lastLatency {
                    Text("Last response  \(latency.formatted(.number.precision(.fractionLength(2))))s")
                        .font(.caption2.monospacedDigit())
                        .tracking(0.35)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(16)

            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(height: 1)
                }
        }
        .frame(width: 360)
        .onAppear {
            engine.refreshPermissions()
        }
    }

    private var modePanel: some View {
        MinimalPanel {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    DottedSectionLabel("Processing")
                    Spacer()
                    MinimalBadge(engine.dictationMode == .fast ? "Local path" : "Luna")
                }

                Picker("Processing mode", selection: modeBinding) {
                    ForEach(DictationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(engine.activity != .idle)

                Text(engine.dictationMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if engine.dictationMode == .pro {
                    ProProfilePicker()
                } else {
                    HStack {
                        Text("Tap Right Shift to switch")
                        Spacer()
                        MinimalKeyCap("R⇧")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            BrandWaveform()
                .frame(width: 72, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("WhisprGo")
                    .font(.system(size: 18, weight: .medium))
                Text(engine.stateTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            DottedActivityMark(engine: engine)
        }
    }

    private var modelPanel: some View {
        MinimalPanel {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    DottedSectionLabel("Model")
                    Spacer()
                    if engine.selectedModel.recommended {
                        MinimalBadge("Default")
                    }
                }

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
                .disabled(!engine.canChangeModel)
                .accessibilityLabel("Transcription model")

                Text(engine.selectedModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dictationButton: some View {
        Button(action: engine.toggleDictation) {
            HStack(spacing: 10) {
                ActionDot(isRecording: engine.activity == .recording)
                Text(engine.activity == .recording ? "Stop and Type" : "Start Dictating")
                    .font(.callout.weight(.semibold))
                Spacer()
                MinimalKeyCap("fn", inverted: true)
                Text("+")
                    .font(.caption)
                    .opacity(0.55)
                MinimalKeyCap("⇧", inverted: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(MonochromePrimaryButtonStyle())
        .disabled(!engine.canToggle)
        .opacity(engine.canToggle ? 1 : 0.42)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button {
                SettingsWindowController.shared.show(engine: engine, tab: .history)
            } label: {
                HStack(spacing: 7) {
                    DotMenuGlyph()
                    Text("History")
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Settings") {
                SettingsWindowController.shared.show(engine: engine)
            }
            .buttonStyle(.plain)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
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

private struct MenuErrorNotice: View {
    let message: String
    @State private var didCopy = false

    var body: some View {
        MinimalPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    DottedSectionLabel("Needs Attention")
                    Spacer()
                    Button(action: copyDetails) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
                    .help(didCopy ? "Copied" : "Copy error details")
                    .accessibilityLabel(didCopy ? "Error copied" : "Copy error details")
                }

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
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

private struct DottedActivityMark: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.primary.opacity(opacity(for: index)))
                    .frame(width: diameter(for: index), height: diameter(for: index))
            }
        }
        .frame(width: 30, height: 20)
        .accessibilityHidden(true)
    }

    private func opacity(for index: Int) -> Double {
        if engine.activity == .recording { return index == 1 ? 1 : 0.55 }
        if engine.activity == .transcribing { return index == 2 ? 1 : 0.3 }
        if engine.permissions.isComplete && engine.modelState == .ready {
            return index == 1 ? 0.72 : 0.2
        }
        return index == 0 ? 0.72 : 0.18
    }

    private func diameter(for index: Int) -> CGFloat {
        index == 1 ? 6 : 4
    }
}

private struct ActionDot: View {
    let isRecording: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: .textBackgroundColor).opacity(0.5), lineWidth: 1)
                .frame(width: 15, height: 15)
            if isRecording {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(Color(nsColor: .textBackgroundColor))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DotMenuGlyph: View {
    var body: some View {
        HStack(spacing: 2.5) {
            Circle().frame(width: 3, height: 3)
            Circle().frame(width: 5, height: 5)
            Circle().frame(width: 3, height: 3)
        }
        .frame(width: 17)
        .accessibilityHidden(true)
    }
}

private struct ShortcutGuide: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    MinimalKeyCap("fn")
                    Text("push to talk")
                }
                Spacer()
                HStack(spacing: 5) {
                    MinimalKeyCap("fn")
                    Text("+").foregroundStyle(.tertiary)
                    MinimalKeyCap("⇧")
                    Text("toggle")
                }
            }

            HStack {
                HStack(spacing: 5) {
                    MinimalKeyCap("R⇧")
                    Text("mode")
                }
                Spacer()
                Button(action: engine.pasteLastDictation) {
                    HStack(spacing: 5) {
                        MinimalKeyCap("⌘")
                        MinimalKeyCap("⌥")
                        MinimalKeyCap("V")
                        Text("paste last")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }
}

private struct ProProfilePicker: View {
    @ObservedObject private var store = ProProfileStore.shared

    var body: some View {
        HStack(spacing: 9) {
            Text("Profile")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Profile", selection: selection) {
                ForEach(store.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            MinimalKeyCap("⌃")
            Text("+").font(.caption2).foregroundStyle(.tertiary)
            MinimalKeyCap("R⇧")
        }
    }

    private var selection: Binding<UUID> {
        Binding(
            get: { store.selectedProfileID },
            set: { store.select($0) }
        )
    }
}

private struct DownloadProgress: View {
    let progress: Double

    var body: some View {
        MinimalPanel {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    DottedSectionLabel("Downloading")
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                }
                ProgressView(value: progress)
                    .tint(.primary)
                Text("One-time download for private, on-device dictation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SetupNotice: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        MinimalPanel {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    DottedSectionLabel("Permissions")
                    Spacer()
                    MinimalBadge("Required", filled: true)
                }
                Text("Microphone and Accessibility access are needed once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Allow") {
                        engine.requestPermissions()
                    }
                    Button("Open Settings") {
                        engine.openAccessibilitySettings()
                    }
                }
            }
        }
    }
}

private struct APIKeyNotice: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        MinimalPanel {
            HStack(spacing: 10) {
                DotSelectionIndicator(isSelected: false)
                Text(
                    engine.dictationMode == .pro
                        ? "Pro Mode needs an OpenAI API key."
                        : "This model needs an OpenAI API key."
                )
                    .font(.caption)
                Spacer()
                Button("Add Key") {
                    SettingsWindowController.shared.show(engine: engine, tab: .providers)
                }
            }
        }
    }
}
