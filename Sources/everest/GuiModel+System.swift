import AppKit
import SwiftUI

// The button daemon, recovery and launch at login.
extension EverestModel {
    // MARK: - Daemon & recovery

    /// Start or stop the D1–D4 listener, and remember the choice: while it is
    /// on, the app starts it at launch and restarts it if it ever dies.
    func toggleDaemon() {
        config.daemonEnabled = daemonProcess == nil
        persist()
        if config.daemonEnabled { startDaemon() } else { stopDaemon() }
    }


    func startDaemon() {
        guard daemonProcess == nil, !Self.snapshotMode else { return }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["listen", "--no-prompt", "--parent-pid", "\(getpid())"]
        // Keep the daemon's output: it says which key fired what, and warns
        // when macOS refuses to post key events.
        let logURL = Config.directory.appendingPathComponent("daemon.log")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        // Keep it small, but keep the previous one: the run that ended (a
        // restart, a crash) is often the one to read.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 512_000 {
            let previous = Config.directory.appendingPathComponent("daemon.log.1")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: logURL, to: previous)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        let launched = Date()
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.daemonProcess === proc else { return }
                self.daemonProcess = nil
                self.daemonRunning = false
                // Unexpected end: bring it back unless the user switched it
                // off, waiting longer each time it dies young (or finds
                // another listener running).
                if Date().timeIntervalSince(launched) > 60 && status != Daemon.alreadyRunning { self.daemonRestarts = 0 }
                self.daemonRestarts += 1
                let delay = min(60, 2 * pow(2, Double(min(self.daemonRestarts, 6) - 1)))
                if self.config.daemonEnabled && !self.quitting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.config.daemonEnabled, !self.quitting else { return }
                        self.startDaemon()
                    }
                }
            }
        }
        do {
            try p.run()
            daemonProcess = p
            daemonRunning = true
            report(tr("status.daemonOn"))
        } catch {
            report(tr("status.daemonStartFailed", error.localizedDescription), error: true)
        }
    }

    func stopDaemon() {
        let p = daemonProcess
        daemonProcess = nil
        daemonRunning = false
        p?.terminate()
        report(tr("status.daemonOff"))
    }

    // MARK: - Application preferences

    func setHideDockIcon(_ hidden: Bool) {
        config.hideDockIcon = hidden
        persist()
    }


    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginItemNote = LoginItem.status == .requiresApproval
                ? tr("status.loginApproval") : nil
        } catch {
            loginItemNote = tr("status.changeFailed", error.localizedDescription)
        }
        launchAtLogin = LoginItem.enabled
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The fix for a ticked entry that no longer matches this copy of the
    /// app (macOS keeps the signature it saw when the box was ticked: a
    /// build signed differently, or the same name pointing at another copy,
    /// shows ticked and gets nothing). `tccutil` forgets Everest's entry,
    /// then asking again makes macOS add a fresh one and show its own
    /// dialog. If the reset fails, the list opens for the manual steps.
    func repairAccessibility() {
        let id = Bundle.main.bundleIdentifier ?? "com.mrrcalendar.everest"
        DispatchQueue.global().async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", id]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let reset = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            DispatchQueue.main.async {
                guard let self else { return }
                if reset {
                    _ = ActionRunner.accessibilityGranted(prompt: true)
                } else {
                    self.openAccessibilitySettings()
                }
            }
        }
    }

    /// Claude / Codex keys on the pad that cannot read CodexBar's data.
    var codexBarBlocked: Bool {
        codexBarAccess == .denied && config.padButtons.contains { $0.live?.needsCodexBar == true }
    }

    /// Full Disk Access for CodexBar's data: as for Accessibility, a ticked
    /// entry may no longer match this copy of the app, and dragging the app
    /// onto it changes nothing. `tccutil` forgets it first; an app cannot add
    /// itself to this list, so the setting and a Finder window showing
    /// Everest open next, ready to drag. macOS then offers "Quit & Reopen".
    func repairCodexBarAccess() {
        let id = Bundle.main.bundleIdentifier ?? "com.mrrcalendar.everest"
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "SystemPolicyAllFiles", id]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit() }
            DispatchQueue.main.async { CodexBarUsage.showFullDiskAccess() }
        }
    }

    func recover() {
        runDevice(tr("status.recovering")) { kb in
            kb.recover()
            return tr("status.recoverySent")
        }
    }

    func clearFlashActions() {
        runDevice(tr("status.cleaning")) { kb in
            kb.neutraliseKeyActions()
            return tr("status.leftoversCleared")
        }
    }
}
