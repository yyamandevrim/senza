import AppKit
import Foundation
import GameController
import SwiftUI

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
        ctrl.onDoctorUpdated = { [weak self] in
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
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
            let statusHeader = NSMenuItem(title: "Playing on \(label)", action: nil, keyEquivalent: "")
            statusHeader.isEnabled = false
            menu.addItem(statusHeader)
            menu.addItem(.separator())

            let focusItem = NSMenuItem(title: "Bring \(label) to Front", action: #selector(menuBringClientToFront), keyEquivalent: "r")
            focusItem.target = self
            menu.addItem(focusItem)

            let studioItem = NSMenuItem(title: "Sensitivity and Keys…", action: #selector(menuShowStudio), keyEquivalent: ",")
            studioItem.target = self
            menu.addItem(studioItem)

            let showItem = NSMenuItem(title: "Show Senza Launcher", action: #selector(menuShowWindow), keyEquivalent: "d")
            showItem.target = self
            menu.addItem(showItem)

            let controlsItem = NSMenuItem(title: "Controls…", action: #selector(menuShowControls), keyEquivalent: "")
            controlsItem.target = self
            menu.addItem(controlsItem)

            menu.addItem(.separator())

            let endItem = NSMenuItem(title: "End Session", action: #selector(menuEndSession), keyEquivalent: "")
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

            let studioItem = NSMenuItem(title: "Sensitivity and Keys…", action: #selector(menuShowStudio), keyEquivalent: ",")
            studioItem.target = self
            menu.addItem(studioItem)

            let showItem = NSMenuItem(title: "Open Senza Window", action: #selector(menuShowWindow), keyEquivalent: "")
            showItem.target = self
            menu.addItem(showItem)

            let restoreItem = NSMenuItem(title: "Restore System Settings", action: #selector(menuRestoreSystem), keyEquivalent: "")
            restoreItem.target = self
            menu.addItem(restoreItem)
        }

        menu.addItem(.separator())
        let sysTun = ctrl.doctor?.system_tunnel
        let tunActive = sysTun?.active == true
        let backendLabel = (sysTun?.active_backend ?? "").uppercased()
        let tunnelTitle = tunActive
            ? "Route Whole Mac Through \(backendLabel == "TAILSCALE" ? "Tailscale" : (backendLabel == "WARP" ? "WARP" : "Tunnel"))"
            : "Route Whole Mac Through \(ctrl.exitNodeLabel)"
        let tunnelItem = NSMenuItem(title: tunnelTitle, action: #selector(menuToggleSystemTunnel), keyEquivalent: "t")
        tunnelItem.state = tunActive ? .on : .off
        tunnelItem.target = self
        menu.addItem(tunnelItem)

        let svcInstalled = sysTun?.service_installed == true
        let svcItem = NSMenuItem(title: "Keep Tunnel Healthy in Background", action: #selector(menuToggleTunnelService),
                                 keyEquivalent: "")
        svcItem.state = svcInstalled ? .on : .off
        svcItem.target = self
        menu.addItem(svcItem)

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

    @objc private func menuToggleSystemTunnel() {
        ctrl.toggleSystemTunnel()
    }

    @objc private func menuToggleTunnelService() {
        ctrl.toggleTunnelService()
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
