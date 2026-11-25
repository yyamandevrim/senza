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
        let tailscale_controlplane_ok: Bool?
        let tailscale_derp_ok: Bool?
        let fortigate_warp_bootstrap_needed: Bool?
    }
    struct SystemTunnel: Decodable {
        let active: Bool
        let active_backend: String
        let target_exit_node: String?
        let service_installed: Bool
    }
    struct Preset: Decodable {
        let name: String
        let resolution: String
        let fps: Int
        let bitrate_kbps: Int
    }
    let network: Network
    let firewall: Firewall?
    let system_tunnel: SystemTunnel?
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
