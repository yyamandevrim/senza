import AppKit
import Foundation
import GameController
import SwiftUI

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
                        TextField("auto (tailnet)", text: $ctrl.tailscaleExitNode)
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
                        Spacer(minLength: 4)
                        let tunActive = ctrl.doctor?.system_tunnel?.active == true
                        Button(action: { ctrl.toggleSystemTunnel() }) {
                            HStack(spacing: 4) {
                                if ctrl.tunnelBusy {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Circle()
                                        .fill(tunActive ? Color.green : Color.white.opacity(0.35))
                                        .frame(width: 5.5, height: 5.5)
                                }
                                Text(tunActive ? "Mac Tunnel ON" : "Whole Mac")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(tunActive ? .green : .white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                (tunActive ? Color.green.opacity(0.16) : Color.white.opacity(0.08)),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().stroke(
                                    tunActive ? Color.green.opacity(0.42) : Color.white.opacity(0.14),
                                    lineWidth: 0.75
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(ctrl.tunnelBusy)
                        .help("Route entire Mac through Tailscale exit node (auto WARP-bootstrap on FortiGate)")
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
            return "Checking Tailscale exit node \(ctrl.exitNodeLabel)…"
        }
        if let st = fw.tailscale_exit_node_status, !st.isEmpty {
            return st
        }
        return "Target: \(ctrl.exitNodeLabel) · auto-starts Tailscale on Launch"
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
