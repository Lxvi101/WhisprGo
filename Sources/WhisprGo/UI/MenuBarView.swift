import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusHeader(engine: engine)

            VStack(alignment: .leading, spacing: 7) {
                Text("MODEL")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

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

            Text("Hold fn for push-to-talk · fn + shift toggles")
                .font(.caption)
                .foregroundStyle(.secondary)

            if case let .downloading(progress) = engine.modelState {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: progress)
                    Text("Downloading once for private, on-device dictation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !engine.permissions.isComplete {
                SetupNotice(engine: engine)
            } else if engine.modelState == .needsAPIKey {
                APIKeyNotice()
            }

            Button(action: engine.toggleDictation) {
                HStack {
                    Image(systemName: engine.activity == .recording ? "stop.fill" : "waveform")
                    Text(engine.activity == .recording ? "Stop and Type" : "Start Dictating")
                    Spacer()
                    ShortcutBadge()
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!engine.canToggle)

            if let latency = engine.lastLatency {
                Text("Last response: \(latency.formatted(.number.precision(.fractionLength(2))))s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()

            HStack {
                Button {
                    SettingsWindowController.shared.show(engine: engine)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            engine.refreshPermissions()
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { engine.selectedModelID },
            set: { engine.selectModel($0) }
        )
    }
}

private struct StatusHeader: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: engine.menuBarSymbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.stateTitle)
                    .font(.headline)
                Text(engine.stateDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var statusColor: Color {
        if engine.activity == .recording { return .red }
        if engine.activity == .transcribing { return .blue }
        if engine.permissions.isComplete && engine.modelState == .ready { return .green }
        return .orange
    }
}

private struct SetupNotice: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Two one-time permissions are needed", systemImage: "lock.shield")
                .font(.callout.weight(.semibold))
            HStack {
                Button("Allow") {
                    engine.requestPermissions()
                }
                Button("Accessibility Settings") {
                    engine.openAccessibilitySettings()
                }
            }
        }
        .padding(11)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct APIKeyNotice: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            Text("This cloud model needs an OpenAI API key.")
                .font(.caption)
            Spacer()
            Button {
                SettingsWindowController.shared.show(engine: .shared)
            } label: {
                Text("Add Key")
            }
        }
        .padding(11)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ShortcutBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            KeyCap("fn")
            Text("+")
                .foregroundStyle(.secondary)
            KeyCap("⇧")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Function plus Shift")
    }
}

private struct KeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }
}
