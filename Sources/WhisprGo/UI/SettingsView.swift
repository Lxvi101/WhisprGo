import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: DictationEngine

    var body: some View {
        TabView {
            GeneralSettingsPane(engine: engine)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }

            ModelSettingsPane(engine: engine)
                .tabItem { Label("Models", systemImage: "circle.grid.3x3") }

            ProviderSettingsPane(engine: engine)
                .tabItem { Label("Providers", systemImage: "key") }
        }
        .tint(.primary)
        .scenePadding()
        .frame(width: 660, height: 520)
        .onAppear {
            engine.refreshPermissions()
        }
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
