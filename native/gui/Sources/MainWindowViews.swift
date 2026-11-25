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

// MARK: - Main window

struct SenzaRootView: View {
    @ObservedObject var ctrl: SenzaController
    @State private var networkName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 32)
                .padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 20) {
                    ConnectionCard(ctrl: ctrl)
                    inputSection
                    settings
                    if let err = ctrl.errorMessage { errorNote(err) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            actions
                .padding(.horizontal, 20)
                .padding(.top, 12)
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 480, height: 760)
        .background(Theme.window)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $ctrl.showControlsSheet) {
            ControlsCheatSheetView(isPresented: $ctrl.showControlsSheet)
        }
        .sheet(isPresented: $ctrl.showStudioSheet) {
            ProfileStudioView(isPresented: $ctrl.showStudioSheet)
        }
        .sheet(isPresented: $ctrl.showOnboarding) {
            OnboardingSheet(ctrl: ctrl)
        }
        .onAppear {
            ctrl.refreshDoctor()
            ctrl.refreshOnboarding(presentIfNeeded: true)
        }
    }

    // Header: product name + the network Senza recognised. Tools on the right.
    private var header: some View {
        HStack(spacing: 12) {
            if let img = SenzaCLI.appIconImage() {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Senza").font(Theme.title()).foregroundStyle(Theme.text1)
                Text(networkLine).font(Theme.small()).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                ToolButton(symbol: "slider.horizontal.3", help: "Sensitivity and key bindings") { ctrl.showStudioSheet = true }
                ToolButton(symbol: "keyboard", help: "Controls") { ctrl.showControlsSheet = true }
                ToolButton(symbol: "checklist", help: "Setup checklist") {
                    ctrl.refreshOnboarding()
                    ctrl.showOnboarding = true
                }
                ToolButton(symbol: "arrow.clockwise", help: "Measure again", busy: ctrl.doctorLoading) { ctrl.refreshDoctor() }
            }
        }
    }

    private var networkLine: String {
        guard let net = ctrl.doctor?.network_profile, net.id != nil else {
            return ctrl.doctor == nil ? "Checking this network" : "Network not recognised"
        }
        let router = net.router_ip.map { "router \($0)" } ?? ""
        if let name = ctrl.networkName { return "\(name) · \(router)" }
        return "Unsaved network · \(router)"
    }

    // Input mode: three quiet options, the selected one is a surface step.
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Input").font(Theme.small(.medium)).foregroundStyle(Theme.text2)
                Spacer()
                if ctrl.connectedControllerName != nil {
                    HStack(spacing: 6) {
                        StatusDot(tone: .good)
                        Text(ctrl.connectedControllerBattery.map { "DualSense \($0)" } ?? "DualSense connected")
                            .font(Theme.small()).foregroundStyle(Theme.text2)
                    }
                }
            }
            HStack(spacing: 4) {
                ModeOption(title: "Trackpad", symbol: "rectangle.and.hand.point.up.left", selected: ctrl.inputMode == .kbm) {
                    ctrl.selectInputMode(.kbm)
                }
                ModeOption(title: "Hybrid", symbol: "arrow.left.arrow.right", selected: ctrl.inputMode == .hybrid) {
                    ctrl.selectInputMode(.hybrid)
                }
                ModeOption(title: "DualSense", symbol: "gamecontroller", selected: ctrl.inputMode == .controller) {
                    ctrl.selectInputMode(.controller)
                }
            }
            .padding(4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            Text(modeDescription).font(Theme.small()).foregroundStyle(Theme.text3)
        }
    }

    private var modeDescription: String {
        switch ctrl.inputMode {
        case .kbm: return "Trackpad and keyboard become a virtual DualSense"
        case .hybrid: return "Play on the DualSense, press 0 to switch to the trackpad any time"
        case .controller: return "Your DualSense as is, with the network and Wi-Fi fixes"
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session").font(Theme.small(.medium)).foregroundStyle(Theme.text2)
            SettingsGroup {
                SettingRow(title: "Client") {
                    Picker("", selection: $ctrl.client) {
                        ForEach(ClientKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                if ctrl.client == .chiaki {
                    SettingRow(title: "Stream preset", detail: "Auto uses this network's history") {
                        Picker("", selection: $ctrl.preset) {
                            ForEach(StreamPresetOption.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                }
                SettingRow(title: "Wi-Fi lag fix", detail: wifiDetail) {
                    Toggle("", isOn: $ctrl.privileged).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                SettingRow(title: "Firewall bypass", detail: "When PSN or UDP is blocked on this network",
                           showDivider: ctrl.firewall == .tailscale || ctrl.doctor?.network_profile?.id != nil) {
                    Picker("", selection: $ctrl.firewall) {
                        ForEach(FirewallMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 132)
                }
                if ctrl.firewall == .tailscale {
                    SettingRow(title: "Exit node", detail: "Empty uses your config or the tailnet") {
                        TextField("auto", text: $ctrl.tailscaleExitNode)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.mono(12))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 150)
                            .onSubmit { ctrl.refreshDoctor() }
                    }
                    SettingRow(title: "Route the whole Mac", detail: tailscaleStatus,
                               showDivider: ctrl.doctor?.network_profile?.id != nil) {
                        if ctrl.tunnelBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { ctrl.doctor?.system_tunnel?.active == true },
                                set: { _ in ctrl.toggleSystemTunnel() }
                            ))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        }
                    }
                }
                if ctrl.doctor?.network_profile?.id != nil { networkRow }
            }
        }
    }

    private var wifiDetail: String {
        let base = "Pauses AWDL and raises UDP buffers"
        return ctrl.doctor?.helper?.ready == true ? base : base + ", asks for Touch ID"
    }

    private var tailscaleStatus: String {
        if let st = ctrl.doctor?.firewall?.tailscale_exit_node_status, !st.isEmpty { return st }
        return "Through \(ctrl.exitNodeLabel)"
    }

    @ViewBuilder private var networkRow: some View {
        if let name = ctrl.networkName {
            SettingRow(title: "Remembered for \(name)", detail: "These settings load when you join this network",
                       showDivider: false) {
                Button("Update") { ctrl.saveNetworkProfile(name: name) }
                    .buttonStyle(QuietButtonStyle(height: 28))
            }
        } else {
            SettingRow(title: "Remember for this network", detail: "Loads these settings next time",
                       showDivider: false) {
                HStack(spacing: 8) {
                    TextField("Home", text: $networkName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                    Button("Save") { ctrl.saveNetworkProfile(name: networkName) }
                        .buttonStyle(QuietButtonStyle(height: 28))
                        .disabled(networkName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func errorNote(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(tone: .warn)
            Text(message).font(Theme.small()).foregroundStyle(Theme.text1).lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    @ViewBuilder private var actions: some View {
        switch ctrl.phase {
        case .idle:
            Button(action: { ctrl.launchSession() }) {
                Text("Launch \(ctrl.client.displayName)")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: [])
        case .launching(let msg), .restoring(let msg):
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(msg).font(Theme.body()).foregroundStyle(Theme.text1).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.rControl + 2, style: .continuous))
        case .playing(_, let label):
            HStack(spacing: 8) {
                Button("Show \(label)") { ctrl.bringActiveClientToFront() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("End session") { ctrl.endActiveSession() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            StatusDot(tone: phaseTone)
            Text(ctrl.statusNote).font(Theme.small()).foregroundStyle(Theme.text3).lineLimit(1)
            Spacer()
            Button("Restore system") { ctrl.runRestoreSystem() }
                .buttonStyle(.plain)
                .font(Theme.small())
                .foregroundStyle(Theme.text2)
                .disabled(ctrl.isBusy)
        }
    }

    private var phaseTone: StatusTone {
        switch ctrl.phase {
        case .idle: return .neutral
        case .launching, .restoring: return .warn
        case .playing: return .good
        }
    }
}

// MARK: - Connection card (the one rich element: live figure + this network's latency history)

struct ConnectionCard: View {
    @ObservedObject var ctrl: SenzaController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latency to \(ctrl.doctor?.network.host ?? ctrl.probeHost)")
                        .font(Theme.small()).foregroundStyle(Theme.text3)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(rtt).font(Theme.figure()).foregroundStyle(Theme.text1)
                        Text("ms").font(Theme.body()).foregroundStyle(Theme.text3)
                    }
                }
                Spacer()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    stat("Jitter", jitter, jitterTone)
                    stat("Loss", loss, lossTone)
                    stat("AWDL", awdl, ctrl.doctor?.network.awdl_active == true ? .warn : .good)
                    stat("PSN", psn, psnTone)
                }
            }
            LatencyChart(points: ctrl.recentRtt)
                .frame(height: 56)
            Text(historyLine).font(Theme.caption()).foregroundStyle(Theme.text3)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    private func stat(_ label: String, _ value: String, _ tone: StatusTone) -> some View {
        GridRow {
            Text(label).font(Theme.small()).foregroundStyle(Theme.text3)
            HStack(spacing: 6) {
                Text(value)
                    .font(value.first?.isNumber == true ? Theme.mono(12) : Theme.small())
                    .foregroundStyle(Theme.text1)
                StatusDot(tone: tone)
            }
            .gridColumnAlignment(.trailing)
        }
    }

    private var net: DoctorResponse.Network? { ctrl.doctor?.network }
    private var rtt: String { net?.rtt_median_ms.map { String(format: "%.0f", $0) } ?? "–" }
    private var jitter: String { net?.jitter_ms.map { String(format: "%.1f ms", $0) } ?? "–" }
    private var loss: String { net.map { String(format: "%.0f%%", $0.packet_loss_pct) } ?? "–" }
    private var awdl: String { net == nil ? "–" : (net!.awdl_active ? "on" : "off") }
    private var psnOk: Bool? {
        guard let fw = ctrl.doctor?.firewall else { return nil }
        return fw.psn_sys_tls_ok || fw.psn_cf_tls_ok
    }
    private var psn: String { psnOk.map { $0 ? "reachable" : "blocked" } ?? "–" }
    private var jitterTone: StatusTone {
        guard let j = net?.jitter_ms else { return .neutral }
        return j < 8 ? .good : (j < 20 ? .warn : .bad)
    }
    private var lossTone: StatusTone {
        guard let l = net?.packet_loss_pct else { return .neutral }
        return l < 0.5 ? .good : (l < 3 ? .warn : .bad)
    }
    private var psnTone: StatusTone { psnOk.map { $0 ? .good : .bad } ?? .neutral }

    private var historyLine: String {
        guard let h = ctrl.doctor?.history, h.probes >= 2 else {
            return "History builds up as you play on this network"
        }
        var parts = ["\(h.probes) checks on this network"]
        if let p50 = h.rtt_median_ms { parts.append(String(format: "median %.0f ms", p50)) }
        if let j = h.jitter_p75_ms { parts.append(String(format: "jitter p75 %.1f ms", j)) }
        if h.play_minutes >= 1 { parts.append(String(format: "%.0f min played", h.play_minutes)) }
        return parts.joined(separator: " · ")
    }
}

/// Recent latency on this network: muted grid, one accent line, the latest point marked.
struct LatencyChart: View {
    let points: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max((points.max() ?? 40) * 1.15, 20)
            ZStack(alignment: .topLeading) {
                ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h * f))
                        p.addLine(to: CGPoint(x: w, y: h * f))
                    }
                    .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: f == 1.0 ? [] : [2, 4]))
                }
                Text(String(format: "%.0f ms", maxV)).font(Theme.mono(10, .regular)).foregroundStyle(Theme.text3)
                    .offset(y: -2)
                if points.count >= 2 {
                    let step = w / CGFloat(points.count - 1)
                    let pt: (Int) -> CGPoint = { i in
                        CGPoint(x: CGFloat(i) * step, y: h - CGFloat(points[i] / maxV) * h)
                    }
                    Path { p in
                        p.move(to: pt(0))
                        for i in 1..<points.count { p.addLine(to: pt(i)) }
                    }
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        .position(pt(points.count - 1))
                } else {
                    Text("No checks yet").font(Theme.caption()).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

struct ModeOption: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .regular))
                    .frame(width: 18)
                Text(title).font(Theme.body(.medium))
            }
            .foregroundStyle(selected ? Theme.text1 : Theme.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(selected ? Theme.surfaceRaised : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.rControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rControl, style: .continuous)
                .stroke(selected ? Color.white.opacity(0.12) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

struct ToolButton: View {
    let symbol: String
    let help: String
    var busy: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).font(.system(size: 14, weight: .regular))
                }
            }
            .foregroundStyle(hover ? Theme.text1 : Theme.text2)
            .frame(width: 28, height: 28)
            .background(hover ? Theme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: Theme.rControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - First-run checklist

struct OnboardingSheet: View {
    @ObservedObject var ctrl: SenzaController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Senza").font(Theme.title()).foregroundStyle(Theme.text1)
                Text("What PS Remote Play needs on this Mac. Required items first.")
                    .font(Theme.small()).foregroundStyle(Theme.text3)
            }
            if let checks = ctrl.onboard?.checks {
                SettingsGroup {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { idx, check in
                        checkRow(check, last: idx == checks.count - 1)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking").font(Theme.small()).foregroundStyle(Theme.text3)
                }
            }
            HStack {
                Spacer()
                if ctrl.onboard?.ready == true {
                    Button("Done") { ctrl.showOnboarding = false }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(width: 120)
                        .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button("Continue anyway") { ctrl.showOnboarding = false }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.window)
        .preferredColorScheme(.dark)
    }

    private func checkRow(_ c: OnboardResponse.Check, last: Bool) -> some View {
        SettingRow(title: c.title, detail: (c.ok || c.runnableArgs != nil || !c.required) ? c.detail : c.fix,
                   showDivider: !last) {
            if c.ok {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.good)
            } else if ctrl.onboardBusy == c.id {
                ProgressView().controlSize(.small)
            } else if c.runnableArgs != nil {
                Button(c.required ? "Fix" : "Set up") { ctrl.runOnboardingFix(c) }
                    .buttonStyle(QuietButtonStyle(height: 28))
                    .disabled(ctrl.onboardBusy != nil)
            } else {
                Text(c.required ? "Required" : "Optional").font(Theme.small()).foregroundStyle(c.required ? Theme.warn : Theme.text3)
            }
        }
    }
}

// MARK: - Controls reference

struct ControlsCheatSheetView: View {
    @Binding var isPresented: Bool

    private struct Entry: Identifiable {
        let keys: [String]
        let text: String
        var face: FaceButton? = nil
        var id: String { keys.joined() + text }
    }

    private let sections: [(String, [Entry])] = [
        ("Anywhere", [
            Entry(keys: ["0"], text: "Lock or release the trackpad"),
            Entry(keys: ["G"], text: "Vehicle mode"),
            Entry(keys: ["O"], text: "Aircraft mode"),
            Entry(keys: ["T"], text: "Smart assists on or off"),
            Entry(keys: ["H"], text: "Controls panel"),
            Entry(keys: ["\\"], text: "Prompt bar"),
            Entry(keys: [";"], text: "Ping, jitter and AWDL"),
            Entry(keys: ["-", "="], text: "Sensitivity, saved to the profile"),
            Entry(keys: ["["], text: "PS5 microphone mute"),
        ]),
        ("On foot", [
            Entry(keys: ["W", "A", "S", "D"], text: "Move, hold Z to walk"),
            Entry(keys: ["Space"], text: "Jump, climb, swim", face: .cross),
            Entry(keys: ["C"], text: "Crouch", face: .circle),
            Entry(keys: ["R"], text: "Reload, melee", face: .square),
            Entry(keys: ["E", "F"], text: "Interact, enter vehicle", face: .triangle),
            Entry(keys: ["Ctrl"], text: "Aim L2, V switches shoulder, Z sniper"),
            Entry(keys: ["Tab"], text: "Weapon wheel L1"),
        ]),
        ("Vehicle", [
            Entry(keys: ["W", "S"], text: "Gas R2, brake L2"),
            Entry(keys: ["Space"], text: "Handbrake", face: .cross),
            Entry(keys: ["F"], text: "Exit", face: .triangle),
            Entry(keys: ["]"], text: "Cruise control"),
        ]),
        ("Aircraft", [
            Entry(keys: ["W", "S"], text: "Throttle"),
            Entry(keys: ["↑", "↓", "←", "→"], text: "Pitch and roll"),
            Entry(keys: ["Q", "E"], text: "Rudder"),
            Entry(keys: ["R"], text: "Landing gear L3"),
        ]),
        ("Assists, hold", [
            Entry(keys: ["U"], text: "Hotwire sweep"),
            Entry(keys: ["I"], text: "Full circle"),
            Entry(keys: ["Y"], text: "Hold the right stick"),
            Entry(keys: ["L"], text: "Rapid tap", face: .cross),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Controls").font(Theme.title()).foregroundStyle(Theme.text1)
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(QuietButtonStyle(height: 28))
                    .keyboardShortcut(.escape, modifiers: [])
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sections, id: \.0) { title, entries in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title).font(Theme.small(.medium)).foregroundStyle(Theme.text2)
                            VStack(spacing: 0) {
                                ForEach(entries) { e in
                                    HStack(spacing: 12) {
                                        HStack(spacing: 4) { ForEach(e.keys, id: \.self) { Keycap(label: $0) } }
                                            .frame(width: 120, alignment: .leading)
                                        Text(e.text).font(Theme.body()).foregroundStyle(Theme.text1)
                                        Spacer()
                                        if let f = e.face { FaceGlyph(button: f) }
                                    }
                                    .frame(height: 32)
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(24)
        .frame(width: 480, height: 560)
        .background(Theme.window)
        .preferredColorScheme(.dark)
    }
}
