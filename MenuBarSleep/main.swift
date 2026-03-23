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
    private let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    private let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")

    private var statusItem: NSStatusItem!
    private var monitorTimer: Timer?
    private var activeSessions: [ActiveSession] = []
    private var lastLoggedSessionCount = Int.min
    private var refreshInFlight = false
    private var overrideMode: SleepOverrideMode = .auto
    private var disableSleepEnabled = false
    private var failedDisableSleepTarget: Bool?

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
        disableSleepEnabled = readDisableSleepSetting()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        log("launch home=\(FileManager.default.homeDirectoryForCurrentUser.path) stateDir=\(sessionStateDirectory.path) mode=\(overrideMode.rawValue) disablesleep=\(disableSleepEnabled ? 1 : 0)")
        startMonitoring()
        refreshState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTimer?.invalidate()
        stopPreventingSleep()
    }

    // MARK: - State

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(refreshNow), userInfo: nil, repeats: true)
        if let monitorTimer {
            RunLoop.main.add(monitorTimer, forMode: .common)
        }
    }

    private func refreshState() {
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

    private func runProcess(executableURL: URL, arguments: [String]) -> (status: Int32, stdout: String, stderr: String)? {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("failed running process path=\(executableURL.path) error=\(error.localizedDescription)")
            return nil
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func appleScriptStringLiteral(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func runPrivilegedShellCommand(_ command: String) -> Bool {
        let script = "do shell script \(appleScriptStringLiteral(command)) with administrator privileges"

        guard let result = runProcess(executableURL: osascriptURL, arguments: ["-e", script]) else {
            return false
        }

        guard result.status == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            log("privileged command failed status=\(result.status) command=\(command) stderr=\(stderr) stdout=\(stdout)")
            return false
        }

        return true
    }

    private func readDisableSleepSetting() -> Bool {
        guard let result = runProcess(executableURL: pmsetURL, arguments: ["-g", "custom"]), result.status == 0 else {
            return disableSleepEnabled
        }

        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "disablesleep" else { continue }
            return fields.last == "1"
        }

        return false
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
        failedDisableSleepTarget = nil
        UserDefaults.standard.set(mode.rawValue, forKey: modeDefaultsKey)
        log("override mode=\(mode.rawValue)")
        syncSleepPrevention()
        updateStatusItem()
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
        guard !disableSleepEnabled else { return }
        guard failedDisableSleepTarget != true else { return }

        let command = "/usr/bin/pmset -a disablesleep 1"
        guard runPrivilegedShellCommand(command) else {
            failedDisableSleepTarget = true
            updateStatusItem()
            return
        }

        disableSleepEnabled = readDisableSleepSetting()
        failedDisableSleepTarget = disableSleepEnabled ? nil : true
        log("set disablesleep=\(disableSleepEnabled ? 1 : 0)")
    }

    private func stopPreventingSleep() {
        guard disableSleepEnabled else { return }
        guard failedDisableSleepTarget != false else { return }

        let command = "/usr/bin/pmset -a disablesleep 0"
        guard runPrivilegedShellCommand(command) else {
            failedDisableSleepTarget = false
            updateStatusItem()
            return
        }

        disableSleepEnabled = readDisableSleepSetting()
        failedDisableSleepTarget = disableSleepEnabled ? false : nil
        log("set disablesleep=\(disableSleepEnabled ? 1 : 0)")
    }

    // MARK: - UI

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let isPreventingSleep = disableSleepEnabled

        if #available(macOS 11.0, *) {
            let symbolName = isPreventingSleep ? "cup.and.saucer.fill" : "moon.zzz.fill"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: isPreventingSleep ? "Preventing Sleep" : "Sleep Allowed")
            button.image?.isTemplate = true
        } else {
            button.title = isPreventingSleep ? "Awake" : "Sleep"
        }

        let menu = NSMenu()

        let statusText: String
        switch overrideMode {
        case .auto:
            if activeSessions.isEmpty {
                if failedDisableSleepTarget == false {
                    statusText = "Auto - Admin approval needed to re-enable sleep"
                } else {
                    statusText = "Auto - Sleep Allowed"
                }
            } else if isPreventingSleep {
                let sessionLabel = activeSessions.count == 1 ? "session" : "sessions"
                statusText = "Auto - Preventing Sleep (\(activeSessions.count) active \(sessionLabel))"
            } else if failedDisableSleepTarget == true {
                statusText = "Auto - Admin approval needed to disable sleep"
            } else {
                statusText = "Auto - Failed to change sleep setting"
            }
        case .on:
            if isPreventingSleep {
                statusText = "Manual On - Preventing Sleep"
            } else if failedDisableSleepTarget == true {
                statusText = "Manual On - Admin approval needed"
            } else {
                statusText = "Manual On - Failed to change sleep setting"
            }
        case .off:
            if failedDisableSleepTarget == false {
                statusText = "Manual Off - Admin approval needed"
            } else {
                statusText = "Manual Off - Sleep Allowed"
            }
        }

        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let modeMenuItem = NSMenuItem(title: "Mode: \(overrideMode.title)", action: nil, keyEquivalent: "")
        modeMenuItem.isEnabled = false
        menu.addItem(modeMenuItem)

        let countMenuItem = NSMenuItem(title: "Detected active sessions: \(activeSessions.count)", action: nil, keyEquivalent: "")
        countMenuItem.isEnabled = false
        menu.addItem(countMenuItem)

        if let firstSession = activeSessions.first {
            let detailMenuItem = NSMenuItem(title: "Example session: \(firstSession.title) [\(firstSession.source)]", action: nil, keyEquivalent: "")
            detailMenuItem.isEnabled = false
            menu.addItem(detailMenuItem)
        }

        menu.addItem(.separator())

        let autoItem = NSMenuItem(title: "Auto", action: #selector(setModeAuto), keyEquivalent: "1")
        autoItem.target = self
        autoItem.state = overrideMode == .auto ? .on : .off
        menu.addItem(autoItem)

        let onItem = NSMenuItem(title: "On", action: #selector(setModeOn), keyEquivalent: "2")
        onItem.target = self
        onItem.state = overrideMode == .on ? .on : .off
        menu.addItem(onItem)

        let offItem = NSMenuItem(title: "Off", action: #selector(setModeOff), keyEquivalent: "3")
        offItem.target = self
        offItem.state = overrideMode == .off ? .on : .off
        menu.addItem(offItem)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        failedDisableSleepTarget = nil
        disableSleepEnabled = readDisableSleepSetting()
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
