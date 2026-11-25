import AppKit
import Foundation
import GameController
import SwiftUI

// MARK: - Controller

@MainActor
final class SenzaController: ObservableObject {
    static let shared = SenzaController()

    @Published var inputMode: InputMode {
        didSet { UserDefaults.standard.set(inputMode.rawValue, forKey: "senza.inputMode") }
    }
    @Published var client: ClientKind {
        didSet { UserDefaults.standard.set(client.rawValue, forKey: "senza.client") }
    }
    @Published var preset: StreamPresetOption {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: "senza.preset") }
    }
    @Published var privileged: Bool {
        didSet { UserDefaults.standard.set(privileged, forKey: "senza.privileged") }
    }
    @Published var firewall: FirewallMode {
        didSet { UserDefaults.standard.set(firewall.rawValue, forKey: "senza.firewall") }
    }
    @Published var tailscaleExitNode: String {
        didSet {
            UserDefaults.standard.set(tailscaleExitNode, forKey: "senza.exitNode")
            scheduleExitNodeConfigWrite()
        }
    }
    @Published var probeHost: String {
        didSet { UserDefaults.standard.set(probeHost, forKey: "senza.host") }
    }

    @Published var connectedControllerName: String? = nil
    @Published var connectedControllerBattery: String? = nil
    @Published var phase: SessionPhase = .idle
    @Published var statusNote: String = "Ready to connect"
    @Published var doctor: DoctorResponse? = nil
    @Published var doctorLoading: Bool = false
    @Published var tunnelBusy: Bool = false
    @Published var showControlsSheet: Bool = false
    @Published var showStudioSheet: Bool = false
    @Published var errorMessage: String? = nil

    private var launcherProcess: Process? = nil
    private var childPid: Int32 = 0
    private var childBundleURL: URL? = nil
    private var handoffDone: Bool = false
    private var userManuallyPickedMode: Bool = false

    weak var mainWindow: NSWindow?
    var onPhaseChanged: ((SessionPhase) -> Void)?
    var onDoctorUpdated: (() -> Void)?

    private init() {
        let ud = UserDefaults.standard
        self.inputMode = InputMode(rawValue: ud.string(forKey: "senza.inputMode") ?? "") ?? .kbm
        self.client = ClientKind(rawValue: ud.string(forKey: "senza.client") ?? "") ?? .sony
        self.preset = StreamPresetOption(rawValue: ud.string(forKey: "senza.preset") ?? "") ?? .auto
        self.privileged = ud.object(forKey: "senza.privileged") == nil ? true : ud.bool(forKey: "senza.privileged")
        self.firewall = FirewallMode(rawValue: ud.string(forKey: "senza.firewall") ?? "") ?? .off
        let savedExit = ud.string(forKey: "senza.exitNode")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.tailscaleExitNode = savedExit
        self.probeHost = ud.string(forKey: "senza.host") ?? "1.1.1.1"
        setupControllerObservers()
        syncExitNodeWithConfig(localValue: savedExit)
    }

    /// Exit node typed in the GUI; empty means "use ~/.config/senza/config.json or auto-discover".
    var resolvedExitNode: String {
        tailscaleExitNode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Human label for status text when no node is typed.
    var exitNodeLabel: String {
        resolvedExitNode.isEmpty ? (doctor?.system_tunnel?.target_exit_node ?? "auto") : resolvedExitNode
    }

    /// CLI args that pin the exit node only when the user typed one.
    var exitNodeArgs: [String] {
        resolvedExitNode.isEmpty ? [] : ["--exit-node", resolvedExitNode]
    }

    private var exitNodeWriteItem: DispatchWorkItem?
    private var suppressExitNodeWrite = false

    /// `~/.config/senza/config.json` is the single source of truth shared with CLI, Raycast and the LaunchAgent.
    /// On first run adopt the config value; if only the GUI has one (older versions), migrate it into config.
    private func syncExitNodeWithConfig(localValue: String) {
        guard SenzaCLI.resolve() != nil else { return }
        Task { @MainActor [weak self] in
            let out = await SenzaCLI.run(["config", "get", "exit-node"])
            let configValue = out.ok ? out.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard let self else { return }
            if !configValue.isEmpty, configValue != localValue {
                self.suppressExitNodeWrite = true
                self.tailscaleExitNode = configValue
                self.suppressExitNodeWrite = false
            } else if configValue.isEmpty, !localValue.isEmpty {
                self.scheduleExitNodeConfigWrite(delay: 0)
            }
        }
    }

    private func scheduleExitNodeConfigWrite(delay: TimeInterval = 0.8) {
        guard !suppressExitNodeWrite, SenzaCLI.resolve() != nil else { return }
        exitNodeWriteItem?.cancel()
        let value = resolvedExitNode
        let item = DispatchWorkItem {
            _ = SenzaCLI.runSync(value.isEmpty ? ["config", "unset", "exit-node"] : ["config", "set", "exit-node", value])
        }
        exitNodeWriteItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }


    func selectInputMode(_ mode: InputMode) {
        userManuallyPickedMode = true
        inputMode = mode
    }

    private func setupControllerObservers() {
        GCController.shouldMonitorBackgroundEvents = true
        refreshConnectedControllers(autoSelect: true)

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnectedControllers(autoSelect: true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnectedControllers(autoSelect: false)
            }
        }
    }

    func refreshConnectedControllers(autoSelect: Bool) {
        let controllers = GCController.controllers()
        if let pad = controllers.first {
            let name = pad.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
            connectedControllerName = (name?.isEmpty == false) ? name : "DualSense"
            if let bat = pad.battery, bat.batteryLevel >= 0 {
                let pct = Int((bat.batteryLevel * 100.0).rounded())
                let chg = (bat.batteryState == .charging) ? " ⚡" : ""
                connectedControllerBattery = "\(pct)%\(chg)"
            } else {
                connectedControllerBattery = nil
            }
            if autoSelect && !userManuallyPickedMode && !isBusy {
                inputMode = .hybrid
            }
        } else {
            connectedControllerName = nil
            connectedControllerBattery = nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .idle: return false
        default: return true
        }
    }

    private func setPhase(_ next: SessionPhase) {
        phase = next
        onPhaseChanged?(next)
    }

    func refreshDoctor() {
        guard !doctorLoading else { return }
        guard SenzaCLI.resolve() != nil else {
            errorMessage = SenzaCLI.notFoundMessage
            return
        }
        doctorLoading = true
        let host = probeHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1.1.1.1" : probeHost
        let args = ["doctor", "--host", host] + exitNodeArgs + ["--json"]
        Task { @MainActor [weak self] in
            let result = await SenzaCLI.run(args)
            guard let self else { return }
            self.doctorLoading = false
            if result.ok, let decoded = try? JSONDecoder().decode(DoctorResponse.self, from: result.stdout) {
                self.doctor = decoded
                self.onDoctorUpdated?()
            }
        }
    }

    func launchSession() {
        guard case .idle = phase else {
            bringActiveClientToFront()
            return
        }
        guard SenzaCLI.resolve() != nil else {
            errorMessage = SenzaCLI.notFoundMessage
            return
        }

        errorMessage = nil
        handoffDone = false
        childPid = 0
        childBundleURL = nil

        var args = ["start", "--client", client.rawValue, "--profile", "gta6"]
        if client == .chiaki {
            args += ["--preset", preset.rawValue]
        }
        let host = probeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            args += ["--host", host]
        }
        if inputMode == .hybrid {
            args.append("--hybrid")
        } else if inputMode == .controller {
            args.append("--controller")
        }
        if privileged {
            args += ["--privileged", "--gui-sudo"]
        }
        if firewall != .off {
            args += ["--bypass-firewall", firewall.rawValue]
            if firewall == .tailscale {
                args += exitNodeArgs
            }
        }

        var env = ["SENZA_GUI_MANAGED": "1", "PYTHONUNBUFFERED": "1"]
        if let win = mainWindow {
            let f = win.frame
            env["SENZA_TARGET_CENTER"] = "\(Int(f.midX.rounded())),\(Int(f.midY.rounded()))"
        }
        guard let proc = SenzaCLI.makeProcess(args, extraEnv: env) else { return }

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let launchStatus: String = {
            if privileged { return "Authorizing Wi-Fi & UDP boost…" }
            if firewall == .tailscale { return "Connecting Tailscale exit node \(exitNodeLabel)…" }
            return "Launching \(client.displayName)…"
        }()
        setPhase(.launching(launchStatus))
        statusNote = "Preparing \(client.displayName)…"

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            let lines = chunk.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines {
                    self.handleOutputLine(line)
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let exitCode = p.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launcherProcess = nil
                self.childPid = 0
                self.childBundleURL = nil
                self.handoffDone = false
                self.setPhase(.idle)
                if exitCode != 0 && self.errorMessage == nil {
                    self.statusNote = "Session ended (code \(exitCode))"
                } else {
                    self.statusNote = "Session ended · System restored"
                }
                self.showMainWindowToFront()
                self.refreshDoctor()
            }
        }

        do {
            try proc.run()
            launcherProcess = proc
        } catch {
            setPhase(.idle)
            errorMessage = "Failed to launch Senza CLI: \(error.localizedDescription)"
            statusNote = "Launch failed"
        }
    }

    private func handleOutputLine(_ line: String) {
        if line.hasPrefix("ERROR:") {
            errorMessage = String(line.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
            return
        }
        if line.contains("[opt]") {
            let clean = line.replacingOccurrences(of: "[opt]", with: "").trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty {
                statusNote = clean
                if case .launching = phase {
                    setPhase(.launching(clean))
                }
            }
        }
        if line.contains("[bypass]") {
            let clean = line.replacingOccurrences(of: "[bypass]", with: "").trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty {
                statusNote = clean
                if case .launching = phase {
                    setPhase(.launching(clean))
                }
            }
        }
        if line.contains("[launch]"), let range = line.range(of: "pid=") {
            let tail = line[range.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            if let pid = Int32(digits), pid > 0 {
                childPid = pid
                let label = client.displayName
                setPhase(.playing(pid: pid, label: label))
                statusNote = "\(label) active"
                performSandwichHandoff(pid: pid)
            }
        }
    }

    /// Hands foreground focus directly to the spawned Remote Play / chiaki-ng PID using macOS 14+ Cooperative Activation,
    /// then smoothly collapses the Senza loader window into the menu bar.
    private func performSandwichHandoff(pid: Int32) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var targetApp: NSRunningApplication? = nil
            for _ in 0..<80 {
                guard self.childPid == pid else { return }
                if let app = NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching {
                    targetApp = app
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let app = targetApp, self.childPid == pid else { return }
            self.childBundleURL = app.bundleURL

            self.activateClientApp(app)
            try? await Task.sleep(nanoseconds: 350_000_000)

            // Belt-and-suspenders fallback on macOS 14-27 if WindowServer deferred activation
            if !app.isActive, let bundleURL = app.bundleURL {
                let openProc = Process()
                openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                openProc.arguments = [bundleURL.path]
                try? openProc.run()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            if !self.handoffDone && self.childPid == pid {
                self.handoffDone = true
                // Collapse launcher window cleanly into the menu bar ("sandwich" into PS Remote Play)
                self.mainWindow?.orderOut(nil)
            }
        }
    }

    private func activateClientApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
        }
        app.unhide()
        app.activate(options: [.activateAllWindows])
    }

    func bringActiveClientToFront() {
        if childPid > 0, let app = NSRunningApplication(processIdentifier: childPid), !app.isTerminated {
            activateClientApp(app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !app.isActive, let url = app.bundleURL {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    p.arguments = [url.path]
                    try? p.run()
                }
            }
            return
        }
        // Fallback: if RemotePlay or chiaki-ng is running independently, focus it
        let targetBundleIds = ["com.playstation.RemotePlay", "com.chiaki.Chiaki"]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier, targetBundleIds.contains(bid) {
                activateClientApp(app)
                return
            }
        }
    }

    func endActiveSession() {
        if childPid > 0, let app = NSRunningApplication(processIdentifier: childPid), !app.isTerminated {
            setPhase(.restoring("Closing \(client.displayName) & restoring system…"))
            statusNote = "Ending session & restoring system…"
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.childPid > 0,
                      let still = NSRunningApplication(processIdentifier: self.childPid),
                      !still.isTerminated else { return }
                still.forceTerminate()
            }
        } else if let proc = launcherProcess, proc.isRunning {
            setPhase(.restoring("Stopping session…"))
            proc.terminate()
        }
    }

    func runRestoreSystem() {
        guard SenzaCLI.resolve() != nil else { return }
        setPhase(.restoring("Restoring awdl0, DNS & sysctl…"))
        statusNote = "Running system restore…"
        Task { @MainActor [weak self] in
            let result = await SenzaCLI.run(["restore", "--gui-sudo"])
            guard let self else { return }
            self.setPhase(.idle)
            self.statusNote = result.status < 0 ? "Restore failed: \(result.output)" : result.summary(or: "System restored")
            self.refreshDoctor()
        }
    }

    func toggleSystemTunnel() {
        guard !tunnelBusy else { return }
        guard SenzaCLI.resolve() != nil else {
            errorMessage = SenzaCLI.notFoundMessage
            return
        }
        let isActive = doctor?.system_tunnel?.active == true
        statusNote = isActive ? "Stopping system-wide tunnel…" : "Enabling system-wide tunnel (\(exitNodeLabel))…"
        runTunnelCommand(isActive ? ["tunnel", "off"] : ["tunnel", "on"] + exitNodeArgs,
                         fallback: isActive ? "System tunnel stopped" : "System tunnel updated")
    }

    func toggleTunnelService() {
        guard !tunnelBusy, SenzaCLI.resolve() != nil else { return }
        let installed = doctor?.system_tunnel?.service_installed == true
        statusNote = installed ? "Removing auto-heal LaunchAgent…" : "Installing macOS auto-heal LaunchAgent…"
        // The agent re-reads ~/.config/senza/config.json on each run, so no --exit-node is pinned.
        runTunnelCommand(installed ? ["tunnel", "uninstall-service"] : ["tunnel", "install-service"],
                         fallback: installed ? "LaunchAgent removed" : "LaunchAgent installed")
    }

    private func runTunnelCommand(_ args: [String], fallback: String) {
        tunnelBusy = true
        Task { @MainActor [weak self] in
            let result = await SenzaCLI.run(args)
            guard let self else { return }
            self.tunnelBusy = false
            self.statusNote = result.status < 0 ? "Command failed: \(result.output)" : result.summary(or: fallback)
            self.refreshDoctor()
        }
    }

    func showMainWindowToFront() {
        guard let win = mainWindow else { return }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }


}
