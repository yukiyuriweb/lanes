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
        panel.message = "Git リポジトリのフォルダを選択"
        if panel.runModal() == .OK, let url = panel.url { controller.open(url) }
    }

    @objc func reload(_ sender: Any?) { controller.reload() }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Lanes について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Lanes を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Lanes を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(withTitle: "開く…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "再読み込み", action: #selector(reload(_:)), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "ウインドウを閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "検索…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)
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
