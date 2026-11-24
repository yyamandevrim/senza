"""CLI entry point for Senza (setup, doctor, start, restore) supporting Sony RemotePlay & chiaki-ng."""

from __future__ import annotations

import argparse
import dataclasses
import json
from pathlib import Path

from . import __version__

from .app_bridge import (
    PATCHED_APP,
    PATCHED_SONY_APP,
    STATE_DIR,
    ensure_dylib_built,
    find_chiaki_app,
    find_sony_app,
    launch_client,
    prepare_patched_app,
    resolve_launched_pid,
)
from .firewall_bypass import (
    DEFAULT_TAILSCALE_EXIT_NODE,
    FirewallBypass,
    install_tunnel_launch_agent,
    probe_psn_firewall,
    restore_firewall_bypass,
    system_tunnel_down,
    system_tunnel_ensure,
    system_tunnel_status,
    system_tunnel_up,
    uninstall_tunnel_launch_agent,
)
from .net_probe import probe_network
from .profiles import export_runtime_config, load_profile
from .stream_profile import (
    PRESETS,
    apply_stream_preset,
    recommend_preset,
    restore_chiaki_plist,
)
from .sys_optimizer import SystemOptimizer, restore_from_crash


def _print_network_report(host: str) -> tuple[object, object]:
    print(f"Probing WAN network to {host} ...")
    report = probe_network(host=host)
    preset = recommend_preset(report)

    print("\n=== Network & macOS Diagnostics ===")
    print(f"  Target host       : {report.host}")
    print(f"  IPv4 reachable    : {'yes' if report.ipv4_ok else 'NO'}")
    if report.rtt_median_ms is not None:
        print(f"  RTT (median/p95)  : {report.rtt_median_ms} ms / {report.rtt_p95_ms} ms")
        print(f"  Jitter (p95-med)  : {report.jitter_ms} ms")
    print(f"  Packet loss       : {report.packet_loss_pct}%")
    if report.mtu_1500_ok is not None:
        print(f"  MTU 1500 (no frag): {'ok' if report.mtu_1500_ok else 'FRAGMENTED (<1500)'}")
    print(f"  Interface         : {report.default_interface} ({'Wi-Fi' if report.is_wifi else 'Wired/Other'})")
    print(f"  AWDL (awdl0)      : {'ACTIVE (lag spike risk)' if report.awdl_active else 'inactive'}")
    if report.noisy_processes:
        print(f"  Background sync   : {', '.join(report.noisy_processes)}")
    print(f"  Recommended preset: {preset.name} ({preset.resolution} @ {preset.fps}fps, {preset.bitrate_kbps} kbps, {preset.codec})")

    if report.warnings:
        print("\nWarnings:")
        for w in report.warnings:
            print(f"  - {w}")
    return report, preset


def cmd_doctor(args: argparse.Namespace) -> int:
    chiaki = find_chiaki_app(args.chiaki_app)
    sony = find_sony_app(args.sony_app)
    fw = probe_psn_firewall(exit_node=args.exit_node)
    sys_tun = system_tunnel_status(exit_node=args.exit_node)

    if args.json:
        report = probe_network(host=args.host)
        preset = recommend_preset(report)
        payload = {
            "network": dataclasses.asdict(report),
            "firewall": dataclasses.asdict(fw),
            "system_tunnel": sys_tun,
            "recommended_preset": dataclasses.asdict(preset),
            "sony_app": str(sony) if sony else None,
            "sony_bundle_ready": PATCHED_SONY_APP.exists(),
            "chiaki_app": str(chiaki) if chiaki else None,
            "patched_bundle_ready": PATCHED_APP.exists(),
        }
        print(json.dumps(payload, indent=2))
        return 0

    _print_network_report(args.host)
    print("\n=== PSN & Firewall Check ===")
    print(f"  PSN TLS (sys DNS) : {'ok' if fw.psn_sys_tls_ok else 'BLOCKED / TIMEOUT'}")
    print(f"  PSN TLS (1.1.1.1) : {'ok' if fw.psn_cf_tls_ok else 'BLOCKED / TIMEOUT'}")
    print(f"  Outbound UDP STUN : {'ok' if fw.udp_high_port_ok else 'BLOCKED (needs tunnel for WAN stream)'}")
    print(f"  Diagnosis         : {fw.diagnosis}")
    backends: list[str] = ["dns (1.1.1.1)"]
    if fw.warp_available:
        backends.append("warp (Cloudflare WARP)")
    if fw.tailscale_available:
        backends.append(f"tailscale ({fw.tailscale_state})")
    if fw.macos_vpns:
        backends.append(f"vpn ({', '.join(fw.macos_vpns)})")
    print(f"  Bypass backends   : {', '.join(backends)}")
    if fw.tailscale_available:
        cp_txt = "ok" if fw.tailscale_controlplane_ok else "BLOCKED (auto WARP-bootstrap will run)"
        derp_txt = (
            f"ok ({', '.join(fw.tailscale_derp_nodes)})"
            if fw.tailscale_derp_ok
            else "BLOCKED (TCP-443 relays unreachable)"
        )
        print(f"  TS controlplane   : {cp_txt}")
        print(f"  TS DERP TCP-443   : {derp_txt}")
        print(f"  Tailscale exit    : {fw.tailscale_exit_node} -> {fw.tailscale_exit_node_status}")
    tun_state = f"ACTIVE ({sys_tun['active_backend']})" if sys_tun["active"] else "off"
    svc_state = "installed (45s watchdog)" if sys_tun["service_installed"] else "not installed"
    print(f"  System tunnel     : {tun_state} | LaunchAgent: {svc_state}")

    print("\n=== Installation Check ===")
    print(f"  Sony RemotePlay   : {sony or 'NOT FOUND'} ({'ready' if PATCHED_SONY_APP.exists() else 'run `senza setup`'})")
    print(f"  chiaki-ng         : {chiaki or 'NOT FOUND'} ({'ready' if PATCHED_APP.exists() else 'run `senza setup`'})")
    print("  Input capture     : Cocoa in-process NSEvent monitor (zero macOS permissions required)")
    return 0


def cmd_setup(args: argparse.Namespace) -> int:
    print("1/3 Compiling Senza native Trackpad+Keyboard DualSense bridges (Sony + chiaki-ng)...")
    sony_dylib = ensure_dylib_built(client="sony", force=args.force)
    chiaki_dylib = ensure_dylib_built(client="chiaki", force=args.force)
    print(f"    Built: {sony_dylib}")
    print(f"    Built: {chiaki_dylib}")

    prepared_any = False

    if args.client in ("all", "sony"):
        sony = find_sony_app(args.sony_app)
        if sony:
            print(f"2/3 Preparing local ad-hoc signed Sony RemotePlay bundle from {sony}...")
            patched_sony = prepare_patched_app(sony, client="sony", force=args.force)
            print(f"    Ready: {patched_sony}")
            prepared_any = True
        else:
            print("2/3 Sony RemotePlay.app not found in /Applications (skipping).")

    if args.client in ("all", "chiaki"):
        chiaki = find_chiaki_app(args.chiaki_app)
        if chiaki:
            print(f"3/3 Preparing local ad-hoc signed chiaki-ng bundle from {chiaki}...")
            patched_chiaki = prepare_patched_app(chiaki, client="chiaki", force=args.force)
            print(f"    Ready: {patched_chiaki}")
            prepared_any = True
        else:
            print("3/3 chiaki-ng.app not found in /Applications (skipping).")

    if not prepared_any:
        print("ERROR: Neither Sony RemotePlay.app nor chiaki-ng.app found in /Applications.")
        return 1

    print("\nSetup complete! Launch via Raycast or `senza start --client sony` (or `--client chiaki`).")
    return 0


def cmd_start(args: argparse.Namespace) -> int:
    start_hybrid = bool(getattr(args, "hybrid", False))
    use_kbm = start_hybrid or (not args.controller)
    client = args.client
    runtime_cfg: Path | None = None
    profile_json_path: Path | None = None
    dylib: Path | None = None

    if use_kbm:
        from .profiles import resolve_profile_path
        profile_json_path = resolve_profile_path(args.profile)
        profile = load_profile(args.profile)
        runtime_cfg = export_runtime_config(profile, STATE_DIR / "runtime_profile.cfg")

    if client == "chiaki":
        if args.preset == "auto":
            _, preset = _print_network_report(args.host)
        else:
            preset = PRESETS[args.preset]
            print(f"Using explicit stream preset: {preset.name} ({preset.resolution}@{preset.fps}fps, {preset.bitrate_kbps} kbps, {preset.codec})")

        print(f"\nApplying chiaki-ng stream settings ({preset.name})...")
        cmds = apply_stream_preset(preset, disable_builtin_kbm=(use_kbm and not args.keep_chiaki_kbm), dry_run=args.dry_run)
        if args.dry_run:
            for c in cmds:
                print(f"  [dry-run] {' '.join(c)}")
    else:
        if start_hybrid:
            mode_desc = "Hybrid DualSense + Trackpad Hot-Swap & Shared HUD (054C:0CE6)"
        elif use_kbm:
            mode_desc = "Virtual USB DualSense 054C:0CE6 bridge"
        else:
            mode_desc = "Native Physical Controller mode (no virtual pad)"
        print(f"Client: Official Sony PS Remote Play ({mode_desc})")

    if use_kbm:
        dylib = ensure_dylib_built(client=client, force=False)
    source_app = find_sony_app(args.sony_app) if client == "sony" else find_chiaki_app(args.chiaki_app)

    if args.dry_run:
        opt = SystemOptimizer(privileged=args.privileged, gui_sudo=args.gui_sudo, dry_run=True)
        for note in opt.enter():
            print(f"  {note}")
        if args.bypass_firewall:
            fb = FirewallBypass(
                mode=args.bypass_firewall,
                exit_node=args.exit_node,
                gui_sudo=args.gui_sudo,
                dry_run=True,
                warp_bootstrap=args.warp_bootstrap,
                fallback_warp=args.fallback_warp,
            )
            for note in fb.enter():
                print(f"  {note}")
        print(f"  [dry-run] client: {client}")
        input_desc = (
            "Hybrid (Physical DualSense + Trackpad Hot-Swap + Shared HUD)"
            if start_hybrid
            else ("Trackpad+Keyboard KBM" if use_kbm else "Physical Controller (native)")
        )
        print(f"  [dry-run] input mode: {input_desc}")
        if runtime_cfg:
            print(f"  [dry-run] profile exported to {runtime_cfg}")
        if dylib:
            print(f"  [dry-run] dylib ready at {dylib}")
        print(f"  [dry-run] source app: {source_app or 'NOT INSTALLED'}")
        return 0

    if not source_app:
        print(f"ERROR: {client} app not found in /Applications.")
        return 1

    target_app = prepare_patched_app(source_app, client=client, force=False) if use_kbm else source_app

    if start_hybrid:
        print(f"\nStarting macOS optimizations & {client} in Hybrid Hot-Swap mode (DualSense + Trackpad + Shared HUD)...")
        print("Hot-Swap: Touch DualSense anytime | '0'=Trackpad+Keys | ';'=Live Ping | '['=PS5 Mic Mute | 'H'=HUD\n")
    elif use_kbm:
        print(f"\nStarting macOS optimizations & {client} with MacBook Trackpad + Keyboard GTA 6 Smart Pack...")
        print("Controls: '0'=Capture | 'G'=Vehicle | 'O'=Aircraft | 'T'=Smart | 'U/I/Y/L'=Assists | '-/='=Sens | ';'=Ping | 'H'=HUD\n")
    else:
        print(f"\nStarting macOS optimizations & {client} in Native Controller mode (full DualSense haptics/triggers)...\n")

    optimizer = SystemOptimizer(privileged=args.privileged, gui_sudo=args.gui_sudo, dry_run=False)
    bypass = (
        FirewallBypass(
            mode=args.bypass_firewall,
            exit_node=args.exit_node,
            gui_sudo=args.gui_sudo,
            dry_run=False,
            warp_bootstrap=args.warp_bootstrap,
            fallback_warp=args.fallback_warp,
        )
        if args.bypass_firewall
        else None
    )
    try:
        for note in optimizer.enter():
            print(f"  [opt] {note}")
        if bypass is not None:
            for note in bypass.enter():
                print(f"  [bypass] {note}")
        proc = launch_client(
            target_app,
            dylib,
            runtime_cfg,
            client=client,
            inject_kbm=use_kbm,
            profile_json_path=profile_json_path,
            ping_host=args.host,
            start_hybrid=start_hybrid,
        )
        real_pid = resolve_launched_pid(proc, client=client, used_open=(not use_kbm))
        label = "Sony RemotePlay" if client == "sony" else "chiaki-ng"
        print(f"  [launch] {label} started (pid={real_pid})", flush=True)
        for note in optimizer.boost_process(real_pid, label=label):
            print(f"  [opt] {note}", flush=True)
        return proc.wait()
    finally:
        if bypass is not None:
            for note in bypass.exit():
                print(f"  [cleanup] {note}")
        for note in optimizer.exit():
            print(f"  [cleanup] {note}")


def cmd_export_profile(args: argparse.Namespace) -> int:
    """Validate a JSON profile and export runtime_profile.cfg (triggers live hot-reload in running sessions)."""
    out_path = Path(args.output).expanduser() if args.output else (STATE_DIR / "runtime_profile.cfg")
    profile = load_profile(args.profile)
    exported = export_runtime_config(profile, out_path)
    if args.json:
        print(json.dumps({"ok": True, "profile": args.profile, "runtime_cfg": str(exported)}))
    else:
        print(f"Exported runtime profile '{args.profile}' -> {exported}")
    return 0


def cmd_tunnel(args: argparse.Namespace) -> int:
    """Manage persistent system-wide FortiGate -> Tailscale Exit Node (+ WARP bootstrap/fallback) tunnel."""
    action = args.tunnel_action
    fallback_warp = not getattr(args, "no_fallback_warp", False)

    if action == "status":
        st = system_tunnel_status(exit_node=args.exit_node, probe_network_checks=True)
        if args.json:
            print(json.dumps(st, indent=2))
            return 0
        print("=== System-Wide FortiGate / Tailscale Tunnel ===")
        print(f"  Active backend    : {st['active_backend'].upper()} ({'ACTIVE' if st['active'] else 'off'})")
        print(f"  Target exit node  : {st['target_exit_node']}")
        print(f"  Tailscale state   : {st['tailscale_state']}")
        print(f"  Exit node status  : {st['tailscale_exit_node_status']}")
        cp_ok = st.get("controlplane_ok")
        print(f"  TS controlplane   : {'ok' if cp_ok else 'BLOCKED (' + str(st.get('controlplane_detail')) + ')'}")
        derp_ok = st.get("derp_ok")
        derp_nodes = st.get("derp_nodes") or []
        print(f"  TS DERP TCP-443   : {'ok (' + ', '.join(derp_nodes) + ')' if derp_ok else 'BLOCKED'}")
        print(f"  WARP MASQUE       : {'CONNECTED' if st['warp_connected'] else 'disconnected'}")
        print(f"  LaunchAgent       : {'INSTALLED (45s auto-heal)' if st['service_installed'] else 'not installed'}")
        return 0

    if action == "on":
        notes = system_tunnel_up(
            exit_node=args.exit_node,
            warp_bootstrap=args.warp_bootstrap,
            fallback_warp=fallback_warp,
            dry_run=args.dry_run,
        )
        for n in notes:
            print(f"  [tunnel] {n}")
        return 0

    if action == "off":
        notes = system_tunnel_down()
        for n in notes:
            print(f"  [tunnel] {n}")
        return 0

    if action == "ensure":
        notes = system_tunnel_ensure(
            exit_node=args.exit_node,
            warp_bootstrap=args.warp_bootstrap,
            fallback_warp=fallback_warp,
        )
        for n in notes:
            print(f"  [tunnel] {n}")
        return 0

    if action == "install-service":
        notes = install_tunnel_launch_agent(
            exit_node=args.exit_node,
            fallback_warp=fallback_warp,
        )
        for n in notes:
            print(f"  [service] {n}")
        return 0

    if action == "uninstall-service":
        notes = uninstall_tunnel_launch_agent()
        for n in notes:
            print(f"  [service] {n}")
        return 0

    return 1


def cmd_restore(args: argparse.Namespace) -> int:
    notes = restore_firewall_bypass(gui_sudo=args.gui_sudo)
    notes.extend(restore_from_crash(gui_sudo=args.gui_sudo))
    for n in notes:
        print(f"  [restore] {n}")
    if args.plist:
        if restore_chiaki_plist():
            print("  [restore] Restored original com.chiaki.Chiaki preferences from backup.")
        else:
            print("  [restore] No chiaki-ng preference backup found.")
    if not notes and not args.plist:
        print("  [restore] System already in clean state. (Pass --plist to also restore chiaki-ng preferences.)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="senza",
        description="Senza — Virtual DualSense Trackpad+Keyboard bridge & WAN optimizer for PS5 Remote Play on macOS",
    )
    p.add_argument("-V", "--version", action="version", version=f"Senza {__version__}")
    sub = p.add_subparsers(dest="command", required=True)

    p_doc = sub.add_parser("doctor", help="Measure WAN latency/jitter/loss and check macOS & client readiness")
    p_doc.add_argument("--host", default="1.1.1.1", help="Target host/IP for WAN ping & MTU check (default: 1.1.1.1)")
    p_doc.add_argument(
        "--exit-node",
        default=DEFAULT_TAILSCALE_EXIT_NODE,
        help=f"Tailscale exit node IP/hostname to check readiness for (default: {DEFAULT_TAILSCALE_EXIT_NODE})",
    )
    p_doc.add_argument("--chiaki-app", default=None, help="Custom path to chiaki-ng.app")
    p_doc.add_argument("--sony-app", default=None, help="Custom path to Sony RemotePlay.app")
    p_doc.add_argument("--json", action="store_true", help="Emit structured JSON output (used by Raycast extension)")
    p_doc.set_defaults(func=cmd_doctor)

    p_setup = sub.add_parser("setup", help="Compile native DualSense bridges and prepare ad-hoc signed app bundles")
    p_setup.add_argument("--client", default="all", choices=["all", "sony", "chiaki"], help="Client bundle to prepare (default: all)")
    p_setup.add_argument("--chiaki-app", default=None, help="Custom path to chiaki-ng.app")
    p_setup.add_argument("--sony-app", default=None, help="Custom path to Sony RemotePlay.app")
    p_setup.add_argument("--force", action="store_true", help="Force rebuild of dylibs and patched app bundles")
    p_setup.set_defaults(func=cmd_setup)

    p_start = sub.add_parser("start", help="Optimize macOS + launch Sony RemotePlay or chiaki-ng with Trackpad+KBM DualSense bridge")
    p_start.add_argument("--client", default="sony", choices=["sony", "chiaki"], help="Remote Play client (default: sony)")
    p_start.add_argument("--profile", default="gta6", help="Profile name in profiles/ or path to JSON (default: gta6)")
    p_start.add_argument(
        "--preset",
        default="auto",
        choices=["auto", *PRESETS.keys()],
        help="chiaki-ng stream bitrate/resolution preset (default: auto)",
    )
    p_start.add_argument("--host", default="1.1.1.1", help="WAN probe target host when --preset auto")
    p_start.add_argument("--privileged", action="store_true", help="Pause awdl0/llw0 (Wi-Fi jitter fix), boost kernel UDP buffers & process priority")
    p_start.add_argument("--gui-sudo", action="store_true", help="Use native macOS Touch ID / password dialog instead of terminal sudo")
    p_start.add_argument(
        "--bypass-firewall",
        nargs="?",
        const="auto",
        default=None,
        metavar="MODE",
        help="Bypass PSN/UDP firewall: auto (default), dns (1.1.1.1), warp (Cloudflare WARP), tailscale, or vpn:<Name>",
    )
    p_start.add_argument(
        "--exit-node",
        default=None,
        help=f"Tailscale exit node IP/hostname (default in tailscale mode: {DEFAULT_TAILSCALE_EXIT_NODE})",
    )
    p_start.add_argument(
        "--warp-bootstrap",
        default="auto",
        choices=["auto", "always", "never"],
        help="FortiGate controlplane bypass: auto (WARP ON -> tailscale up -> WARP OFF when blocked), always, or never",
    )
    p_start.add_argument(
        "--fallback-warp",
        action="store_true",
        help="Fallback to Cloudflare WARP MASQUE (TCP-443) if Tailscale exit node is unavailable or blocked",
    )
    p_start.add_argument("--hybrid", action="store_true", help="Hybrid Hot-Swap mode: start on physical DualSense with shared Ping/HUD/Mic shortcuts and instant '0' Trackpad switch")
    p_start.add_argument("--controller", "--no-kbm", dest="controller", action="store_true", help="Use physical DualSense/controller natively (keep WAN/macOS optimizations, skip virtual KBM pad)")
    p_start.add_argument("--keep-chiaki-kbm", action="store_true", help="Do not disable chiaki-ng built-in keyboard/mouse-touch")
    p_start.add_argument("--chiaki-app", default=None, help="Custom path to chiaki-ng.app")
    p_start.add_argument("--sony-app", default=None, help="Custom path to Sony RemotePlay.app")
    p_start.add_argument("--dry-run", action="store_true", help="Show planned actions without modifying system or launching")
    p_start.set_defaults(func=cmd_start)

    p_tun = sub.add_parser(
        "tunnel",
        help="System-wide macOS FortiGate/Tailscale exit-node bypass (persists across all apps, optional LaunchAgent)",
    )
    p_tun.add_argument(
        "tunnel_action",
        choices=["on", "off", "status", "ensure", "install-service", "uninstall-service"],
        help="on/off/status: control system tunnel; ensure: health-check/heal; install-service/uninstall-service: macOS LaunchAgent",
    )
    p_tun.add_argument(
        "--exit-node",
        default=None,
        help=f"Tailscale exit node IP/hostname (default: {DEFAULT_TAILSCALE_EXIT_NODE})",
    )
    p_tun.add_argument(
        "--warp-bootstrap",
        default="auto",
        choices=["auto", "always", "never"],
        help="FortiGate controlplane WARP bootstrap mode (default: auto)",
    )
    p_tun.add_argument(
        "--no-fallback-warp",
        action="store_true",
        help="Do not fall back to Cloudflare WARP MASQUE if Tailscale exit node is pending/offline/blocked",
    )
    p_tun.add_argument("--dry-run", action="store_true", help="Show planned tunnel steps without modifying state")
    p_tun.add_argument("--json", action="store_true", help="Emit JSON output (for `status`)")
    p_tun.set_defaults(func=cmd_tunnel)

    p_exp = sub.add_parser("export-profile", help="Validate JSON profile and write runtime_profile.cfg for live hot-reload")
    p_exp.add_argument("--profile", default="gta6", help="Profile name in profiles/ or path to JSON (default: gta6)")
    p_exp.add_argument("--output", default=None, help="Optional custom output path (default: ~/.local/share/senza/runtime_profile.cfg)")
    p_exp.add_argument("--json", action="store_true", help="Emit JSON confirmation")
    p_exp.set_defaults(func=cmd_export_profile)

    p_rest = sub.add_parser("restore", help="Recover awdl0/llw0, DNS, VPN/WARP, and sysctl settings after a crash (optional --plist)")
    p_rest.add_argument("--plist", action="store_true", help="Also restore backed-up com.chiaki.Chiaki preferences")
    p_rest.add_argument("--gui-sudo", action="store_true", help="Use native macOS Touch ID / password dialog for restore")
    p_rest.set_defaults(func=cmd_restore)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
