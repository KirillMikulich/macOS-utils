import Carbon.HIToolbox
import XCTest
@testable import MacUtilities

final class KeyComboTests: XCTestCase {
    func testDisplayString() {
        XCTAssertEqual(KeyCombo.switcherForwardDefault.displayString, "⌥⇥")
        XCTAssertEqual(KeyCombo.switcherBackwardDefault.displayString, "⌥⇧⇥")
        XCTAssertEqual(KeyCombo.clipboardPanelDefault.displayString, "⌥⇧V")
    }

    func testValidity() {
        XCTAssertTrue(KeyCombo(keyCode: kVK_ANSI_V, modifiers: [.option]).isValidGlobalShortcut)
        XCTAssertFalse(KeyCombo(keyCode: kVK_ANSI_V, modifiers: []).isValidGlobalShortcut)
        XCTAssertFalse(KeyCombo(keyCode: kVK_ANSI_V, modifiers: [.shift]).isValidGlobalShortcut, "одного ⇧ недостаточно")
        XCTAssertTrue(KeyCombo(keyCode: kVK_F5, modifiers: []).isValidGlobalShortcut)
    }

    func testModifierRoundTrip() {
        let combo = KeyCombo(keyCode: kVK_Tab, modifiers: [.command, .option, .control, .shift])
        XCTAssertEqual(combo.modifierFlags, [.command, .option, .control, .shift])
    }

    func testCodable() throws {
        let data = try JSONEncoder().encode(KeyCombo.clipboardPanelDefault)
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: data), .clipboardPanelDefault)
    }
}

@MainActor
final class ShortcutManagerTests: XCTestCase {
    func testConflictBetweenModulesIsDetected() {
        let manager = ShortcutManager()
        let combo = KeyCombo(keyCode: kVK_ANSI_K, modifiers: [.control, .option])
        manager.update(ShortcutID("a.first"), title: "Первое", combo: combo, active: false) {}
        manager.update(ShortcutID("b.second"), title: "Второе", combo: combo, active: false) {}

        XCTAssertEqual(manager.status(for: ShortcutID("a.first")), .inactive)
        XCTAssertEqual(manager.status(for: ShortcutID("b.second")), .conflict("Первое"))
        XCTAssertEqual(manager.conflictingTitle(for: combo, excluding: ShortcutID("b.second")), "Первое")
    }

    func testConflictResolvesAfterReassignment() {
        let manager = ShortcutManager()
        let combo = KeyCombo(keyCode: kVK_ANSI_K, modifiers: [.control, .option])
        manager.update(ShortcutID("a"), title: "A", combo: combo, active: false) {}
        manager.update(ShortcutID("b"), title: "B", combo: combo, active: false) {}
        manager.update(ShortcutID("b"), title: "B", combo: KeyCombo(keyCode: kVK_ANSI_J, modifiers: [.control, .option]), active: false) {}
        XCTAssertEqual(manager.status(for: ShortcutID("b")), .inactive)
    }

    func testSystemReservedAndInvalid() {
        let manager = ShortcutManager()
        manager.update(ShortcutID("sys"), title: "S", combo: KeyCombo(keyCode: kVK_Tab, modifiers: [.command]), active: true) {}
        manager.update(ShortcutID("bad"), title: "B", combo: KeyCombo(keyCode: kVK_ANSI_A, modifiers: []), active: true) {}
        manager.update(ShortcutID("none"), title: "N", combo: nil, active: true) {}

        guard case .systemReserved = manager.status(for: ShortcutID("sys")) else { return XCTFail("⌘⇥ должен считаться системным") }
        XCTAssertEqual(manager.status(for: ShortcutID("bad")), .invalid)
        XCTAssertEqual(manager.status(for: ShortcutID("none")), .notSet)
    }

    func testRegisterAndUnregister() {
        let manager = ShortcutManager()
        let id = ShortcutID("test.register")
        // Редкое сочетание, чтобы не пересечься с чем-то в системе.
        let combo = KeyCombo(keyCode: kVK_F19, modifiers: [.control, .option, .command, .shift])
        manager.update(id, title: "T", combo: combo, active: true) {}
        XCTAssertEqual(manager.status(for: id), .registered)
        // Повторное объявление того же сочетания не создаёт новую регистрацию.
        manager.update(id, title: "T", combo: combo, active: true) {}
        XCTAssertEqual(manager.status(for: id), .registered)
        manager.deactivate(id)
        XCTAssertEqual(manager.status(for: id), .inactive)
    }
}
