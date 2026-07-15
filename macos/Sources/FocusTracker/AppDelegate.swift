import AppKit
import SwiftUI

private struct DatabaseCategoryRow: Decodable {
    let category: String
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config = Config.load()
    private let store = SessionStore()
    private let suggestions = Suggestions()
    private let dashboardNavigation = DashboardNavigation()
    private lazy var focusTimer = FocusTimerModel(defaultMinutes: config.sessionMinutes)
    private lazy var menuBarIcon = makeMenuBarIcon()
    private var dashWindow: NSWindow?
    private var databaseCategories: [String] = []
    private var categoriesLoading = true
    private var categoriesLoadFailed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        configureFocusTimer()
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateTitle()
        rebuildMenu()
        reloadDatabaseCategories()
        store.flushOutbox(config: config)
        if CommandLine.arguments.contains("--open-dashboard") {
            openOverview()
        } else {
            openTimer()
        }
    }

    // MARK: - Rendering

    private func installApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon

        let dockIcon = NSImageView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        dockIcon.image = icon
        dockIcon.imageScaling = .scaleProportionallyUpOrDown
        NSApp.dockTile.contentView = dockIcon
        NSApp.dockTile.display()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "FocusTracker")
        let quitItem = appMenu.addItem(withTitle: "Quit FocusTracker",
                                       action: #selector(NSApplication.terminate(_:)),
                                       keyEquivalent: "q")
        quitItem.target = NSApp
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if focusTimer.phase == .idle {
            button.title = ""
            button.image = menuBarIcon
            button.setAccessibilityLabel("FocusTracker")
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.title = timeString(focusTimer.remainingSeconds)
            button.imagePosition = .noImage
        }
    }

    private func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.shouldAntialias = true
            let center = NSPoint(x: rect.midX, y: rect.midY)

            func strokeArc(radius: CGFloat,
                           startAngle: CGFloat,
                           endAngle: CGFloat,
                           lineWidth: CGFloat,
                           color: NSColor) {
                let path = NSBezierPath()
                path.appendArc(withCenter: center,
                               radius: radius,
                               startAngle: startAngle,
                               endAngle: endAngle)
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                color.setStroke()
                path.stroke()
            }

            let templateInk = NSColor.white

            strokeArc(radius: 3.8, startAngle: 0, endAngle: 360,
                      lineWidth: 2.0, color: templateInk)
            strokeArc(radius: 7.0, startAngle: 100, endAngle: 205,
                      lineWidth: 2.5, color: templateInk)
            strokeArc(radius: 7.0, startAngle: -25, endAngle: 80,
                      lineWidth: 2.5, color: templateInk)
            strokeArc(radius: 7.0, startAngle: 220, endAngle: 320,
                      lineWidth: 2.5, color: templateInk)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(action("Timer", #selector(openTimer), symbol: "timer"))
        menu.addItem(action("Dashboard", #selector(openOverview), symbol: "chart.bar.xaxis"))
        menu.addItem(action("Sessions", #selector(openSessions), symbol: "calendar"))
        menu.addItem(.separator())

        if focusTimer.phase == .idle {
            menu.addItem(disabled("Start a session"))
            if categoriesLoading {
                menu.addItem(disabled("Loading categories…"))
            } else if categoriesLoadFailed {
                menu.addItem(disabled("Could not load database categories"))
            } else if databaseCategories.isEmpty {
                menu.addItem(disabled("No categories in database"))
            }
            for cat in databaseCategories {
                let item = NSMenuItem(title: cat,
                                      action: #selector(startTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = cat
                item.image = menuSymbol("play.fill")
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(action("Add category with session…", #selector(openSessions),
                                symbol: "plus.circle"))
            menu.addItem(action("Refresh categories", #selector(refreshCategories),
                                symbol: "arrow.clockwise"))
        } else {
            menu.addItem(disabled("\(focusTimer.category) — \(timeString(focusTimer.remainingSeconds)) left"))
            menu.addItem(.separator())
            if focusTimer.phase == .running {
                menu.addItem(action("Pause", #selector(pauseSession), symbol: "pause.fill"))
            } else {
                menu.addItem(action("Resume", #selector(resumeSession), symbol: "play.fill"))
            }
            menu.addItem(action("Restart", #selector(restartSession),
                                symbol: "arrow.counterclockwise"))
            menu.addItem(action("Stop & Save now", #selector(stopAndSave),
                                symbol: "stop.circle"))
            menu.addItem(action("Cancel (discard)", #selector(cancelSession),
                                symbol: "xmark.circle"))
        }

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), symbol: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ sel: Selector,
                        symbol: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = menuSymbol(symbol) }
        return item
    }

    private func menuSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    // MARK: - Session lifecycle

    private func configureFocusTimer() {
        focusTimer.onTick = { [weak self] in
            self?.updateTitle()
        }
        focusTimer.onStateChange = { [weak self] in
            self?.updateTitle()
            self?.rebuildMenu()
        }
        focusTimer.onComplete = { [weak self] completion in
            self?.saveTimerCompletion(completion)
        }
    }

    @objc private func startTapped(_ sender: NSMenuItem) {
        guard let cat = sender.representedObject as? String else { return }
        focusTimer.startFromMenu(category: cat)
    }

    @objc private func pauseSession() {
        focusTimer.pause()
    }

    @objc private func resumeSession() {
        focusTimer.startOrResume()
    }

    @objc private func restartSession() {
        focusTimer.restart()
    }

    @objc private func stopAndSave() {
        focusTimer.finishNow()
    }

    @objc private func cancelSession() {
        focusTimer.cancel()
    }

    private func saveTimerCompletion(_ completion: FocusTimerCompletion) {
        guard !completion.category.isEmpty else { return }
        if completion.reachedZero { NSSound.beep() }

        var sessionNames = completion.sessionNames
        var note = completion.note
        if completion.collectDetailsAfterTimer {
            let details = promptSessionDetails(category: completion.category)
            sessionNames = details.sessions
            note = details.note
        }

        suggestions.record(sessionNames, for: completion.category)
        let end = Date()
        let start = end.addingTimeInterval(-Double(completion.elapsedSeconds))
        let rec = SessionRecord(start: start, end: end, category: completion.category,
                                sessionNames: sessionNames, description: note)
        store.save(rec, config: config)
        dashboardNavigation.reloadToken = UUID()
        reloadDatabaseCategories()
    }

    // MARK: - Prompts

    /// Shows saved session names for the category plus an optional per-session note.
    private func promptSessionDetails(category: String) -> (sessions: [String], note: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(category) session done"
        alert.informativeText = "Choose what you worked on, then add an optional note for extra detail."
        alert.addButton(withTitle: "Save")

        let options = suggestions.list(for: category)
        let width: CGFloat = 320

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let sessionsLabel = NSTextField(labelWithString: "Sessions")
        sessionsLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(sessionsLabel)

        var checks: [NSButton] = []
        for opt in options {
            let cb = NSButton(checkboxWithTitle: opt, target: nil, action: nil)
            cb.state = .off
            checks.append(cb)
            stack.addArrangedSubview(cb)
        }

        let newField = NSTextField()
        newField.placeholderString = options.isEmpty
            ? "e.g. Claude Youtube Channel"
            : "add sessions (comma-separated)…"
        newField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(newField)
        newField.widthAnchor.constraint(equalToConstant: width).isActive = true

        let noteLabel = NSTextField(labelWithString: "Note")
        noteLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(noteLabel)

        let noteField = NSTextField()
        noteField.placeholderString = "optional extra detail…"
        noteField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(noteField)
        noteField.widthAnchor.constraint(equalToConstant: width).isActive = true

        stack.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: max(width, fit.width), height: fit.height)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = newField

        alert.runModal()

        var result: [String] = []
        for cb in checks where cb.state == .on { result.append(cb.title) }
        let typed = newField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for t in typed where !result.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            result.append(t)
        }
        return (result, noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func openTimer() {
        showDashboard(section: .timer)
    }

    @objc private func openOverview() {
        showDashboard(section: .overview)
    }

    @objc private func openSessions() {
        showDashboard(section: .sessions)
    }

    @objc private func openSettings() {
        showDashboard(section: dashboardNavigation.section)
        dashboardNavigation.settingsRequestToken = UUID()
    }

    private func showDashboard(section: DashboardSection) {
        dashboardNavigation.section = section
        NSApp.setActivationPolicy(.regular)
        if let w = dashWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: DashboardView(
            config: config,
            navigation: dashboardNavigation,
            focusTimer: focusTimer,
            onConfigChanged: { [weak self] savedConfig in
                self?.applyConfig(savedConfig)
            }
        ) { [weak self] in
            self?.reloadDatabaseCategories()
        })
        let w = NSWindow(contentViewController: host)
        w.title = "FocusTracker"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 860, height: 700))
        w.isReleasedWhenClosed = false
        w.center()
        dashWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        guard let window = dashWindow else { return false }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func applyConfig(_ savedConfig: Config) {
        config = savedConfig
        config.save()
        focusTimer.setDurationMinutes(config.sessionMinutes)
        reloadDatabaseCategories()
        if config.storageBackend == .firebase {
            store.flushOutbox(config: config)
        }
    }

    @objc private func refreshCategories() {
        reloadDatabaseCategories()
    }

    private func reloadDatabaseCategories() {
        categoriesLoading = true
        categoriesLoadFailed = false
        rebuildMenu()
        let activeConfig = config
        Task { [weak self] in
            let categories = await Self.fetchDatabaseCategories(config: activeConfig)
            await MainActor.run {
                guard let self else { return }
                self.categoriesLoading = false
                self.categoriesLoadFailed = categories == nil
                self.databaseCategories = categories ?? []
                self.rebuildMenu()
            }
        }
    }

    private static func fetchDatabaseCategories(config: Config) async -> [String]? {
        if config.storageBackend == .local {
            let categories = Set(SessionStore.loadLocalRows().compactMap { row -> String? in
                let value = row.category.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            })
            return categories.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
        guard !config.supabaseUrl.isEmpty, !config.apiKey.isEmpty,
              var components = URLComponents(string: config.supabaseUrl) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "select", value: "category"),
            URLQueryItem(name: "order", value: "category.asc")
        ]
        guard let url = components.url else { return nil }

        do {
            let pageSize = 1_000
            var offset = 0
            var categories = Set<String>()
            while true {
                var request = URLRequest(url: url)
                request.setValue(config.apiKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("items", forHTTPHeaderField: "Range-Unit")
                request.setValue("\(offset)-\(offset + pageSize - 1)", forHTTPHeaderField: "Range")

                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(code) else { return nil }
                let page = try JSONDecoder().decode([DatabaseCategoryRow].self, from: data)
                for row in page {
                    let category = row.category.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !category.isEmpty { categories.insert(category) }
                }
                if page.count < pageSize { break }
                offset += pageSize
            }
            return categories.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        } catch {
            return nil
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
