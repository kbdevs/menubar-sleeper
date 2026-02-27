import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var sleepDisabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshState()
    }

    // MARK: - State

    private func refreshState() {
        checkCurrentState()
        updateStatusItem()
    }

    private func checkCurrentState() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // pmset output has "disablesleep" followed by whitespace and 0 or 1
                sleepDisabled = output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
            }
        } catch {
            sleepDisabled = false
        }
    }

    // MARK: - UI

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        // Menu bar icon: coffee cup when caffeinated, moon when sleep enabled
        if #available(macOS 11.0, *) {
            let symbolName = sleepDisabled ? "cup.and.saucer.fill" : "moon.zzz.fill"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: sleepDisabled ? "Sleep Disabled" : "Sleep Enabled")
        } else {
            button.title = sleepDisabled ? "Awake" : "Sleep"
        }

        // Build the dropdown menu
        let menu = NSMenu()

        let statusText = sleepDisabled ? "Sleep Disabled (Caffeinated)" : "Sleep Enabled"
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        let toggleTitle = sleepDisabled ? "Enable Sleep" : "Disable Sleep"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleSleep), keyEquivalent: "t")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleSleep() {
        let newValue = sleepDisabled ? "0" : "1"
        let success = runPrivilegedCommand("pmset -a disablesleep \(newValue)")
        if success {
            refreshState()
        }
    }

    private func runPrivilegedCommand(_ command: String) -> Bool {
        let script = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            return error == nil
        }
        return false
    }

    @objc private func quitApp() {
        if sleepDisabled {
            _ = runPrivilegedCommand("pmset -a disablesleep 0")
        }
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // No dock icon, no app menu bar
let delegate = AppDelegate()
app.delegate = delegate
app.run()
