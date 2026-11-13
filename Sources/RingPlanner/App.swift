import AppKit
import SwiftUI
import Carbon
import Combine
import RingCore

@MainActor enum AppActions {
    static var capture: () -> Void = {}
    static var captureNote: () -> Void = {}
    static var recordMeeting: () -> Void = {}
    static var reviewCapture: (String) -> Void = { _ in }
    static var open: () -> Void = {}
    static var enterQuadrantFullScreen: () -> Void = {}
    static var leaveQuadrantFullScreen: () -> Void = {}
    static var prepareMeetingCapture: () -> Void = {}
}

@main struct Launcher {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let store = PlannerStore(demo: CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--library-demo") || CommandLine.arguments.contains("--inbox-demo") || (Bundle.main.object(forInfoDictionaryKey: "OneRingIsolatedDemo") as? Bool == true))
    private var window: NSWindow!
    private var captureWindow: NSPanel?
    private var statusItem: NSStatusItem!
    private var eyeStatusItem: NSStatusItem!
    private let eyePopover = NSPopover()
    private var terminating = false
    private let popover = NSPopover()
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var keyMonitor: Any?
    private var updates: AnyCancellable?
    private var meetingStatusUpdates: AnyCancellable?
    private var quadrantOwnsFullScreen = false
    private var fullScreenTransition = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if store.isDemo && CommandLine.arguments.contains("--demo-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if store.isDemo && CommandLine.arguments.contains("--demo-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        AppActions.capture = { [weak self] in self?.openCapture() }
        AppActions.captureNote = { [weak self] in self?.openCapture(destination: .note) }
        AppActions.recordMeeting = { [weak self] in self?.recordMeetingAction() }
        AppActions.reviewCapture = { [weak self] text in
            guard let self else { return }
            guard self.store.taskCapture.preparing == 0 else { return }; self.captureWindow?.close()
            self.showMain(); self.store.prepareCapture(text)
        }
        AppActions.open = { [weak self] in self?.showMain() }
        AppActions.prepareMeetingCapture = { [weak self] in self?.captureWindow?.close() }
        AppActions.enterQuadrantFullScreen = { [weak self] in self?.enterQuadrantFullScreen() }
        AppActions.leaveQuadrantFullScreen = { [weak self] in self?.leaveQuadrantFullScreen() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "The One Ring Planner"
        window.minSize = NSSize(width: 1180, height: 740)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = PlannerHostingView(rootView: MainView().environmentObject(store).environment(\.libraryDemoReduceMotion, store.isDemo && CommandLine.arguments.contains("--demo-reduce-motion")))
        window.center()
        setupMenuBar(); setupEyeMenu(); setupApplicationMenu(); registerShortcut()
        store.eventAlerts.openCalendar = { [weak self] day in
            guard let self else { return }
            self.store.selectedDay = day; self.store.page = .calendar; self.showMain()
        }
        store.startEventAlerts()
        updates = store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.updateStatus() }
        meetingStatusUpdates = Publishers.MergeMany([
            store.meetings.$activeID.map { _ in () }.eraseToAnyPublisher(),
            store.meetings.$finishing.map { _ in () }.eraseToAnyPublisher(),
            store.meetings.recorder.$phase.map { _ in () }.eraseToAnyPublisher(),
            store.meetings.recorder.$elapsed.map { _ in () }.eraseToAnyPublisher()
        ]).receive(on: DispatchQueue.main).sink { [weak self] in self?.updateStatus() }
        if !CommandLine.arguments.contains("--menu-bar-only") { showMain() }
        if CommandLine.arguments.contains("--meeting-models") { store.page = .meetings; store.meetings.showModels = true; store.meetings.discoverModels() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !terminating { terminating = true; Task { await store.telegram.stop(); await store.meetings.shutdown(); await store.library.prepareShutdown(); await store.taskCapture.flush(); await store.sharedInbox.shutdown(); sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        Task {
            await store.eventAlerts.refresh()
            await store.retryPendingPublications()
            guard !store.isDemo, store.calendarConnection.enabled, !store.calendarConnection.loading else { return }
            await store.calendarConnection.refresh(day: store.selectedDay, settings: store.settings)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        store.taskDrag = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            store.expandedQuadrant = nil; store.taskDrag = nil; quadrantOwnsFullScreen = false
        }
    }
    private func enterQuadrantFullScreen() {
        guard !window.styleMask.contains(.fullScreen), !fullScreenTransition else { return }
        quadrantOwnsFullScreen = true
        window.toggleFullScreen(nil)
    }
    private func leaveQuadrantFullScreen() {
        guard quadrantOwnsFullScreen, !fullScreenTransition, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }
    func windowWillEnterFullScreen(_ notification: Notification) { fullScreenTransition = true }
    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = false
        if quadrantOwnsFullScreen && store.expandedQuadrant == nil { leaveQuadrantFullScreen() }
    }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransition = false; quadrantOwnsFullScreen = false
        store.expandedQuadrant = nil; store.taskDrag = nil
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenTransition = false; quadrantOwnsFullScreen = false
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenTransition = false; quadrantOwnsFullScreen = false
    }
    func applicationDidResignActive(_ notification: Notification) { store.taskDrag = nil }
    private func setupApplicationMenu() {
        let mainMenu = NSMenu()
        let item = NSMenuItem(); let menu = NSMenu()
        menu.addItem(withTitle: "About The One Ring Planner", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quick Capture", action: #selector(captureAction), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Open Planner", action: #selector(openAction), keyEquivalent: "1").target = self
        menu.addItem(withTitle: "Record meeting…", action: #selector(recordMeetingAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open recordings · The Eye", action: #selector(openMeetings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Menu Bar Panel", action: #selector(togglePopover), keyEquivalent: "b").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide The One Ring Planner", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Quit The One Ring Planner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu; mainMenu.addItem(item)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; mainMenu.addItem(editItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu; NSApp.mainMenu = mainMenu
    }
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "TheOneRingPlanner"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = RingArtwork.menuBarImage ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "The One Ring Planner")
            button.image?.isTemplate = false; button.imagePosition = .imageLeading
            button.contentTintColor = nil
            button.target = self; button.action = #selector(togglePopover)
            button.setAccessibilityLabel("The One Ring Planner")
            button.toolTip = "The One Ring Planner · Control Option Space to capture"
        }
        popover.behavior = .semitransient
        popover.contentSize = NSSize(width: 350, height: 450)
        popover.contentViewController = NSHostingController(rootView: MenuBarView().environmentObject(store))
        updateStatus()
    }
    private func updateStatus() {
        let recording = store.meetings.activeID != nil && (store.meetings.recorder.phase == .recording || store.meetings.finishing)
        if recording && eyeStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = EyeArtwork.menuBarImage ?? NSImage(systemSymbolName: "eye", accessibilityDescription: "The Eye")
                button.imagePosition = .imageLeading
                button.target = self; button.action = #selector(toggleEyePopover)
            }
            eyeStatusItem = item
        } else if !recording, let item = eyeStatusItem {
            eyePopover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            eyeStatusItem = nil
        }
        if let eye = eyeStatusItem?.button {
            let elapsed = MeetingTaskImport.timestamp(store.meetings.recorder.elapsed)
            let title = " ● " + elapsed
            eye.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
            eye.toolTip = store.meetings.finishing ? "The Eye · Saving recording…" : "The Eye · Recording \(elapsed) · Click for Stop & save"
            eye.setAccessibilityLabel("The Eye · Meeting recording · \(elapsed)")
        }
        guard let button = statusItem?.button else { return }
        if let current = store.running {
            let remaining = max(0, Int(current.end.timeIntervalSince(Date()) / 60))
            button.title = " \(remaining)m"
            button.toolTip = "\(current.title) · \(remaining) minutes to planned boundary"
        } else { button.title = ""; button.toolTip = "The One Ring Planner · Quick capture ⌃⌥Space" }
    }
    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    @objc private func captureAction() { openCapture() }
    @objc private func openAction() { showMain() }
    private func setupEyeMenu() {
        eyePopover.behavior = .semitransient
        eyePopover.contentViewController = NSHostingController(rootView: EyeMenuView(meetings: store.meetings) { [weak self] in self?.openMeetings() })
    }
    @objc private func toggleEyePopover() {
        guard let button = eyeStatusItem?.button else { return }
        popover.performClose(nil)
        if eyePopover.isShown { eyePopover.performClose(nil) }
        else { eyePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); eyePopover.contentViewController?.view.window?.makeKey() }
    }
    @objc private func openMeetings() { eyePopover.performClose(nil); store.page = .meetings; showMain() }
    @objc private func recordMeetingAction() {
        if store.meetings.activeID != nil {
            guard !store.meetings.finishing else { return }
            popover.performClose(nil); eyePopover.performClose(nil)
            Task { await store.meetings.stopRecording() }
            return
        }
        openMeetings()
        // Opening setup is explicit; the microphone/call picker starts only after Start.
        if !store.meetings.busy { store.meetings.showSetup = true }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(recordMeetingAction) else { return true }
        menuItem.title = store.meetings.finishing ? "Saving recording…" : (store.meetings.activeID == nil ? "Record meeting…" : "Stop & save recording")
        return !store.meetings.finishing && (store.meetings.activeID != nil || !store.meetings.busy)
    }
    private func showMain() {
        popover.performClose(nil)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func openCapture(destination: CaptureDestination = .inbox) {
        store.captureDestination = destination
        if destination == .inbox && store.inboxDraft.isEmpty && store.taskCapture.files.isEmpty && store.taskCapture.preparing == 0 { store.taskCapture.rotateIdentity() }
        if destination == .note && !store.library.draft.hasContent && store.library.preparingAttachments == 0 { store.library.draft = LibraryDraft() }
        popover.performClose(nil)
        if let captureWindow, captureWindow.isVisible { captureWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 656, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Quick Capture · The One Ring Planner"; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CaptureView(close: { [weak self] in self?.captureWindow?.close() }).environmentObject(store))
        captureWindow = panel; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func registerShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] {
                if event.keyCode == UInt16(kVK_Space) {
                    if !event.isARepeat { Task { @MainActor in AppActions.capture() } }
                    return nil
                }

            }
            return event
        }
        if store.isDemo { return } // Demo shortcuts stay local to its window.
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let action = id.id
            Task { @MainActor in
                if action == 1 { AppActions.capture() }
            }
            return noErr
        }
        let result = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, nil, &handler)
        guard result == noErr else { store.showNotice("Global shortcut unavailable. Use the menu bar to capture."); return }
        let id = EventHotKeyID(signature: OSType(0x52494E47), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotkey)
        if status != noErr { store.showNotice("Control Option Space is already in use. Capture is in the menu bar.") }

    }
}

/// Let a drag begin on the first press, including when another app currently has focus.
private final class PlannerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct MenuBarView: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { RingMark(size: 38); VStack(alignment: .leading, spacing: 3) { Text("The One Ring Planner").font(Theme.display(18)); Text(store.dayTitle(store.now)).font(Theme.body(10)).foregroundStyle(Theme.secondary) }; Spacer() }
            DividerLine()
            SectionLabel(title: store.running == nil ? "Up next" : "In focus")
            if let b = store.running ?? store.nextBlock {
                Text(b.title).font(Theme.body(15, weight: .semibold))
                Text("\(store.time(b.start))–\(store.time(b.end)) · \(b.minutes) min").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                if b.state == .running {
                    HStack { Button("Complete") { store.selectedDay = store.now; store.complete(b); if b.routineID != nil { AppActions.open() } }.buttonStyle(GoldButton()); Button("Open block") { store.page = .today; AppActions.open() }.buttonStyle(QuietButton()) }
                } else { Button("Start block") { store.selectedDay = store.now; store.start(b) }.buttonStyle(GoldButton()) }
            } else {
                Text("A little room to begin.").font(Theme.display(22))
                Text("Capture a thought, or open your day to make a plan.").font(Theme.body(12)).foregroundStyle(Theme.secondary)
            }
            DividerLine()
            Button { AppActions.capture() } label: { HStack { Label("Quick capture", systemImage: "plus"); Spacer(); Text("⌃⌥Space").foregroundStyle(Theme.secondary) } }.buttonStyle(.plain).font(Theme.body(12))
            MenuBarMeetingControl(meetings: store.meetings)
            Button { AppActions.open() } label: { HStack { Text("Open planner"); Spacer(); Image(systemName: "arrow.up.right") } }.buttonStyle(.plain).font(Theme.body(12))
            HStack { Text(store.calendarConnection.status).font(Theme.body(9)).foregroundStyle(Theme.secondary); Spacer(); Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(Theme.body(10)).foregroundStyle(Theme.secondary) }
        }.padding(24).frame(width: 350).background(Theme.background).foregroundStyle(Theme.text)
    }
}

private struct MenuBarMeetingControl: View {
    @ObservedObject var meetings: MeetingStore
    private var active: Bool { meetings.activeID != nil }
    var body: some View {
        Button { AppActions.recordMeeting() } label: {
            HStack {
                Image(systemName: active ? "stop.circle.fill" : "record.circle").foregroundStyle(active ? Theme.calendarTask : Theme.gold)
                Text(meetings.finishing ? "Saving recording…" : (active ? "Stop & save recording" : "Record meeting…"))
                Spacer()
                if active { Text(MeetingTaskImport.timestamp(meetings.recorder.elapsed)).monospacedDigit().foregroundStyle(Theme.calendarTask) }
            }
        }.buttonStyle(.plain).font(Theme.body(12))
            .disabled(meetings.finishing || (!active && meetings.busy))
    }
}
