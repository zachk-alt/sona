import AppKit

/// An explicitly opened settings window. All edits stay in a draft until Save.
@MainActor
final class TextSettingsController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var words: [String]
    private var phrases: [Snippet]
    private let saveDraft: ([String], [Snippet], Bool) -> String?
    private let suggest: (String, @escaping ([Snippet]?, String?) -> Void) -> Void
    private let closed: () -> Void
    private let assistEnabled: Bool
    private let wordsTable = NSTableView()
    private let phrasesTable = NSTableView()
    private let tabs = NSTabView()
    private let status = NSTextField(wrappingLabelWithString: "Changes are saved only when you click Save.")
    private let learning = NSButton(checkboxWithTitle: "Suggest spellings when I correct my dictation", target: nil, action: nil)
    private var assistButton: NSButton?
    private var saveButton: NSButton?
    private var busy = false
    private var finished = false

    init(vocabulary: [String], snippets: [Snippet], autoAddToDictionary: Bool,
         assistEnabled: Bool,
         onSave: @escaping ([String], [Snippet], Bool) -> String?,
         onSuggest: @escaping (String, @escaping ([Snippet]?, String?) -> Void) -> Void,
         onClose: @escaping () -> Void) {
        words = vocabulary
        phrases = snippets
        saveDraft = onSave
        suggest = onSuggest
        closed = onClose
        self.assistEnabled = assistEnabled
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 610),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sona words and saved phrases"
        window.minSize = NSSize(width: 640, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        learning.state = autoAddToDictionary ? .on : .off
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(showAssist: Bool = false) {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if showAssist && assistEnabled {
            tabs.selectTabViewItem(at: 1)
            DispatchQueue.main.async { [weak self] in self?.askForSuggestions() }
        }
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Make Sona sound like you")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Teach Sona names and spellings, or expand a spoken phrase into text you use often.")
        intro.textColor = .secondaryLabelColor

        let wordsItem = NSTabViewItem(identifier: "words")
        wordsItem.label = "Words"
        wordsItem.view = listPage(table: wordsTable,
            explanation: "Words help the optional AI cleanup recognize names and specialized spellings.",
            columns: [("word", "Word", 580)],
            add: #selector(addWord), edit: #selector(editWord), remove: #selector(removeWord), assist: false)
        let phrasesItem = NSTabViewItem(identifier: "phrases")
        phrasesItem.label = "Saved phrases"
        phrasesItem.view = listPage(table: phrasesTable,
            explanation: "Say a trigger such as “my scheduling link” to insert its saved text. Matching ignores capitalization and works without AI.",
            columns: [("trigger", "When I say", 215), ("expansion", "Insert this text", 375)],
            add: #selector(addPhrase), edit: #selector(editPhrase), remove: #selector(removePhrase), assist: assistEnabled)
        tabs.addTabViewItem(wordsItem)
        tabs.addTabViewItem(phrasesItem)

        let scope = NSTextField(wrappingLabelWithString: "Optional: for up to 15 seconds after an insertion, watch only the text Sona inserted in supported fields. Ask before saving a spelling. Stop if focus changes or the edited range cannot be verified.")
        scope.font = .systemFont(ofSize: 11)
        scope.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.setAccessibilityIdentifier("sona.textSettings.status")

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEdits))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveEdits))
        save.keyEquivalent = "\r"
        saveButton = save
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 12
        for view in [title, intro, tabs, learning, scope, status, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            intro.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            intro.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            tabs.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 18),
            tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            learning.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            learning.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 18),
            scope.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 20),
            scope.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            scope.topAnchor.constraint(equalTo: learning.bottomAnchor, constant: 5),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            status.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 16),
            buttons.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    private func listPage(table: NSTableView, explanation: String,
                          columns: [(String, String, CGFloat)], add: Selector,
                          edit: Selector, remove: Selector, assist: Bool) -> NSView {
        let page = NSView()
        let description = NSTextField(wrappingLabelWithString: explanation)
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: 12)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 29
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = edit
        table.setAccessibilityLabel(table === wordsTable ? "Vocabulary words" : "Saved phrases")
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 110
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let actions = NSStackView(views: [
            NSButton(title: "Add", target: self, action: add),
            NSButton(title: "Edit", target: self, action: edit),
            NSButton(title: "Remove", target: self, action: remove)
        ])
        actions.spacing = 9
        if assist {
            let button = NSButton(title: "Suggest saved phrases…", target: self, action: #selector(askForSuggestions))
            actions.addArrangedSubview(button)
            assistButton = button
        }
        for view in [description, scroll, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(view)
        }
        NSLayoutConstraint.activate([
            description.topAnchor.constraint(equalTo: page.topAnchor, constant: 14),
            description.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 14),
            description.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: description.trailingAnchor),
            actions.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            actions.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            actions.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -12)
        ])
        return page
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === wordsTable ? words.count : phrases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === wordsTable {
            guard words.indices.contains(row) else { return nil }
            text = words[row]
        } else {
            guard phrases.indices.contains(row) else { return nil }
            text = tableColumn?.identifier.rawValue == "trigger" ? phrases[row].trigger : phrases[row].expansion
        }
        let cell = NSTextField(labelWithString: text.replacingOccurrences(of: "\n", with: " ↵ "))
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = text
        return cell
    }

    @objc private func addWord() { wordEditor(at: nil) }
    @objc private func editWord() {
        guard words.indices.contains(wordsTable.selectedRow) else { return }
        wordEditor(at: wordsTable.selectedRow)
    }
    @objc private func removeWord() {
        guard !busy, words.indices.contains(wordsTable.selectedRow) else { return }
        words.remove(at: wordsTable.selectedRow)
        wordsTable.reloadData()
        draftChanged()
    }

    private func wordEditor(at index: Int?) {
        guard !busy, let window else { return }
        let field = NSTextField(string: index.map { words[$0] } ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 430, height: 26)
        field.placeholderString = "Name or spelling"
        field.setAccessibilityLabel("Vocabulary word")
        let alert = NSAlert()
        alert.messageText = index == nil ? "Add a word" : "Edit a word"
        alert.informativeText = "Use the spelling you want Sona to recognize."
        alert.accessoryView = field
        alert.addButton(withTitle: "Keep in draft")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.finished, response == .alertFirstButtonReturn else { return }
            let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.utf16.count <= 100,
                  !word.unicodeScalars.contains(where: Self.control) else {
                self.showStatus("Use 1 to 100 characters without line breaks or control characters.", error: true)
                return
            }
            guard !self.words.enumerated().contains(where: { $0.offset != index && $0.element.caseInsensitiveCompare(word) == .orderedSame }) else {
                self.showStatus("That word is already in your list.", error: true)
                return
            }
            if let index { self.words[index] = word } else { self.words.append(word) }
            self.wordsTable.reloadData()
            self.draftChanged()
        }
    }

    @objc private func addPhrase() { phraseEditor(at: nil) }
    @objc private func editPhrase() {
        guard phrases.indices.contains(phrasesTable.selectedRow) else { return }
        phraseEditor(at: phrasesTable.selectedRow)
    }
    @objc private func removePhrase() {
        guard !busy, phrases.indices.contains(phrasesTable.selectedRow) else { return }
        phrases.remove(at: phrasesTable.selectedRow)
        phrasesTable.reloadData()
        draftChanged()
    }

    private func phraseEditor(at index: Int?, proposal: Snippet? = nil,
                              reviewTitle: String? = nil, completion: (() -> Void)? = nil) {
        guard !busy, !finished, let window else { return }
        let existing = proposal ?? index.map { phrases[$0] }
        let reviewing = completion != nil
        let trigger = NSTextField(string: existing?.trigger ?? "")
        trigger.placeholderString = "For example: my scheduling link"
        trigger.setAccessibilityLabel("Spoken trigger")
        let (editor, scroll) = Self.textEditor(text: existing?.expansion ?? "", label: "Expansion text")
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "When I say"), trigger,
            NSTextField(labelWithString: "Insert this text"), scroll
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: 235)
        trigger.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let alert = NSAlert()
        alert.messageText = reviewTitle ?? (index == nil ? "Add a saved phrase" : "Edit a saved phrase")
        alert.informativeText = !reviewing
            ? "The trigger matches a whole phrase, regardless of capitalization. Longer matching triggers take priority."
            : "Review both fields and correct any details. Nothing is saved until you keep the entry and click Save in Settings."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Keep in draft")
        alert.addButton(withTitle: reviewing ? "Skip" : "Cancel")
        if reviewing { alert.addButton(withTitle: "Stop review") }
        alert.window.initialFirstResponder = trigger
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.finished else { return }
            if response == .alertFirstButtonReturn {
                let phrase = Snippet(trigger: trigger.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), expansion: editor.string)
                if let error = self.phraseError(phrase, replacing: index) {
                    self.showStatus(error, error: true)
                    // Keep invalid input available for correction instead of losing the draft.
                    DispatchQueue.main.async {
                        self.phraseEditor(at: index, proposal: phrase,
                                          reviewTitle: error, completion: completion)
                    }
                    return
                }
                if let index { self.phrases[index] = phrase } else { self.phrases.append(phrase) }
                self.phrasesTable.reloadData()
                self.draftChanged()
            }
            if response != .alertThirdButtonReturn {
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    private func phraseError(_ phrase: Snippet, replacing index: Int?) -> String? {
        if phrase.trigger.isEmpty || phrase.trigger.unicodeScalars.count > 120 ||
            phrase.trigger.unicodeScalars.contains(where: { Self.control($0) || $0.value == 0x2028 || $0.value == 0x2029 }) {
            return "Use a trigger of 1 to 120 characters, without line breaks."
        }
        if phrase.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phrase.expansion.utf8.count > 8192 ||
            phrase.expansion.unicodeScalars.contains(where: { Self.control($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) {
            return "Enter expansion text up to 8 KB. Line breaks and tabs are allowed."
        }
        if phrases.enumerated().contains(where: { $0.offset != index && $0.element.trigger.caseInsensitiveCompare(phrase.trigger) == .orderedSame }) {
            return "That trigger is already used. Choose a different phrase."
        }
        if index == nil && phrases.count >= 128 { return "You can save up to 128 phrases." }
        let bytes = phrases.enumerated().filter { $0.offset != index }.reduce(0) { $0 + $1.element.expansion.utf8.count }
        if bytes + phrase.expansion.utf8.count > 65536 { return "Saved expansions must total 64 KB or less." }
        return nil
    }

    private static func control(_ scalar: UnicodeScalar) -> Bool {
        scalar.value <= 0x1f || (0x7f...0x9f).contains(scalar.value)
    }

    @objc private func askForSuggestions() {
        guard assistEnabled, !busy, !finished, let window else { return }
        tabs.selectTabViewItem(at: 1)
        let (editor, scroll) = Self.textEditor(text: "", label: "Information to use for suggested phrases")
        scroll.frame = NSRect(x: 0, y: 0, width: 480, height: 190)
        let alert = NSAlert()
        alert.messageText = "Suggest saved phrases"
        alert.informativeText = "Paste the details you want your configured AI to turn into saved phrases, such as your scheduling link or email signature. Sona does not read your past chats or search your files. Review every suggestion before saving it."
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Suggest")
        alert.addButton(withTitle: "Enter manually")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = editor
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.finished else { return }
            if response == .alertSecondButtonReturn {
                DispatchQueue.main.async { self.phraseEditor(at: nil) }
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            let context = editor.string
            guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.showStatus("Enter a saved phrase manually, or supply details for a suggestion.")
                DispatchQueue.main.async { self.phraseEditor(at: nil) }
                return
            }
            self.setBusy(true)
            self.showStatus("Asking your configured AI for suggestions…")
            self.suggest(context) { [weak self] proposals, error in
                DispatchQueue.main.async {
                    guard let self, !self.finished else { return }
                    self.setBusy(false)
                    guard let proposals, !proposals.isEmpty else {
                        self.showStatus(error ?? "No useful suggestions came back. You can add a phrase manually.", error: error != nil)
                        self.phraseEditor(at: nil)
                        return
                    }
                    self.showStatus("Review each suggestion. Keep only details you know are correct.")
                    self.review(proposals, at: 0)
                }
            }
        }
    }

    private func review(_ proposals: [Snippet], at index: Int) {
        guard !finished, proposals.indices.contains(index) else { return }
        phraseEditor(at: nil, proposal: proposals[index],
                     reviewTitle: "Suggested phrase \(index + 1) of \(proposals.count)") { [weak self] in
            self?.review(proposals, at: index + 1)
        }
    }

    private static func textEditor(text: String, label: String) -> (NSTextView, NSScrollView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel(label)
        editor.string = text
        scroll.documentView = editor
        return (editor, scroll)
    }

    private func setBusy(_ value: Bool) {
        busy = value
        assistButton?.isEnabled = !value
        saveButton?.isEnabled = !value
    }

    private func draftChanged() { showStatus("Draft updated. Click Save to apply your changes.") }
    private func showStatus(_ text: String, error: Bool = false) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func saveEdits() {
        guard !busy, !finished else { return }
        if let error = saveDraft(words, phrases, learning.state == .on) {
            showStatus(error, error: true)
            return
        }
        close()
    }

    @objc private func cancelEdits() { close() }
    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        closed()
    }
}
