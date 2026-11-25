import AppKit
import Foundation
import GameController
import SwiftUI

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
        guard let url = profileURL() else {
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

        Task { @MainActor [weak self] in
            let result = await SenzaCLI.run(["export-profile", "--profile", "gta6", "--json"])
            guard let self else { return }
            self.saving = false
            if result.ok {
                self.statusText = "Saved & Live Hot-Reloaded (no restart needed)"
            } else {
                let msg = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.errorText = msg.isEmpty ? "Validation failed while exporting profile." : msg
                self.statusText = nil
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
