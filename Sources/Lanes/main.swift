import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController!
    private var receivedOpenRequest = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        controller = MainWindowController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Defer so a folder passed via `open -a Lanes <dir>` arrives first.
        DispatchQueue.main.async { [self] in
            guard !receivedOpenRequest else { return }
            let arg = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
            if let path = arg ?? UserDefaults.standard.string(forKey: "lastRepo"),
               FileManager.default.fileExists(atPath: path) {
                controller.open(URL(fileURLWithPath: path))
            } else {
                openDocument(nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        receivedOpenRequest = true
        controller.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a Git repository folder")
        if panel.runModal() == .OK, let url = panel.url { controller.open(url) }
    }

    @objc func reload(_ sender: Any?) { controller.reload() }

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
        fileMenu.addItem(withTitle: String(localized: "Reload"), action: #selector(reload(_:)), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: String(localized: "Find…"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = editMenu

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
