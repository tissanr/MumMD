// MDView – minimaler Markdown-Viewer für macOS (AppKit + WKWebView).
// Gebaut mit build.sh (nur swiftc, kein Xcode-Projekt).

import AppKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Hilfsfunktionen

/// MDVIEW_DEBUG=1 gibt Render-Ereignisse auf stderr aus (für Tests).
let debugEnabled = ProcessInfo.processInfo.environment["MDVIEW_DEBUG"] != nil
func debugLog(_ message: String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

func isOpenableTextFile(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let ext = url.pathExtension.lowercased()
    if markdownExtensions.contains(ext) { return true }
    return UTType(filenameExtension: ext)?.conforms(to: .plainText) ?? false
}

func readText(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .windowsCP1252)
        ?? String(decoding: data, as: UTF8.self)
}

// MARK: - Dateiüberwachung

/// Überwacht eine Datei per kqueue (DispatchSource). Atomare Speichervorgänge
/// (Datei wird ersetzt, umbenannt oder gelöscht) setzen den Watcher auf den Pfad neu auf.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var needsRearm = false
    private var retryCount = 0

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    deinit { stop() }

    var isWatching: Bool { source != nil }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    /// Öffnet die Datei neu und beginnt mit der Überwachung. Liefert false, wenn sie (noch) fehlt.
    @discardableResult
    func arm() -> Bool {
        source?.cancel()
        source = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        retryCount = 0
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .delete, .rename, .revoke],
            queue: .main)
        src.setEventHandler { [weak self, unowned src] in
            guard let self else { return }
            let events = src.data
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                // Der beobachtete Inode ist weg (z. B. `mv tmp datei`): neu aufsetzen.
                src.cancel()
                if self.source === src { self.source = nil }
                self.needsRearm = true
            }
            self.schedule(after: 0.1)
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        return true
    }

    /// Entprellt: Mehrere Ereignisse innerhalb von ~100 ms führen zu genau einem Reload.
    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func fire() {
        if needsRearm || source == nil {
            guard arm() else {
                // Datei fehlt gerade (mitten im atomaren Speichern oder gelöscht): später erneut versuchen.
                needsRearm = true
                retryCount += 1
                schedule(after: retryCount < 25 ? 0.2 : 2.0)
                return
            }
            needsRearm = false
        }
        onChange()
    }
}

// MARK: - WebView mit Drag & Drop

final class MarkdownWebView: WKWebView {
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(isOpenableTextFile)
    }

    // Eigene Behandlung statt WebKit-Standard (der würde die Datei im WebView laden).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return false }
        AppDelegate.shared.open(files)
        return true
    }
}

// MARK: - Dokumentfenster

final class DocumentWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    let fileURL: URL
    private let webView: MarkdownWebView
    private let templateURL = Bundle.main.url(forResource: "template", withExtension: "html")!
    private var watcher: FileWatcher?
    private var pageReady = false
    private var shown = false

    init(fileURL: URL, cascadeFrom previous: NSWindow?) {
        self.fileURL = fileURL

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        webView = MarkdownWebView(frame: .zero, configuration: config)
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false

        let size = NSSize(width: 900, height: 1000)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 200)
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.backgroundColor = .textBackgroundColor
        window.contentView = webView
        window.isRestorable = false
        if let saved = UserDefaults.standard.string(forKey: "windowSize") {
            window.setContentSize(NSSizeFromString(saved))
        }
        if let previous {
            window.setFrameTopLeftPoint(previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else {
            window.center()
        }

        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self

        // Zugriff auf "/" statt nur auf den Dokumentordner: Das Template liegt im App-Bundle,
        // relative Pfade werden per <base href="Dokumentordner/"> aufgelöst. Netzwerk ist per CSP gesperrt.
        webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        watcher = FileWatcher(path: fileURL.path) { [weak self] in self?.render() }

        // Fenster erst nach dem ersten Rendern zeigen (kein weißes Aufblitzen) – mit Fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showWindow() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func showWindow() {
        guard !shown, let window else { return }
        shown = true
        window.makeKeyAndOrderFront(nil)
    }

    func render() {
        guard pageReady else { return }
        guard let text = readText(fileURL) else {
            debugLog("unreadable: \(fileURL.path)")
            return
        }
        let base = fileURL.deletingLastPathComponent().absoluteString
        webView.callAsyncJavaScript(
            "return render(md, base, fontSize)",
            arguments: ["md": text, "base": base, "fontSize": AppDelegate.shared.fontSize],
            in: nil, in: .page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info): debugLog("rendered \(self.fileURL.lastPathComponent): \(info)")
            case .failure(let error): debugLog("render error: \(error)")
            }
            self.showWindow()
            if debugEnabled { self.debugAfterRender() }
        }
    }

    /// Testhilfen: MDVIEW_DEBUG_SCROLL=<px> scrollt nach dem ersten Rendern,
    /// MDVIEW_DEBUG_SNAPSHOT=<ordner> speichert nach jedem Rendern ein PNG.
    private var renderCount = 0
    private func debugAfterRender() {
        renderCount += 1
        let env = ProcessInfo.processInfo.environment
        if renderCount == 1, let y = env["MDVIEW_DEBUG_SCROLL"] {
            webView.evaluateJavaScript("window.scrollTo(0, \(Int(y) ?? 0))")
        }
        guard let dir = env["MDVIEW_DEBUG_SNAPSHOT"] else { return }
        let n = renderCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.webView.evaluateJavaScript("Math.round(window.scrollY)") { y, _ in debugLog("snapshot \(n) scrollY=\(y ?? "?")") }
            self?.webView.takeSnapshot(with: nil) { image, _ in
                guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("render-\(n).png"))
            }
        }
    }

    func applyFontSize(_ size: Double) {
        webView.evaluateJavaScript("setFontSize(\(size))")
    }

    @objc func reloadDocument(_ sender: Any?) {
        if !(watcher?.isWatching ?? false) { watcher?.arm() }
        render()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        AppDelegate.shared.windowClosed(self)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let view = window?.contentView else { return }
        UserDefaults.standard.set(NSStringFromSize(view.frame.size), forKey: "windowSize")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        render()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }

        // Nur das eigene Template darf im WebView geladen werden.
        if url.isFileURL, url.path == templateURL.path, action.navigationType != .linkActivated {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        guard action.navigationType == .linkActivated else { return }

        if url.isFileURL {
            if isOpenableTextFile(url), FileManager.default.fileExists(atPath: url.path) {
                AppDelegate.shared.open([url])          // verlinkte .md-Datei in MDView öffnen
            } else {
                NSWorkspace.shared.open(url)            // andere Dateien/Ordner mit Standard-App
            }
        } else {
            NSWorkspace.shared.open(url)                // http(s), mailto, … im Standardbrowser
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private var controllers: [DocumentWindowController] = []
    private var openedSomething = false

    private(set) var fontSize: Double = {
        let v = UserDefaults.standard.double(forKey: "fontSize")
        return v > 0 ? v : 16
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        // Testhilfe: MDVIEW_DEBUG_APPEARANCE=dark|light erzwingt ein Erscheinungsbild.
        switch ProcessInfo.processInfo.environment["MDVIEW_DEBUG_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Direkter Aufruf des Binaries mit Dateipfaden (z. B. zum Testen).
        let args = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if !args.isEmpty { open(args) }

        DispatchQueue.main.async { [self] in
            if !openedSomething { showOpenPanel(nil) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && controllers.isEmpty { showOpenPanel(nil) }
        return true
    }

    // Nicht AppKit entscheiden lassen: Das schließende Öffnen-Fenster wäre sonst das „letzte Fenster“,
    // während das neue Dokumentfenster noch unsichtbar aufs erste Rendern wartet – die App würde beendet.
    // Stattdessen beenden, wenn das letzte Dokument geschlossen wird (windowClosed / showOpenPanel).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Dokumente

    func open(_ urls: [URL]) {
        for url in urls {
            openedSomething = true
            let url = url.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = controllers.first(where: { $0.fileURL == url }) {
                existing.showWindow()
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }
            let controller = DocumentWindowController(fileURL: url, cascadeFrom: controllers.last?.window)
            controllers.append(controller)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    func windowClosed(_ controller: DocumentWindowController) {
        controllers.removeAll { $0 === controller }
        if controllers.isEmpty { NSApp.terminate(nil) }
    }

    @objc func showOpenPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            open(panel.urls)
        } else if controllers.isEmpty {
            NSApp.terminate(nil)  // abgebrochen und kein Dokument offen: wie bisher beenden
        }
    }

    // MARK: Schriftgröße (gilt für alle Fenster, wird gespeichert)

    private func setFontSize(_ size: Double) {
        fontSize = min(max(size, 9), 40)
        UserDefaults.standard.set(fontSize, forKey: "fontSize")
        controllers.forEach { $0.applyFontSize(fontSize) }
    }
    @objc func increaseFontSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func decreaseFontSize(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc func resetFontSize(_ sender: Any?) { setFontSize(16) }

    // MARK: Menü

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }

        _ = submenu("MDView", [
            item("Über MDView", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("MDView ausblenden", #selector(NSApplication.hide(_:)), "h"),
            item("Andere ausblenden", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Alle einblenden", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("MDView beenden", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("Ablage", [
            item("Öffnen …", #selector(showOpenPanel(_:)), "o"),
            .separator(),
            item("Neu laden", #selector(DocumentWindowController.reloadDocument(_:)), "r"),
            .separator(),
            item("Schließen", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = submenu("Bearbeiten", [
            item("Kopieren", #selector(NSText.copy(_:)), "c"),
            item("Alles auswählen", #selector(NSText.selectAll(_:)), "a"),
        ])
        let biggerAlt = item("Größer", #selector(increaseFontSize(_:)), "=")
        biggerAlt.isHidden = true
        biggerAlt.allowsKeyEquivalentWhenHidden = true
        _ = submenu("Darstellung", [
            item("Größer", #selector(increaseFontSize(_:)), "+"),
            biggerAlt,
            item("Kleiner", #selector(decreaseFontSize(_:)), "-"),
            item("Originalgröße", #selector(resetFontSize(_:)), "0"),
            .separator(),
            item("Vollbild", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let windowMenu = submenu("Fenster", [
            item("Im Dock ablegen", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoomen", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Alle nach vorne bringen", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenu
        return main
    }
}

// MARK: - Start

let app = NSApplication.shared
app.delegate = AppDelegate.shared
app.setActivationPolicy(.regular)
app.run()
