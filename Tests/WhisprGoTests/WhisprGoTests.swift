import AVFoundation
import AppKit
import CoreGraphics
import XCTest
@testable import WhisprGo

final class WhisprGoTests: XCTestCase {
    func testAppVersionComparesGitHubReleaseTagsNumerically() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("v1.9.9")), try XCTUnwrap(AppVersion("1.10.0")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.0")), try XCTUnwrap(AppVersion("v1.0.0")))
        XCTAssertNil(AppVersion("release-one"))
    }

    func testGitHubReleaseUpdateSelectsDMGOnlyForNewerVersion() throws {
        let data = Data(#"""
        {
            "tag_name":"v1.1.0",
            "html_url":"https://github.com/Lxvi101/WhisprGo/releases/tag/v1.1.0",
            "assets":[
                {"name":"WhisprGo-1.1.0.zip","browser_download_url":"https://example.com/app.zip"},
                {"name":"WhisprGo-1.1.0.dmg","browser_download_url":"https://example.com/app.dmg"}
            ]
        }
        """#.utf8)

        let update = try XCTUnwrap(
            GitHubReleaseUpdateParser.availableUpdate(from: data, currentVersion: "1.0.0")
        )
        XCTAssertEqual(update.version, "1.1.0")
        XCTAssertEqual(update.downloadURL.absoluteString, "https://example.com/app.dmg")
        XCTAssertNil(
            try GitHubReleaseUpdateParser.availableUpdate(from: data, currentVersion: "1.1.0")
        )
    }

    func testModelCatalogHasUniqueIDsAndValidDefault() {
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
        XCTAssertEqual(ModelCatalog.model(id: ModelCatalog.defaultModelID).id, "local.parakeet.v3")
        XCTAssertEqual(ModelCatalog.model(id: ModelCatalog.defaultModelID).name, "Parakeet TDT 0.6B v3")
        XCTAssertTrue(ModelCatalog.all.contains(where: { !$0.isLocal }))
    }

    func testDictationModesKeepFastAndProAsSeparatePipelines() {
        XCTAssertEqual(DictationMode.allCases, [.fast, .pro])
        XCTAssertTrue(DictationMode.fast.detail.contains("No cleanup model"))
        XCTAssertTrue(DictationMode.pro.detail.contains("GPT-5.6 Luna"))
    }

    func testProCleanupProvidersIncludeCloudAndLocalMLX() {
        XCTAssertEqual(ProCleanupProvider.allCases, [.openAI, .local])
        XCTAssertEqual(ProCleanupProvider.defaultProvider, .openAI)
        XCTAssertTrue(ProCleanupProvider.local.title.contains("Beta"))
        XCTAssertTrue(ProCleanupProvider.local.detail.contains("MLX"))
        XCTAssertTrue(LocalProModel.repositoryID.contains("E2B-it-UD-MLX-4bit"))
        XCTAssertEqual(LocalProModel.unloadDelay, .seconds(300))
    }

    func testProOutputRemovesModelWrappers() {
        XCTAssertEqual(
            ProTranscriptionOutput.clean("<think>ignore this</think>\nI took the taxi."),
            "I took the taxi."
        )
        XCTAssertEqual(
            ProTranscriptionOutput.clean("```text\nI took the taxi.\n```"),
            "I took the taxi."
        )
        XCTAssertEqual(
            ProTranscriptionOutput.clean("<final>I took the taxi.</final>"),
            "I took the taxi."
        )
    }

    func testRightShiftTapTogglesModeButTypingDoesNot() {
        var state = ModeShortcutState()
        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: [.maskShift]
        ))
        XCTAssertEqual(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: []
        ), .toggleMode)

        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: [.maskShift]
        ))
        XCTAssertNil(state.consume(
            type: .keyDown,
            keyCode: 0,
            flags: [.maskShift]
        ))
        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: []
        ))
    }

    func testRightControlAndRightShiftCyclesProfile() {
        var state = ModeShortcutState()
        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 62,
            flags: [.maskControl]
        ))
        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: [.maskControl, .maskShift]
        ))
        XCTAssertEqual(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: [.maskControl]
        ), .cycleProfile)
    }

    func testLeftControlAndRightShiftDoesNotSwitchMode() {
        var state = ModeShortcutState()
        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 59,
            flags: [.maskControl]
        ))
        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: [.maskControl, .maskShift]
        ))
        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: [.maskControl]
        ))
    }

    func testFnAndRightShiftDoesNotSwitchMode() {
        var state = ModeShortcutState()
        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: [.maskSecondaryFn, .maskShift]
        ))
        XCTAssertNil(state.consume(
            type: .flagsChanged,
            keyCode: 60,
            flags: []
        ))
    }

    func testPasteLastShortcutRequiresExactCommandOptionVChord() {
        XCTAssertTrue(HotkeyMonitor.isPasteLastShortcut(
            type: .keyDown,
            keyCode: 9,
            flags: [.maskCommand, .maskAlternate]
        ))
        XCTAssertTrue(HotkeyMonitor.isPasteLastChord(
            type: .keyDown,
            keyCode: 9,
            flags: [.maskCommand, .maskAlternate]
        ))
        XCTAssertFalse(HotkeyMonitor.isPasteLastShortcut(
            type: .keyDown,
            keyCode: 9,
            flags: [.maskAlternate]
        ))
        XCTAssertFalse(HotkeyMonitor.isPasteLastShortcut(
            type: .keyDown,
            keyCode: 9,
            flags: [.maskCommand, .maskAlternate, .maskShift]
        ))
        XCTAssertFalse(HotkeyMonitor.isPasteLastShortcut(
            type: .keyUp,
            keyCode: 9,
            flags: [.maskCommand, .maskAlternate]
        ))
        XCTAssertFalse(HotkeyMonitor.isPasteLastShortcut(
            type: .keyDown,
            keyCode: 9,
            flags: [.maskCommand, .maskAlternate],
            isRepeat: true
        ))
        XCTAssertFalse(HotkeyMonitor.isPasteLastShortcut(
            type: .keyDown,
            keyCode: 9,
            flags: [.maskControl, .maskAlternate]
        ))
    }

    func testDefaultHotkeysPreserveExistingGestures() {
        let configuration = HotkeyConfiguration.default
        XCTAssertEqual(configuration[.pushToTalk].displayComponents, ["fn"])
        XCTAssertEqual(configuration[.toggleDictation].displayComponents, ["fn", "⇧"])
        XCTAssertEqual(configuration[.toggleMode].displayComponents, ["R⇧"])
        XCTAssertEqual(configuration[.cycleProfile].displayComponents, ["R⌃", "R⇧"])
        XCTAssertEqual(configuration[.pasteLast].displayComponents, ["⌥", "⌘", "V"])
    }

    func testHotkeyConfigurationPersistsCustomShortcuts() throws {
        let suiteName = "WhisprGoHotkeyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var configuration = HotkeyConfiguration.default
        configuration[.toggleDictation] = .key(2, modifiers: [.control, .command])
        configuration.save(to: defaults)

        XCTAssertEqual(HotkeyConfiguration.load(from: defaults), configuration)
    }

    func testHotkeyValidationRejectsBareTypingKeysAndDuplicates() {
        let bareLetter = HotkeyShortcut.key(0, modifiers: [])
        XCTAssertNotNil(bareLetter.validationMessage)
        XCTAssertNil(HotkeyShortcut.key(122, modifiers: []).validationMessage)

        XCTAssertTrue(
            HotkeyShortcut.modifierChord([.init(.shift)])
                .conflicts(with: .modifierChord([.init(.shift, side: .right)]))
        )
        XCTAssertFalse(
            HotkeyShortcut.modifierChord([.init(.shift, side: .left)])
                .conflicts(with: .modifierChord([.init(.shift, side: .right)]))
        )

        let configuration = HotkeyConfiguration.default
        XCTAssertEqual(
            configuration.action(
                conflictingWith: configuration[.pasteLast],
                excluding: .toggleDictation
            ),
            .pasteLast
        )
    }

    func testConfigurableHotkeyMatchingUsesExactModifiersAndPhysicalSides() {
        let configuration = HotkeyConfiguration.default
        XCTAssertTrue(HotkeyMonitor.modifierShortcutMatches(
            configuration: configuration,
            action: .toggleMode,
            flags: [.maskShift],
            pressedModifierKeyCodes: [60]
        ))
        XCTAssertFalse(HotkeyMonitor.modifierShortcutMatches(
            configuration: configuration,
            action: .toggleMode,
            flags: [.maskShift],
            pressedModifierKeyCodes: [56]
        ))
        XCTAssertFalse(HotkeyMonitor.modifierShortcutMatches(
            configuration: configuration,
            action: .toggleMode,
            flags: [.maskShift, .maskControl],
            pressedModifierKeyCodes: [60, 62]
        ))
        XCTAssertEqual(
            HotkeyMonitor.keyShortcutAction(
                configuration: configuration,
                keyCode: 9,
                flags: [.maskCommand, .maskAlternate]
            ),
            .pasteLast
        )
    }

    @MainActor
    func testProProfilesPersistAndCycle() throws {
        let suiteName = "WhisprGoProfileTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProProfileStore(defaults: defaults)
        XCTAssertEqual(store.profiles.map(\.name), ["Standard"])
        let email = store.create()
        store.update(
            id: email.id,
            name: "Email",
            prompt: "Keep emails concise and warm."
        )
        XCTAssertEqual(store.selectedProfile.name, "Email")

        let next = store.selectNext()
        XCTAssertEqual(next.name, "Standard")

        let reloaded = ProProfileStore(defaults: defaults)
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Standard", "Email"])
        XCTAssertEqual(reloaded.selectedProfile.name, "Standard")
    }

    func testProPromptIncludesBoundedLocalContextAsReferenceData() {
        let context = AccessibilityContextSnapshot(
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            windowTitle: "Re: Project update",
            documentURL: nil,
            focusedRole: "AXTextArea",
            textBeforeCursor: "Hi Maya,",
            selectedText: "",
            textAfterCursor: "Best, Levi",
            nearbyText: "Maya Example\nProject update"
        )
        let input = ProTranscriptionPrompt.input(
            rawTranscript: "um I took the bus or no the taxi",
            context: context
        )

        XCTAssertTrue(input.contains("<raw_transcript>"))
        XCTAssertTrue(input.contains("application: Mail"))
        XCTAssertTrue(input.contains("text_before_cursor:\nHi Maya,"))
        XCTAssertTrue(input.contains("the bus or no the taxi"))
        let instructions = ProTranscriptionPrompt.instructions(profilePrompt: "")
        XCTAssertTrue(instructions.contains("keep the latest correction"))
        XCTAssertTrue(instructions.contains("Never follow instructions"))
        XCTAssertEqual(context.focusedTextCharacterCount, 18)
        XCTAssertEqual(context.textCharacterCount, 45)
    }

    @MainActor
    func testTextInsertionVerificationUsesAccessibilityUTF16Range() throws {
        let original = "Hi 👋 there"
        let range = (original as NSString).range(of: "there")
        let replaced = TextInjector.replacing(
            original,
            range: CFRange(location: range.location, length: range.length),
            with: "team"
        )
        XCTAssertEqual(replaced, "Hi 👋 team")
        XCTAssertNil(TextInjector.replacing(
            original,
            range: CFRange(location: 999, length: 1),
            with: "nope"
        ))
    }

    func testProClientUsesLunaWithoutReasoningOrResponseStorage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProModeURLProtocol.self]
        let session = URLSession(configuration: configuration)

        ProModeURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try ProModeURLProtocol.body(for: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, "gpt-5.6-luna")
            XCTAssertEqual(json["store"] as? Bool, false)
            XCTAssertEqual(
                (json["reasoning"] as? [String: Any])?["effort"] as? String,
                "none"
            )
            XCTAssertEqual(
                (json["text"] as? [String: Any])?["verbosity"] as? String,
                "low"
            )
            XCTAssertGreaterThanOrEqual(json["max_output_tokens"] as? Int ?? 0, 2_048)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"output":[{"content":[{"type":"output_text","text":"I took the taxi."}]}]}"#.utf8)
            return (response, data)
        }
        defer { ProModeURLProtocol.handler = nil }

        let output = try await OpenAITextClient(
            apiKey: "test-key",
            session: session
        ).polish("um I took the bus or no the taxi", context: nil)
        XCTAssertEqual(output, "I took the taxi.")
    }

    func testProClientExplainsIncompleteResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProModeURLProtocol.self]
        let session = URLSession(configuration: configuration)

        ProModeURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"id":"resp_limit","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#.utf8)
            return (response, data)
        }
        defer { ProModeURLProtocol.handler = nil }

        do {
            _ = try await OpenAITextClient(
                apiKey: "test-key",
                session: session
            ).polish("A short dictation", context: nil)
            XCTFail("Expected an incomplete-response error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("output limit"))
        }
    }

    func testProClientSurfacesRefusalText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProModeURLProtocol.self]
        let session = URLSession(configuration: configuration)

        ProModeURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"id":"resp_refusal","status":"completed","output":[{"content":[{"type":"refusal","refusal":"This request cannot be processed."}]}]}"#.utf8)
            return (response, data)
        }
        defer { ProModeURLProtocol.handler = nil }

        do {
            _ = try await OpenAITextClient(
                apiKey: "test-key",
                session: session
            ).polish("A short dictation", context: nil)
            XCTFail("Expected a refusal error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot be processed"))
        }
    }

    func testSanitizerRemovesNonSpeechTokensAndWhitespace() {
        let value = "  Hello   [BLANK_AUDIO]  world. (music)  "
        XCTAssertEqual(TextSanitizer.sanitize(value), "Hello world.")
    }

    func testWAVHeaderAndLength() {
        let data = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1])
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(data: data[0..<4], encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .utf8), "data")
    }

    func testWAVRoundTripForSavedHistoryAudio() throws {
        let original: [Float] = [-1, -0.5, 0, 0.25, 0.75, 1]
        let decoded = try WAVDecoder.decode(WAVEncoder.encode(samples: original))
        XCTAssertEqual(decoded.count, original.count)
        for (actual, expected) in zip(decoded, original) {
            XCTAssertEqual(actual, expected, accuracy: 1.0 / 32_767.0)
        }
    }

    func testHistoryPersistsAudioAndMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisprGoHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let persistence = DictationHistoryPersistence(rootURL: root)
        let samples = [Float](repeating: 0.2, count: 320)
        let created = try await persistence.add(
            samples: samples,
            transcript: "A saved dictation",
            modelID: "local.parakeet.v3",
            modelName: "Parakeet",
            duration: 0.02,
            latency: 0.12,
            errorMessage: nil
        )

        XCTAssertEqual(created.entries.count, 1)
        XCTAssertEqual(created.entries[0].transcript, "A saved dictation")
        let restoredSamples = try await persistence.samples(for: created.entries[0].id)
        XCTAssertEqual(restoredSamples.count, samples.count)
        XCTAssertEqual(restoredSamples[0], 0.2, accuracy: 1.0 / 32_767.0)

        let reloaded = DictationHistoryPersistence(rootURL: root)
        let reloadedSnapshot = try await reloaded.snapshot()
        XCTAssertEqual(reloadedSnapshot.entries, created.entries)

        let cleared = try await reloaded.removeAll()
        XCTAssertTrue(cleared.entries.isEmpty)
    }

    func testHistoryRetentionStaysBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisprGoHistoryLimitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let persistence = DictationHistoryPersistence(rootURL: root)
        var snapshot: DictationHistorySnapshot?
        for index in 0...DictationHistoryPersistence.maximumEntryCount {
            snapshot = try await persistence.add(
                samples: [Float(index) / 100],
                transcript: "Run \(index)",
                modelID: "local.parakeet.v3",
                modelName: "Parakeet",
                duration: 1.0 / AudioCapture.sampleRate,
                latency: nil,
                errorMessage: nil
            )
        }

        XCTAssertEqual(
            snapshot?.entries.count,
            DictationHistoryPersistence.maximumEntryCount
        )
        let audioFiles = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
            .filter { $0.pathExtension == "wav" }
        XCTAssertEqual(audioFiles.count, DictationHistoryPersistence.maximumEntryCount)
    }

    func testHistoryPreviewBoundsVeryLongTranscripts() {
        let longTranscript = String(repeating: "word ", count: 10_000)
        let preview = HistoryText.preview(longTranscript)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThanOrEqual(preview.count, HistoryText.previewCharacterLimit + 1)
        XCTAssertEqual(HistoryText.preview("Short transcript"), "Short transcript")
    }

    @MainActor
    func testPasteboardSnapshotRestoresEveryItemAndRepresentation() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        first.setData(Data([0x01, 0x02, 0x03]), forType: .init("com.whisprgo.test-data"))
        let second = NSPasteboardItem()
        second.setString("second item", forType: .string)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let snapshot = TextInjector.PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("temporary transcript", forType: .string))
        let ownedChangeCount = pasteboard.changeCount
        XCTAssertTrue(snapshot.restore(on: pasteboard, ifChangeCountIs: ownedChangeCount))

        let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "original")
        XCTAssertEqual(
            restoredItems[0].data(forType: .init("com.whisprgo.test-data")),
            Data([0x01, 0x02, 0x03])
        )
        XCTAssertEqual(restoredItems[1].string(forType: .string), "second item")
    }

    @MainActor
    func testPasteboardSnapshotDoesNotOverwriteAUserClipboardChange() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let snapshot = TextInjector.PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("temporary transcript", forType: .string))
        let staleChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new user copy", forType: .string))

        XCTAssertFalse(snapshot.restore(on: pasteboard, ifChangeCountIs: staleChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    @MainActor
    func testPasteboardSessionOwnershipSurvivesBenignRewriteButNotUserCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        let sessionID = UUID().uuidString

        func writeSession() {
            let item = NSPasteboardItem()
            item.setString("temporary transcript", forType: .string)
            item.setString(sessionID, forType: TextInjector.pasteSessionType)
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([item]))
        }

        writeSession()
        let originalChangeCount = pasteboard.changeCount
        XCTAssertTrue(TextInjector.pasteboardIsOwned(
            pasteboard,
            expectedChangeCount: originalChangeCount,
            text: "temporary transcript",
            sessionID: sessionID
        ))

        // Clipboard managers and Universal Clipboard can rewrite an item
        // without changing the text or WhisprGo's session marker.
        writeSession()
        XCTAssertNotEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertTrue(TextInjector.pasteboardIsOwned(
            pasteboard,
            expectedChangeCount: originalChangeCount,
            text: "temporary transcript",
            sessionID: sessionID
        ))

        // Some clipboard tools preserve only the plain string and strip
        // custom ownership markers while syncing the item.
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("temporary transcript", forType: .string))
        XCTAssertTrue(TextInjector.pasteboardIsOwned(
            pasteboard,
            expectedChangeCount: originalChangeCount,
            text: "temporary transcript",
            sessionID: sessionID
        ))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new user copy", forType: .string))
        XCTAssertFalse(TextInjector.pasteboardIsOwned(
            pasteboard,
            expectedChangeCount: originalChangeCount,
            text: "temporary transcript",
            sessionID: sessionID
        ))
    }

    func testStartupLineWaveBuildsLeftToRightAndSettlesExactly() throws {
        XCTAssertEqual(StartupMotionPreset.production, .lineWave)
        XCTAssertEqual(StartupMotionPreset.allCases.count, 4)
        XCTAssertEqual(StartupDotGeometry.dots.count, 55)

        let left = try XCTUnwrap(StartupDotGeometry.dots.min { $0.centerX < $1.centerX })
        let right = try XCTUnwrap(StartupDotGeometry.dots.max { $0.centerX < $1.centerX })
        let leftSamples = StartupMotionPreset.lineWave.samples(for: left, index: 0)
        let rightSamples = StartupMotionPreset.lineWave.samples(for: right, index: 0)
        let final = try XCTUnwrap(leftSamples.last)

        XCTAssertEqual(leftSamples.count, 86)
        XCTAssertGreaterThan(leftSamples[24].opacity, rightSamples[24].opacity)
        XCTAssertEqual(final.opacity, 1, accuracy: 0.000_001)
        XCTAssertEqual(final.translateX, 0, accuracy: 0.000_001)
        XCTAssertEqual(final.translateY, 0, accuracy: 0.000_001)
        XCTAssertEqual(final.scale, 1, accuracy: 0.000_001)
    }

    func testAudioLevelMeterKeepsNewestValue() {
        let meter = AudioLevelMeter()
        meter.store(0.125)
        meter.store(0.75)
        XCTAssertEqual(meter.load(), 0.75)
        meter.reset()
        XCTAssertEqual(meter.load(), 0)
    }

    func testAudioCallbackGateChangesImmediately() {
        let gate = AtomicFlag()
        XCTAssertFalse(gate.load())
        gate.store(true)
        XCTAssertTrue(gate.load())
        gate.store(false)
        XCTAssertFalse(gate.load())
    }

    func testMicrophoneResamplerPreservesVariablePacketDuration() throws {
        let sourceRate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        ))
        let resampler = try MicrophoneResampler(
            inputFormat: format,
            targetSampleRate: AudioCapture.sampleRate
        )

        let packetPattern = [257, 1_024, 4_800, 97, 10_000, 333]
        var sourceOffset = 0
        var packetIndex = 0
        var converted = [Float]()
        while sourceOffset < Int(sourceRate) {
            let requested = packetPattern[packetIndex % packetPattern.count]
            let count = min(requested, Int(sourceRate) - sourceOffset)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ))
            buffer.frameLength = AVAudioFrameCount(count)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<count {
                let phase = 2 * Double.pi * 440 * Double(sourceOffset + index) / sourceRate
                channel[index] = Float(sin(phase) * 0.5)
            }
            try resampler.withConvertedSamples(from: buffer) { samples in
                converted.append(contentsOf: samples)
            }
            sourceOffset += count
            packetIndex += 1
        }

        let convertedDuration = Double(converted.count) / AudioCapture.sampleRate
        XCTAssertEqual(convertedDuration, 1, accuracy: 0.03)
        XCTAssertTrue(converted.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(converted.map(abs).max() ?? 0, 0.25)
    }

    func testFunctionKeySchedulesAndEndsPushToTalk() {
        var state = HotkeyGestureState()
        XCTAssertEqual(
            state.consume(flags: [.maskSecondaryFn], pushToTalkIsActive: false),
            [.schedulePushToTalk]
        )
        XCTAssertEqual(
            state.consume(flags: [], pushToTalkIsActive: true),
            [.cancelPendingPushToTalk, .endPushToTalk]
        )
    }

    func testChordCancelsPendingPushToTalkAndTogglesOnce() {
        var state = HotkeyGestureState()
        _ = state.consume(flags: [.maskSecondaryFn], pushToTalkIsActive: false)
        XCTAssertEqual(
            state.consume(
                flags: [.maskSecondaryFn, .maskShift],
                pushToTalkIsActive: false
            ),
            [.cancelPendingPushToTalk, .toggle]
        )
        XCTAssertEqual(
            state.consume(
                flags: [.maskSecondaryFn, .maskShift],
                pushToTalkIsActive: false
            ),
            []
        )
    }
}
