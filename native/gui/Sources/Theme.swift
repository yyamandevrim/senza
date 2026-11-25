import AppKit
import SwiftUI

/// One visual system for Senza.app and the in-game HUD (native/kbm_bridge/hud.m uses the same values):
/// graphite chrome, three text roles, one quiet accent, colour reserved for status and the PS face buttons,
/// Mac shortcuts drawn as keycaps.
enum Theme {
    // Neutral ramp (graphite)
    static let window = Color(red: 0.071, green: 0.075, blue: 0.086)
    static let surface = Color.white.opacity(0.045)
    static let surfaceRaised = Color.white.opacity(0.075)
    static let hairline = Color.white.opacity(0.08)

    // Text roles
    static let text1 = Color.white.opacity(0.94)
    static let text2 = Color.white.opacity(0.62)
    static let text3 = Color.white.opacity(0.40)

    /// The one accent: selection, focus, the line you're tracking in a chart.
    static let accent = Color(red: 0.49, green: 0.65, blue: 0.95)

    // Status (toned to sit inside the palette)
    static let good = Color(red: 0.42, green: 0.82, blue: 0.56)
    static let warn = Color(red: 0.91, green: 0.72, blue: 0.38)
    static let bad = Color(red: 0.91, green: 0.46, blue: 0.43)

    // PlayStation face buttons
    static let cross = Color(red: 0.49, green: 0.65, blue: 0.95)
    static let circle = Color(red: 0.93, green: 0.44, blue: 0.45)
    static let square = Color(red: 0.86, green: 0.57, blue: 0.86)
    static let triangle = Color(red: 0.30, green: 0.80, blue: 0.66)

    // Radii (nested: card 12 - padding 4 = control 8)
    static let rControl: CGFloat = 8
    static let rCard: CGFloat = 12

    // Type scale: 11 / 12 / 13 / 15 / 28
    static func caption(_ w: Font.Weight = .regular) -> Font { .system(size: 11, weight: w) }
    static func small(_ w: Font.Weight = .regular) -> Font { .system(size: 12, weight: w) }
    static func body(_ w: Font.Weight = .regular) -> Font { .system(size: 13, weight: w) }
    static func title(_ w: Font.Weight = .semibold) -> Font { .system(size: 15, weight: w) }
    static func figure(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .medium).monospacedDigit() }
    static func mono(_ size: CGFloat = 11, _ w: Font.Weight = .medium) -> Font {
        .system(size: size, weight: w, design: .monospaced)
    }
}

enum StatusTone {
    case neutral, good, warn, bad

    var color: Color {
        switch self {
        case .neutral: return Theme.text3
        case .good: return Theme.good
        case .warn: return Theme.warn
        case .bad: return Theme.bad
        }
    }
}

struct StatusDot: View {
    var tone: StatusTone
    var body: some View {
        Circle().fill(tone.color).frame(width: 6, height: 6)
    }
}

/// Mac key drawn as a small keycap (the signature detail shared with the in-game HUD).
struct Keycap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.11))
                    .shadow(color: .black.opacity(0.35), radius: 0, y: 1.5)
            )
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.75))
    }
}

enum FaceButton { case cross, circle, square, triangle }

/// PS face button glyph drawn as a vector shape in its own colour.
struct FaceGlyph: View {
    let button: FaceButton
    var size: CGFloat = 12

    var body: some View {
        shape
            .frame(width: size, height: size)
    }

    @ViewBuilder private var shape: some View {
        let stroke = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        switch button {
        case .circle: Circle().inset(by: 1).stroke(Theme.circle, style: stroke)
        case .square: Rectangle().inset(by: 1.5).stroke(Theme.square, style: stroke)
        case .triangle: TriangleShape().stroke(Theme.triangle, style: stroke)
        case .cross: CrossShape().stroke(Theme.cross, style: stroke)
        }
    }
}

private struct TriangleShape: Shape {
    func path(in r: CGRect) -> Path {
        let box = r.insetBy(dx: 1.2, dy: 1.6)
        var p = Path()
        p.move(to: CGPoint(x: box.midX, y: box.minY))
        p.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        p.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        p.closeSubpath()
        return p
    }
}

private struct CrossShape: Shape {
    func path(in r: CGRect) -> Path {
        let box = r.insetBy(dx: 1.5, dy: 1.5)
        var p = Path()
        p.move(to: CGPoint(x: box.minX, y: box.minY))
        p.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        p.move(to: CGPoint(x: box.maxX, y: box.minY))
        p.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        return p
    }
}

/// Grouped settings container: one surface, hairline dividers between rows.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var showDivider: Bool = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.body(.medium)).foregroundStyle(Theme.text1)
                    if let detail {
                        Text(detail).font(Theme.caption()).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            if showDivider {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 16)
            }
        }
    }
}

/// Off-white primary button with dark text (reads as deliberate on a dark window).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(.semibold))
            .foregroundStyle(Color.black.opacity(0.86))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Color.white.opacity(configuration.isPressed ? 0.78 : 0.92),
                        in: RoundedRectangle(cornerRadius: Theme.rControl + 2, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var height: CGFloat = 40
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(.medium))
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(configuration.isPressed ? Theme.surfaceRaised : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.rControl + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rControl + 2, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}
