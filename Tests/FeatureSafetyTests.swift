import AppKit
import ApplicationServices
import Foundation

@main struct FeatureSafetyTests {
    @MainActor static func main() throws {
        var assertions = 0
        func check(_ condition:@autoclosure ()->Bool,_ name:String) { assertions += 1; if !condition() { fatalError(name) } }
        let old = try JSONDecoder().decode(Config.self,from:Data(#"{"hotkey":"right-command","vocabulary":["Sona"],"cleanupEnabled":false}"#.utf8))
        check(!old.autoAddToDictionary && old.snippets.isEmpty,"backward defaults")
        let retired = try JSONDecoder().decode(Config.self,from:Data(#"{"hotkey":"right-option","commandHotkey":"right-option","assistant":{"timeoutMs":-1},"sound":"sona-blend","ai":{"provider":"codex"}}"#.utf8))
        check(retired.hotkey == "right-option" && retired.validationError() == nil,"retired conflicting shortcut and invalid assistant preferences cannot block dictation")
        check(retired.sound == "sona-blend" && retired.ai.provider == "codex" && retired.ai.model == "economy","dictation sound and economy preferences retained")
        let legacyPath = try JSONDecoder().decode(Config.self,from:Data(#"{"claudePath":"/custom/bin/claude"}"#.utf8))
        check(legacyPath.claudePath == "/custom/bin/claude" && legacyPath.ai.executable == nil,"legacy path retained for shared bridge interpretation")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sona-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let url = folder.appendingPathComponent("config.json")
        try Data(#"{"future":{"retain":true},"vocabulary":["Old"]}"#.utf8).write(to:url)
        var config = old; config.snippets = [.init(trigger:"my signature",expansion:"  Regards,\nSona\n")]
        check(config.save(to:url) == nil,"valid atomic save")
        let saved = try Data(contentsOf:url)
        let dictionary = try JSONSerialization.jsonObject(with:saved) as! [String:Any]
        check(dictionary["future"] != nil,"unknown setting preserved")
        let retiredJSON = Data(#"{"commandHotkey":42,"assistant":["malformed legacy preference"],"future":{"retain":true},"hotkey":"right-option","ai":{"provider":"codex"},"sound":"sona-blend"}"#.utf8)
        try retiredJSON.write(to:url)
        let retiredConfig = try JSONDecoder().decode(Config.self,from:retiredJSON)
        check(retiredConfig.save(to:url) == nil,"malformed retired fields do not block saving dictation settings")
        let retiredSaved = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        check(retiredSaved["commandHotkey"] == nil && retiredSaved["assistant"] == nil,"retired activation fields removed from saved config")
        check(retiredSaved["future"] != nil,"retired field cleanup preserves unknown settings")
        let reloaded = try JSONDecoder().decode(Config.self,from:Data(contentsOf:url))
        check(reloaded.hotkey == "right-option" && reloaded.ai.provider == "codex" && reloaded.sound == "sona-blend","retired cleanup preserves chosen dictation shortcut provider and sound")
        let beforeInvalid = try Data(contentsOf:url)
        config.hotkey = "invalid-key"
        check(config.save(to:url) != nil && (try! Data(contentsOf:url)) == beforeInvalid,"invalid dictation shortcut leaves file identical")
        config.hotkey = old.hotkey; config.snippets.append(config.snippets[0])
        check(config.save(to:url) != nil,"duplicate snippet rejected")
        check(!Snippet(trigger:"x",expansion:" \n ").isValid,"blank expansion rejected")
        config.snippets = []
        let malformed = Data(#"{"hotkey":"f8","ai":{"provider":"codex"},"snippets":"invalid"}"#.utf8)
        try malformed.write(to:url)
        check(config.save(to:url) != nil && (try! Data(contentsOf:url)) == malformed,"malformed known setting cannot overwrite valid preferences")
        try Data(#"{"ai":{"provider":"codex","futurePolicy":"retain"}}"#.utf8).write(to:url)
        check(config.save(to:url) == nil,"valid old config accepts new app keys")
        let withAI = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        check((withAI["ai"] as? [String:Any])?["futurePolicy"] as? String == "retain","unknown nested AI setting retained")
        check(Snippet(trigger:"team",expansion:"👩‍💻 Team").isValid,"ZWJ expansion remains valid")
        try FileManager.default.removeItem(at:url); try FileManager.default.removeItem(at:folder)

        var scope = CorrectionScope(text:"Hello Jon.",now:0)
        check(scope.noteSelection(NSRange(location:6,length:3),count:10,now:1),"selected word is owned")
        scope.key(.text,now:1.1)
        let short = scope.permittedRead(count:8,caret:NSRange(location:7,length:0),now:1.2)
        check(short == NSRange(location:0,length:8),"deletion maps moving owned end before read")
        check(scope.accept("Hello J.",range:short!,caret:NSRange(location:7,length:0),now:1.2),"verified replacement receipt")
        scope.key(.text,now:1.3)
        let next = scope.permittedRead(count:9,caret:NSRange(location:8,length:0),now:1.4)!
        check(scope.accept("Hello Ja.",range:next,caret:NSRange(location:8,length:0),now:1.4),"typing continues inside owned correction")
        scope.key(.text,now:1.5)
        let last = scope.permittedRead(count:10,caret:NSRange(location:9,length:0),now:1.6)!
        check(scope.accept("Hello Jan.",range:last,caret:NSRange(location:9,length:0),now:1.6),"final word edit")
        check(scope.candidate() == "Jan","only corrected word offered")
        var append = CorrectionScope(text:"Hello",now:0); append.key(.text,now:1)
        check(!append.alive && append.permittedRead(count:6,caret:NSRange(location:6,length:0),now:1.1) == nil,"trailing append ends ownership before read")
        var external = CorrectionScope(text:"Hello",now:0)
        check(external.permittedRead(count:5,caret:NSRange(location:5,length:0),now:1) == nil,"external change has no edit witness")
        var expired = CorrectionScope(text:"Hello",now:0)
        check(!expired.noteSelection(NSRange(location:0,length:2),count:5,now:15),"strict deadline")
        var delayed = CorrectionScope(text:"Hello Jon.",now:0)
        _ = delayed.noteSelection(NSRange(location:6,length:3),count:10,now:14.8)
        delayed.key(.text,now:14.9)
        check(delayed.permittedRead(count:8,caret:NSRange(location:7,length:0),now:15) == nil,"deadline gates a pending edit before content read")
        var lateReceipt = CorrectionScope(text:"Hello Jon.",now:0)
        _ = lateReceipt.noteSelection(NSRange(location:6,length:3),count:10,now:14.8)
        lateReceipt.key(.text,now:14.9)
        check(!lateReceipt.accept("Hello J.",range:NSRange(location:0,length:8),caret:NSRange(location:7,length:0),now:15),"AX receipt crossing deadline is discarded")
        var escape = CorrectionScope(text:"Hello",now:0)
        check(!escape.noteSelection(NSRange(location:4,length:2),count:5,now:1),"out of range selection stops before reading")
        var paste = CorrectionScope(text:"Hello",now:0); paste.key(.unsafe,now:1)
        check(!paste.alive,"paste or command shortcuts stop observation")
        var bad = CorrectionScope(text:"Hello Jon.",now:0)
        _ = bad.noteSelection(NSRange(location:6,length:3),count:10,now:1); bad.key(.text,now:1.1)
        check(!bad.accept("Xello J.",range:NSRange(location:0,length:8),caret:NSRange(location:7,length:0),now:1.2),"outside edit cannot be accepted")
        let activity = FocusedElement.Activity(session:UUID(),revision:1)
        let field = AXUIElementCreateApplication(1)
        let target = FocusedElement.Target(pid:1,element:field,window:nil,document:"test",windowTitle:nil,activity:activity)
        let original = SelectionContents(range:NSRange(location:2,length:4),text:"Café",characterCount:9)
        let selection = SelectionSnapshot(target:target,contents:original)
        check(selection.validates(current:target,contents:original),"same complete selection validates")
        check(!selection.validates(current:target,contents:.init(range:NSRange(location:3,length:4),text:"Café",characterCount:9)),"same field moved selection refuses")
        check(!selection.validates(current:target,contents:.init(range:original.range,text:"Cafe",characterCount:9)),"same field equal-length edit refuses")
        var changed = target; changed.activity = .init(session:activity.session,revision:2)
        check(!selection.validates(current:changed,contents:original),"input revision invalidates exact field")
        changed = target; changed.blocked = true
        check(!selection.validates(current:changed,contents:original),"secure field rejects command")
        let disabled = CorrectionObservation()
        let synthetic = FocusedElement.Target(pid:1,element:AXUIElementCreateApplication(1),window:nil,document:nil,windowTitle:nil)
        disabled.verifyAndBegin(text:"Hello",before:.init(target:synthetic,contents:.init(range:NSRange(location:0,length:0),text:"",characterCount:0)))
        check(disabled.contentReads == 0 && disabled.observerStarts == 0,"off has zero AX reads and observers")
        print("PASS: \(assertions) feature configuration, moving range, edit ownership, fake-clock and off-state checks")
    }
}
