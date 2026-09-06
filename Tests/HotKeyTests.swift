import Foundation
func XCTAssertEqual<T: Equatable>(_ a:T,_ b:T) { if a != b { fatalError("Expected \(a) == \(b)") } }
func XCTAssertNotEqual<T: Equatable>(_ a:T,_ b:T) { if a == b { fatalError("Expected distinct values") } }
func XCTAssertTrue(_ a:Bool) { if !a { fatalError("Expected true") } }
func XCTAssertFalse(_ a:Bool) { XCTAssertTrue(!a) }
func XCTAssertNil<T>(_ a:T?) { if a != nil { fatalError("Expected nil") } }

final class HotKeyTests {
    func testTapStartsAndSecondTapStops() {
        var events:[String] = []
        let gesture = HotKeyGesture { events.append(String(describing:$0)); return true }
        gesture.press(at:0); gesture.release(at:0.06)
        XCTAssertTrue(gesture.latched)
        gesture.press(at:2)
        XCTAssertEqual(events,["begin","latch"])
        gesture.release(at:2.08)
        XCTAssertEqual(events,["begin","latch","unlatch"])
        XCTAssertFalse(gesture.latched)
    }
    func testHeldShortcutIsDiscardedBeforeCommit() {
        var events:[String] = []
        let gesture = HotKeyGesture { events.append(String(describing:$0)); return true }
        gesture.press(at:0); gesture.release(at:1.5,otherKey:true)
        XCTAssertEqual(events,["begin","discard"])
    }
    func testShortcutDuringLatchedRecordingDoesNotLoseDictation() {
        var events:[String] = []
        let gesture = HotKeyGesture { events.append(String(describing:$0)); return true }
        gesture.press(at:0); gesture.release(at:0.05)
        gesture.press(at:1); gesture.release(at:1.1,otherKey:true)
        XCTAssertTrue(gesture.latched)
        XCTAssertEqual(events,["begin","latch"])
        gesture.press(at:2); gesture.release(at:2.1)
        XCTAssertEqual(events.last,"unlatch")
    }
    func testHoldAndRepeatedKeyDown() {
        var events:[String] = []
        let gesture = HotKeyGesture { events.append(String(describing:$0)); return true }
        gesture.press(at:0); gesture.press(at:0.02); gesture.press(at:0.3); gesture.release(at:1)
        XCTAssertEqual(events,["begin","commit"])
    }
    func testRefusedFocusCannotLatch() {
        var events:[String] = []
        let gesture = HotKeyGesture { events.append(String(describing:$0)); return false }
        gesture.press(at:0); gesture.release(at:0.06)
        XCTAssertEqual(events,["begin"]); XCTAssertFalse(gesture.latched)
    }
    func testHotkeySelectionDistinguishesSideAndModifiers() {
        let right = HotKeyBinding("right-command")!, left = HotKeyBinding("command")!
        XCTAssertNotEqual(right.keyCode,left.keyCode)
        let chord = HotKeyBinding("ctrl+alt+space")!
        XCTAssertEqual(chord.name,"control+option+space")
        XCTAssertTrue(chord.matches(flags:[.maskControl,.maskAlternate]))
        XCTAssertFalse(chord.matches(flags:[.maskControl,.maskAlternate,.maskShift]))
        XCTAssertNil(HotKeyBinding("control+control+a"))
        XCTAssertNil(HotKeyBinding("some unknown key"))
        XCTAssertNil(HotKeyBinding("option++space"))
    }
    func testLegacyConfigKeepsPreferencesAndDoesNotForceSetup() throws {
        let data = Data(#"{"vocabulary":["ExampleWord"],"cleanupEnabled":false}"#.utf8)
        let config = try JSONDecoder().decode(Config.self,from:data)
        XCTAssertEqual(config.vocabulary,["ExampleWord"])
        XCTAssertEqual(config.hotkey,"right-command")
        XCTAssertEqual(config.ai.model,"economy")
        XCTAssertTrue(config.setupComplete)
        XCTAssertFalse(config.cleanupEnabled)
    }
    func testNewPartialAIConfigPreservesEconomyDefaults() throws {
        let config = try JSONDecoder().decode(Config.self,from:Data(#"{"ai":{"provider":"codex"},"hotkey":"option+space"}"#.utf8))
        XCTAssertEqual(config.ai.provider,"codex")
        XCTAssertEqual(config.ai.model,"economy")
        XCTAssertEqual(config.hotkey,"option+space")
    }
}

@main struct RunHotKeyTests {
    static func main() throws {
        let tests = HotKeyTests()
        tests.testTapStartsAndSecondTapStops()
        tests.testHeldShortcutIsDiscardedBeforeCommit()
        tests.testShortcutDuringLatchedRecordingDoesNotLoseDictation()
        tests.testHoldAndRepeatedKeyDown()
        tests.testRefusedFocusCannotLatch()
        tests.testHotkeySelectionDistinguishesSideAndModifiers()
        try tests.testLegacyConfigKeepsPreferencesAndDoesNotForceSetup()
        try tests.testNewPartialAIConfigPreservesEconomyDefaults()
        print("8 hotkey and configuration behavior checks passed.")
    }
}
