import AppKit
import Foundation
import SwiftUI

// MARK: - Models

enum InputMode: String, CaseIterable, Identifiable {
    case kbm = "kbm"
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

    @AppStorage("senza.inputMode") var inputModeRaw: String = InputMode.kbm.rawValue
    @AppStorage("senza.client") var clientRaw: String = ClientKind.sony.rawValue
    @AppStorage("senza.preset") var presetRaw: String = StreamPresetOption.auto.rawValue
    @AppStorage("senza.privileged") var privileged: Bool = true
    @AppStorage("senza.firewall") var firewallRaw: String = FirewallMode.off.rawValue
    @AppStorage("senza.host") var probeHost: String = "1.1.1.1"

    @Published var phase: SessionPhase = .idle
    @Published var statusNote: String = "Ready to connect"
    @Published var doctor: DoctorResponse? = nil
    @Published var doctorLoading: Bool = false
    @Published var showControlsSheet: Bool = false
    @Published var errorMessage: String? = nil

    private var launcherProcess: Process? = nil
    private var childPid: Int32 = 0
    private var childBundleURL: URL? = nil
    private var handoffDone: Bool = false

    weak var mainWindow: NSWindow?
    var onPhaseChanged: ((SessionPhase) -> Void)?

    var inputMode: InputMode {
        get { InputMode(rawValue: inputModeRaw) ?? .kbm }
        set { inputModeRaw = newValue.rawValue; objectWillChange.send() }
    }

    var client: ClientKind {
        get { ClientKind(rawValue: clientRaw) ?? .sony }
        set { clientRaw = newValue.rawValue; objectWillChange.send() }
    }

    var preset: StreamPresetOption {
        get { StreamPresetOption(rawValue: presetRaw) ?? .auto }
        set { presetRaw = newValue.rawValue; objectWillChange.send() }
    }

    var firewall: FirewallMode {
        get { FirewallMode(rawValue: firewallRaw) ?? .off }
        set { firewallRaw = newValue.rawValue; objectWillChange.send() }
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

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = cli.executable
            proc.currentDirectoryURL = cli.workingDir
            proc.arguments = ["doctor", "--host", host, "--json"]
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
        if inputMode == .controller {
            args.append("--controller")
        }
        if privileged {
            args += ["--privileged", "--gui-sudo"]
        }
        if firewall != .off {
            args += ["--bypass-firewall", firewall.rawValue]
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

        setPhase(.launching(privileged ? "Authorizing Wi-Fi & UDP boost…" : "Launching \(client.displayName)…"))
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
        .frame(width: 456, height: 590)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $ctrl.showControlsSheet) {
            ControlsCheatSheetView(isPresented: $ctrl.showControlsSheet)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("INPUT MODE")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.8)

            HStack(spacing: 10) {
                ModeCard(
                    title: "Trackpad + Keys",
                    subtitle: "GTA 6 Smart Pack",
                    icon: "rectangle.and.hand.point.up.left.filled",
                    selected: ctrl.inputMode == .kbm,
                    accent: sapphire
                ) {
                    ctrl.inputMode = .kbm
                }

                ModeCard(
                    title: "DualSense",
                    subtitle: "Physical Controller",
                    icon: "gamecontroller.fill",
                    selected: ctrl.inputMode == .controller,
                    accent: sapphire
                ) {
                    ctrl.inputMode = .controller
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
                Picker("", selection: Binding(get: { ctrl.client }, set: { ctrl.client = $0 })) {
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
                    Picker("", selection: Binding(get: { ctrl.preset }, set: { ctrl.preset = $0 })) {
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
                Picker("", selection: Binding(get: { ctrl.firewall }, set: { ctrl.firewall = $0 })) {
                    ForEach(FirewallMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 126)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 0.75))
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
            Button(action: { ctrl.launchSession() }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Launch \(ctrl.client.displayName)")
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
    let accent: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? accent : .white.opacity(0.65))
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
        ("0 (Zero)", "Toggle Trackpad + Keyboard capture ON / OFF"),
        ("F / G / O", "F: Enter/Exit (Auto Car) · G: Car · O: Aircraft"),
        ("2-Finger Scroll", "DualSense Touchpad Swipe · Aiming (L2): Sniper Zoom"),
        ("U / I / Y (Hold)", "U: Hotwire (◡) · I: 360° Circle · Y: Sticky R-Stick"),
        ("L (Hold)", "Rapid-Tap ✕ (12.5 Hz) — Bike / Swim / QTE"),
        ("- / =", "Live Sensitivity ±0.10 (auto-saved to gta6.json)"),
        ("CapsLock + Z", "Aim (L2) + Extra Precision Sniper Scale"),
        ("[  /  ;  /  H  /  T", "PS5 Mic Mute · Ping/AWDL Pill · HUD · Smart Mode"),
        ("] (Toggle)", "Auto-Sprint (Foot) · Cruise Control (Car / Air)"),
        ("Trackpad / J", "Look & Aim (R-Stick) · Click / J = R2 Shoot"),
        ("W A S D / Shift / Space", "Move · Run (L3) · Jump (✕) / Handbrake (Car R1)"),
        ("Aircraft Pitch / Rudder", "↑/↓ or Shift/C: Pitch · Q/E or ←/→: Rudder · R: Gear"),
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
        .frame(width: 470, height: 420)
        .preferredColorScheme(.dark)
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
            contentRect: NSRect(x: 0, y: 0, width: 456, height: 590),
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
