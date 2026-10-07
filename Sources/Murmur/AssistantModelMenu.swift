import AppKit

/// Metadata-only model choices. Nothing changes until the person picks an item.
final class AssistantModelMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Option model")
    var onChoose: ((AssistantChoice) -> Void)?
    var onRefresh: (() -> Void)?
    private var test: (NSMenu, Int, () -> Bool, (Bool) -> Void)?
    private var testTracked = false
    private var testObserver: NSObjectProtocol?
    override init() { super.init(); setCatalog(nil) }
    func menuWillOpen(_ menu: NSMenu) { onRefresh?() }

    func setCatalog(_ catalog: BridgeCatalog?) {
        menu.removeAllItems()
        guard let catalog else {
            let item = NSMenuItem(title: "Loading model choices…", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); return
        }
        guard !catalog.providers.isEmpty else {
            let item = NSMenuItem(title: "No supported Assistant provider", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); return
        }
        for provider in catalog.providers {
            let row = NSMenuItem(title: provider.label, action: nil, keyEquivalent: "")
            row.state = catalog.selected?.provider == provider.id ? .on : .off
            row.isEnabled = provider.available; row.toolTip = provider.reason
            if provider.available {
                let models = NSMenu(title: provider.label)
                models.addItem(choice("Use default model", .init(provider: provider.id, model: "default", effort: "default"), selected: false))
                if !provider.models.isEmpty { models.addItem(.separator()) }
                for model in provider.models {
                    let entry = NSMenuItem(title: model.label, action: nil, keyEquivalent: "")
                    let selected = catalog.selected?.provider == provider.id && catalog.selected?.model == model.id
                    entry.state = selected ? .on : .off
                    let efforts = NSMenu(title: model.label)
                    for effort in model.efforts.isEmpty ? ["default"] : model.efforts {
                        let title = effort == "default" ? "Default" : effort.prefix(1).uppercased() + effort.dropFirst()
                        efforts.addItem(choice(title, .init(provider: provider.id, model: model.id, effort: effort), selected: selected && catalog.selected?.effort == effort))
                    }
                    entry.submenu = efforts; models.addItem(entry)
                }
                row.submenu = models
            }
            menu.addItem(row)
        }
    }
    private func choice(_ title: String, _ choice: AssistantChoice, selected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = choice; item.state = selected ? .on : .off
        return item
    }
    @objc private func pick(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? AssistantChoice else { return }; onChoose?(choice)
    }

    /// Explicit owned-editor test only. Exercise the real leaf menu and its
    /// existing action, without touching configuration or invoking a provider.
    func exerciseOwnedMenu(relativeTo view: NSView?, verify: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        func leaf(_ menu: NSMenu) -> NSMenu? {
            if menu.items.contains(where: { $0.representedObject is AssistantChoice }) && menu.numberOfItems >= 2 && menu.items.allSatisfy({ $0.submenu == nil }) { return menu }
            for item in menu.items { if let child = item.submenu, let found = leaf(child) { return found } }
            return nil
        }
        guard let view, let leaf = leaf(menu), leaf.numberOfItems >= 2 else { completion(false); return }
        test = (leaf, 1, verify, completion); testTracked = false
        testObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: leaf, queue: .main) { [weak self] _ in self?.testTracked = true }
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in self?.finishOwnedMenu() }
        RunLoop.main.add(timer, forMode: .common)
        leaf.popUp(positioning: leaf.item(at: 0), at: NSPoint(x: 0, y: -4), in: view)
    }
    private func finishOwnedMenu() {
        guard let test else { return }
        let stable = testTracked && test.2()
        test.0.cancelTrackingWithoutAnimation()
        test.0.performActionForItem(at: test.1)
        if let testObserver { NotificationCenter.default.removeObserver(testObserver) }
        testObserver = nil; self.test = nil
        test.3(stable && test.2())
    }
}
