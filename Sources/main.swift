import AppKit
import SwiftUI
import ServiceManagement

final class MenuState: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var failure: UsageError? = .unavailable
    @Published var refreshing = false
    @Published var now = Date()
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var loginFailure = false
}

struct UsagePopover: View {
    @ObservedObject var state: MenuState
    let refresh: () -> Void
    let toggleLogin: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = state.snapshot {
                metric("5H", window: snapshot.fiveHour)
                Divider()
                metric("Weekly", window: snapshot.weekly)
                Divider()
                Text("마지막 업데이트: \(Self.updatedTime(snapshot.updatedAt))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text((state.failure ?? .unavailable).rawValue).font(.system(size: 13))
            }
            Divider()
            HStack {
                Button(state.refreshing ? "Refreshing…" : "Refresh", action: refresh)
                    .disabled(state.refreshing).keyboardShortcut("r")
                Spacer()
                Button("Quit", action: quit).keyboardShortcut("q")
            }
            Toggle("Launch at Login", isOn: Binding(
                get: { state.loginStatus == .enabled }, set: { _ in toggleLogin() }
            )).toggleStyle(.checkbox).font(.system(size: 12))
            if state.loginFailure || state.loginStatus == .requiresApproval {
                Button("로그인 항목 설정 열기…") { SMAppService.openSystemSettingsLoginItems() }
                    .font(.system(size: 11))
            }
        }
        .buttonStyle(.bordered)
        .padding(14)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func updatedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "MM.dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func metric(_ name: String, window: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(name) 남은 사용량").foregroundStyle(.secondary)
                Spacer()
                Text(window.map { "\($0.remainingPercent)%" } ?? "--")
                    .fontWeight(.semibold).monospacedDigit()
            }
            HStack {
                Text("리셋까지").foregroundStyle(.secondary)
                Spacer()
                Text(window.map { ResetTime.text(until: $0.resetsAt, now: state.now) } ?? "--")
                    .monospacedDigit()
            }
            if window == nil {
                Text("Rate limit unavailable").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }.font(.system(size: 12))
    }
}

final class MenuApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private let state = MenuState()
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private let audit: Audit
    private let server: AppServer
    private var observers: [NSObjectProtocol] = []
    static let refreshInterval: TimeInterval = 300

    override init() {
        let args = CommandLine.arguments
        let path = args.firstIndex(of: "--audit").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        audit = Audit(path: path)
        server = AppServer(audit: audit)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        item.button?.setAccessibilityLabel("Codex Weekly 남은 사용량")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        // The popover is created on first click. No main window and no SwiftUI work while idle.
        server.onDisconnect = { [weak self] in
            self?.state.snapshot = nil; self?.state.failure = .notRunning; self?.updateDisplay()
        }
        let start = Date()
        refreshTimer = Timer(fire: start.addingTimeInterval(Self.refreshInterval),
                             interval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh(reason: "automatic")
        }
        refreshTimer!.tolerance = 0
        RunLoop.main.add(refreshTimer!, forMode: .common)
        let nextMinute = Date(timeIntervalSince1970: (floor(start.timeIntervalSince1970 / 60) + 1) * 60)
        displayTimer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            self?.updateDisplay() // arithmetic/UI only; no read request
        }
        displayTimer!.tolerance = 1
        RunLoop.main.add(displayTimer!, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.openai.codex" else { return }
            self?.server.stop(); self?.state.snapshot = nil; self?.state.failure = .notRunning
            self?.updateDisplay()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.updateDisplay() // next automatic tick handles the read; no wake burst
        })
        updateDisplay()
        refresh(reason: "startup")
        audit.record("appStart", ["refreshIntervalSeconds": Self.refreshInterval,
                                 "loginStatus": SMAppService.mainApp.status.rawValue])
    }

    private func runningCodex() -> URL? {
        for app in NSWorkspace.shared.runningApplications {
            guard app.bundleIdentifier == "com.openai.codex", let bundle = app.bundleURL else { continue }
            for relativePath in ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                                 "Contents/Resources/codex"] {
                let path = bundle.appendingPathComponent(relativePath)
                if FileManager.default.isExecutableFile(atPath: path.path) { return path }
            }
        }
        return nil
    }

    private func refresh(reason: String) {
        guard !state.refreshing else { return }
        state.refreshing = true
        audit.record("refresh", ["reason": reason])
        server.fetch(executable: runningCodex()) { [weak self] result in
            guard let self else { return }
            self.state.refreshing = false
            // A completion queued immediately before desktop termination must not restore stale data.
            guard self.runningCodex() != nil else {
                self.state.snapshot = nil; self.state.failure = .notRunning; self.updateDisplay(); return
            }
            switch result {
            case .success(let snapshot): self.state.snapshot = snapshot; self.state.failure = nil
            case .failure(let error): self.state.snapshot = nil; self.state.failure = error
            }
            self.updateDisplay()
        }
    }

    private func updateDisplay() {
        guard item != nil else { return }
        let now = Date()
        let title = state.snapshot?.title(now: now) ?? "W-- · --"
        if item.button?.title != title { item.button?.title = title }
        item.button?.setAccessibilityValue(title)
        item.button?.toolTip = state.failure?.rawValue ?? "Codex Weekly 남은 사용량 · 5분마다 업데이트"
        if popover?.isShown == true { state.now = now }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover(); return false
    }
    @objc private func togglePopover() {
        if popover?.isShown == true { popover.close() } else { showPopover() }
    }
    private func showPopover() {
        guard let button = item?.button else { return }
        state.now = Date(); state.loginStatus = SMAppService.mainApp.status
        if popover == nil {
            popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: UsagePopover(
                state: state,
                refresh: { [weak self] in self?.refresh(reason: "manual") },
                toggleLogin: { [weak self] in self?.toggleLogin() },
                quit: { NSApp.terminate(nil) }
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.setAccessibilityLabel("Weekly Menu")
        popover.contentViewController?.view.window?.makeKey()
        audit.record("menuOpened", ["title": button.title])
    }
    func popoverDidClose(_ notification: Notification) {
        // Release the SwiftUI view tree while closed; only the NSStatusItem remains.
        popover?.contentViewController = nil
        popover = nil
    }
    private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else { try SMAppService.mainApp.register() }
            state.loginFailure = false
        } catch { state.loginFailure = true }
        state.loginStatus = SMAppService.mainApp.status
        audit.record("loginChanged", ["status": state.loginStatus.rawValue, "failed": state.loginFailure])
    }
    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate(); displayTimer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        server.stop(); audit.record("appQuit")
    }
}

let app = NSApplication.shared
let delegate = MenuApp()
app.delegate = delegate
app.run()
