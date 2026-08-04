import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        TabView {
            GeneralSettingsPane(engine: engine)
                .tabItem { Label("General", systemImage: "gearshape") }

            ModelSettingsPane(engine: engine)
                .tabItem { Label("Models", systemImage: "cpu") }

            ProviderSettingsPane(engine: engine)
                .tabItem { Label("Providers", systemImage: "key") }
        }
        .scenePadding()
        .frame(width: 620, height: 490)
        .onAppear {
            engine.refreshPermissions()
        }
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        Form {
            Section("Dictation") {
                LabeledContent("Push to talk") {
                    HStack(spacing: 6) {
                        Text("fn")
                            .modifier(SettingsKeyCap())
                        Text("Hold")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Toggle") {
                    HStack(spacing: 6) {
                        Text("fn")
                            .modifier(SettingsKeyCap())
                        Text("+").foregroundStyle(.secondary)
                        Text("⇧")
                            .modifier(SettingsKeyCap())
                    }
                }

                Toggle("Add a space after each dictation", isOn: $engine.appendTrailingSpace)
            }

            Section("Background") {
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
            }

            Section("Audio input") {
                Toggle(
                    "Use the Mac microphone instead of AirPods",
                    isOn: Binding(
                        get: { engine.preferBuiltInMicrophone },
                        set: { engine.setPreferBuiltInMicrophone($0) }
                    )
                )
                .disabled(engine.activity != .idle)

                Text("On by default. WhisprGo records from \(engine.microphoneRouteDescription) while leaving AirPods available for high-quality playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Instant response") {
                Toggle(
                    "Keep microphone active between dictations",
                    isOn: Binding(
                        get: { engine.keepMicrophoneActive },
                        set: { engine.setKeepMicrophoneActive($0) }
                    )
                )
                .disabled(engine.activity != .idle)

                Text("Off by default. When enabled, the selected input stays active for near-instant starts. Idle audio is discarded immediately and is never saved or transcribed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    isGranted: engine.permissions.microphone
                )
                PermissionRow(
                    title: "Accessibility",
                    isGranted: engine.permissions.accessibility
                )

                HStack {
                    Button("Request Permissions") {
                        engine.requestPermissions()
                    }
                    Button("Open Accessibility Settings") {
                        engine.openAccessibilitySettings()
                    }
                    Button("Check Again") {
                        engine.refreshPermissions()
                    }
                }
            }

            if let error = engine.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

private struct ModelSettingsPane: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ModelSection(
                    title: "On Device",
                    subtitle: "Private, offline, and accelerated by Apple silicon.",
                    models: ModelCatalog.local,
                    engine: engine
                )
                ModelSection(
                    title: "OpenAI",
                    subtitle: "Uses your API key. Audio is sent only when you finish speaking.",
                    models: ModelCatalog.cloud,
                    engine: engine
                )
            }
            .padding(16)
        }
    }
}

private struct ModelSection: View {
    let title: String
    let subtitle: String
    let models: [TranscriptionModel]
    @ObservedObject var engine: DictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
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
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(model.name)
                                .font(.body.weight(.medium))
                            if model.recommended {
                                Text("RECOMMENDED")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
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
                .padding(11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!engine.canChangeModel)
            .accessibilityLabel("\(model.name), \(status(for: model))")

            if isDownloaded {
                Button {
                    isConfirmingRemoval = true
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .disabled(!engine.canRemoveDownloadedModel(model.id))
                .help(
                    isSelected
                        ? "Choose another model first, then remove this download."
                        : "Delete this model from your Mac."
                )
                .padding(.trailing, 11)
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.16),
                    lineWidth: 1
                )
        }
        .alert("Remove \(model.name)?", isPresented: $isConfirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Download", role: .destructive) {
                engine.removeDownloadedModel(model.id)
            }
        } message: {
            Text("This frees \(model.sizeLabel ?? "its") of storage. You can download it again anytime by selecting it.")
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
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenAI")
                            .font(.headline)
                        Text(engine.openAIKeyConfigured ? "API key configured" : "No API key saved")
                            .font(.caption)
                            .foregroundStyle(engine.openAIKeyConfigured ? .green : .secondary)
                    }
                }
            }

            Section("API Key") {
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)

                HStack {
                    Button("Save in Keychain", action: save)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if engine.openAIKeyConfigured {
                        Button("Remove Key", role: .destructive) {
                            if engine.saveOpenAIAPIKey("") {
                                apiKey = ""
                            }
                        }
                    }

                    if didSave {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }

            Section("Privacy") {
                Text("The key is stored in macOS Keychain. It is never written to preferences, logs, or source files. Local models never send audio over the network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
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

private struct PermissionRow: View {
    let title: String
    let isGranted: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Label(
                isGranted ? "Allowed" : "Required",
                systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .foregroundStyle(isGranted ? .green : .orange)
        }
    }
}

private struct SettingsKeyCap: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold).monospaced())
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}
