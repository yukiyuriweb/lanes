import AppKit

/// A window and its tabs, as saved for the next launch.
struct SavedWindow: Codable {
    var frame: String?   // NSStringFromRect
    var repos: [String]  // tab order
    var selected = 0     // index into repos
}

/// Where to put a newly opened repository.
enum Placement {
    case newTab           // a new tab in the front window, or a new window if there's none
    case window(NSRect?)  // a new window, optionally with this frame
    case tab(of: NSWindow)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []
    private var receivedOpenRequest = false
    /// Saved windows not restored yet at launch; saved again along with the open ones.
    private var pendingWindows: [SavedWindow] = []
    /// Set once quitting starts, so the windows AppKit closes afterwards don't change the saved state.
    private var isTerminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An empty window to show while the first repository opens, or if the open panel is cancelled.
        newController().showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Defer so a folder passed via `open -a Lanes <dir>` arrives first.
        DispatchQueue.main.async { [self] in
            guard !receivedOpenRequest else { return }
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            let windows = args.isEmpty ? savedWindows() : [SavedWindow(frame: nil, repos: Array(args))]
            let existing = windows.compactMap { w -> SavedWindow? in
                var w = w
                let selected = w.repos.indices.contains(w.selected) ? w.repos[w.selected] : nil
                w.repos = w.repos.filter { FileManager.default.fileExists(atPath: $0) }
                w.selected = selected.flatMap(w.repos.firstIndex(of:)) ?? 0
                return w.repos.isEmpty ? nil : w
            }
            if existing.isEmpty {
                openDocument(nil)
            } else {
                restore(existing)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedOpenRequest = true
        urls.forEach { open($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isTerminating && (controllers.contains { $0.repo != nil } || !pendingWindows.isEmpty) { saveWindows() }
        isTerminating = true
        return .terminateNow
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a Git repository folder")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Shows the repository containing `url`: in the window that already shows it, or as a new tab.
    private func open(_ url: URL) {
        Task.detached {
            let top = Git.topLevel(of: url)
            await MainActor.run { _ = self.show(url, topLevel: top, placement: .newTab) }
        }
    }

    /// Reopens saved windows one repository after another, back to front, so each window gets its tabs
    /// in order and the front window ends up in front.
    private func restore(_ windows: [SavedWindow]) {
        pendingWindows = windows
        Task { @MainActor in
            for saved in windows.reversed() {
                var anchor: NSWindow?
                var opened: [Int: NSWindow] = [:]
                for (i, path) in saved.repos.enumerated() {
                    let url = URL(fileURLWithPath: path)
                    // Git stays off the main thread; placing the window happens back here.
                    let top = await Task.detached { Git.topLevel(of: url) }.value
                    // If the user closed what has been restored of this window so far, don't bring it back.
                    if !opened.isEmpty {
                        let open = opened.sorted { $0.key < $1.key }.map(\.value).filter { w in controllers.contains { $0.window === w } }
                        guard let first = open.first else { break }
                        anchor = first
                    }
                    let placement: Placement = anchor.map { .tab(of: $0) } ?? .window(saved.frame.map(NSRectFromString))
                    if let window = show(url, topLevel: top, placement: placement) {
                        anchor = anchor ?? window
                        opened[i] = window
                    }
                }
                opened[saved.selected]?.makeKeyAndOrderFront(nil)
                // Done with this window: from now on it's saved from the open windows instead.
                pendingWindows.removeLast()
                saveWindows()
            }
        }
    }

    /// Returns the repository's window, or nil if `url` isn't in a repository.
    @discardableResult
    private func show(_ url: URL, topLevel top: URL?, placement: Placement) -> NSWindow? {
        guard let top else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Not a Git repository")
            alert.informativeText = url.path
            alert.runModal()
            return nil
        }
        if let existing = controllers.first(where: { $0.repo?.standardizedFileURL == top.standardizedFileURL }) {
            existing.showWindow(nil)
            return existing.window
        }
        let empty = controllers.first { $0.repo == nil }
        let controller = empty ?? newController()
        if let window = controller.window {
            switch placement {
            case .newTab:
                // Join the front window, or the most recently used one, unless this is the empty startup window.
                let front = (NSApp.keyWindow?.windowController as? MainWindowController).flatMap { $0 === controller ? nil : $0.window }
                    ?? controllers.last { $0 !== controller && $0.window?.isVisible == true }?.window
                if empty == nil, let front { (front.tabGroup?.windows.last ?? front).addTabbedWindow(window, ordered: .above) }
            case .window(let frame):
                if let frame { window.setFrame(frame, display: false) }
            case .tab(let anchor):
                if anchor !== window { (anchor.tabGroup?.windows.last ?? anchor).addTabbedWindow(window, ordered: .above) }
            }
        }
        controller.show(top)
        controller.showWindow(nil)
        NSDocumentController.shared.noteNewRecentDocumentURL(top)
        saveWindows()
        return controller.window
    }

    private func newController() -> MainWindowController {
        let controller = MainWindowController()
        if let key = controllers.last(where: { $0.window?.isVisible == true })?.window, let window = controller.window {
            window.setFrame(key.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        }
        controllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, !self.isTerminating else { return }
            // Closing the last window quits the app; save before it goes, so it's restored as it was.
            if !self.controllers.contains(where: { $0 !== controller && $0.repo != nil }) {
                if controller?.repo != nil { self.saveWindows() }
                self.controllers.removeAll { $0 === controller }
                return
            }
            self.controllers.removeAll { $0 === controller }
            self.saveWindows()
        }
        return controller
    }

    private func savedWindows() -> [SavedWindow] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "openWindows"),
           let windows = try? JSONDecoder().decode([SavedWindow].self, from: data) { return windows }
        // Earlier versions saved only the repositories.
        let repos = defaults.stringArray(forKey: "openRepos") ?? defaults.string(forKey: "lastRepo").map { [$0] } ?? []
        return repos.isEmpty ? [] : [SavedWindow(frame: nil, repos: repos)]
    }

    /// Remembers the open windows, front to back, with their frames and tabs, so the next launch restores them.
    private func saveWindows() {
        let mine = controllers.compactMap(\.window)
        var groups: [[NSWindow]] = []
        for window in mine where !groups.contains(where: { $0.contains(window) }) {
            groups.append((window.tabGroup?.windows ?? [window]).filter { mine.contains($0) })
        }
        // Front to back by the z-order of each group's visible tab; minimized or hidden ones go last.
        let order = NSApp.orderedWindows
        func rank(_ g: [NSWindow]) -> Int {
            let visible = g.first?.tabGroup?.selectedWindow ?? g.first
            return visible.flatMap { order.firstIndex(of: $0) } ?? Int.max
        }
        let open = groups.sorted { rank($0) < rank($1) }.compactMap { g -> SavedWindow? in
            let tabs = g.filter { ($0.windowController as? MainWindowController)?.repo != nil }
            guard !tabs.isEmpty else { return nil }
            let selected = g.first?.tabGroup?.selectedWindow ?? g.first
            return SavedWindow(frame: NSStringFromRect((selected ?? tabs[0]).frame),
                               repos: tabs.map { ($0.windowController as! MainWindowController).repo!.path },
                               selected: selected.flatMap(tabs.firstIndex(of:)) ?? 0)
        }
        // Windows still waiting to be restored are the frontmost ones (restoring goes back to front).
        guard let data = try? JSONEncoder().encode(pendingWindows + open) else { return }
        UserDefaults.standard.set(data, forKey: "openWindows")
    }

    @objc func bigger(_ sender: Any?) { TextSize.step(1) }
    @objc func smaller(_ sender: Any?) { TextSize.step(-1) }
    @objc func actualSize(_ sender: Any?) { TextSize.reset() }

    @objc func selectTab(_ sender: NSMenuItem) {
        guard let window = NSApp.keyWindow else { return }
        let tabs = window.tabGroup?.windows ?? [window]
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        if index < tabs.count { tabs[index].makeKeyAndOrderFront(nil) }
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Lanes"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Lanes"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Quit Lanes"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: String(localized: "File"))
        fileMenu.addItem(withTitle: String(localized: "Open…"), action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: String(localized: "Reload"), action: #selector(MainWindowController.reload(_:)), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: String(localized: "Find…"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = editMenu

        let viewMenu = NSMenu(title: String(localized: "View"))
        viewMenu.addItem(withTitle: String(localized: "Actual Size"), action: #selector(actualSize(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: String(localized: "Bigger"), action: #selector(bigger(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: String(localized: "Smaller"), action: #selector(smaller(_:)), keyEquivalent: "-")
        // ⌘+ needs Shift on many layouts; ⌘= works too, as in most Mac apps.
        let equals = viewMenu.addItem(withTitle: String(localized: "Bigger"), action: #selector(bigger(_:)), keyEquivalent: "=")
        equals.isHidden = true
        equals.allowsKeyEquivalentWhenHidden = true
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = viewMenu

        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        // Browser-style tab shortcuts: ⌘1–⌘8 select that tab, ⌘9 the last one. Hidden to keep the menu short.
        for n in 1...9 {
            let item = windowMenu.addItem(withTitle: n == 9 ? "Select Last Tab" : "Select Tab \(n)",
                                          action: #selector(selectTab(_:)), keyEquivalent: "\(n)")
            item.tag = n
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
