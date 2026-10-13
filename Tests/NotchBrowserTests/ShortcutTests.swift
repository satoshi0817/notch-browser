import AppKit
import Combine
import XCTest
@testable import NotchBrowser

final class ShortcutTests: XCTestCase {
    private let prefix = ShortcutStroke(keyCode: 40, modifiers: .command)
    private let second = ShortcutStroke(keyCode: 1, modifiers: [.command,.option])

    func testRowErrorHidesNoteAndDismissedErrorRestoresSavedCaps() {
        let saved = ShortcutBinding.keys([prefix])
        let rejected = ShortcutBinding.keys([.init(keyCode: 40, modifiers: [])])
        let error = ShortcutRowPresentation(saved: saved, attempted: rejected, error: "エラー")
        XCTAssertEqual(error.caps, rejected.caps)
        XCTAssertTrue(error.hasError)
        XCTAssertNil(error.note)
        let restored = ShortcutRowPresentation(saved: saved, attempted: rejected, error: nil)
        XCTAssertEqual(restored.caps, saved.caps)
        XCTAssertFalse(restored.hasError)
        XCTAssertEqual(restored.note, saved.warning)
    }

    @MainActor
    func testRecorderErrorDismissesOnNextInteractionAndFocusLoss() {
        let store = SettingsStore(defaults: MemoryShortcutDefaults())
        let controller = ShortcutController(registrar: FakeShortcutRegistrar(), store: store,
                                            permissionAvailable: { false })
        let recorder = ShortcutRecorder(controller: controller)
        defer { recorder.cancel(); controller.shutdown() }
        let saved = ShortcutBinding.keys([prefix])
        XCTAssertNil(controller.set(saved, for: .toggle))
        func reject() {
            recorder.begin(.toggle)
            recorder.finish(.keys([.init(keyCode: 40, modifiers: [])]))
            XCTAssertNotNil(recorder.errors[.toggle])
            XCTAssertNotNil(recorder.attempted[.toggle])
        }
        func assertRestored() {
            let row = ShortcutRowPresentation(saved: store.data.shortcuts.toggle,
                attempted: recorder.attempted[.toggle], error: recorder.errors[.toggle])
            XCTAssertEqual(row.caps, saved.caps)
            XCTAssertEqual(row.note, saved.warning)
            XCTAssertFalse(row.hasError)
            XCTAssertTrue(recorder.attempted.isEmpty)
        }
        reject()
        recorder.begin(.detach)
        assertRestored()
        recorder.cancel()
        reject()
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        assertRestored()
        reject()
        recorder.dismissErrors() // Same dismissal path used by clicks/keyDown/scroll.
        assertRestored()
    }

    @MainActor
    func testStorePublishesSetAndResetAllSynchronouslyWithoutPermissionIPC() {
        let store = SettingsStore(defaults: MemoryShortcutDefaults())
        var permissionChecks = 0
        let controller = ShortcutController(registrar: FakeShortcutRegistrar(), store: store,
            permissionAvailable: { permissionChecks += 1; return false })
        defer { controller.shutdown() }
        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        var published: [ShortcutPreferences] = []
        let dataSubscription = store.$data.dropFirst().sink { published.append($0.shortcuts) }
        let binding = ShortcutBinding.keys([prefix, second])
        XCTAssertNil(controller.set(binding, for: .toggle))
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(published.last?.toggle, binding)
        XCTAssertEqual(store.data.shortcuts.toggle.caps, binding.caps)
        XCTAssertEqual(store.data.shortcuts.openHint, "⌘K  ⌥⌘S で開く")
        XCTAssertNotEqual(store.data.shortcuts.toggle, GlobalShortcutAction.toggle.defaultBinding)
        XCTAssertNil(controller.set(.doubleModifier(.command), for: .toggle))
        controller.resetAll()
        XCTAssertEqual(notifications, 3)
        XCTAssertEqual(store.data.shortcuts, ShortcutPreferences())
        XCTAssertEqual(store.data.shortcuts.openHint, "⌃⌥N で開く")
        XCTAssertEqual(permissionChecks, 0)
        withExtendedLifetime((subscription, dataSubscription)) {}
    }

    @MainActor
    func testRecorderSuccessAndResetClearAttemptedAndErrorsSynchronously() {
        let store = SettingsStore(defaults: MemoryShortcutDefaults())
        let controller = ShortcutController(registrar: FakeShortcutRegistrar(), store: store,
                                            permissionAvailable: { false })
        let recorder = ShortcutRecorder(controller: controller)
        defer { recorder.cancel(); controller.shutdown() }
        recorder.begin(.toggle)
        recorder.finish(.keys([.init(keyCode: 0, modifiers: [])]))
        XCTAssertNotNil(recorder.errors[.toggle])
        XCTAssertNotNil(recorder.attempted[.toggle])
        recorder.begin(.toggle)
        recorder.finish(.keys([prefix, second]))
        XCTAssertNil(recorder.errors[.toggle])
        XCTAssertNil(recorder.attempted[.toggle])
        XCTAssertEqual(store.data.shortcuts.toggle.caps, [prefix.display, second.display])
        recorder.reset(.toggle)
        XCTAssertEqual(store.data.shortcuts.toggle, GlobalShortcutAction.toggle.defaultBinding)
        XCTAssertNil(recorder.errors[.toggle])
        XCTAssertNil(recorder.attempted[.toggle])
        recorder.begin(.toggle)
        recorder.finish(.doubleModifier(.command))
        recorder.resetAll()
        XCTAssertEqual(store.data.shortcuts, ShortcutPreferences())
        XCTAssertTrue(recorder.errors.isEmpty)
        XCTAssertTrue(recorder.attempted.isEmpty)
    }

    func testOpenHintTracksDefaultCustomSequenceAndUnassigned() {
        var preferences = ShortcutPreferences()
        XCTAssertEqual(preferences.openHint, "⌃⌥N で開く")
        preferences.toggle = .keys([.init(keyCode:40, modifiers:[.command,.shift])])
        XCTAssertEqual(preferences.openHint, "⇧⌘K で開く")
        preferences.toggle = .keys([prefix,second])
        XCTAssertEqual(preferences.openHint, "⌘K  ⌥⌘S で開く")
        XCTAssertEqual(preferences.openSummary, "ノッチにカーソルを乗せるか、⌘K  ⌥⌘S で開く")
        preferences.toggle = .unassigned
        XCTAssertNil(preferences.openHint)
        XCTAssertEqual(preferences.openSummary, "ノッチにカーソルを乗せて開く")
    }

    func testDetachDefaultSurvivesMissingInvalidAndLegacyPreferences() throws {
        XCTAssertEqual(GlobalShortcutAction.toggle.defaultBinding.display, "⌃⌥N")
        XCTAssertEqual(GlobalShortcutAction.detach.defaultBinding.display, "⌃⌥⌘N")
        XCTAssertTrue(GlobalShortcutAction.allCases.contains(.detach))
        for json in ["{}", "{\"detach\":false}"] {
            XCTAssertEqual(try JSONDecoder().decode(ShortcutPreferences.self, from:Data(json.utf8)).detach,
                           GlobalShortcutAction.detach.defaultBinding)
        }
        let old = try JSONDecoder().decode(SettingsData.self, from:Data("{}".utf8))
        XCTAssertEqual(old.shortcuts.detach.display, "⌃⌥⌘N")
        XCTAssertEqual(old.shortcuts.toggle.display, "⌃⌥N")
    }

    func testWarningForOneModifierPrefixAndShiftOnlyValidation() {
        for binding: ShortcutBinding in [.keys([prefix]), .keys([prefix,.init(keyCode:37, modifiers:.command)])] {
            XCTAssertNil(ShortcutPreferences().error(for:binding, action:.toggle))
            XCTAssertEqual(binding.warning, "⌘K は他のアプリでは使えなくなります")
        }
        XCTAssertNil(GlobalShortcutAction.toggle.defaultBinding.warning)
        XCTAssertFalse(ShortcutStroke(keyCode:40, modifiers:.shift).isValid)
        XCTAssertTrue(ShortcutBinding.doubleModifier(.shift).isValid)
    }

    func testKeyUpOnlyObservationInterruptsSecondModifierPress() {
        var machine = ModifierDoublePressMachine()
        _ = machine.update(.command, at:0)
        _ = machine.update([], at:0.1)
        XCTAssertNil(machine.update(.command, at:0.2))
        machine.interrupt() // keyUp observed even when keyDown was consumed elsewhere.
        XCTAssertNil(machine.update([], at:0.3))
    }

    func testSecureInputDisablesPairAndDoesNotReuseHeldPressAfterExit() {
        var machine = ModifierDoublePressMachine()
        _ = machine.update(.option, at:0)
        _ = machine.update([], at:0.1)
        XCTAssertNil(machine.update(.option, at:0.2, secureInput:true))
        XCTAssertNil(machine.update([], at:0.3))
        XCTAssertNil(machine.update(.option, at:0.4))
        XCTAssertNil(machine.update([], at:0.5))
        XCTAssertNil(machine.update(.option, at:0.6))
        XCTAssertEqual(machine.update([], at:0.7), .option)
        for (flags,time): (ShortcutModifiers,TimeInterval) in [(.option,1),([],1.1),(.option,1.2),([],1.3)] {
            XCTAssertNil(machine.update(flags, at:time, secureInput:true))
        }
    }

    func testCapsLockAndUnrelatedFlagsDoNotChangeDoublePressIdentity() {
        var machine = ModifierDoublePressMachine()
        let other: NSEvent.ModifierFlags = [.capsLock,.numericPad,.help,.function]
        let down = ShortcutModifiers(other.union(.option))
        let up = ShortcutModifiers(other)
        XCTAssertEqual(down, .option)
        XCTAssertEqual(up, [])
        XCTAssertNil(machine.update(down, at:0))
        XCTAssertNil(machine.update(up, at:0.1))
        XCTAssertNil(machine.update(down, at:0.2))
        XCTAssertEqual(machine.update(up, at:0.3), .option)
    }

    func testMouseAndScrollInterruptionsDiscardPendingDoublePress() {
        for _ in 0..<4 { // left/right/other mouse down and scroll all use content-free interrupt().
            var machine = ModifierDoublePressMachine()
            _ = machine.update(.option, at:0)
            _ = machine.update([], at:0.1)
            machine.interrupt()
            XCTAssertNil(machine.update(.option, at:0.2))
            XCTAssertNil(machine.update([], at:0.3))
        }
    }

    func testTapResetWithModifierHeldRequiresFreshPair() {
        var machine = ModifierDoublePressMachine()
        machine.cancel(held:.command)
        XCTAssertNil(machine.update(.command, at:0))
        XCTAssertNil(machine.update([], at:0.1))
        XCTAssertNil(machine.update(.command, at:0.2))
        XCTAssertNil(machine.update([], at:0.3))
        XCTAssertNil(machine.update(.command, at:0.4))
        XCTAssertEqual(machine.update([], at:0.5), .command)
    }

    func testConsumedCarbonHotKeyInterruptsDoublePress() {
        let registrar = FakeShortcutRegistrar()
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix]); preferences.detach = .unassigned
        var doublePress = ModifierDoublePressMachine()
        let machine = ShortcutKeyMachine(registrar:registrar, now:{ 0 }, action:{ _ in }, keyPressed:{ doublePress.interrupt() })
        machine.start(preferences)
        _ = doublePress.update(.command, at:0)
        _ = doublePress.update([], at:0.1)
        _ = doublePress.update(.command, at:0.2)
        registrar.callbacks[1]?() // Command-K consumed by Carbon, absent from the session tap.
        XCTAssertNil(doublePress.update([], at:0.3))
        machine.stop()
    }

    func testForegroundLocalMonitorPreservesPrefixAndSecondButCancelsOtherKeys() {
        let registrar = FakeShortcutRegistrar()
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix,second]); preferences.detach = .unassigned
        var fired = 0
        let machine = ShortcutKeyMachine(registrar:registrar, now:{ 0 }, action:{ _ in fired += 1 })
        machine.start(preferences)
        machine.localKeyDown(prefix) // Local monitor before Carbon dispatch.
        registrar.callbacks[1]?()
        machine.localKeyDown(prefix) // Local monitor after Carbon dispatch.
        machine.localKeyDown(second)
        XCTAssertEqual(registrar.live, [1,2])
        registrar.callbacks[2]?()
        XCTAssertEqual(fired, 1)
        registrar.callbacks[1]?()
        machine.localKeyDown(.init(keyCode:38, modifiers:.option))
        XCTAssertEqual(registrar.live, [1])
        machine.stop()
        XCTAssertTrue(registrar.live.isEmpty)
    }

    func testKeyCodeAndModifierDisplay() {
        XCTAssertEqual(ShortcutStroke(keyCode: 45, modifiers: [.command,.control,.option]).display, "⌃⌥⌘N")
        XCTAssertEqual(ShortcutStroke(keyCode: 20, modifiers: [.command,.shift]).display, "⇧⌘3")
        XCTAssertEqual(ShortcutStroke(keyCode: 122, modifiers: []).display, "F1")
        XCTAssertEqual(ShortcutBinding.doubleModifier(.option).display, "⌥ ×2")
        XCTAssertEqual(ShortcutBinding.keys([prefix,second]).caps, ["⌘K","⌥⌘S"])
    }

    func testModifierPlatformConversion() {
        let modifiers: ShortcutModifiers = [.control,.option,.shift,.command]
        XCTAssertEqual(ShortcutModifiers(modifiers.appKit), modifiers)
        XCTAssertEqual(ShortcutModifiers([.capsLock,.function]), [])
        XCTAssertEqual(ShortcutModifiers(.command).carbon, 256)
    }

    func testMenuEquivalentClearsSequencesDoublePressAndUnassigned() {
        let item = NSMenuItem(title: "test", action: nil, keyEquivalent: "x")
        GlobalShortcutAction.detach.defaultBinding.apply(to: item)
        XCTAssertEqual(item.keyEquivalent, "n")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.control,.option,.command])
        for binding: ShortcutBinding in [.unassigned, .keys([prefix,second]), .doubleModifier(.option)] {
            binding.apply(to: item)
            XCTAssertEqual(item.keyEquivalent, "")
            XCTAssertEqual(item.keyEquivalentModifierMask, [])
        }
        ShortcutBinding.keys([.init(keyCode:122, modifiers:[])]).apply(to:item)
        XCTAssertEqual(item.keyEquivalent, "\u{f704}")
        ShortcutBinding.keys([.init(keyCode:123, modifiers:.option)]).apply(to:item)
        XCTAssertEqual(item.keyEquivalent, "\u{f702}")
        ShortcutBinding.keys([.init(keyCode:76, modifiers:.command)]).apply(to:item)
        XCTAssertEqual(item.keyEquivalent, "\u{3}")
    }

    func testReservedKeys() {
        let reserved: [ShortcutStroke] = [
            .init(keyCode:49, modifiers:.command), .init(keyCode:49, modifiers:.control),
            .init(keyCode:48, modifiers:.command), .init(keyCode:48, modifiers:[.command,.shift]),
            .init(keyCode:50, modifiers:.command), .init(keyCode:12, modifiers:.command),
            .init(keyCode:53, modifiers:[.command,.option]), .init(keyCode:12, modifiers:[.control,.command]),
            .init(keyCode:20, modifiers:[.command,.shift]), .init(keyCode:21, modifiers:[.command,.shift]),
            .init(keyCode:23, modifiers:[.command,.shift])
        ]
        for stroke in reserved {
            XCTAssertTrue(stroke.isReserved)
            XCTAssertEqual(ShortcutPreferences().error(for:.keys([stroke]), action:.toggle), "システムで使われています")
        }
        XCTAssertFalse(prefix.isReserved)
    }

    func testUnmodifiedKeysAreRejectedExceptFunctionKeys() {
        XCTAssertFalse(ShortcutStroke(keyCode:40, modifiers:[]).isValid)
        XCTAssertTrue(ShortcutStroke(keyCode:122, modifiers:[]).isValid)
        XCTAssertFalse(ShortcutStroke(keyCode:999, modifiers:.command).isValid)
        XCTAssertFalse(ShortcutStroke(keyCode:40, modifiers:.init(rawValue:16)).isValid)
        XCTAssertFalse(ShortcutBinding.keys([]).isValid)
        XCTAssertFalse(ShortcutBinding.keys([prefix,prefix,prefix]).isValid)
        XCTAssertFalse(ShortcutBinding.doubleModifier([.command,.option]).isValid)
        XCTAssertEqual(ShortcutPreferences().error(for: .keys([.init(keyCode:40, modifiers:[])]), action:.toggle),
                       "⌘・⌥・⌃ のどれかと一緒に押してください")
    }

    func testConflictAcrossSingleAndSequencePrefixesAndTemporarySteps() {
        let single = ShortcutBinding.keys([prefix])
        let sequence = ShortcutBinding.keys([prefix,second])
        XCTAssertTrue(single.overlaps(sequence))
        XCTAssertTrue(sequence.overlaps(single))
        XCTAssertTrue(sequence.overlaps(.keys([prefix,.init(keyCode:38, modifiers:.option)])))
        XCTAssertTrue(sequence.overlaps(.keys([second])))
        XCTAssertFalse(single.overlaps(.keys([second])))
        XCTAssertFalse(ShortcutBinding.unassigned.overlaps(.unassigned))
        var settings = ShortcutPreferences()
        settings.detach = sequence
        XCTAssertEqual(settings.error(for:single, action:.toggle), "『ウインドウで開く / ノッチに戻す』と同じキーです")
    }

    func testDoubleModifierConflict() {
        var settings = ShortcutPreferences()
        settings.detach = .doubleModifier(.option)
        XCTAssertNotNil(settings.error(for:.doubleModifier(.option), action:.toggle))
        XCTAssertNil(settings.error(for:.doubleModifier(.control), action:.toggle))
        XCTAssertNil(settings.error(for:.unassigned, action:.toggle))
    }

    func testFixedApplicationShortcutConflict() {
        XCTAssertEqual(ShortcutPreferences().error(for:.keys([.init(keyCode:43, modifiers:.command)]), action:.toggle), "『設定』と同じキーです")
        XCTAssertEqual(ShortcutPreferences().error(for:.keys([.init(keyCode:17, modifiers:.command)]), action:.toggle), "『新規タブ』と同じキーです")
        XCTAssertEqual(ShortcutPreferences().error(for:.keys([.init(keyCode:43, modifiers:.command),prefix]), action:.toggle), "『設定』と同じキーです")
        XCTAssertNil(ShortcutPreferences().error(for:.keys([prefix,.init(keyCode:17, modifiers:.command)]), action:.toggle))
    }

    func testOneModifierIsAcceptedAndWarnsForSingleAndSequencePrefix() {
        let preferences = ShortcutPreferences()
        for binding: ShortcutBinding in [.keys([prefix]), .keys([prefix,second])] {
            XCTAssertNil(preferences.error(for:binding, action:.toggle))
            XCTAssertEqual(binding.warning, "⌘K は他のアプリでは使えなくなります")
        }
        XCTAssertNil(GlobalShortcutAction.toggle.defaultBinding.warning)
        XCTAssertNil(ShortcutBinding.doubleModifier(.option).warning)
    }

    func testRecordingSingleAtPointEightAndSequenceBeforeDeadline() {
        var recording = ShortcutRecordingMachine()
        XCTAssertNil(recording.key(prefix, at:10))
        XCTAssertNil(recording.tick(at:10.799))
        XCTAssertEqual(recording.tick(at:10.8), .keys([prefix]))
        XCTAssertNil(recording.first)
        XCTAssertNil(recording.key(prefix, at:20))
        XCTAssertEqual(recording.key(second, at:20.799), .keys([prefix,second]))
        XCTAssertNil(recording.tick(at:21))
    }

    func testRecordingCancellationAndLateSecond() {
        var recording = ShortcutRecordingMachine()
        _ = recording.key(prefix, at:0)
        recording.cancel()
        XCTAssertNil(recording.tick(at:1))
        XCTAssertNil(recording.key(second, at:2))
        XCTAssertEqual(recording.key(prefix, at:2.8), .keys([second]))
    }

    func testDoublePressRequiresReleaseAndMatchingModifierWithinDeadline() {
        var machine = ModifierDoublePressMachine()
        XCTAssertNil(machine.update(.option, at:0))
        XCTAssertNil(machine.update(.option, at:0.1)) // holding/repeat is not a second press
        XCTAssertNil(machine.update([], at:0.2))
        XCTAssertNil(machine.update(.option, at:0.5))
        XCTAssertEqual(machine.update([], at:0.6), .option)
        XCTAssertNil(machine.update(.option, at:0.7)) // no overlapping triples
        XCTAssertNil(machine.update([], at:0.8))
        machine.cancel()
        XCTAssertNil(machine.update(.command, at:2))
        XCTAssertNil(machine.update([], at:2.1))
        XCTAssertNil(machine.update(.option, at:2.2))
        XCTAssertNil(machine.update([], at:2.3))
    }

    func testDoublePressChordAndCancellationResetHistory() {
        var machine = ModifierDoublePressMachine()
        _ = machine.update(.option, at:0)
        _ = machine.update([.option,.command], at:0.1)
        _ = machine.update([], at:0.2)
        XCTAssertNil(machine.update(.option, at:0.3))
        XCTAssertNil(machine.update([], at:0.4))
        machine.cancel()
        XCTAssertNil(machine.update(.option, at:0.5))
        XCTAssertNil(machine.update([], at:0.6))
    }

    func testDoublePressIgnoresKeyDownWhileModifierHeld() {
        var machine = ModifierDoublePressMachine()
        XCTAssertNil(machine.update(.option, at:0))
        machine.interrupt() // Ordinary keyDown: no event contents are supplied.
        XCTAssertNil(machine.update(.option, at:0.1)) // Still held, not a new first press.
        XCTAssertNil(machine.update([], at:0.2))
        XCTAssertNil(machine.update(.option, at:0.3))
        XCTAssertNil(machine.update([], at:0.4))
    }

    func testDoublePressIgnoresKeyDownBetweenPresses() {
        var machine = ModifierDoublePressMachine()
        XCTAssertNil(machine.update(.option, at:0))
        XCTAssertNil(machine.update([], at:0.1))
        machine.interrupt()
        XCTAssertNil(machine.update(.option, at:0.3))
        XCTAssertNil(machine.update([], at:0.4))
    }

    func testDoublePressStillFiresWithoutKeyInput() {
        var machine = ModifierDoublePressMachine()
        XCTAssertNil(machine.update(.option, at:0))
        XCTAssertNil(machine.update([], at:0.1))
        XCTAssertNil(machine.update(.option, at:0.3))
        XCTAssertEqual(machine.update([], at:0.4), .option)
    }

    func testDoublePressRecoversWithFreshPairAfterKeyDown() {
        var machine = ModifierDoublePressMachine()
        _ = machine.update(.option, at:0)
        machine.interrupt()
        machine.interrupt() // Repeated keyDown also invalidates history.
        _ = machine.update([], at:0.1)
        XCTAssertNil(machine.update(.option, at:0.2))
        XCTAssertNil(machine.update([], at:0.3))
        XCTAssertNil(machine.update(.option, at:0.4))
        XCTAssertEqual(machine.update([], at:0.5), .option)
    }

    func testDoublePressCommandThenCommandKeyDoesNotFireOnRelease() {
        var machine = ModifierDoublePressMachine()
        XCTAssertNil(machine.update(.command, at:0))
        XCTAssertNil(machine.update([], at:0.1))
        XCTAssertNil(machine.update(.command, at:0.2))
        machine.interrupt() // The tap supplies no key contents, including for Command-K.
        XCTAssertNil(machine.update([], at:0.3))
    }

    func testDoublePressSecondOptionPressInterruptedByKeyDownDoesNotFire() {
        var machine = ModifierDoublePressMachine()
        _ = machine.update(.option, at:0)
        _ = machine.update([], at:0.1)
        XCTAssertNil(machine.update(.option, at:0.2))
        machine.interrupt()
        XCTAssertNil(machine.update(.option, at:0.25)) // Holding cannot restart a press.
        XCTAssertNil(machine.update([], at:0.3))
        XCTAssertNil(machine.update(.option, at:0.4))
        XCTAssertNil(machine.update([], at:0.5))
        XCTAssertNil(machine.update(.option, at:0.6))
        XCTAssertEqual(machine.update([], at:0.7), .option) // Fresh pair still works.
    }

    func testDoublePressDifferentModifierBetweenTapsInvalidatesPair() {
        var machine = ModifierDoublePressMachine()
        for (flags, time): (ShortcutModifiers, TimeInterval) in [
            (.command, 0), ([], 0.05), (.option, 0.1), ([], 0.15), (.command, 0.2), ([], 0.25)
        ] {
            XCTAssertNil(machine.update(flags, at:time))
        }
        machine.cancel()
        _ = machine.update(.command, at:0)
        _ = machine.update([], at:0.05)
        _ = machine.update(.command, at:0.1)
        XCTAssertNil(machine.update([.command,.shift], at:0.15))
        XCTAssertNil(machine.update(.command, at:0.2))
        XCTAssertNil(machine.update([], at:0.25))
    }

    func testDoublePressRejectsLongFirstPress() {
        var machine = ModifierDoublePressMachine()
        _ = machine.update(.option, at:0)
        XCTAssertNil(machine.update([], at:0.301))
        XCTAssertNil(machine.update(.option, at:0.4))
        XCTAssertNil(machine.update([], at:0.5))
    }

    func testDoublePressRejectsLongSecondPress() {
        var machine = ModifierDoublePressMachine()
        _ = machine.update(.option, at:0)
        _ = machine.update([], at:0.1)
        XCTAssertNil(machine.update(.option, at:0.2))
        XCTAssertNil(machine.update([], at:0.501))
        XCTAssertNil(machine.update(.option, at:0.6))
        XCTAssertNil(machine.update([], at:0.7))
    }

    func testDoublePressRejectsGapBeyondPointFourSeconds() {
        var machine = ModifierDoublePressMachine()
        _ = machine.update(.option, at:0)
        _ = machine.update([], at:0.1)
        XCTAssertNil(machine.update(.option, at:0.501))
        XCTAssertNil(machine.update([], at:0.6))
    }

    func testDoublePressTripleTapFiresOnlyOnce() {
        var machine = ModifierDoublePressMachine()
        var fired: [ShortcutModifiers] = []
        for index in 0..<3 {
            XCTAssertNil(machine.update(.option, at:Double(index) * 0.2))
            if let modifier = machine.update([], at:Double(index) * 0.2 + 0.1) { fired.append(modifier) }
        }
        XCTAssertEqual(fired, [.option])
    }

    func testDoublePressIncludesExactPressAndGapBoundaries() {
        XCTAssertEqual(ModifierDoublePressMachine.maxPressDuration, 0.3)
        XCTAssertEqual(ModifierDoublePressMachine.maxGap, 0.4)
        var machine = ModifierDoublePressMachine()
        XCTAssertNil(machine.update(.option, at:0))
        XCTAssertNil(machine.update([], at:0.3))
        XCTAssertNil(machine.update(.option, at:0.7))
        XCTAssertEqual(machine.update([], at:1.0), .option)
    }

    func testPermissionPollingOnlyRunsWhileAwaitingPermission() {
        XCTAssertTrue(ShortcutPermissionPolling.shouldRun(running:true, recording:false, hasDoublePress:true, needsPermission:true))
        // Grant, removing the last double press, recording and shutdown each stop polling.
        XCTAssertFalse(ShortcutPermissionPolling.shouldRun(running:true, recording:false, hasDoublePress:true, needsPermission:false))
        XCTAssertFalse(ShortcutPermissionPolling.shouldRun(running:true, recording:false, hasDoublePress:false, needsPermission:true))
        XCTAssertFalse(ShortcutPermissionPolling.shouldRun(running:true, recording:true, hasDoublePress:true, needsPermission:true))
        XCTAssertFalse(ShortcutPermissionPolling.shouldRun(running:false, recording:false, hasDoublePress:true, needsPermission:true))
    }

    func testSequenceTimeoutUnregistersAndCancelsScheduledWork() {
        let registrar = FakeShortcutRegistrar()
        var time: TimeInterval = 0
        let scheduler = FakeShortcutScheduler()
        let machine = ShortcutSequenceMachine(registrar:registrar, now:{ time }, schedule:scheduler.schedule)
        XCTAssertTrue(machine.begin(second:second) { XCTFail("timeout must not fire") })
        XCTAssertEqual(scheduler.delay, 0.8)
        time = 0.799; machine.tick()
        XCTAssertTrue(machine.isPending)
        time = 0.8; scheduler.callback?()
        XCTAssertFalse(machine.isPending)
        XCTAssertEqual(registrar.unregistered, [1])
        XCTAssertEqual(scheduler.cancellations, 1)
        machine.cancel()
        XCTAssertEqual(registrar.unregistered, [1])
    }

    func testSequenceAcceptsSecondAndUnregistersBeforeAction() {
        let registrar = FakeShortcutRegistrar()
        var time: TimeInterval = 10
        let machine = ShortcutSequenceMachine(registrar:registrar, now:{ time })
        var fired = 0
        machine.begin(second:second) {
            XCTAssertTrue(registrar.live.isEmpty)
            fired += 1
        }
        time = 10.7
        registrar.callbacks[1]?()
        registrar.callbacks[1]?()
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(registrar.unregistered, [1])
    }

    func testSequenceLateDeliveryDoesNotFireAndStillUnregisters() {
        let registrar = FakeShortcutRegistrar()
        var time: TimeInterval = 0
        let machine = ShortcutSequenceMachine(registrar:registrar, now:{ time })
        machine.begin(second:second) { XCTFail("late callback") }
        time = 0.8; registrar.callbacks[1]?()
        XCTAssertEqual(registrar.unregistered, [1])
    }

    func testSequenceReplacedOrCancelledIgnoresQueuedOldCallbacks() {
        let registrar = FakeShortcutRegistrar()
        let machine = ShortcutSequenceMachine(registrar:registrar, now:{ 0 })
        var fired = 0
        machine.begin(second:second) { XCTFail("old action") }
        machine.begin(second:prefix) { fired += 1 }
        registrar.callbacks[1]?()
        XCTAssertTrue(machine.isPending)
        XCTAssertEqual(registrar.unregistered, [1])
        registrar.callbacks[2]?()
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(registrar.unregistered, [1,2])
        machine.begin(second:second) { XCTFail("cancelled action") }
        machine.cancel(); registrar.callbacks[3]?()
        XCTAssertEqual(registrar.unregistered, [1,2,3])
    }

    func testSequenceRegistrationFailureAndDeinitCleanup() {
        let registrar = FakeShortcutRegistrar()
        var machine: ShortcutSequenceMachine? = ShortcutSequenceMachine(registrar:registrar, now:{ 0 })
        machine?.begin(second:second) {}
        registrar.fail = true
        XCTAssertFalse(machine!.begin(second:prefix) {})
        XCTAssertFalse(machine!.isPending)
        XCTAssertEqual(registrar.unregistered, [1])
        registrar.fail = false
        machine?.begin(second:second) {}
        machine = nil
        XCTAssertEqual(registrar.unregistered, [1,2])
        XCTAssertTrue(registrar.live.isEmpty)
    }

    func testPreferencesRoundTripAllBindingTypesAndUnset() throws {
        for binding: ShortcutBinding in [.unassigned,.keys([prefix]),.keys([prefix,second]),.doubleModifier(.option)] {
            var preferences = ShortcutPreferences(); preferences.toggle = binding
            let raw = try JSONEncoder().encode(preferences)
            XCTAssertEqual(try JSONDecoder().decode(ShortcutPreferences.self, from:raw), preferences)
        }
    }

    func testMissingAndBrokenDataFallsBackWithoutDiscardingOtherSettings() throws {
        let defaults = ShortcutPreferences()
        XCTAssertEqual(try JSONDecoder().decode(ShortcutPreferences.self, from:Data("{}".utf8)), defaults)
        let broken = Data("{\"toggle\":false,\"detach\":null}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutPreferences.self, from:broken), defaults)
        let settings = try JSONDecoder().decode(SettingsData.self, from:Data("{\"shortcuts\":false,\"countdownMinutes\":42}".utf8))
        XCTAssertEqual(settings.shortcuts, defaults)
        XCTAssertEqual(settings.countdownMinutes, 42)
        XCTAssertThrowsError(try JSONDecoder().decode(ShortcutPreferences.self, from:Data("broken".utf8)))
    }

    func testInvalidAndConflictingSavedBindingsFallBack() throws {
        var preferences = ShortcutPreferences()
        for invalid: ShortcutBinding in [.keys([]), .doubleModifier([]), .keys([.init(keyCode:49, modifiers:.command)])] {
            preferences.toggle = invalid
            let raw = try JSONEncoder().encode(preferences)
            XCTAssertEqual(try JSONDecoder().decode(ShortcutPreferences.self, from:raw).toggle, GlobalShortcutAction.toggle.defaultBinding)
        }
        preferences.toggle = preferences.detach
        let raw = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(ShortcutPreferences.self, from:raw)
        XCTAssertFalse(decoded.toggle.overlaps(decoded.detach))
    }

    func testSettingsDataRoundTripPreservesUnassigned() throws {
        var settings = SettingsData()
        settings.shortcuts.toggle = .unassigned
        settings.shortcuts.detach = .doubleModifier(.control)
        let decoded = try JSONDecoder().decode(SettingsData.self, from:JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.shortcuts, settings.shortcuts)
    }

    func testRepeatedStrokeSequenceTransfersOwnershipThenRestoresPrefix() {
        let registrar = FakeShortcutRegistrar()
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix,prefix]); preferences.detach = .unassigned
        var actions: [GlobalShortcutAction] = []
        let machine = ShortcutKeyMachine(registrar:registrar, now:{ 0 }, action:{ actions.append($0) })
        machine.start(preferences)
        registrar.callbacks[1]?()
        XCTAssertEqual(registrar.unregistered, [1])
        XCTAssertEqual(registrar.live, [2])
        registrar.callbacks[1]?() // obsolete queued permanent-prefix delivery
        XCTAssertEqual(registrar.live, [2])
        registrar.callbacks[2]?()
        XCTAssertEqual(actions, [.toggle])
        XCTAssertEqual(registrar.unregistered, [1,2])
        XCTAssertEqual(registrar.live, [3])
        machine.stop()
        XCTAssertEqual(registrar.unregistered, [1,2,3])
    }

    func testRepeatedStrokeTimeoutRestoresPrefixWithoutAction() {
        let registrar = FakeShortcutRegistrar()
        let scheduler = FakeShortcutScheduler()
        var time: TimeInterval = 0
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix,prefix]); preferences.detach = .unassigned
        let machine = ShortcutKeyMachine(registrar:registrar, now:{ time }, schedule:scheduler.schedule,
                                         action:{ _ in XCTFail("timeout") })
        machine.start(preferences); registrar.callbacks[1]?()
        time = 0.8; scheduler.callback?()
        XCTAssertEqual(registrar.unregistered, [1,2])
        XCTAssertEqual(registrar.live, [3])
        machine.stop()
    }

    func testOtherActionCancelsTemporaryRegistration() {
        let registrar = FakeShortcutRegistrar()
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix, .init(keyCode:38, modifiers:.option)])
        preferences.detach = .keys([second])
        var actions: [GlobalShortcutAction] = []
        let machine = ShortcutKeyMachine(registrar:registrar, now:{ 0 }, action:{ actions.append($0) })
        machine.start(preferences)
        registrar.callbacks[1]?() // temporary token 3
        XCTAssertEqual(registrar.live.count, 3)
        registrar.callbacks[2]?() // other global shortcut
        XCTAssertEqual(actions, [.detach])
        XCTAssertEqual(registrar.unregistered, [3])
        registrar.callbacks[3]?()
        XCTAssertEqual(actions, [.detach])
        machine.stop()
        XCTAssertTrue(registrar.live.isEmpty)
    }

    func testRecordingSuspensionResumePreferenceChangeAndShutdownCleanAllRegistrations() {
        let registrar = FakeShortcutRegistrar()
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix,second]); preferences.detach = .unassigned
        var machine: ShortcutKeyMachine? = ShortcutKeyMachine(registrar:registrar, now:{ 0 }, action:{ _ in XCTFail("stale action") })
        machine?.start(preferences); registrar.callbacks[1]?()
        XCTAssertEqual(registrar.live.count, 2)
        machine?.stop() // recorder begins
        XCTAssertTrue(registrar.live.isEmpty)
        registrar.callbacks[1]?(); registrar.callbacks[2]?()
        machine?.start(preferences) // recorder cancels or finishes
        XCTAssertEqual(registrar.live, [3])
        registrar.callbacks[3]?() // temporary 4
        preferences.toggle = .keys([second])
        machine?.start(preferences) // assignment changes
        XCTAssertEqual(Set(registrar.unregistered), [1,2,3,4])
        XCTAssertEqual(registrar.live, [5])
        machine = nil // app shuts down/deinitializes
        XCTAssertTrue(registrar.live.isEmpty)
        XCTAssertEqual(Set(registrar.unregistered), [1,2,3,4,5])
    }

    func testTemporaryRegistrationFailureLeavesPrefixUsableAndReportsError() {
        let registrar = FakeShortcutRegistrar()
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix,second]); preferences.detach = .unassigned
        var failed: [GlobalShortcutAction] = []
        let machine = ShortcutKeyMachine(registrar:registrar, now:{ 0 }, action:{ _ in XCTFail("failed second") },
                                         registrationFailed:{ failed.append($0) })
        machine.start(preferences)
        registrar.failStroke = second
        registrar.callbacks[1]?()
        XCTAssertEqual(failed, [.toggle])
        XCTAssertEqual(registrar.live, [1])
        machine.stop()
    }

    func testPrefixHandlerRegistersSecondBeforeReturning() {
        let registrar = FakeShortcutRegistrar()
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix,second]); preferences.detach = .unassigned
        let machine = ShortcutKeyMachine(registrar:registrar, now:{ 0 }, action:{ _ in })
        machine.start(preferences)
        registrar.callbacks[1]?()
        XCTAssertEqual(registrar.live, [1,2])
        XCTAssertEqual(registrar.stroke(for:2), second)
        machine.stop()
        XCTAssertTrue(registrar.live.isEmpty)
    }

    func testUnchangedPreferencesPreservePendingSecondAndPrefix() {
        let registrar = FakeShortcutRegistrar()
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix,second]); preferences.detach = .unassigned
        let machine = ShortcutKeyMachine(registrar:registrar, now:{ 0 }, action:{ _ in })
        machine.start(preferences); registrar.callbacks[1]?()
        machine.start(preferences)
        XCTAssertEqual(registrar.live, [1,2])
        XCTAssertTrue(registrar.unregistered.isEmpty)
        machine.stop()
    }

    @MainActor
    func testApplicationActivationPermissionRefreshPreservesCarbonRegistrations() {
        let registrar = FakeShortcutRegistrar()
        var preferences = ShortcutPreferences()
        preferences.toggle = .keys([prefix,second]); preferences.detach = .doubleModifier(.option)
        var permission = false
        let controller = ShortcutController(registrar:registrar, loadPreferences:{ preferences }, permissionAvailable:{ permission })
        controller.start()
        defer { controller.shutdown() }
        registrar.callbacks[1]?()
        XCTAssertEqual(registrar.stroke(for:2), second)
        NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification, object:nil)
        XCTAssertEqual(registrar.live, [1,2])
        XCTAssertTrue(registrar.unregistered.isEmpty)
        XCTAssertTrue(controller.needsPermission)
        permission = true
        NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification, object:nil)
        XCTAssertFalse(controller.needsPermission)
        XCTAssertEqual(registrar.live, [1,2])
        XCTAssertTrue(registrar.unregistered.isEmpty)
        controller.shutdown()
        XCTAssertTrue(registrar.live.isEmpty)
    }
}

private final class MemoryShortcutDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

private final class FakeShortcutRegistrar: ShortcutRegistrar {
    var fail = false
    var live: Set<Int> = []
    var callbacks: [Int:() -> Void] = [:]
    var unregistered: [Int] = []
    var failStroke: ShortcutStroke?
    private var strokes: [Int:ShortcutStroke] = [:]
    private var next = 0
    func stroke(for token: Int) -> ShortcutStroke? { strokes[token] }
    func register(_ stroke: ShortcutStroke, action: @escaping () -> Void) -> Int? {
        if fail || stroke == failStroke || strokes.values.contains(stroke) { return nil }
        next += 1; live.insert(next); callbacks[next] = action; strokes[next] = stroke; return next
    }
    func unregister(_ token: Int) {
        XCTAssertNotNil(live.remove(token), "each registration must be removed exactly once")
        unregistered.append(token)
        strokes[token] = nil
    }
}

private final class FakeShortcutScheduler {
    var delay: TimeInterval?
    var callback: (() -> Void)?
    var cancellations = 0
    func schedule(_ delay: TimeInterval, _ callback: @escaping () -> Void) -> (() -> Void) {
        self.delay = delay; self.callback = callback
        return { self.cancellations += 1 }
    }
}
