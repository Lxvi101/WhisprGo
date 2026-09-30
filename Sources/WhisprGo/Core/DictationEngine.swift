import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import ServiceManagement

@MainActor
final class DictationEngine: ObservableObject {
    enum Activity: Equatable {
        case idle
        case recording
        case transcribing
    }

    private enum RecordingMode {
        case pushToTalk
        case toggle
    }

    enum ModelState: Equatable {
        case starting
        case downloading(Double)
        case warming
        case ready
        case needsAPIKey
        case failed(String)
    }

    struct Permissions: Equatable {
        var microphone = false
        var accessibility = false

        var isComplete: Bool { microphone && accessibility }
    }

    static let shared = DictationEngine()

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var modelState: ModelState = .starting
    @Published private(set) var permissions = Permissions()
    @Published private(set) var lastLatency: TimeInterval?
    @Published private(set) var lastError: String?
    @Published private(set) var openAIKeyConfigured = KeychainStore.openAIAPIKey() != nil
    @Published private(set) var googleAPIKeyConfigured = KeychainStore.googleAPIKey() != nil
    @Published private(set) var modelCacheRevision = 0
    @Published private(set) var keepMicrophoneActive: Bool
    @Published private(set) var allowedExternalMicrophoneUIDs: Set<String>
    @Published private(set) var knownExternalMicrophoneNames: [String: String]
    @Published private(set) var microphoneRoutes: [AudioInputRoute]
    @Published private(set) var dictationMode: DictationMode
    @Published private(set) var proModeEngine: ProModeEngine
    @Published private(set) var proContextEnabled: Bool
    @Published private(set) var lastContextSummary: String?
    @Published private(set) var hotkeyConfiguration: HotkeyConfiguration

    @Published var selectedModelID: String {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: Self.selectedModelKey)
        }
    }

    @Published var appendTrailingSpace: Bool {
        didSet {
            UserDefaults.standard.set(appendTrailingSpace, forKey: Self.trailingSpaceKey)
        }
    }

    @Published private(set) var launchAtLogin: Bool

    private static let selectedModelKey = "selectedModelID"
    private static let trailingSpaceKey = "appendTrailingSpace"
    // Separate from the older prepared-but-paused setting: keeping the
    // hardware stream active is a new privacy choice and must be opted into.
    private static let keepMicrophoneActiveKey = "keepMicrophoneActive"
    private static let allowedExternalMicrophoneUIDsKey = "allowedExternalMicrophoneUIDs"
    private static let knownExternalMicrophoneNamesKey = "knownExternalMicrophoneNames"
    private static let dictationModeKey = "dictationMode"
    private static let proModeEngineKey = "proModeEngine"
    private static let proContextEnabledKey = "proContextEnabled"
    private static let defaultModelVersionKey = "defaultModelVersion"
    private static let currentDefaultModelVersion = 2
    private static let retiredProModelCacheID = "cleanup.gemma4.e2b.mlx.4bit"

    /// Read-only access to the live input level for visualizations.
    let levelMeter: AudioLevelMeter

    private let runtime = TranscriptionRuntime()
    private let capture: AudioCapture
    private let audioDeviceMonitor = AudioInputDeviceMonitor()
    private let hotkey = HotkeyMonitor()
    private let overlay: RecordingOverlay
    private let modeBadge = ModeBadgeOverlay()
    private let history = DictationHistoryStore.shared
    private let profileStore = ProProfileStore.shared

    private var hasStarted = false
    private var recordingMode: RecordingMode?
    private var recordingSessionID: UUID?
    private var insertionTarget: TextInjector.Target?
    private var recordingContext: AccessibilityContextSnapshot?
    private var lastCompletedTranscript: String?
    private var modelPreparationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var geminiClient: GeminiTranscriptionClient?
    private var geminiClientKey: String?
    private var instructClient: OpenAITextClient?
    private var instructClientKey: String?
    private var hasPendingAudioRouteChange = false

    private init() {
        LegacyMigration.run()
        let defaults = UserDefaults.standard
        let allowedMicrophones = Set(
            defaults.stringArray(forKey: Self.allowedExternalMicrophoneUIDsKey) ?? []
        )
        allowedExternalMicrophoneUIDs = allowedMicrophones
        knownExternalMicrophoneNames = defaults.dictionary(
            forKey: Self.knownExternalMicrophoneNamesKey
        ) as? [String: String] ?? [:]
        microphoneRoutes = AudioInputRouter.inputRoutes()
        dictationMode = DictationMode(
            rawValue: defaults.string(forKey: Self.dictationModeKey) ?? ""
        ) ?? .fast
        proModeEngine = ProModeEngine(
            rawValue: defaults.string(forKey: Self.proModeEngineKey) ?? ""
        ) ?? .defaultEngine
        proContextEnabled = defaults.object(forKey: Self.proContextEnabledKey) as? Bool
            ?? true
        hotkeyConfiguration = HotkeyConfiguration.load(from: defaults)

        let levelMeter = AudioLevelMeter()
        self.levelMeter = levelMeter
        capture = AudioCapture(
            levelMeter: levelMeter,
            allowedExternalMicrophoneUIDs: allowedMicrophones
        )
        overlay = RecordingOverlay(levelMeter: levelMeter)

        let savedModelID = defaults.string(forKey: Self.selectedModelKey)
        let shouldAdoptParakeetDefault = defaults.integer(forKey: Self.defaultModelVersionKey)
            < Self.currentDefaultModelVersion
            && (savedModelID == nil || savedModelID == "local.base.en")
        let requestedModelID = shouldAdoptParakeetDefault
            ? ModelCatalog.defaultModelID
            : (savedModelID ?? ModelCatalog.defaultModelID)
        selectedModelID = ModelCatalog.model(id: requestedModelID).id
        appendTrailingSpace = defaults.object(forKey: Self.trailingSpaceKey) as? Bool ?? true
        keepMicrophoneActive = defaults.bool(forKey: Self.keepMicrophoneActiveKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        defaults.set(Self.currentDefaultModelVersion, forKey: Self.defaultModelVersionKey)
        defaults.set(selectedModelID, forKey: Self.selectedModelKey)
        defaults.set(proModeEngine.rawValue, forKey: Self.proModeEngineKey)
    }

    var selectedModel: TranscriptionModel {
        ModelCatalog.model(id: selectedModelID)
    }

    var needsProviderKey: Bool {
        if dictationMode == .pro, proModeEngine == .geminiTranscribe {
            return !googleAPIKeyConfigured
        }
        return (dictationMode == .pro || !selectedModel.isLocal)
            && !openAIKeyConfigured
    }

    var dictationModeDetail: String {
        dictationMode == .pro ? proModeEngine.detail : dictationMode.detail
    }

    var isRetiredProModelDownloaded: Bool {
        _ = modelCacheRevision
        return ModelCache.isDownloaded(Self.retiredProModelCacheID)
    }

    var canToggle: Bool {
        switch activity {
        case .recording:
            return true
        case .idle:
            return permissions.isComplete
                && pipelineIsReady
        case .transcribing:
            return false
        }
    }

    var canChangeModel: Bool {
        activity == .idle
    }

    var canRerunHistory: Bool {
        activity == .idle
            && pipelineIsReady
    }

    var stateTitle: String {
        switch activity {
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .idle: break
        }

        if !permissions.isComplete { return "Finish setup" }
        if needsProviderKey { return "API key needed" }
        if dictationMode == .pro, proModeEngine == .geminiTranscribe { return "Ready" }
        switch modelState {
        case .starting: return "Starting"
        case .downloading: return "Downloading model"
        case .warming: return "Warming model"
        case .ready: return "Ready"
        case .needsAPIKey: return "API key needed"
        case .failed: return "Needs attention"
        }
    }

    var stateDetail: String {
        if let lastError { return lastError }
        switch activity {
        case .recording:
            return recordingMode == .pushToTalk
                ? "Release \(hotkeyConfiguration[.pushToTalk].displayText) to type"
                : "Press \(hotkeyConfiguration[.toggleDictation].displayText) again to type"
        case .transcribing:
            return "Your audio is becoming text"
        case .idle:
            break
        }
        if !permissions.microphone { return "Allow microphone access" }
        if !permissions.accessibility { return "Allow Accessibility access" }
        if needsProviderKey {
            return dictationMode == .pro && proModeEngine == .geminiTranscribe
                ? "Add your Google key in Settings"
                : "Add your OpenAI key in Settings"
        }
        if dictationMode == .pro, proModeEngine == .geminiTranscribe {
            return "Hold \(hotkeyConfiguration[.pushToTalk].displayText), or \(hotkeyConfiguration[.toggleDictation].displayText) to toggle"
        }
        switch modelState {
        case .starting: return "Preparing WhisprGo"
        case let .downloading(progress):
            return "\(Int(progress * 100))% downloaded"
        case .warming: return "Optimizing for this Mac"
        case .ready:
            return "Hold \(hotkeyConfiguration[.pushToTalk].displayText), or \(hotkeyConfiguration[.toggleDictation].displayText) to toggle"
        case .needsAPIKey: return "Add your OpenAI key in Settings"
        case let .failed(message): return message
        }
    }

    var menuBarSymbol: String {
        switch activity {
        case .recording: return "waveform.circle.fill"
        case .transcribing: return "ellipsis.circle"
        case .idle:
            return permissions.isComplete && pipelineIsReady
                ? "waveform.circle"
                : "exclamationmark.circle"
        }
    }

    private var pipelineIsReady: Bool {
        guard !needsProviderKey else { return false }
        return dictationMode == .pro && proModeEngine == .geminiTranscribe
            || modelState == .ready
    }

    private var usesSelectedTranscriptionModel: Bool {
        dictationMode == .fast || proModeEngine == .instruct
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        audioDeviceMonitor.start { [weak self] in
            Task { @MainActor in
                self?.audioDevicesDidChange()
            }
        }
        refreshPermissions()
        prepareSelectedModel()

        if !permissions.isComplete {
            requestPermissions()
        }
    }

    func shutdown() {
        modelPreparationTask?.cancel()
        transcriptionTask?.cancel()
        if activity == .recording {
            _ = capture.stop(keepActive: false)
        }
        recordingSessionID = nil
        audioDeviceMonitor.stop()
        capture.shutdown()
        hotkey.stop()
        history.stopPlayback()
        Task {
            await runtime.release()
        }
    }

    func refreshPermissions() {
        permissions = Permissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted()
        )
        if permissions.accessibility {
            startHotkeyIfPossible()
        } else {
            hotkey.stop()
        }
        if permissions.microphone, keepMicrophoneActive, activity == .idle {
            activateAudioCapture()
        }
    }

    func requestPermissions() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        Task { [weak self] in
            let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let microphoneGranted: Bool
            if microphoneStatus == .notDetermined {
                microphoneGranted = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            } else {
                microphoneGranted = microphoneStatus == .authorized
            }
            guard let self else { return }
            self.permissions = Permissions(
                microphone: microphoneGranted,
                accessibility: AXIsProcessTrusted()
            )
            if self.permissions.accessibility {
                self.startHotkeyIfPossible()
            } else {
                self.hotkey.stop()
            }
            if microphoneGranted, self.keepMicrophoneActive, self.activity == .idle {
                self.activateAudioCapture()
            }
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func toggleDictation() {
        lastError = nil
        switch activity {
        case .recording:
            stopAndTranscribe()
        case .idle:
            guard canToggle else {
                if !permissions.isComplete {
                    requestPermissions()
                }
                return
            }
            startRecording(mode: .toggle)
        case .transcribing:
            break
        }
    }

    func rerunHistoryEntry(_ id: UUID) {
        guard canRerunHistory else { return }
        let insertionTarget = TextInjector.captureTarget()
        let dictationMode = self.dictationMode
        let proModeEngine = self.proModeEngine
        let proProfile = profileStore.selectedProfile
        lastError = nil
        activity = .transcribing
        overlay.show(.transcribing)
        history.setRerunning(id)
        let model = selectedModel

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { history.setRerunning(nil) }

            do {
                // File mapping and PCM decoding happen before the inference
                // timer and away from the main actor in the history actor.
                let samples = try await history.samples(for: id)
                guard !Task.isCancelled else { return }
                let started = ProcessInfo.processInfo.systemUptime
                let result = try await transcribe(
                    samples: samples,
                    model: model,
                    mode: dictationMode,
                    proEngine: proModeEngine,
                    context: nil,
                    profile: proProfile
                )
                guard !Task.isCancelled else { return }
                let transcript = result.text
                lastCompletedTranscript = transcript

                var insertion = transcript
                if appendTrailingSpace, !insertion.isEmpty {
                    insertion.append(" ")
                }
                let insertionResult = await TextInjector.inject(
                    insertion,
                    into: insertionTarget
                )
                let latency = ProcessInfo.processInfo.systemUptime - started
                lastLatency = latency
                activity = .idle
                let warning = insertionResult.errorMessage ?? result.warning
                if let warning {
                    lastError = warning
                    overlay.show(.error)
                    overlay.hide(after: 0.9)
                } else {
                    overlay.hide()
                }
                history.updateAfterRerun(
                    id: id,
                    transcript: transcript,
                    modelID: historyModelID(
                        model,
                        mode: dictationMode,
                        proEngine: proModeEngine
                    ),
                    modelName: historyModelName(
                        model,
                        mode: dictationMode,
                        proEngine: proModeEngine,
                        profile: proProfile
                    ),
                    latency: latency,
                    errorMessage: warning
                )
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                lastError = message
                activity = .idle
                overlay.show(.error)
                overlay.hide(after: 0.9)
                history.updateAfterRerun(
                    id: id,
                    transcript: nil,
                    modelID: nil,
                    modelName: nil,
                    latency: nil,
                    errorMessage: message
                )
            }
        }
    }

    func selectModel(_ id: String) {
        guard canChangeModel, selectedModelID != id else { return }
        selectedModelID = id
        lastError = nil
        if usesSelectedTranscriptionModel {
            prepareSelectedModel()
        }
    }

    func setDictationMode(_ mode: DictationMode) {
        guard activity == .idle, dictationMode != mode else { return }
        dictationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.dictationModeKey)
        lastError = nil
        if usesSelectedTranscriptionModel {
            prepareSelectedModel()
        } else {
            modelPreparationTask?.cancel()
            modelState = .ready
            Task { await runtime.release() }
        }
    }

    func setProModeEngine(_ engine: ProModeEngine) {
        guard activity == .idle, proModeEngine != engine else { return }
        proModeEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: Self.proModeEngineKey)
        lastError = nil

        guard dictationMode == .pro else { return }
        if usesSelectedTranscriptionModel {
            prepareSelectedModel()
        } else {
            modelPreparationTask?.cancel()
            modelState = .ready
            Task { await runtime.release() }
        }
    }

    func setProContextEnabled(_ enabled: Bool) {
        guard activity == .idle, proContextEnabled != enabled else { return }
        proContextEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.proContextEnabledKey)
        if !enabled {
            lastContextSummary = "Context is turned off"
        }
        lastError = nil
    }

    func pasteLastDictation() {
        guard activity == .idle else { return }
        let target = TextInjector.captureTarget()
        Task { [weak self] in
            guard let self else { return }
            let transcript: String?
            if let lastCompletedTranscript {
                transcript = lastCompletedTranscript
            } else {
                transcript = await history.latestTranscript()
            }
            guard let transcript, !transcript.isEmpty else {
                modeBadge.show("No dictation yet")
                return
            }
            let result = await TextInjector.inject(transcript, into: target)
            if let error = result.errorMessage {
                lastError = error
                modeBadge.show("Could not paste")
            } else {
                modeBadge.show("Pasted last dictation")
            }
        }
    }

    func isModelDownloaded(_ id: String) -> Bool {
        _ = modelCacheRevision
        return ModelCache.isDownloaded(id)
    }

    func canRemoveDownloadedModel(_ id: String) -> Bool {
        guard activity == .idle,
              selectedModelID != id,
              ModelCache.isDownloaded(id)
        else { return false }

        switch modelState {
        case .ready, .needsAPIKey, .failed:
            return true
        case .starting, .downloading, .warming:
            return false
        }
    }

    func removeDownloadedModel(_ id: String) {
        guard canRemoveDownloadedModel(id) else { return }
        let preparation = modelPreparationTask

        Task { [weak self] in
            if let preparation {
                await preparation.value
            }
            guard let self,
                  self.activity == .idle,
                  self.selectedModelID != id
            else { return }

            do {
                try ModelCache.removeDownload(for: id)
                modelCacheRevision &+= 1
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeRetiredProModelDownload() {
        guard activity == .idle, isRetiredProModelDownloaded else { return }
        do {
            try ModelCache.removeDownload(for: Self.retiredProModelCacheID)
            modelCacheRevision &+= 1
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveOpenAIAPIKey(_ key: String) -> Bool {
        do {
            try KeychainStore.saveOpenAIAPIKey(key)
            openAIKeyConfigured = KeychainStore.openAIAPIKey() != nil
            instructClient = nil
            instructClientKey = nil
            lastError = nil
            if usesSelectedTranscriptionModel {
                prepareSelectedModel()
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func saveGoogleAPIKey(_ key: String) -> Bool {
        do {
            try KeychainStore.saveGoogleAPIKey(key)
            googleAPIKeyConfigured = KeychainStore.googleAPIKey() != nil
            geminiClient = nil
            geminiClientKey = nil
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            lastError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            lastError = "Launch at login could not be changed: \(error.localizedDescription)"
        }
    }

    func setKeepMicrophoneActive(_ enabled: Bool) {
        guard activity == .idle, keepMicrophoneActive != enabled else { return }
        keepMicrophoneActive = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keepMicrophoneActiveKey)
        lastError = nil

        if enabled, permissions.microphone {
            activateAudioCapture()
        } else if !enabled {
            capture.shutdown()
        }
    }

    func refreshMicrophoneRoutes() {
        microphoneRoutes = AudioInputRouter.inputRoutes()
    }

    func setExternalMicrophoneAllowed(_ route: AudioInputRoute, allowed: Bool) {
        guard activity == .idle, !route.isBuiltIn, !route.isBluetooth else { return }
        if allowed {
            allowedExternalMicrophoneUIDs.insert(route.uid)
            knownExternalMicrophoneNames[route.uid] = route.name
        } else {
            allowedExternalMicrophoneUIDs.remove(route.uid)
            knownExternalMicrophoneNames.removeValue(forKey: route.uid)
        }
        persistMicrophoneExceptions()
        restartAudioCaptureForRoutingChange()
    }

    func removeDisconnectedMicrophoneException(_ uid: String) {
        guard activity == .idle else { return }
        allowedExternalMicrophoneUIDs.remove(uid)
        knownExternalMicrophoneNames.removeValue(forKey: uid)
        persistMicrophoneExceptions()
        restartAudioCaptureForRoutingChange()
    }

    private func persistMicrophoneExceptions() {
        let defaults = UserDefaults.standard
        defaults.set(
            allowedExternalMicrophoneUIDs.sorted(),
            forKey: Self.allowedExternalMicrophoneUIDsKey
        )
        defaults.set(knownExternalMicrophoneNames, forKey: Self.knownExternalMicrophoneNamesKey)
    }

    private func restartAudioCaptureForRoutingChange() {
        lastError = nil
        capture.shutdown()
        capture.setAllowedExternalMicrophoneUIDs(allowedExternalMicrophoneUIDs)
        if keepMicrophoneActive, permissions.microphone {
            activateAudioCapture()
        }
    }

    @discardableResult
    func setHotkey(_ shortcut: HotkeyShortcut, for action: HotkeyAction) -> HotkeyAction? {
        guard shortcut.validationMessage == nil else { return nil }
        if let conflict = hotkeyConfiguration.action(
            conflictingWith: shortcut,
            excluding: action
        ) {
            return conflict
        }
        guard hotkeyConfiguration[action] != shortcut else { return nil }
        hotkeyConfiguration[action] = shortcut
        hotkeyConfiguration.save()
        hotkey.update(configuration: hotkeyConfiguration)
        return nil
    }

    func resetHotkeys() {
        guard hotkeyConfiguration != .default else { return }
        hotkeyConfiguration = .default
        hotkeyConfiguration.save()
        hotkey.update(configuration: hotkeyConfiguration)
    }

    @discardableResult
    func beginRecordingHotkey() -> Bool {
        guard activity == .idle else { return false }
        hotkey.stop()
        return true
    }

    func endRecordingHotkey() {
        startHotkeyIfPossible()
    }

    var microphoneRouteDescription: String {
        capture.activeInputName ?? capture.preferredInputName() ?? "System default microphone"
    }

    private func startHotkeyIfPossible() {
        guard permissions.accessibility else { return }
        do {
            try hotkey.start(configuration: hotkeyConfiguration) { [weak self] event in
                self?.handleHotkey(event)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func activateAudioCapture() {
        do {
            try capture.activate()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func prepareSelectedModel() {
        let previousPreparation = modelPreparationTask
        previousPreparation?.cancel()
        let model = selectedModel

        guard usesSelectedTranscriptionModel else {
            modelState = .ready
            modelPreparationTask = Task { [runtime] in
                if let previousPreparation {
                    await previousPreparation.value
                }
                await runtime.release()
            }
            return
        }

        if !model.isLocal && !openAIKeyConfigured {
            modelState = .needsAPIKey
            modelPreparationTask = Task { [runtime] in
                if let previousPreparation {
                    await previousPreparation.value
                }
                await runtime.release()
            }
            return
        }

        modelState = model.isLocal && !ModelCache.isDownloaded(model.id)
            ? .downloading(0)
            : .warming

        modelPreparationTask = Task { [weak self] in
            guard let self else { return }
            // Core ML specialization is not always immediately cancellable.
            // Waiting here prevents two model graphs from loading at once.
            if let previousPreparation {
                await previousPreparation.value
            }
            guard !Task.isCancelled else { return }
            do {
                try await runtime.prepare(model: model) { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              self.usesSelectedTranscriptionModel,
                              self.selectedModelID == model.id
                        else { return }
                        self.modelState = progress < 0.999
                            ? .downloading(progress)
                            : .warming
                    }
                }
                guard !Task.isCancelled,
                      usesSelectedTranscriptionModel,
                      selectedModelID == model.id
                else { return }
                modelState = .ready
            } catch is CancellationError {
                return
            } catch TranscriptionError.missingAPIKey {
                guard usesSelectedTranscriptionModel, selectedModelID == model.id else { return }
                modelState = .needsAPIKey
            } catch {
                guard usesSelectedTranscriptionModel, selectedModelID == model.id else { return }
                modelState = .failed(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }

    private func handleHotkey(_ event: HotkeyMonitor.Event) {
        lastError = nil
        switch event {
        case .pushToTalkBegan:
            guard activity == .idle, canToggle else { return }
            startRecording(mode: .pushToTalk)

        case .pushToTalkEnded:
            guard activity == .recording, recordingMode == .pushToTalk else { return }
            stopAndTranscribe()

        case .pushToTalkCancelled:
            guard activity == .recording, recordingMode == .pushToTalk else { return }
            let recording = capture.stop(keepActive: keepMicrophoneActive)
            applyPendingAudioRouteChangeIfNeeded()
            capture.recycle(recording.samples)
            recordingMode = nil
            recordingSessionID = nil
            insertionTarget = nil
            recordingContext = nil
            activity = .idle
            overlay.hide(after: 0)

        case .toggle:
            toggleDictation()

        case .toggleMode:
            guard activity == .idle else { return }
            let nextMode: DictationMode = dictationMode == .fast ? .pro : .fast
            setDictationMode(nextMode)
            let suffix: String
            if nextMode == .pro, needsProviderKey {
                suffix = " · Key needed"
            } else if nextMode == .pro,
                      proModeEngine == .instruct,
                      modelState != .ready {
                suffix = " · Preparing model"
            } else {
                suffix = ""
            }
            modeBadge.show("\(nextMode.title) Mode\(suffix)")

        case .cycleProfile:
            guard activity == .idle, dictationMode == .pro else { return }
            let profile = profileStore.selectNext()
            modeBadge.show("Profile · \(profile.name)")

        case .pasteLast:
            pasteLastDictation()
        }
    }

    private func startRecording(mode: RecordingMode) {
        let target = TextInjector.captureTarget()
        do {
            try capture.start()
            let sessionID = UUID()
            recordingSessionID = sessionID
            insertionTarget = target
            recordingMode = mode
            activity = .recording
            overlay.show(.recording)
            recordingContext = nil

            // Let the recording overlay commit its first frame before the
            // bounded Accessibility read. Audio is already running, and Fast
            // Mode never creates this task at all.
            if dictationMode == .pro, proContextEnabled {
                lastContextSummary = "Reading context…"
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.recordingSessionID == sessionID else { return }
                    let context = AccessibilityContextReader.capture(from: target)
                    guard self.recordingSessionID == sessionID else { return }
                    self.recordingContext = context
                    if let context {
                        let focusedCount = context.focusedTextCharacterCount
                        let nearbyCount = context.nearbyText.count
                        self.lastContextSummary = context.textCharacterCount > 0
                            ? "\(context.applicationName) · \(focusedCount.formatted()) in editor + \(nearbyCount.formatted()) nearby"
                            : "\(context.applicationName) · no readable text"
                    } else {
                        self.lastContextSummary = "No readable context found"
                    }
                }
            } else if dictationMode == .pro {
                lastContextSummary = "Context is turned off"
            }
        } catch {
            if !keepMicrophoneActive {
                capture.shutdown()
            }
            lastError = error.localizedDescription
            overlay.show(.error)
            overlay.hide(after: 0.8)
        }
    }

    private func stopAndTranscribe() {
        let recording = capture.stop(keepActive: keepMicrophoneActive)
        applyPendingAudioRouteChangeIfNeeded()
        recordingMode = nil
        recordingSessionID = nil
        let insertionTarget = self.insertionTarget
        self.insertionTarget = nil
        let context = recordingContext
        recordingContext = nil
        let model = selectedModel
        let dictationMode = self.dictationMode
        let proModeEngine = self.proModeEngine
        let proProfile = profileStore.selectedProfile

        if let integrityIssue = recording.integrityIssue {
            capture.recycle(recording.samples)
            lastError = integrityIssue
            activity = .idle
            overlay.show(.error)
            overlay.hide(after: 0.9)
            return
        }

        guard recording.duration >= 0.16, recording.rms >= 0.0025 else {
            capture.recycle(recording.samples)
            activity = .idle
            overlay.hide()
            return
        }

        activity = .transcribing
        overlay.show(.transcribing)
        let started = ProcessInfo.processInfo.systemUptime

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { capture.recycle(recording.samples) }
            do {
                let result = try await transcribe(
                    samples: recording.samples,
                    model: model,
                    mode: dictationMode,
                    proEngine: proModeEngine,
                    context: context,
                    profile: proProfile
                )
                guard !Task.isCancelled else { return }
                let transcript = result.text
                lastCompletedTranscript = transcript
                var insertion = transcript
                if appendTrailingSpace, !insertion.isEmpty {
                    insertion.append(" ")
                }
                let insertionResult = await TextInjector.inject(
                    insertion,
                    into: insertionTarget
                )
                let latency = ProcessInfo.processInfo.systemUptime - started
                lastLatency = latency
                let warning = insertionResult.errorMessage
                    ?? result.warning
                    ?? (recording.wasTruncated
                    ? "The five-minute recording limit was reached."
                    : nil)
                if let warning {
                    lastError = warning
                }
                activity = .idle
                if warning != nil {
                    overlay.show(.error)
                    overlay.hide(after: 0.9)
                } else {
                    overlay.hide()
                }
                // Persistence is deliberately enqueued only after the result
                // has been injected and the latency-sensitive work is over.
                history.enqueue(
                    samples: recording.samples,
                    transcript: transcript,
                    modelID: historyModelID(
                        model,
                        mode: dictationMode,
                        proEngine: proModeEngine
                    ),
                    modelName: historyModelName(
                        model,
                        mode: dictationMode,
                        proEngine: proModeEngine,
                        profile: proProfile
                    ),
                    duration: recording.duration,
                    latency: latency,
                    errorMessage: warning
                )
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                lastError = message
                activity = .idle
                overlay.show(.error)
                overlay.hide(after: 0.9)
                history.enqueue(
                    samples: recording.samples,
                    transcript: "",
                    modelID: historyModelID(
                        model,
                        mode: dictationMode,
                        proEngine: proModeEngine
                    ),
                    modelName: historyModelName(
                        model,
                        mode: dictationMode,
                        proEngine: proModeEngine,
                        profile: proProfile
                    ),
                    duration: recording.duration,
                    latency: nil,
                    errorMessage: message
                )
            }
        }
    }

    private func transcribe(
        samples: [Float],
        model: TranscriptionModel,
        mode: DictationMode,
        proEngine: ProModeEngine,
        context: AccessibilityContextSnapshot?,
        profile: ProProfile
    ) async throws -> (text: String, warning: String?) {
        guard mode == .pro else {
            let transcript = try await runtime.transcribe(samples: samples, modelID: model.id)
            return (transcript, nil)
        }

        switch proEngine {
        case .instruct:
            let rawTranscript = try await runtime.transcribe(
                samples: samples,
                modelID: model.id
            )
            guard let apiKey = KeychainStore.openAIAPIKey(), !apiKey.isEmpty else {
                throw ProTranscriptionError.missingAPIKey
            }
            if instructClient == nil || instructClientKey != apiKey {
                instructClient = OpenAITextClient(apiKey: apiKey)
                instructClientKey = apiKey
            }
            guard let instructClient else { throw ProTranscriptionError.invalidResponse }
            do {
                let polished = try await instructClient.polish(
                    rawTranscript,
                    context: context,
                    profilePrompt: profile.prompt
                )
                return (polished, nil)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                return (
                    rawTranscript,
                    "Instruct Pro cleanup was unavailable, so the Fast transcript was inserted. \(error.localizedDescription)"
                )
            }

        case .geminiTranscribe:
            guard let apiKey = KeychainStore.googleAPIKey(), !apiKey.isEmpty else {
                throw GeminiTranscriptionError.missingAPIKey
            }
            if geminiClient == nil || geminiClientKey != apiKey {
                geminiClient = GeminiTranscriptionClient(apiKey: apiKey)
                geminiClientKey = apiKey
            }
            guard let geminiClient else { throw GeminiTranscriptionError.invalidResponse }
            let transcript = try await geminiClient.transcribe(
                samples: samples,
                customVocabulary: GeminiVocabulary.terms(
                    profileText: profile.prompt,
                    context: context
                )
            )
            return (transcript, nil)
        }
    }

    private func audioDevicesDidChange() {
        refreshMicrophoneRoutes()
        guard !capture.isUsingPreferredInput() else { return }
        guard activity == .recording else {
            if keepMicrophoneActive { restartAudioCaptureForRoutingChange() }
            return
        }
        hasPendingAudioRouteChange = true
    }

    private func applyPendingAudioRouteChangeIfNeeded() {
        guard hasPendingAudioRouteChange else { return }
        hasPendingAudioRouteChange = false
        if keepMicrophoneActive {
            restartAudioCaptureForRoutingChange()
        }
    }

    private func historyModelID(
        _ model: TranscriptionModel,
        mode: DictationMode,
        proEngine: ProModeEngine
    ) -> String {
        guard mode == .pro else { return model.id }
        switch proEngine {
        case .instruct:
            return "\(model.id)+openai.\(OpenAITextClient.model)"
        case .geminiTranscribe:
            return "google.\(GeminiTranscriptionClient.model)"
        }
    }

    private func historyModelName(
        _ model: TranscriptionModel,
        mode: DictationMode,
        proEngine: ProModeEngine,
        profile: ProProfile
    ) -> String {
        guard mode == .pro else { return model.name }
        switch proEngine {
        case .instruct:
            return "\(model.name) · Instruct Pro · \(profile.name)"
        case .geminiTranscribe:
            return "Gemini 3.5 Transcribe · Pro · \(profile.name)"
        }
    }
}
