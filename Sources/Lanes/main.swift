import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []
    private var receivedOpenRequest = false

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
            let paths = (args.isEmpty ? savedRepos() : args).filter { FileManager.default.fileExists(atPath: $0) }
            if paths.isEmpty {
                openDocument(nil)
            } else {
                paths.forEach { open(URL(fileURLWithPath: $0)) }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedOpenRequest = true
        urls.forEach(open)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a Git repository folder")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Shows the repository containing `url`: in the window that already shows it,
    /// in an empty window, or in a new one.
    private func open(_ url: URL) {
        Task.detached {
            let top = Git.topLevel(of: url)
            await MainActor.run { self.show(url, topLevel: top) }
        }
    }

    private func show(_ url: URL, topLevel top: URL?) {
        guard let top else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Not a Git repository")
            alert.informativeText = url.path
            alert.runModal()
            return
        }
        if let existing = controllers.first(where: { $0.repo?.standardizedFileURL == top.standardizedFileURL }) {
            existing.showWindow(nil)
            return
        }
        let controller = controllers.first { $0.repo == nil } ?? newController()
        controller.show(top)
        controller.showWindow(nil)
        NSDocumentController.shared.noteNewRecentDocumentURL(top)
        saveRepos()
    }

    private func newController() -> MainWindowController {
        let controller = MainWindowController()
        if let key = controllers.last(where: { $0.window?.isVisible == true })?.window, let window = controller.window {
            window.setFrame(key.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        }
        controllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            self.controllers.removeAll { $0 === controller }
            // Closing the last window quits the app; keep its repository for the next launch.
            if self.controllers.contains(where: { $0.repo != nil }) { self.saveRepos() }
        }
        return controller
    }

    private func savedRepos() -> [String] {
        let defaults = UserDefaults.standard
        return defaults.stringArray(forKey: "openRepos") ?? defaults.string(forKey: "lastRepo").map { [$0] } ?? []
    }

    /// Remembers the open repositories, in the order they were opened, so the next launch restores them.
    private func saveRepos() {
        UserDefaults.standard.set(controllers.compactMap { $0.repo?.path }, forKey: "openRepos")
    }

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
