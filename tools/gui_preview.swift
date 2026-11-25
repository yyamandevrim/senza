// Render Senza.app's windows offscreen to PNG with live CLI data: `make gui-preview` -> build/gui-preview/
import AppKit
import SwiftUI

@MainActor
func snapshot<V: View>(_ view: V, size: NSSize, to path: String) {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print(path)
}

@main
struct GUIPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/gui-preview"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let ctrl = SenzaController.shared
        // Keep the user's saved toggles untouched: remember and restore them.
        let saved = (ctrl.firewall, ctrl.client)

        let host = NSHostingView(rootView: SenzaRootView(ctrl: ctrl))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline && (ctrl.doctor == nil || ctrl.onboard == nil || ctrl.doctorLoading) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0)) // history request
        ctrl.showOnboarding = false
        snapshot(SenzaRootView(ctrl: ctrl), size: NSSize(width: 480, height: 760), to: "\(out)/main.png")
        ctrl.firewall = .tailscale
        ctrl.client = .chiaki
        snapshot(SenzaRootView(ctrl: ctrl), size: NSSize(width: 480, height: 760), to: "\(out)/main-tailscale-chiaki.png")
        ctrl.firewall = saved.0
        ctrl.client = saved.1
        snapshot(OnboardingSheet(ctrl: ctrl), size: NSSize(width: 520, height: 600), to: "\(out)/onboarding.png")
        snapshot(ControlsCheatSheetView(isPresented: .constant(true)), size: NSSize(width: 480, height: 560),
                 to: "\(out)/controls.png")
        snapshot(ProfileStudioView(isPresented: .constant(true)), size: NSSize(width: 640, height: 590),
                 to: "\(out)/studio.png")
        exit(0)
    }
}
