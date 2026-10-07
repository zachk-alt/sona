import CoreGraphics

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
    func testDefaultDictationRouter() {
        let router = HotKeyRouter(binding:HotKeyBinding("right-command")!)
        let command = CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue | 0x10)
        func event(_ type:CGEventType,_ code:Int64,_ flags:CGEventFlags,_ time:Double) -> HotKeyRoute {
            router.route(type:type,code:code,flags:flags,time:time)
        }
        XCTAssertEqual(event(.flagsChanged,54,command,0).events,[.begin])
        XCTAssertEqual(event(.flagsChanged,54,[],0.1).events,[.latch])
        XCTAssertTrue(event(.flagsChanged,54,command,1).events.isEmpty)
        XCTAssertEqual(event(.flagsChanged,54,[],1.1).events,[.unlatch])
        XCTAssertEqual(event(.flagsChanged,54,command,2).events,[.begin])
        XCTAssertEqual(event(.flagsChanged,54,[],2.8).events,[.commit])
        router.reset()
        XCTAssertEqual(event(.flagsChanged,54,command,3).events,[.begin])
        router.reset()
        XCTAssertTrue(event(.flagsChanged,54,[],3.1).events.isEmpty)
    }
    func testRetiredSettingsCannotReactivateOption() throws {
        for extra in [
            #""commandHotkey":"right-option","assistant":{"provider":"codex","model":"chosen","effort":"high"}"#,
            #""commandHotkey":"right-command","assistant":{"timeoutMs":-1}"#,
            #""commandHotkey":42,"assistant":["invalid legacy value"]"#
        ] {
            let json = #"{"hotkey":"right-command","sound":"sona-blend","ai":{"provider":"claude","model":"economy"},"vocabulary":["Sona"],"# + extra + "}"
            let config = try JSONDecoder().decode(Config.self,from:Data(json.utf8))
            XCTAssertNil(config.validationError())
            XCTAssertEqual(config.hotkey,"right-command")
            XCTAssertEqual(config.sound,"sona-blend")
            XCTAssertEqual(config.ai.provider,"claude")
            XCTAssertEqual(config.ai.model,"economy")
            XCTAssertEqual(config.vocabulary,["Sona"])
            let router = HotKeyRouter(binding:HotKeyBinding(config.hotkey)!)
            for side:Int64 in [58,61] {
                let option = CGEventFlags(rawValue:CGEventFlags.maskAlternate.rawValue | (side == 58 ? 0x20 : 0x40))
                for duration in [0.1,1.0] {
                    let down = router.route(type:.flagsChanged,code:side,flags:option,time:0)
                    let up = router.route(type:.flagsChanged,code:side,flags:[],time:duration)
                    XCTAssertFalse(down.consumed); XCTAssertFalse(up.consumed)
                    XCTAssertTrue(down.events.isEmpty); XCTAssertTrue(up.events.isEmpty)
                }
            }
        }
    }
    func testOptionCharactersAndOrdinaryChordsPassThrough() {
        let router = HotKeyRouter(binding:HotKeyBinding("right-command")!)
        for side:Int64 in [58,61] {
            let option = CGEventFlags(rawValue:CGEventFlags.maskAlternate.rawValue | (side == 58 ? 0x20 : 0x40))
            for (type,code,flags,time):(CGEventType,Int64,CGEventFlags,Double) in [
                (.flagsChanged,side,option,0),(.keyDown,0,option,0.1),
                (.keyUp,0,option,0.2),(.flagsChanged,side,[],0.3)
            ] {
                let result = router.route(type:type,code:code,flags:flags,time:time)
                XCTAssertFalse(result.consumed); XCTAssertTrue(result.events.isEmpty)
            }
        }
        let command = CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue | 0x10)
        XCTAssertEqual(router.route(type:.flagsChanged,code:54,flags:command,time:1).events,[.begin])
        let copy = router.route(type:.keyDown,code:8,flags:command,time:1.05)
        XCTAssertFalse(copy.consumed); XCTAssertEqual(copy.events,[.discard])
        XCTAssertTrue(router.route(type:.keyUp,code:8,flags:command,time:1.1).events.isEmpty)
        XCTAssertTrue(router.route(type:.flagsChanged,code:54,flags:[],time:1.2).events.isEmpty)
        // A normal chord during latched dictation must not stop the recording.
        _ = router.route(type:.flagsChanged,code:54,flags:command,time:2)
        XCTAssertEqual(router.route(type:.flagsChanged,code:54,flags:[],time:2.1).events,[.latch])
        _ = router.route(type:.flagsChanged,code:54,flags:command,time:3)
        XCTAssertTrue(router.route(type:.keyDown,code:8,flags:command,time:3.05).events.isEmpty)
        _ = router.route(type:.keyUp,code:8,flags:command,time:3.1)
        XCTAssertTrue(router.route(type:.flagsChanged,code:54,flags:[],time:3.2).events.isEmpty)
        _ = router.route(type:.flagsChanged,code:54,flags:command,time:4)
        XCTAssertEqual(router.route(type:.flagsChanged,code:54,flags:[],time:4.1).events,[.unlatch])
    }
    func testOnlyChosenOptionSideCanBeTheDictationKey() {
        let left = HotKeyBinding("left-option")!, right = HotKeyBinding("right-option")!
        XCTAssertEqual(left.keyCode,58); XCTAssertEqual(right.keyCode,61)
        XCTAssertEqual(left.deviceFlag,0x20); XCTAssertEqual(right.deviceFlag,0x40)
        for selected in [left,right] {
            let router = HotKeyRouter(binding:selected)
            let other = selected == left ? right : left
            let otherFlags = CGEventFlags(rawValue:CGEventFlags.maskAlternate.rawValue | other.deviceFlag!)
            XCTAssertTrue(router.route(type:.flagsChanged,code:other.keyCode,flags:otherFlags,time:0).events.isEmpty)
            XCTAssertTrue(router.route(type:.flagsChanged,code:other.keyCode,flags:[],time:0.1).events.isEmpty)
            let ownFlags = CGEventFlags(rawValue:CGEventFlags.maskAlternate.rawValue | selected.deviceFlag!)
            XCTAssertEqual(router.route(type:.flagsChanged,code:selected.keyCode,flags:ownFlags,time:1).events,[.begin])
            XCTAssertEqual(router.route(type:.flagsChanged,code:selected.keyCode,flags:[],time:1.8).events,[.commit])
            router.reset()
            _ = router.route(type:.flagsChanged,code:selected.keyCode,flags:ownFlags,time:2)
            let both = CGEventFlags(rawValue:ownFlags.rawValue | other.deviceFlag!)
            XCTAssertEqual(router.route(type:.flagsChanged,code:other.keyCode,flags:both,time:2.1).events,[.discard])
            XCTAssertTrue(router.route(type:.flagsChanged,code:other.keyCode,flags:ownFlags,time:2.2).events.isEmpty)
            XCTAssertTrue(router.route(type:.flagsChanged,code:selected.keyCode,flags:[],time:2.3).events.isEmpty)
        }
    }
    func testChosenChordAndRepeatedKeys() {
        let router = HotKeyRouter(binding:HotKeyBinding("option+space")!)
        let repeatOnly = router.route(type:.keyDown,code:49,flags:.maskAlternate,repeatKey:true,time:0)
        XCTAssertFalse(repeatOnly.consumed); XCTAssertTrue(repeatOnly.events.isEmpty)
        XCTAssertFalse(router.route(type:.keyUp,code:49,flags:.maskAlternate,time:0.1).consumed)
        let down = router.route(type:.keyDown,code:49,flags:.maskAlternate,time:1)
        XCTAssertTrue(down.consumed); XCTAssertEqual(down.events,[.begin])
        let repeatDown = router.route(type:.keyDown,code:49,flags:.maskAlternate,repeatKey:true,time:1.1)
        XCTAssertTrue(repeatDown.consumed); XCTAssertTrue(repeatDown.events.isEmpty)
        let up = router.route(type:.keyUp,code:49,flags:.maskAlternate,time:1.8)
        XCTAssertTrue(up.consumed); XCTAssertEqual(up.events,[.commit])
        router.reset()
        let plainSpace = router.route(type:.keyDown,code:49,flags:[],time:2)
        XCTAssertFalse(plainSpace.consumed); XCTAssertTrue(plainSpace.events.isEmpty)
        XCTAssertFalse(router.route(type:.keyUp,code:49,flags:[],time:2.1).consumed)
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
        tests.testDefaultDictationRouter()
        try tests.testRetiredSettingsCannotReactivateOption()
        tests.testOptionCharactersAndOrdinaryChordsPassThrough()
        tests.testOnlyChosenOptionSideCanBeTheDictationKey()
        tests.testChosenChordAndRepeatedKeys()
        print("13 dictation-only hotkey, passthrough and configuration behavior groups passed.")
    }
}
