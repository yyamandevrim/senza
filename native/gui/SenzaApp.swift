import AppKit
import Foundation
import GameController
import SwiftUI

// MARK: - Models

enum InputMode: String, CaseIterable, Identifiable {
    case kbm = "kbm"
    case hybrid = "hybrid"
    case controller = "controller"
    var id: String { rawValue }
}

enum ClientKind: String, CaseIterable, Identifiable {
    case sony = "sony"
    case chiaki = "chiaki"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sony: return "PS Remote Play"
        case .chiaki: return "chiaki-ng"
        }
    }
}

enum FirewallMode: String, CaseIterable, Identifiable {
    case off = "off"
    case auto = "auto"
    case dns = "dns"
    case warp = "warp"
    case tailscale = "tailscale"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        case .dns: return "DNS 1.1.1.1"
        case .warp: return "WARP"
        case .tailscale: return "Tailscale"
        }
    }
}

enum StreamPresetOption: String, CaseIterable, Identifiable {
    case auto = "auto"
    case wanHigh = "wan-high"
    case wanBalanced = "wan-balanced"
    case wanLowBw = "wan-lowbw"
    case lanMax = "lan-max"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (WAN)"
        case .wanHigh: return "WAN High · 1080p60"
        case .wanBalanced: return "WAN Balanced · 1080p60"
        case .wanLowBw: return "WAN Low-BW · 720p60"
        case .lanMax: return "LAN Max · 30 Mbps"
        }
    }
}

struct DoctorResponse: Decodable {
    struct Network: Decodable {
        let host: String
        let rtt_median_ms: Double?
        let rtt_p95_ms: Double?
        let jitter_ms: Double?
        let packet_loss_pct: Double
        let default_interface: String
        let is_wifi: Bool
        let awdl_active: Bool
        let warnings: [String]
    }
    struct Firewall: Decodable {
        let psn_sys_tls_ok: Bool
        let psn_cf_tls_ok: Bool
        let udp_high_port_ok: Bool
        let diagnosis: String
        let tailscale_state: String?
        let tailscale_exit_node: String?
        let tailscale_exit_node_ready: Bool?
        let tailscale_exit_node_status: String?
    }
    struct Preset: Decodable {
        let name: String
        let resolution: String
        let fps: Int
        let bitrate_kbps: Int
    }
    let network: Network
    let firewall: Firewall?
    let recommended_preset: Preset
    let sony_app: String?
    let sony_bundle_ready: Bool?
    let chiaki_app: String?
    let patched_bundle_ready: Bool?
}

enum SessionPhase: Equatable {
    case idle
    case launching(String)
    case playing(pid: Int32, label: String)
    case restoring(String)
}

// MARK: - CLI Discovery

struct SenzaCLI {
    static func resolve() -> (executable: URL, workingDir: URL)? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []

        if let repoRoot = Bundle.main.infoDictionary?["SenzaRepoRoot"] as? String, !repoRoot.isEmpty {
            candidates.append((repoRoot as NSString).appendingPathComponent("bin/senza"))
        }
        candidates.append("\(home)/.local/bin/senza")
        candidates.append("/opt/homebrew/bin/senza")
        candidates.append("/usr/local/bin/senza")

        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let repoDir = resolved.deletingLastPathComponent().deletingLastPathComponent()
                let cwd = fm.fileExists(atPath: repoDir.path) ? repoDir : fm.homeDirectoryForCurrentUser
                return (URL(fileURLWithPath: path), cwd)
            }
        }
        return nil
    }

    static func appIconImage() -> NSImage? {
        if let icnsURL = Bundle.main.url(forResource: "Senza", withExtension: "icns"),
           let img = NSImage(contentsOf: icnsURL) {
            return img
        }
        return NSApp.applicationIconImage
    }
}

// MARK: - Controller

@MainActor
final class SenzaController: ObservableObject {
    static let shared = SenzaController()
    static let defaultTailscaleExitNode = "100.123.154.74"

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
        didSet { UserDefaults.standard.set(tailscaleExitNode, forKey: "senza.exitNode") }
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

    private init() {
        let ud = UserDefaults.standard
        self.inputMode = InputMode(rawValue: ud.string(forKey: "senza.inputMode") ?? "") ?? .kbm
        self.client = ClientKind(rawValue: ud.string(forKey: "senza.client") ?? "") ?? .sony
        self.preset = StreamPresetOption(rawValue: ud.string(forKey: "senza.preset") ?? "") ?? .auto
        self.privileged = ud.object(forKey: "senza.privileged") == nil ? true : ud.bool(forKey: "senza.privileged")
        self.firewall = FirewallMode(rawValue: ud.string(forKey: "senza.firewall") ?? "") ?? .off
        let savedExit = ud.string(forKey: "senza.exitNode")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.tailscaleExitNode = savedExit.isEmpty ? Self.defaultTailscaleExitNode : savedExit
        self.probeHost = ud.string(forKey: "senza.host") ?? "1.1.1.1"
        setupControllerObservers()
    }

    var resolvedExitNode: String {
        let trimmed = tailscaleExitNode.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultTailscaleExitNode : trimmed
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
        guard let cli = SenzaCLI.resolve() else {
            errorMessage = "Senza CLI not found. Run `make install` in the repository first."
            return
        }
        doctorLoading = true
        let host = probeHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1.1.1.1" : probeHost
        let exitNode = resolvedExitNode

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = cli.executable
            proc.currentDirectoryURL = cli.workingDir
            proc.arguments = ["doctor", "--host", host, "--exit-node", exitNode, "--json"]
            proc.environment = Self.baseEnv()

            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = Pipe()

            var decoded: DoctorResponse? = nil
            do {
                try proc.run()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    decoded = try? JSONDecoder().decode(DoctorResponse.self, from: data)
                }
            } catch {
                decoded = nil
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.doctorLoading = false
                if let decoded {
                    self.doctor = decoded
                }
            }
        }
    }

    func launchSession() {
        guard case .idle = phase else {
            bringActiveClientToFront()
            return
        }
        guard let cli = SenzaCLI.resolve() else {
            errorMessage = "Senza CLI not found. Run `make install` first."
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
                args += ["--exit-node", resolvedExitNode]
            }
        }

        var env = Self.baseEnv()
        env["SENZA_GUI_MANAGED"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        if let win = mainWindow {
            let f = win.frame
            let cx = Int(f.midX.rounded())
            let cy = Int(f.midY.rounded())
            env["SENZA_TARGET_CENTER"] = "\(cx),\(cy)"
        }

        let proc = Process()
        proc.executableURL = cli.executable
        proc.currentDirectoryURL = cli.workingDir
        proc.arguments = args
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let launchStatus: String = {
            if privileged { return "Authorizing Wi-Fi & UDP boost…" }
            if firewall == .tailscale { return "Connecting Tailscale exit node \(resolvedExitNode)…" }
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
        guard let cli = SenzaCLI.resolve() else { return }
        setPhase(.restoring("Restoring awdl0, DNS & sysctl…"))
        statusNote = "Running system restore…"

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = cli.executable
            proc.currentDirectoryURL = cli.workingDir
            proc.arguments = ["restore", "--gui-sudo"]
            proc.environment = Self.baseEnv()
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var out = "System restored"
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if let str = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty {
                    out = str.components(separatedBy: .newlines).last ?? out
                }
            } catch {
                out = "Restore failed: \(error.localizedDescription)"
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setPhase(.idle)
                self.statusNote = out.replacingOccurrences(of: "[restore]", with: "").trimmingCharacters(in: .whitespaces)
                self.refreshDoctor()
            }
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

    private nonisolated static func baseEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let curPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(curPath)"
        return env
    }
}

// MARK: - Native Frosted Background

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - SwiftUI Views

struct SenzaRootView: View {
    @ObservedObject var ctrl: SenzaController

    private let sapphire = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
            LinearGradient(
                colors: [Color(white: 0.10, opacity: 0.55), Color(white: 0.05, opacity: 0.80)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                headerRow
                telemetryStrip
                inputModeSection
                clientSettingsCard
                if let err = ctrl.errorMessage {
                    errorBanner(err)
                }
                Spacer(minLength: 0)
                actionSection
                footerBar
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 16)
        }
        .frame(width: 486, height: 648)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $ctrl.showControlsSheet) {
            ControlsCheatSheetView(isPresented: $ctrl.showControlsSheet)
        }
        .sheet(isPresented: $ctrl.showStudioSheet) {
            ProfileStudioView(isPresented: $ctrl.showStudioSheet)
        }
        .onAppear {
            ctrl.refreshDoctor()
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            if let img = SenzaCLI.appIconImage() {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Senza")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("GTA 6")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(sapphire)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(sapphire.opacity(0.16), in: Capsule())
                        .overlay(Capsule().stroke(sapphire.opacity(0.35), lineWidth: 0.75))
                }
                Text("Virtual DualSense · PS5 Remote Play Suite")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer()
            HStack(spacing: 6) {
                IconHeaderButton(systemName: "slider.horizontal.3", help: "GTA 6 Sensitivity & Keybind Studio") {
                    ctrl.showStudioSheet = true
                }
                IconHeaderButton(systemName: "keyboard", help: "GTA 6 Controls Cheat Sheet") {
                    ctrl.showControlsSheet = true
                }
                IconHeaderButton(systemName: "arrow.clockwise", help: "Refresh Network Doctor", spinning: ctrl.doctorLoading) {
                    ctrl.refreshDoctor()
                }
            }
        }
    }

    private var telemetryStrip: some View {
        HStack(spacing: 8) {
            if let doc = ctrl.doctor {
                let rttText = doc.network.rtt_median_ms.map { String(format: "%.0f ms", $0) } ?? "—"
                let jitText = doc.network.jitter_ms.map { String(format: "%.1f ms", $0) } ?? "—"
                let jitColor: Color = {
                    guard let j = doc.network.jitter_ms else { return .gray }
                    return j < 8 ? .green : (j < 20 ? .yellow : .red)
                }()
                let awdlActive = doc.network.awdl_active
                let psnOk = (doc.firewall?.psn_sys_tls_ok ?? true) || (doc.firewall?.psn_cf_tls_ok ?? true)

                TelemetryPill(label: "PING", value: rttText, dot: .green)
                TelemetryPill(label: "JITTER", value: jitText, dot: jitColor)
                TelemetryPill(label: "AWDL", value: awdlActive ? "Active" : "Clean", dot: awdlActive ? .orange : .green)
                TelemetryPill(label: "PSN", value: psnOk ? "OK" : "Blocked", dot: psnOk ? .green : .red)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring WAN latency, jitter, AWDL & PSN reachability…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.75))
            }
        }
    }

    private var inputModeSection: some View {
        let emerald = Color(red: 0.16, green: 0.80, blue: 0.56)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("INPUT MODE")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.8)
                Spacer()
                if ctrl.connectedControllerName != nil {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text(ctrl.connectedControllerBattery.map { "DualSense · \($0)" } ?? "DualSense Connected")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green.opacity(0.92))
                    }
                }
            }

            HStack(spacing: 8) {
                ModeCard(
                    title: "Trackpad",
                    subtitle: "GTA 6 Smart Pack",
                    icon: "rectangle.and.hand.point.up.left.filled",
                    selected: ctrl.inputMode == .kbm,
                    badge: nil,
                    accent: sapphire
                ) {
                    ctrl.selectInputMode(.kbm)
                }

                ModeCard(
                    title: "Hybrid",
                    subtitle: "Hot-Swap + HUD",
                    icon: "arrow.triangle.2.circlepath",
                    selected: ctrl.inputMode == .hybrid,
                    badge: ctrl.connectedControllerName != nil ? "LIVE" : nil,
                    accent: emerald
                ) {
                    ctrl.selectInputMode(.hybrid)
                }

                ModeCard(
                    title: "Native Pad",
                    subtitle: "Pure DualSense",
                    icon: "gamecontroller.fill",
                    selected: ctrl.inputMode == .controller,
                    badge: nil,
                    accent: sapphire
                ) {
                    ctrl.selectInputMode(.controller)
                }
            }
        }
    }

    private var clientSettingsCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Client")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Picker("", selection: $ctrl.client) {
                    ForEach(ClientKind.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 224)
            }

            if ctrl.client == .chiaki {
                Divider().overlay(Color.white.opacity(0.08))
                HStack {
                    Text("Stream Preset")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Spacer()
                    Picker("", selection: $ctrl.preset) {
                        ForEach(StreamPresetOption.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi AWDL Lag Fix")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("Pauses awdl0/llw0 & boosts UDP buffers via Touch ID")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Toggle("", isOn: $ctrl.privileged)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Firewall Bypass")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("Clean DNS / WARP / Tailscale if PSN is blocked")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Picker("", selection: $ctrl.firewall) {
                    ForEach(FirewallMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 126)
            }

            if ctrl.firewall == .tailscale {
                Divider().overlay(Color.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("Exit Node")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                        Spacer()
                        TextField("100.123.154.74", text: $ctrl.tailscaleExitNode)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(width: 156)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.75))
                            .onSubmit {
                                ctrl.refreshDoctor()
                            }
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(tailscaleStatusColor)
                            .frame(width: 6, height: 6)
                        Text(tailscaleStatusText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 0.75))
    }

    private var tailscaleStatusColor: Color {
        guard let fw = ctrl.doctor?.firewall else { return .gray }
        if fw.tailscale_exit_node_ready == true { return .green }
        if fw.tailscale_state == "Stopped" { return sapphire }
        if fw.tailscale_state == "NeedsLogin" || fw.tailscale_state == "NotRunning" { return .red }
        return .orange
    }

    private var tailscaleStatusText: String {
        guard let fw = ctrl.doctor?.firewall else {
            return "Checking Tailscale exit node \(ctrl.resolvedExitNode)…"
        }
        if let st = fw.tailscale_exit_node_status, !st.isEmpty {
            return st
        }
        return "Target: \(ctrl.resolvedExitNode) · auto-starts Tailscale on Launch"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.35), lineWidth: 0.75))
    }

    @ViewBuilder
    private var actionSection: some View {
        switch ctrl.phase {
        case .idle:
            let modeTag: String = {
                switch ctrl.inputMode {
                case .kbm: return "Trackpad"
                case .hybrid: return "Hybrid"
                case .controller: return "Native DualSense"
                }
            }()
            Button(action: { ctrl.launchSession() }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Launch \(ctrl.client.displayName) · \(modeTag)")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    LinearGradient(
                        colors: [sapphire, Color(red: 0.02, green: 0.39, blue: 0.88)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 0.75))
                .shadow(color: sapphire.opacity(0.32), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])

        case .launching(let msg), .restoring(let msg):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(msg)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(sapphire.opacity(0.45), lineWidth: 0.9))

        case .playing(_, let label):
            HStack(spacing: 10) {
                Button(action: { ctrl.bringActiveClientToFront() }) {
                    HStack(spacing: 7) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Focus \(label)")
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(sapphire, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: { ctrl.endActiveSession() }) {
                    Text("End Session")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(Color.red.opacity(0.24), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.red.opacity(0.45), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footerBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6.5, height: 6.5)
                Text(ctrl.statusNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
            }
            Spacer()
            Button("Restore System") {
                ctrl.runRestoreSystem()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .disabled(ctrl.isBusy)
        }
    }

    private var statusDotColor: Color {
        switch ctrl.phase {
        case .idle: return .gray
        case .launching, .restoring: return .orange
        case .playing: return .green
        }
    }
}

struct TelemetryPill: View {
    let label: String
    let value: String
    let dot: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(dot).frame(width: 5.5, height: 5.5)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.75))
    }
}

struct ModeCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let selected: Bool
    let badge: String?
    let accent: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? accent : .white.opacity(0.65))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.16), in: Capsule())
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(accent)
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (selected ? accent.opacity(0.14) : Color.white.opacity(0.045)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? accent.opacity(0.75) : Color.white.opacity(0.08), lineWidth: selected ? 1.2 : 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct IconHeaderButton: View {
    let systemName: String
    let help: String
    var spinning: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if spinning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ControlsCheatSheetView: View {
    @Binding var isPresented: Bool

    private let rows: [(String, String)] = [
        ("DualSense Hot-Swap", "Touch physical DualSense anytime · [0] switches back to Trackpad"),
        ("0 (Zero)  /  \\", "0: Lock/Release Capture · \\: Toggle Live PS→Key Bottom Bar"),
        ("F / G / O", "F: Enter/Exit (Auto Car) · G: Car · O: Aircraft"),
        ("Aiming (Ctrl / RMB)", "L2 Aim · +V: 1-Tap Switch Shoulder · +Z: Sniper · 2P: Scope Zoom"),
        ("Vehicle / Bicycle", "W/S: Gas/Brake · Space: Handbrake/Bike(✕) · Click/Q: Shoot(R1) · C: Lights/Duck(◯)"),
        ("Vehicle Extras", "Tab: Loadout Wheel(L1) · R: Melee(▢) · Shift/E: Horn/Nitro(L3) · 1-4: D-Pad"),
        ("Aircraft Flight", "W/S: Throttle · ↑↓←→: Pitch & Roll (2-Hand) · A/D + Shift/C: 1-Hand"),
        ("Aircraft Combat", "Q/E: Yaw Left(▢) / Right(◯) · Space/Click: Shoot(R1) · Tab: L1 · R: Gear(L3)"),
        ("U / I / Y / L (Hold)", "U: Hotwire (◡) · I: 360° Circle · Y: Sticky R-Stick · L: Rapid ✕"),
        ("2-Finger Scroll", "DualSense Touchpad Swipe · While Aiming (L2): Hold D-Pad Up/Down Zoom"),
        ("- / =  ·  [  ·  ;  ·  H", "Live Sens ±0.10 · PS5 Mic Mute · Ping/AWDL · Top-Right HUD"),
        ("] (Toggle)", "Auto-Sprint (Foot) · Cruise Control (Car / Aircraft)"),
        ("W A S D · Space · C · R", "Move · Jump/Swim(✕) · Crouch/Kick(◯) · Reload/Melee(▢) · E: Interact(△)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GTA 6 Smart Pack Controls")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(rows, id: \.0) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Text(item.0)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.35, green: 0.72, blue: 1.0))
                                .frame(width: 155, alignment: .leading)
                            Text(item.1)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.88))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 480, height: 440)
        .preferredColorScheme(.dark)
    }
}

// MARK: - GTA 6 Visual Sensitivity & Keybind Studio

struct SenzaKeyMapper {
    static let codeToName: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "Equals", 25: "9",
        26: "7", 27: "Minus", 28: "8", 29: "0", 30: "RightBracket", 31: "O", 32: "U",
        33: "LeftBracket", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 40: "K",
        41: "Semicolon", 42: "Backslash", 45: "N", 46: "M", 48: "Tab", 49: "Space",
        50: "Backtick", 51: "Backspace", 53: "Escape",
        56: "LeftShift", 57: "CapsLock", 58: "LeftOption", 59: "LeftControl",
        60: "RightShift", 61: "RightOption", 62: "RightControl",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
    ]

    static let allTargets: [(id: String, label: String)] = [
        ("CROSS", "✕  Cross"),
        ("CIRCLE", "◯  Circle"),
        ("SQUARE", "▢  Square"),
        ("TRIANGLE", "△  Triangle"),
        ("L1", "L1  Shoulder"),
        ("R1", "R1  Shoulder"),
        ("L2", "L2  Trigger / Aim"),
        ("R2", "R2  Trigger / Fire"),
        ("L3", "L3  Left Stick"),
        ("R3", "R3  Right Stick"),
        ("DPAD_UP", "↑  D-Pad Up"),
        ("DPAD_DOWN", "↓  D-Pad Down"),
        ("DPAD_LEFT", "←  D-Pad Left"),
        ("DPAD_RIGHT", "→  D-Pad Right"),
        ("TOUCHPAD", "▭  Touchpad"),
        ("OPTIONS", "☰  Options"),
        ("SHARE", "⎙  Create / Share"),
        ("PS", "PS  Home"),
        ("MIC", "🎙  Mic Mute"),
    ]

    static func displayKey(_ token: String) -> String {
        switch token {
        case "LeftShift", "Shift": return "L-Shift"
        case "RightShift": return "R-Shift"
        case "LeftControl", "Control": return "L-Ctrl"
        case "RightControl": return "R-Ctrl"
        case "LeftOption", "Option": return "L-Opt"
        case "RightOption": return "R-Opt"
        case "LeftBracket": return "["
        case "RightBracket": return "]"
        case "Minus": return "-"
        case "Equals": return "="
        case "Semicolon": return ";"
        case "Backslash": return "\\"
        case "Backtick": return "`"
        case "Backspace": return "⌫ Backspace"
        case "Return", "Enter": return "⏎ Return"
        case "Escape": return "Esc"
        case "Up": return "↑ Up"
        case "Down": return "↓ Down"
        case "Left": return "← Left"
        case "Right": return "→ Right"
        case "LMB": return "Left Click"
        case "RMB": return "Right Click"
        case "MMB": return "Middle Click"
        default: return token
        }
    }

    static func keyName(from event: NSEvent) -> String? {
        switch event.type {
        case .keyDown, .flagsChanged:
            return codeToName[event.keyCode]
        case .leftMouseDown:
            return "LMB"
        case .rightMouseDown:
            return "RMB"
        case .otherMouseDown:
            switch event.buttonNumber {
            case 2: return "MMB"
            case 3: return "Mouse4"
            case 4: return "Mouse5"
            default: return nil
            }
        default:
            return nil
        }
    }
}

struct KeybindEntry: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var target: String
}

enum StudioTab: String, CaseIterable, Identifiable {
    case tuning = "Tuning & Curves"
    case keybinds = "Keybinds"
    var id: String { rawValue }
}

enum KeybindSection: String, CaseIterable, Identifiable {
    case onFoot = "On-Foot"
    case vehicle = "Vehicle"
    case aircraft = "Aircraft"
    case smart = "Smart & Hotkeys"
    var id: String { rawValue }
}

@MainActor
final class ProfileStudioModel: ObservableObject {
    @Published var sensitivity: Double = 2.95
    @Published var adsScale: Double = 0.50
    @Published var sniperScale: Double = 0.45
    @Published var deadzone: Double = 0.16
    @Published var curveExponent: Double = 0.85
    @Published var smoothing: Double = 0.30
    @Published var decayHalfLifeMs: Double = 42.0
    @Published var maxVelocity: Double = 2200.0
    @Published var trackpadAccel: Double = 1.45
    @Published var invertY: Bool = false
    @Published var trackpadMode: Bool = true

    @Published var moveUp: String = "W"
    @Published var moveDown: String = "S"
    @Published var moveLeft: String = "A"
    @Published var moveRight: String = "D"
    @Published var walkModifier: String = "Z"
    @Published var walkScale: Double = 0.45

    @Published var toggleCapture: String = "0"
    @Published var toggleVehicle: String = "G"
    @Published var toggleAircraft: String = "O"
    @Published var toggleSmart: String = "T"
    @Published var smartVehicle: String = "F"
    @Published var rstickHold: String = "Y"
    @Published var hotwireAssist: String = "U"
    @Published var circleAssist: String = "I"
    @Published var rapidTap: String = "L"
    @Published var cruiseToggle: String = "RightBracket"
    @Published var sensDown: String = "Minus"
    @Published var sensUp: String = "Equals"
    @Published var micMute: String = "LeftBracket"
    @Published var enabledByDefault: Bool = true
    @Published var trackpadHaptics: Bool = true

    @Published var onFoot: [KeybindEntry] = []
    @Published var vehicle: [KeybindEntry] = []
    @Published var aircraft: [KeybindEntry] = []

    @Published var saving: Bool = false
    @Published var statusText: String? = nil
    @Published var errorText: String? = nil

    private var profileDescription: String = "GTA 6 Official Default Control Scheme — MacBook Trackpad + Keyboard"

    func profileURL() -> URL? {
        guard let cli = SenzaCLI.resolve() else { return nil }
        return cli.workingDir.appendingPathComponent("profiles/gta6.json")
    }

    func load() {
        errorText = nil
        statusText = nil
        guard let url = profileURL(),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            resetDefaults()
            errorText = "Could not open profiles/gta6.json — loaded built-in GTA 6 defaults."
            return
        }

        if let desc = root["description"] as? String { profileDescription = desc }

        if let ms = root["mouse"] as? [String: Any] {
            sensitivity = (ms["sensitivity"] as? NSNumber)?.doubleValue ?? 2.95
            adsScale = (ms["ads_sensitivity_scale"] as? NSNumber)?.doubleValue ?? 0.50
            sniperScale = (ms["sniper_sensitivity_scale"] as? NSNumber)?.doubleValue ?? 0.45
            deadzone = (ms["deadzone"] as? NSNumber)?.doubleValue ?? 0.16
            curveExponent = (ms["curve_exponent"] as? NSNumber)?.doubleValue ?? 0.85
            smoothing = (ms["smoothing"] as? NSNumber)?.doubleValue ?? 0.30
            decayHalfLifeMs = (ms["decay_half_life_ms"] as? NSNumber)?.doubleValue ?? 42.0
            maxVelocity = (ms["max_velocity_px_per_sec"] as? NSNumber)?.doubleValue ?? 2200.0
            trackpadAccel = (ms["trackpad_accel"] as? NSNumber)?.doubleValue ?? 1.45
            invertY = (ms["invert_y"] as? Bool) ?? false
            trackpadMode = (ms["trackpad_mode"] as? Bool) ?? true
        }

        if let mv = root["movement"] as? [String: Any] {
            moveUp = (mv["up"] as? String) ?? "W"
            moveDown = (mv["down"] as? String) ?? "S"
            moveLeft = (mv["left"] as? String) ?? "A"
            moveRight = (mv["right"] as? String) ?? "D"
            walkModifier = (mv["walk_modifier"] as? String) ?? "Z"
            walkScale = (mv["walk_scale"] as? NSNumber)?.doubleValue ?? 0.45
        }

        if let hk = root["hotkeys"] as? [String: Any] {
            toggleCapture = (hk["toggle_capture"] as? String) ?? "0"
            toggleVehicle = (hk["toggle_vehicle_mode"] as? String) ?? "G"
        }

        if let sm = root["smart"] as? [String: Any] {
            enabledByDefault = (sm["enabled_by_default"] as? Bool) ?? true
            trackpadHaptics = (sm["trackpad_haptics"] as? Bool) ?? true
            toggleAircraft = (sm["toggle_aircraft"] as? String) ?? "O"
            toggleSmart = (sm["toggle_smart"] as? String) ?? "T"
            smartVehicle = (sm["smart_vehicle"] as? String) ?? "F"
            rstickHold = (sm["rstick_hold"] as? String) ?? "Y"
            hotwireAssist = (sm["hotwire_assist"] as? String) ?? "U"
            circleAssist = (sm["circle_assist"] as? String) ?? "I"
            rapidTap = (sm["rapid_tap"] as? String) ?? "L"
            cruiseToggle = (sm["cruise_toggle"] as? String) ?? "RightBracket"
            sensDown = (sm["sens_down"] as? String) ?? "Minus"
            sensUp = (sm["sens_up"] as? String) ?? "Equals"
            micMute = (sm["mic_mute"] as? String) ?? "LeftBracket"
        }

        onFoot = decodeMap(root["on_foot"] as? [String: String] ?? [:])
        vehicle = decodeMap(root["vehicle"] as? [String: String] ?? [:])
        aircraft = decodeMap(root["aircraft"] as? [String: String] ?? [:])
    }

    private func decodeMap(_ dict: [String: String]) -> [KeybindEntry] {
        dict.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
            .map { KeybindEntry(key: $0.key, target: $0.value) }
    }

    func applyTuningPreset(_ kind: String) {
        switch kind {
        case "snappy":
            sensitivity = 3.40
            adsScale = 0.55
            sniperScale = 0.40
            deadzone = 0.14
            curveExponent = 0.78
            smoothing = 0.22
            trackpadAccel = 1.60
        case "precision":
            sensitivity = 2.25
            adsScale = 0.42
            sniperScale = 0.32
            deadzone = 0.16
            curveExponent = 0.95
            smoothing = 0.36
            trackpadAccel = 1.25
        default: // balanced
            sensitivity = 2.95
            adsScale = 0.50
            sniperScale = 0.45
            deadzone = 0.16
            curveExponent = 0.85
            smoothing = 0.35
            trackpadAccel = 1.45
        }
    }

    func resetDefaults() {
        applyTuningPreset("balanced")
        decayHalfLifeMs = 42.0
        maxVelocity = 2200.0
        invertY = false
        trackpadMode = true

        moveUp = "W"; moveDown = "S"; moveLeft = "A"; moveRight = "D"
        walkModifier = "Z"; walkScale = 0.45

        toggleCapture = "0"; toggleVehicle = "G"; toggleAircraft = "O"; toggleSmart = "T"
        smartVehicle = "F"; rstickHold = "Y"; hotwireAssist = "U"; circleAssist = "I"
        rapidTap = "L"; cruiseToggle = "RightBracket"; sensDown = "Minus"; sensUp = "Equals"
        micMute = "LeftBracket"; enabledByDefault = true; trackpadHaptics = true

        onFoot = decodeMap([
            "LMB": "R2", "J": "R2", "RMB": "L2", "K": "L2", "LeftControl": "L2", "LeftOption": "L2",
            "LeftShift": "L3", "Space": "CROSS", "Return": "CROSS", "C": "CIRCLE", "Backspace": "CIRCLE",
            "R": "SQUARE", "V": "SQUARE", "E": "TRIANGLE", "F": "TRIANGLE", "Q": "R1", "Tab": "L1",
            "M": "TOUCHPAD", "Escape": "OPTIONS", "N": "SHARE", "P": "PS", "B": "R3", "X": "R3",
            "1": "DPAD_UP", "2": "DPAD_RIGHT", "3": "DPAD_DOWN", "4": "DPAD_LEFT",
            "Up": "DPAD_UP", "Right": "DPAD_RIGHT", "Down": "DPAD_DOWN", "Left": "DPAD_LEFT",
        ])
        vehicle = decodeMap([
            "W": "R2", "S": "L2", "Space": "CROSS", "Return": "CROSS",
            "LMB": "R1", "J": "R1", "Q": "R1",
            "Tab": "L1", "LeftControl": "L1", "RMB": "L1",
            "C": "CIRCLE", "Backspace": "CIRCLE", "R": "SQUARE",
            "LeftShift": "L3", "E": "L3", "F": "TRIANGLE",
            "B": "R3", "X": "R3", "M": "TOUCHPAD", "V": "TOUCHPAD",
            "Escape": "OPTIONS", "P": "PS", "N": "SHARE",
            "1": "DPAD_UP", "2": "DPAD_RIGHT", "3": "DPAD_DOWN", "4": "DPAD_LEFT",
            "Up": "DPAD_UP", "Right": "DPAD_RIGHT", "Down": "DPAD_DOWN", "Left": "DPAD_LEFT",
        ])
        aircraft = decodeMap([
            "W": "R2", "S": "L2", "Q": "SQUARE", "E": "CIRCLE",
            "Space": "R1", "LMB": "R1", "J": "R1",
            "Tab": "L1", "LeftControl": "L1", "RMB": "L1",
            "R": "L3", "F": "TRIANGLE", "Return": "CROSS", "Backspace": "CIRCLE",
            "B": "R3", "X": "R3", "M": "TOUCHPAD", "V": "TOUCHPAD",
            "Escape": "OPTIONS", "P": "PS", "N": "SHARE",
            "1": "DPAD_UP", "2": "DPAD_RIGHT", "3": "DPAD_DOWN", "4": "DPAD_LEFT",
        ])
        statusText = "GTA 6 defaults staged — click Save & Hot-Reload to apply."
    }

    func saveAndHotReload() {
        guard let cli = SenzaCLI.resolve(), let url = profileURL() else {
            errorText = "Senza CLI / profiles directory not found."
            return
        }

        func encodeMap(_ list: [KeybindEntry]) -> [String: String] {
            var dict: [String: String] = [:]
            for item in list where !item.key.isEmpty && !item.target.isEmpty {
                dict[item.key] = item.target
            }
            return dict
        }

        let payload: [String: Any] = [
            "name": "gta6",
            "description": profileDescription,
            "hotkeys": [
                "toggle_capture": toggleCapture,
                "toggle_vehicle_mode": toggleVehicle,
            ],
            "mouse": [
                "sensitivity": (sensitivity * 100).rounded() / 100,
                "ads_sensitivity_scale": (adsScale * 100).rounded() / 100,
                "sniper_sensitivity_scale": (sniperScale * 100).rounded() / 100,
                "deadzone": (deadzone * 100).rounded() / 100,
                "curve_exponent": (curveExponent * 100).rounded() / 100,
                "smoothing": (smoothing * 100).rounded() / 100,
                "decay_half_life_ms": Int(decayHalfLifeMs.rounded()),
                "max_velocity_px_per_sec": Int(maxVelocity.rounded()),
                "invert_y": invertY,
                "trackpad_mode": trackpadMode,
                "trackpad_accel": (trackpadAccel * 100).rounded() / 100,
            ],
            "movement": [
                "up": moveUp,
                "down": moveDown,
                "left": moveLeft,
                "right": moveRight,
                "walk_modifier": walkModifier,
                "walk_scale": (walkScale * 100).rounded() / 100,
            ],
            "smart": [
                "enabled_by_default": enabledByDefault,
                "trackpad_haptics": trackpadHaptics,
                "toggle_smart": toggleSmart,
                "toggle_aircraft": toggleAircraft,
                "smart_vehicle": smartVehicle,
                "rstick_hold": rstickHold,
                "hotwire_assist": hotwireAssist,
                "circle_assist": circleAssist,
                "rapid_tap": rapidTap,
                "cruise_toggle": cruiseToggle,
                "sens_down": sensDown,
                "sens_up": sensUp,
                "mic_mute": micMute,
            ],
            "on_foot": encodeMap(onFoot),
            "vehicle": encodeMap(vehicle),
            "aircraft": encodeMap(aircraft),
        ]

        saving = true
        errorText = nil
        statusText = "Saving & exporting live profile…"

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: url, options: .atomic)
        } catch {
            saving = false
            errorText = "Write failed: \(error.localizedDescription)"
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = cli.executable
            proc.currentDirectoryURL = cli.workingDir
            proc.arguments = ["export-profile", "--profile", "gta6", "--json"]
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(env["PATH"] ?? "")"
            proc.environment = env

            let errPipe = Pipe()
            proc.standardOutput = Pipe()
            proc.standardError = errPipe

            var ok = false
            var errMsg: String? = nil
            do {
                try proc.run()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    ok = true
                } else {
                    errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                errMsg = error.localizedDescription
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.saving = false
                if ok {
                    self.statusText = "Saved & Live Hot-Reloaded (no restart needed)"
                } else {
                    self.errorText = errMsg?.isEmpty == false ? errMsg : "Validation failed while exporting profile."
                    self.statusText = nil
                }
            }
        }
    }
}

struct ResponseCurveCanvas: View {
    let sensitivity: Double
    let adsScale: Double
    let sniperScale: Double
    let deadzone: Double
    let curveExponent: Double

    private func evalCurve(x: Double, scale: Double) -> Double {
        let clampedX = min(max(x, 0.0), 1.0)
        if clampedX <= 0.001 { return 0.0 }
        let scaled = min(clampedX * (sensitivity / 2.5) * scale, 1.0)
        let mag = deadzone + (1.0 - deadzone) * pow(scaled, curveExponent)
        return min(max(mag, 0.0), 1.0)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let padL: CGFloat = 28
                let padR: CGFloat = 12
                let padT: CGFloat = 14
                let padB: CGFloat = 22
                let w = size.width - padL - padR
                let h = size.height - padT - padB
                let plot = CGRect(x: padL, y: padT, width: w, height: h)

                // Subtle grid
                for i in 0...4 {
                    let frac = CGFloat(i) / 4.0
                    let gx = plot.minX + w * frac
                    let gy = plot.minY + h * frac
                    var vLine = Path()
                    vLine.move(to: CGPoint(x: gx, y: plot.minY))
                    vLine.addLine(to: CGPoint(x: gx, y: plot.maxY))
                    ctx.stroke(vLine, with: .color(.white.opacity(0.07)), lineWidth: 0.75)

                    var hLine = Path()
                    hLine.move(to: CGPoint(x: plot.minX, y: gy))
                    hLine.addLine(to: CGPoint(x: plot.maxX, y: gy))
                    ctx.stroke(hLine, with: .color(.white.opacity(0.07)), lineWidth: 0.75)
                }

                // Deadzone shaded band
                let dzH = h * CGFloat(deadzone)
                let dzRect = CGRect(x: plot.minX, y: plot.maxY - dzH, width: w, height: dzH)
                ctx.fill(Path(dzRect), with: .color(Color.orange.opacity(0.11)))
                var dzLine = Path()
                dzLine.move(to: CGPoint(x: plot.minX, y: plot.maxY - dzH))
                dzLine.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY - dzH))
                ctx.stroke(dzLine, with: .color(Color.orange.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                // Linear reference diagonal
                var diag = Path()
                diag.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                diag.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
                ctx.stroke(diag, with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 4]))

                func makeCurvePath(scale: Double) -> Path {
                    var p = Path()
                    let steps = 80
                    for s in 0...steps {
                        let nx = Double(s) / Double(steps)
                        let ny = evalCurve(x: nx, scale: scale)
                        let pt = CGPoint(x: plot.minX + CGFloat(nx) * w, y: plot.maxY - CGFloat(ny) * h)
                        if s == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    return p
                }

                // Sniper curve (violet)
                ctx.stroke(
                    makeCurvePath(scale: adsScale * sniperScale),
                    with: .color(Color(red: 0.76, green: 0.54, blue: 1.0).opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                // ADS curve (amber)
                ctx.stroke(
                    makeCurvePath(scale: adsScale),
                    with: .color(Color(red: 1.0, green: 0.76, blue: 0.30).opacity(0.92)),
                    style: StrokeStyle(lineWidth: 1.8, dash: [6, 3])
                )
                // Hipfire / Normal curve (sapphire cyan)
                ctx.stroke(
                    makeCurvePath(scale: 1.0),
                    with: .color(Color(red: 0.25, green: 0.78, blue: 1.0)),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
            }

            HStack(spacing: 12) {
                LegendChip(color: Color(red: 0.25, green: 0.78, blue: 1.0), label: "Aim \(String(format: "%.2fx", sensitivity))")
                LegendChip(color: Color(red: 1.0, green: 0.76, blue: 0.30), label: "ADS \(Int((adsScale * 100).rounded()))%")
                LegendChip(color: Color(red: 0.76, green: 0.54, blue: 1.0), label: "Sniper \(Int((sniperScale * 100).rounded()))%")
                LegendChip(color: Color.orange, label: "DZ \(Int((deadzone * 100).rounded()))%")
            }
            .padding(.leading, 34)
            .padding(.top, 6)
        }
        .frame(height: 146)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.75))
    }
}

struct LegendChip: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.84))
        }
    }
}

struct StudioSliderRow: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(format(value))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 1.0))
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct KeyCaptureButton: View {
    @Binding var keyName: String
    @State private var isRecording: Bool = false
    @State private var monitor: Any? = nil

    private let sapphire = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { isRecording ? stopRecording() : startRecording() }) {
                Text(isRecording ? "Press key / right-click…" : SenzaKeyMapper.displayKey(keyName))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isRecording ? Color(red: 0.45, green: 0.88, blue: 1.0) : .white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .frame(minWidth: 106)
                    .background(
                        (isRecording ? sapphire.opacity(0.24) : Color.white.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isRecording ? sapphire : Color.white.opacity(0.14), lineWidth: isRecording ? 1.2 : 0.75)
                    )
            }
            .buttonStyle(.plain)

            if isRecording {
                Button("LMB") {
                    keyName = "LMB"
                    stopRecording()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))

                Button("Esc") {
                    keyName = "Escape"
                    stopRecording()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))

                Button("✕") {
                    stopRecording()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .rightMouseDown, .otherMouseDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if event.type == .keyDown && event.keyCode == 53 {
                stopRecording()
                return nil
            }
            if event.type == .flagsChanged {
                let mods = event.modifierFlags.intersection([.shift, .control, .option])
                if event.keyCode != 57 && mods.isEmpty {
                    return event
                }
            }
            if let mapped = SenzaKeyMapper.keyName(from: event) {
                keyName = mapped
                stopRecording()
                return nil
            }
            return event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

struct ProfileStudioView: View {
    @Binding var isPresented: Bool
    @StateObject private var model = ProfileStudioModel()
    @State private var activeTab: StudioTab = .tuning
    @State private var keybindSection: KeybindSection = .onFoot

    private let sapphire = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        VStack(spacing: 12) {
            // Top bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GTA 6 Sensitivity & Keybind Studio")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("Edits profiles/gta6.json · Live hot-reloads inside running Remote Play")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Picker("", selection: $activeTab) {
                    ForEach(StudioTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            Divider().overlay(Color.white.opacity(0.08))

            if activeTab == .tuning {
                tuningContent
            } else {
                keybindsContent
            }

            if let err = model.errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider().overlay(Color.white.opacity(0.08))

            // Bottom action bar
            HStack(spacing: 10) {
                Button("Reset GTA 6 Defaults") {
                    model.resetDefaults()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))

                if let status = model.statusText {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text(status)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green.opacity(0.92))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button("Close") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])

                Button(action: { model.saveAndHotReload() }) {
                    HStack(spacing: 6) {
                        if model.saving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "bolt.fill").font(.system(size: 11))
                        }
                        Text("Save & Hot-Reload")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(sapphire, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.saving)
            }
        }
        .padding(18)
        .frame(width: 640, height: 590)
        .preferredColorScheme(.dark)
        .onAppear { model.load() }
    }

    private var tuningContent: some View {
        VStack(spacing: 10) {
            ResponseCurveCanvas(
                sensitivity: model.sensitivity,
                adsScale: model.adsScale,
                sniperScale: model.sniperScale,
                deadzone: model.deadzone,
                curveExponent: model.curveExponent
            )

            HStack(spacing: 8) {
                Text("Quick Curve:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                presetPill("Balanced GTA 6") { model.applyTuningPreset("balanced") }
                presetPill("Snappy Flick") { model.applyTuningPreset("snappy") }
                presetPill("Precision Sniper") { model.applyTuningPreset("precision") }
                Spacer()
            }

            ScrollView {
                VStack(spacing: 7) {
                    StudioSliderRow(
                        title: "Aim Sensitivity",
                        subtitle: "Trackpad / mouse camera speed",
                        value: $model.sensitivity,
                        range: 0.50...6.00,
                        step: 0.05
                    ) { String(format: "%.2fx", $0) }

                    HStack(spacing: 8) {
                        StudioSliderRow(
                            title: "ADS Scale",
                            subtitle: "L2 aiming",
                            value: $model.adsScale,
                            range: 0.15...1.00,
                            step: 0.05
                        ) { "\(Int(($0 * 100).rounded()))%" }

                        StudioSliderRow(
                            title: "Sniper Scale",
                            subtitle: "L2 + Z",
                            value: $model.sniperScale,
                            range: 0.15...1.00,
                            step: 0.05
                        ) { "\(Int(($0 * 100).rounded()))%" }
                    }

                    HStack(spacing: 8) {
                        StudioSliderRow(
                            title: "Stick Deadzone",
                            subtitle: "GTA inner zone",
                            value: $model.deadzone,
                            range: 0.00...0.40,
                            step: 0.01
                        ) { "\(Int(($0 * 100).rounded()))%" }

                        StudioSliderRow(
                            title: "Curve Exponent",
                            subtitle: "<1 snappy · >1 micro",
                            value: $model.curveExponent,
                            range: 0.45...1.80,
                            step: 0.05
                        ) { String(format: "%.2f", $0) }
                    }

                    HStack(spacing: 8) {
                        StudioSliderRow(
                            title: "Smoothing",
                            subtitle: "EMA filter",
                            value: $model.smoothing,
                            range: 0.00...0.80,
                            step: 0.02
                        ) { "\(Int(($0 * 100).rounded()))%" }

                        StudioSliderRow(
                            title: "Trackpad Accel",
                            subtitle: "Fast flick boost",
                            value: $model.trackpadAccel,
                            range: 0.80...2.50,
                            step: 0.05
                        ) { String(format: "%.2fx", $0) }
                    }

                    StudioSliderRow(
                        title: "Walk Speed Scale",
                        subtitle: "Hold '\(SenzaKeyMapper.displayKey(model.walkModifier))' slow walk",
                        value: $model.walkScale,
                        range: 0.20...0.85,
                        step: 0.05
                    ) { "\(Int(($0 * 100).rounded()))%" }

                    HStack(spacing: 16) {
                        Toggle("Trackpad Mode", isOn: $model.trackpadMode)
                        Toggle("Force Touch Haptics", isOn: $model.trackpadHaptics)
                        Toggle("Smart Pack Default", isOn: $model.enabledByDefault)
                        Toggle("Invert Y", isOn: $model.invertY)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func presetPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.75))
    }

    private var keybindsContent: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("", selection: $keybindSection) {
                    ForEach(KeybindSection.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)

                if keybindSection != .smart {
                    Button(action: addBindingForCurrentSection) {
                        Label("Add", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(sapphire.opacity(0.24), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(sapphire.opacity(0.6), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView {
                switch keybindSection {
                case .onFoot:
                    bindingListEditor(entries: $model.onFoot)
                case .vehicle:
                    bindingListEditor(entries: $model.vehicle)
                case .aircraft:
                    bindingListEditor(entries: $model.aircraft)
                case .smart:
                    smartAndHotkeysEditor
                }
            }
        }
    }

    private func addBindingForCurrentSection() {
        let row = KeybindEntry(key: "H", target: "CROSS")
        switch keybindSection {
        case .onFoot: model.onFoot.insert(row, at: 0)
        case .vehicle: model.vehicle.insert(row, at: 0)
        case .aircraft: model.aircraft.insert(row, at: 0)
        case .smart: break
        }
    }

    private func bindingListEditor(entries: Binding<[KeybindEntry]>) -> some View {
        VStack(spacing: 5) {
            ForEach(entries) { $entry in
                HStack(spacing: 10) {
                    KeyCaptureButton(keyName: $entry.key)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Picker("", selection: $entry.target) {
                        ForEach(SenzaKeyMapper.allTargets, id: \.id) { t in
                            Text(t.label).tag(t.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 195)
                    Spacer()
                    Button(action: {
                        entries.wrappedValue.removeAll { $0.id == entry.id }
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var smartAndHotkeysEditor: some View {
        VStack(spacing: 6) {
            hotkeyRow("Toggle Capture (Lock / Release)", key: $model.toggleCapture)
            hotkeyRow("Vehicle Mode Toggle", key: $model.toggleVehicle)
            hotkeyRow("Aircraft Mode Toggle", key: $model.toggleAircraft)
            hotkeyRow("Smart Pack Mode Toggle", key: $model.toggleSmart)
            Divider().overlay(Color.white.opacity(0.08))
            hotkeyRow("Move Up (Left Stick +Y)", key: $model.moveUp)
            hotkeyRow("Move Down (Left Stick -Y)", key: $model.moveDown)
            hotkeyRow("Move Left (Left Stick -X)", key: $model.moveLeft)
            hotkeyRow("Move Right (Left Stick +X)", key: $model.moveRight)
            hotkeyRow("Slow Walk / Sniper Precision", key: $model.walkModifier)
            Divider().overlay(Color.white.opacity(0.08))
            hotkeyRow("Auto-Vehicle Enter/Exit (Smart)", key: $model.smartVehicle)
            hotkeyRow("Hotwire Sweep Assist (◡)", key: $model.hotwireAssist)
            hotkeyRow("360° Full Circle Assist (↻)", key: $model.circleAssist)
            hotkeyRow("Sticky Right-Stick Hold", key: $model.rstickHold)
            hotkeyRow("Rapid-Tap ✕ (QTE / Bike)", key: $model.rapidTap)
            hotkeyRow("Cruise Control / Auto-Sprint", key: $model.cruiseToggle)
            hotkeyRow("Live Sensitivity Down (−0.10)", key: $model.sensDown)
            hotkeyRow("Live Sensitivity Up (+0.10)", key: $model.sensUp)
            hotkeyRow("PS5 Mic Mute", key: $model.micMute)
        }
    }

    private func hotkeyRow(_ label: String, key: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
            Spacer()
            KeyCaptureButton(keyName: key)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - AppDelegate (Sandwich Window + Menu Bar Status Item)

@MainActor
final class SenzaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let ctrl = SenzaController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let img = SenzaCLI.appIconImage() {
            NSApp.applicationIconImage = img
        }

        setupMainWindow()
        setupStatusItem()

        ctrl.onPhaseChanged = { [weak self] _ in
            self?.rebuildStatusMenu()
        }
        rebuildStatusMenu()

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if case .playing = ctrl.phase {
            ctrl.bringActiveClientToFront()
        } else {
            ctrl.showMainWindowToFront()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ctrl.endActiveSession()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if case .playing = ctrl.phase {
            // Keep running cleanly in menu bar while Remote Play is active
            sender.orderOut(nil)
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    private func setupMainWindow() {
        let hosting = NSHostingController(rootView: SenzaRootView(ctrl: ctrl))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 486, height: 648),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Senza"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = .clear
        win.isOpaque = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentViewController = hosting
        win.center()
        win.delegate = self

        mainWindow = win
        ctrl.mainWindow = win
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else { return }

        if let button = item.button {
            let symbolName: String
            switch ctrl.phase {
            case .playing:
                symbolName = "gamecontroller.fill"
            default:
                symbolName = "gamecontroller"
            }
            let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Senza")
            img?.isTemplate = true
            button.image = img
        }

        let menu = NSMenu()

        switch ctrl.phase {
        case .playing(_, let label):
            let statusHeader = NSMenuItem(title: "● Active — \(label)", action: nil, keyEquivalent: "")
            statusHeader.isEnabled = false
            menu.addItem(statusHeader)
            menu.addItem(.separator())

            let focusItem = NSMenuItem(title: "Bring \(label) to Front", action: #selector(menuBringClientToFront), keyEquivalent: "r")
            focusItem.target = self
            menu.addItem(focusItem)

            let studioItem = NSMenuItem(title: "GTA 6 Tuning & Keybind Studio…", action: #selector(menuShowStudio), keyEquivalent: ",")
            studioItem.target = self
            menu.addItem(studioItem)

            let showItem = NSMenuItem(title: "Show Senza Launcher", action: #selector(menuShowWindow), keyEquivalent: "d")
            showItem.target = self
            menu.addItem(showItem)

            let controlsItem = NSMenuItem(title: "GTA 6 Controls Cheat Sheet", action: #selector(menuShowControls), keyEquivalent: "")
            controlsItem.target = self
            menu.addItem(controlsItem)

            menu.addItem(.separator())

            let endItem = NSMenuItem(title: "End Session & Restore System", action: #selector(menuEndSession), keyEquivalent: "")
            endItem.target = self
            menu.addItem(endItem)

        case .launching(let msg), .restoring(let msg):
            let header = NSMenuItem(title: msg, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
            let showItem = NSMenuItem(title: "Show Senza", action: #selector(menuShowWindow), keyEquivalent: "")
            showItem.target = self
            menu.addItem(showItem)

        case .idle:
            let launchItem = NSMenuItem(title: "Launch \(ctrl.client.displayName)", action: #selector(menuQuickLaunch), keyEquivalent: "l")
            launchItem.target = self
            menu.addItem(launchItem)

            let studioItem = NSMenuItem(title: "GTA 6 Tuning & Keybind Studio…", action: #selector(menuShowStudio), keyEquivalent: ",")
            studioItem.target = self
            menu.addItem(studioItem)

            let showItem = NSMenuItem(title: "Open Senza Window", action: #selector(menuShowWindow), keyEquivalent: "")
            showItem.target = self
            menu.addItem(showItem)

            let restoreItem = NSMenuItem(title: "Restore System (AWDL / DNS)", action: #selector(menuRestoreSystem), keyEquivalent: "")
            restoreItem.target = self
            menu.addItem(restoreItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Senza", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    @objc private func menuBringClientToFront() {
        ctrl.bringActiveClientToFront()
    }

    @objc private func menuShowWindow() {
        ctrl.showMainWindowToFront()
    }

    @objc private func menuShowStudio() {
        ctrl.showStudioSheet = true
        ctrl.showMainWindowToFront()
    }

    @objc private func menuShowControls() {
        ctrl.showControlsSheet = true
        ctrl.showMainWindowToFront()
    }

    @objc private func menuQuickLaunch() {
        ctrl.launchSession()
    }

    @objc private func menuEndSession() {
        ctrl.endActiveSession()
    }

    @objc private func menuRestoreSystem() {
        ctrl.runRestoreSystem()
    }

    @objc private func menuQuit() {
        ctrl.endActiveSession()
        NSApp.terminate(nil)
    }
}

@main
struct SenzaEntry {
    static func main() {
        let app = NSApplication.shared
        let delegate = SenzaAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
