import Cocoa
import Darwin

struct ActiveSessionMarker: Decodable {
    let sessionID: String
    let pid: Int32
    let status: String
    let updatedAt: String?
}

struct ActiveSession {
    let sessionID: String
    let title: String
    let source: String
}

struct OpenCodeSessionSummary: Decodable {
    let id: String
    let title: String?
    let directory: String?
    let time: OpenCodeTimeInfo
}

struct OpenCodeTimeInfo: Decodable {
    let created: Int64?
    let updated: Int64?
    let completed: Int64?
}

struct OpenCodeMessageEnvelope: Decodable {
    let info: OpenCodeMessageInfo
    let parts: [OpenCodeMessagePart]?
}

struct OpenCodeMessageInfo: Decodable {
    let role: String
    let time: OpenCodeTimeInfo?
}

struct OpenCodeMessagePart: Decodable {
    let type: String
    let state: OpenCodeToolState?
}

struct OpenCodeToolState: Decodable {
    let status: String?
}

enum SleepOverrideMode: String {
    case auto
    case on
    case off

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .on:
            return "On"
        case .off:
            return "Off"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let apiBaseURL = URL(string: "http://127.0.0.1:4096")!
    private let maxSessionChecks = 8
    private let recentSessionWindowMs: Int64 = 6 * 60 * 60 * 1000
    private let sessionStateDirectory = AppDelegate.makeSessionStateDirectory()
    private let logFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("MenuBarSleep.log")
    private let refreshQueue = DispatchQueue(label: "MenuBarSleep.refresh", qos: .utility)
    private let modeDefaultsKey = "sleepOverrideMode"
    private let caffeinateURL = URL(fileURLWithPath: "/usr/bin/caffeinate")

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusTextItem: NSMenuItem!
    private var modeTextItem: NSMenuItem!
    private var countTextItem: NSMenuItem!
    private var detailTextItem: NSMenuItem!
    private var autoModeItem: NSMenuItem!
    private var onModeItem: NSMenuItem!
    private var offModeItem: NSMenuItem!
    private var monitorTimer: Timer?
    private var caffeinateProcess: Process?
    private var activeSessions: [ActiveSession] = []
    private var lastLoggedSessionCount = Int.min
    private var refreshInFlight = false
    private var overrideMode: SleepOverrideMode = .auto

    private func hasAnotherRunningInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { app in
                app.processIdentifier != currentPID && !app.isTerminated
            }
    }

    private static func makeSessionStateDirectory() -> URL {
        let configHome: URL

        if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
            configHome = URL(fileURLWithPath: xdgConfigHome)
        } else {
            configHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }

        return configHome
            .appendingPathComponent("opencode")
            .appendingPathComponent("menubarsleep")
            .appendingPathComponent("active-sessions")
    }

    private func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if hasAnotherRunningInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        overrideMode = loadOverrideMode()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureMenu()
        log("launch home=\(FileManager.default.homeDirectoryForCurrentUser.path) stateDir=\(sessionStateDirectory.path) mode=\(overrideMode.rawValue)")
        if overrideMode != .off {
            startMonitoring()
        }
        refreshState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTimer?.invalidate()
        stopPreventingSleep()
    }

    // MARK: - State

    private func startMonitoring() {
        guard monitorTimer == nil else { return }
        monitorTimer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(timerRefreshNow), userInfo: nil, repeats: true)
        if let monitorTimer {
            RunLoop.main.add(monitorTimer, forMode: .common)
        }
    }

    private func refreshState() {
        if overrideMode == .off {
            activeSessions = []
            lastLoggedSessionCount = 0
            stopPreventingSleep()
            updateStatusItem()
            return
        }

        guard !refreshInFlight else { return }
        refreshInFlight = true

        refreshQueue.async {
            let refreshedSessions = self.fetchActiveSessions()

            DispatchQueue.main.async {
                self.refreshInFlight = false
                self.activeSessions = refreshedSessions

                if self.activeSessions.count != self.lastLoggedSessionCount {
                    self.lastLoggedSessionCount = self.activeSessions.count
                    self.log("activeSessions=\(self.activeSessions.count) ids=\(self.activeSessions.map(\.sessionID).joined(separator: ","))")
                }

                self.syncSleepPrevention()
                self.updateStatusItem()
            }
        }
    }

    private func fetchActiveSessions() -> [ActiveSession] {
        var sessionsByID: [String: ActiveSession] = [:]

        for marker in fetchMarkerSessions() {
            sessionsByID[marker.sessionID] = ActiveSession(
                sessionID: marker.sessionID,
                title: "OpenCode session",
                source: "plugin"
            )
        }

        for session in fetchBusySessionsFromAPI() {
            sessionsByID[session.sessionID] = session
        }

        return sessionsByID.values.sorted { $0.sessionID < $1.sessionID }
    }

    private func fetchMarkerSessions() -> [ActiveSessionMarker] {
        do {
            let markerURLs = try FileManager.default.contentsOfDirectory(
                at: sessionStateDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            var validSessions: [String: ActiveSessionMarker] = [:]
            var staleMarkerURLs: [URL] = []

            for markerURL in markerURLs where markerURL.pathExtension == "json" {
                guard let marker = decodeMarker(at: markerURL) else {
                    staleMarkerURLs.append(markerURL)
                    log("stale marker decode failed path=\(markerURL.path)")
                    continue
                }

                guard isProcessAlive(marker.pid) else {
                    staleMarkerURLs.append(markerURL)
                    log("stale marker dead pid session=\(marker.sessionID) pid=\(marker.pid)")
                    continue
                }

                validSessions[marker.sessionID] = marker
            }

            removeStaleMarkers(at: staleMarkerURLs)

            return validSessions.values.sorted { $0.sessionID < $1.sessionID }
        } catch {
            log("failed reading state dir error=\(error.localizedDescription)")
            return []
        }
    }

    private func fetchBusySessionsFromAPI() -> [ActiveSession] {
        guard let sessions: [OpenCodeSessionSummary] = fetchJSON(from: apiBaseURL.appendingPathComponent("session")) else {
            log("api session fetch failed")
            return []
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let candidateSessions = sessions
            .filter { session in
                let updatedAt = session.time.updated ?? session.time.created ?? 0
                return nowMs - updatedAt <= recentSessionWindowMs
            }
            .sorted { ($0.time.updated ?? 0) > ($1.time.updated ?? 0) }
            .prefix(maxSessionChecks)

        var busySessions: [ActiveSession] = []

        for session in candidateSessions where isSessionBusy(session.id) {
            busySessions.append(
                ActiveSession(
                    sessionID: session.id,
                    title: session.title ?? session.directory ?? session.id,
                    source: "api"
                )
            )
        }

        return busySessions
    }

    private func isSessionBusy(_ sessionID: String) -> Bool {
        let messagesURL = apiBaseURL
            .appendingPathComponent("session")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("message")

        guard let messages: [OpenCodeMessageEnvelope] = fetchJSON(from: messagesURL),
              let latestMessage = messages.last else {
            return false
        }

        if latestMessage.info.role == "assistant", latestMessage.info.time?.completed == nil {
            return true
        }

        var openStepCount = 0

        for part in latestMessage.parts ?? [] {
            if part.type == "tool", part.state?.status == "running" {
                return true
            }

            if part.type == "step-start" {
                openStepCount += 1
            } else if part.type == "step-finish", openStepCount > 0 {
                openStepCount -= 1
            }
        }

        return openStepCount > 0
    }

    private func fetchJSON<T: Decodable>(from url: URL) -> T? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        if #available(macOS 10.15, *) {
            configuration.waitsForConnectivity = false
        }

        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        let task = session.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + 3) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            log("request timed out url=\(url.absoluteString)")
            return nil
        }

        if let responseError {
            log("request failed url=\(url.absoluteString) error=\(responseError.localizedDescription)")
        }

        guard let responseData else { return nil }

        return try? JSONDecoder().decode(T.self, from: responseData)
    }

    private func decodeMarker(at url: URL) -> ActiveSessionMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ActiveSessionMarker.self, from: data)
    }

    private func removeStaleMarkers(at urls: [URL]) {
        guard !urls.isEmpty else { return }

        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }

        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }

    private func loadOverrideMode() -> SleepOverrideMode {
        guard let rawValue = UserDefaults.standard.string(forKey: modeDefaultsKey),
              let mode = SleepOverrideMode(rawValue: rawValue) else {
            return .auto
        }

        return mode
    }

    private func setOverrideMode(_ mode: SleepOverrideMode) {
        guard overrideMode != mode else { return }

        overrideMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: modeDefaultsKey)
        log("override mode=\(mode.rawValue)")

        if mode == .off {
            monitorTimer?.invalidate()
            monitorTimer = nil
            activeSessions = []
        } else {
            startMonitoring()
        }

        syncSleepPrevention()
        updateStatusItem()
        if mode != .off {
            refreshState()
        }
    }

    private func shouldPreventSleep() -> Bool {
        switch overrideMode {
        case .auto:
            return !activeSessions.isEmpty
        case .on:
            return true
        case .off:
            return false
        }
    }

    private func syncSleepPrevention() {
        if shouldPreventSleep() {
            startPreventingSleep()
        } else {
            stopPreventingSleep()
        }
    }

    private func startPreventingSleep() {
        guard !(caffeinateProcess?.isRunning ?? false) else { return }

        let process = Process()
        process.executableURL = caffeinateURL
        process.arguments = ["-dimsu"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            caffeinateProcess = process
            log("started caffeinate pid=\(process.processIdentifier)")
        } catch {
            log("failed starting caffeinate error=\(error.localizedDescription)")
            caffeinateProcess = nil
        }
    }

    private func stopPreventingSleep() {
        guard let process = caffeinateProcess else { return }

        if process.isRunning {
            process.terminate()
            log("stopped caffeinate pid=\(process.processIdentifier)")
        }

        caffeinateProcess = nil
    }

    // MARK: - UI

    private func configureMenu() {
        statusMenu = NSMenu()

        statusTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusTextItem.isEnabled = false
        statusMenu.addItem(statusTextItem)

        modeTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        modeTextItem.isEnabled = false
        statusMenu.addItem(modeTextItem)

        countTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        countTextItem.isEnabled = false
        statusMenu.addItem(countTextItem)

        detailTextItem = NSMenuItem(title: "No active session details", action: nil, keyEquivalent: "")
        detailTextItem.isEnabled = false
        statusMenu.addItem(detailTextItem)

        statusMenu.addItem(.separator())

        autoModeItem = NSMenuItem(title: "Auto", action: #selector(setModeAuto), keyEquivalent: "1")
        autoModeItem.target = self
        statusMenu.addItem(autoModeItem)

        onModeItem = NSMenuItem(title: "On", action: #selector(setModeOn), keyEquivalent: "2")
        onModeItem.target = self
        statusMenu.addItem(onModeItem)

        offModeItem = NSMenuItem(title: "Off", action: #selector(setModeOff), keyEquivalent: "3")
        offModeItem.target = self
        statusMenu.addItem(offModeItem)

        statusMenu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(manualRefreshNow), keyEquivalent: "r")
        refreshItem.target = self
        statusMenu.addItem(refreshItem)

        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        statusItem.menu = statusMenu
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let isPreventingSleep = caffeinateProcess?.isRunning ?? false

        if #available(macOS 11.0, *) {
            let symbolName = isPreventingSleep ? "cup.and.saucer.fill" : "moon.zzz.fill"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: isPreventingSleep ? "Preventing Sleep" : "Sleep Allowed")
            button.image?.isTemplate = true
        } else {
            button.title = isPreventingSleep ? "Awake" : "Sleep"
        }

        let statusText: String
        switch overrideMode {
        case .auto:
            if activeSessions.isEmpty {
                statusText = "Auto - Sleep Allowed"
            } else if isPreventingSleep {
                let sessionLabel = activeSessions.count == 1 ? "session" : "sessions"
                statusText = "Auto - Preventing Sleep (\(activeSessions.count) active \(sessionLabel))"
            } else {
                statusText = "Auto - Failed to prevent sleep"
            }
        case .on:
            if isPreventingSleep {
                statusText = "Manual On - Preventing Sleep"
            } else {
                statusText = "Manual On - Failed to prevent sleep"
            }
        case .off:
            statusText = "Manual Off - Sleep Allowed"
        }

        statusTextItem.title = statusText
        modeTextItem.title = "Mode: \(overrideMode.title)"
        countTextItem.title = overrideMode == .off ? "Detected active sessions: 0" : "Detected active sessions: \(activeSessions.count)"

        if overrideMode == .off {
            detailTextItem.title = "Monitoring paused in Off"
        } else if let firstSession = activeSessions.first {
            detailTextItem.title = "Example session: \(firstSession.title) [\(firstSession.source)]"
        } else {
            detailTextItem.title = "No active session details"
        }

        autoModeItem.state = overrideMode == .auto ? .on : .off
        onModeItem.state = overrideMode == .on ? .on : .off
        offModeItem.state = overrideMode == .off ? .on : .off
    }

    // MARK: - Actions

    @objc private func timerRefreshNow() {
        guard overrideMode != .off else { return }
        refreshState()
    }

    @objc private func manualRefreshNow() {
        guard overrideMode != .off else {
            activeSessions = []
            updateStatusItem()
            return
        }
        refreshState()
    }

    @objc private func setModeAuto() {
        setOverrideMode(.auto)
    }

    @objc private func setModeOn() {
        setOverrideMode(.on)
    }

    @objc private func setModeOff() {
        setOverrideMode(.off)
    }

    @objc private func quitApp() {
        stopPreventingSleep()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
