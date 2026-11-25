"""Backward-compatible facade: the implementation lives in the `senza.firewall` package.

Patch targets for tests live in the defining module, e.g. `senza.firewall.tailscale._tailscale_cli_candidates`.
"""

from __future__ import annotations

from .firewall.common import (  # noqa: F401
    STATE_DIR,
    BYPASS_STATE_FILE,
    SYSTEM_TUNNEL_STATE_FILE,
    CLEAN_DNS_SERVERS,
    NO_EXIT_NODE_HINT,
    TAILSCALE_DERP_PROBE_HOSTS,
    Runner,
    _default_runner,
    _privileged_shell_cmd,
)
from .firewall.warp import (  # noqa: F401
    find_warp_cli,
    _warp_is_connected,
)
from .firewall.tailscale import (  # noqa: F401
    _tailscale_cli_candidates,
    _tailscale_status_json,
    find_tailscale_cli,
    _tailscale_find_peer,
    _tailscale_active_exit_node,
    _tailscale_list_exit_nodes,
    _tailscale_discover_exit_node,
    resolve_exit_node,
    inspect_tailscale_exit_node,
)
from .firewall.netsvc import (  # noqa: F401
    list_macos_vpns,
    detect_active_network_service,
    get_dns_servers,
    _dns_cmd,
)
from .firewall.probes import (  # noqa: F401
    FirewallProbeReport,
    probe_tailscale_controlplane,
    probe_tailscale_derp,
    probe_egress_via_tunnel,
    _tls_check_ip,
    _stun_check,
    _resolve_via_server,
    probe_psn_firewall,
)
from .firewall.bypass import (  # noqa: F401
    FirewallBypass,
    _session_defers_to_system_tunnel,
    restore_firewall_bypass,
)
from .firewall.launchd import (  # noqa: F401
    LAUNCH_AGENT_LABEL,
    LAUNCH_AGENT_PATH,
    TUNNEL_WATCHDOG_LOG,
    _resolve_senza_cli_path,
    install_tunnel_launch_agent,
    uninstall_tunnel_launch_agent,
)
from .firewall.system_tunnel import (  # noqa: F401
    _read_json_file,
    system_tunnel_status,
    system_tunnel_up,
    system_tunnel_down,
    system_tunnel_ensure,
)
