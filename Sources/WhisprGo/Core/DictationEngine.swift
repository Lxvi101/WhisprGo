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
    @Published private(set) var modelCacheRevision = 0
    @Published private(set) var keepMicrophoneActive: Bool
    @Published private(set) var preferBuiltInMicrophone: Bool

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
    private static let preferBuiltInMicrophoneKey = "preferBuiltInMicrophone"
    private static let defaultModelVersionKey = "defaultModelVersion"
    private static let currentDefaultModelVersion = 2

    private let runtime = TranscriptionRuntime()
    private let capture: AudioCapture
    private let hotkey = HotkeyMonitor()
    private let overlay: RecordingOverlay
    private let history = DictationHistoryStore.shared

    private var hasStarted = false
    private var recordingMode: RecordingMode?
    private var insertionTarget: TextInjector.Target?
    private var modelPreparationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?

    private init() {
        LegacyMigration.run()
        let defaults = UserDefaults.standard
        let prefersBuiltIn = defaults.object(forKey: Self.preferBuiltInMicrophoneKey) as? Bool
            ?? true
        preferBuiltInMicrophone = prefersBuiltIn

        let levelMeter = AudioLevelMeter()
        capture = AudioCapture(
            levelMeter: levelMeter,
            preferBuiltInMicrophone: prefersBuiltIn
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
    }

    var selectedModel: TranscriptionModel {
        ModelCatalog.model(id: selectedModelID)
    }

    var canToggle: Bool {
        switch activity {
        case .recording:
            return true
        case .idle:
            return permissions.isComplete && modelState == .ready
        case .transcribing:
            return false
        }
    }

    var canChangeModel: Bool {
        activity == .idle
    }

    var canRerunHistory: Bool {
        activity == .idle && modelState == .ready
    }

    var stateTitle: String {
        switch activity {
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .idle: break
        }

        if !permissions.isComplete { return "Finish setup" }
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
                ? "Release fn to type"
                : "Press fn + shift again to type"
        case .transcribing:
            return "Your audio is becoming text"
        case .idle:
            break
        }
        if !permissions.microphone { return "Allow microphone access" }
        if !permissions.accessibility { return "Allow Accessibility access" }
        switch modelState {
        case .starting: return "Preparing WhisprGo"
        case let .downloading(progress):
            return "\(Int(progress * 100))% downloaded"
        case .warming: return "Optimizing for this Mac"
        case .ready: return "Hold fn, or fn + shift to toggle"
        case .needsAPIKey: return "Add your OpenAI key in Settings"
        case let .failed(message): return message
        }
    }

    var menuBarSymbol: String {
        switch activity {
        case .recording: return "waveform.circle.fill"
        case .transcribing: return "ellipsis.circle"
        case .idle:
            return permissions.isComplete && modelState == .ready
                ? "waveform.circle"
                : "exclamationmark.circle"
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
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
        capture.shutdown()
        hotkey.stop()
        history.stopPlayback()
        Task { await runtime.release() }
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
                let transcript = try await runtime.transcribe(
                    samples: samples,
                    modelID: model.id
                )
                guard !Task.isCancelled else { return }

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
                if let insertionError = insertionResult.errorMessage {
                    lastError = insertionError
                    overlay.show(.error)
                    overlay.hide(after: 0.9)
                } else {
                    overlay.hide()
                }
                history.updateAfterRerun(
                    id: id,
                    transcript: transcript,
                    modelID: model.id,
                    modelName: model.name,
                    latency: latency,
                    errorMessage: insertionResult.errorMessage
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
        prepareSelectedModel()
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

    func saveOpenAIAPIKey(_ key: String) -> Bool {
        do {
            try KeychainStore.saveOpenAIAPIKey(key)
            openAIKeyConfigured = KeychainStore.openAIAPIKey() != nil
            lastError = nil
            if !selectedModel.isLocal {
                prepareSelectedModel()
            }
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

    func setPreferBuiltInMicrophone(_ enabled: Bool) {
        guard activity == .idle, preferBuiltInMicrophone != enabled else { return }
        preferBuiltInMicrophone = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferBuiltInMicrophoneKey)
        lastError = nil

        capture.shutdown()
        capture.setPreferBuiltInMicrophone(enabled)
        if keepMicrophoneActive, permissions.microphone {
            activateAudioCapture()
        }
    }

    var microphoneRouteDescription: String {
        capture.activeInputName ?? capture.preferredInputName() ?? "System default microphone"
    }

    private func startHotkeyIfPossible() {
        guard permissions.accessibility else { return }
        do {
            try hotkey.start { [weak self] event in
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
                        guard let self, self.selectedModelID == model.id else { return }
                        self.modelState = progress < 0.999
                            ? .downloading(progress)
                            : .warming
                    }
                }
                guard !Task.isCancelled, selectedModelID == model.id else { return }
                modelState = .ready
            } catch is CancellationError {
                return
            } catch TranscriptionError.missingAPIKey {
                guard selectedModelID == model.id else { return }
                modelState = .needsAPIKey
            } catch {
                guard selectedModelID == model.id else { return }
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
            capture.recycle(recording.samples)
            recordingMode = nil
            insertionTarget = nil
            activity = .idle
            overlay.hide(after: 0)

        case .toggle:
            toggleDictation()
        }
    }

    private func startRecording(mode: RecordingMode) {
        let target = TextInjector.captureTarget()
        do {
            try capture.start()
            insertionTarget = target
            recordingMode = mode
            activity = .recording
            overlay.show(.recording)
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
        recordingMode = nil
        let insertionTarget = self.insertionTarget
        self.insertionTarget = nil
        let model = selectedModel

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
                let transcript = try await runtime.transcribe(
                    samples: recording.samples,
                    modelID: model.id
                )
                guard !Task.isCancelled else { return }
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
                let warning = insertionResult.errorMessage ?? (recording.wasTruncated
                    ? "The five-minute recording limit was reached."
                    : nil)
                if let warning {
                    lastError = warning
                }
                activity = .idle
                if insertionResult.errorMessage != nil {
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
                    modelID: model.id,
                    modelName: model.name,
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
                    modelID: model.id,
                    modelName: model.name,
                    duration: recording.duration,
                    latency: nil,
                    errorMessage: message
                )
            }
        }
    }
}
