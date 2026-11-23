import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { getCliContext, launchGta6, MACBOOK_CONTROLS_MD } from "./lib";

interface LaunchOption {
  id: string;
  client: "sony" | "chiaki";
  preset: string;
  title: string;
  badge: string;
  color: Color;
  details: string;
}

const LAUNCH_OPTIONS: LaunchOption[] = [
  {
    id: "sony-official",
    client: "sony",
    preset: "auto",
    title: "Official PS Remote Play (Sony) — Instant Connect",
    badge: "WAN Ready",
    color: Color.Green,
    details:
      "Works over the internet out of the box. Injects a Virtual USB DualSense (054C:0CE6) with MacBook Trackpad + Keyboard GTA 6 Smart Pack, Force Touch haptics, and DualSense lightbar HUD.",
  },
  {
    id: "chiaki-auto",
    client: "chiaki",
    preset: "auto",
    title: "chiaki-ng — Auto (WAN Adaptive)",
    badge: "H.265 60fps",
    color: Color.Blue,
    details:
      "Probes WAN RTT, jitter, and packet loss, then picks the smoothest H.265 60fps bitrate & resolution preset automatically.",
  },
  {
    id: "chiaki-balanced",
    client: "chiaki",
    preset: "wan-balanced",
    title: "chiaki-ng — WAN Balanced (1080p @ 60fps)",
    badge: "10 Mbps",
    color: Color.Purple,
    details: "Crisp 1080p 60fps balance with low latency for typical remote Wi-Fi networks.",
  },
  {
    id: "chiaki-lowbw",
    client: "chiaki",
    preset: "wan-lowbw",
    title: "chiaki-ng — WAN Low-BW (720p @ 60fps)",
    badge: "6.5 Mbps",
    color: Color.Orange,
    details: "Keeps rock-solid 60fps fluidity on congested Wi-Fi or mobile hotspots.",
  },
  {
    id: "chiaki-lan",
    client: "chiaki",
    preset: "lan-max",
    title: "chiaki-ng — LAN Max (1080p @ 60fps)",
    badge: "30 Mbps",
    color: Color.Magenta,
    details: "Maximum visual fidelity and lowest audio buffer for home local networks.",
  },
];

export default function PlayGta6Command() {
  const { privilegedByDefault } = getCliContext();

  return (
    <List isShowingDetail searchBarPlaceholder="Choose PS5 Remote Play client / stream preset...">
      {LAUNCH_OPTIONS.map((item) => (
        <List.Item
          key={item.id}
          icon={{ source: Icon.GameController, tintColor: item.color }}
          title={item.title}
          accessories={[{ tag: { value: item.badge, color: item.color } }]}
          detail={
            <List.Item.Detail
              markdown={`## ${item.title}\n\n${item.details}\n\n---\n${MACBOOK_CONTROLS_MD}`}
            />
          }
          actions={
            <ActionPanel>
              <Action
                title={privilegedByDefault ? "Launch (Wi-Fi AWDL Fix ON)" : "Launch GTA 6"}
                icon={Icon.Play}
                onAction={() => launchGta6(item.preset, privilegedByDefault, item.client)}
              />
              <Action
                title={privilegedByDefault ? "Launch (Standard / No Sudo)" : "Launch + Wi-Fi AWDL Lag Fix (Touch ID)"}
                icon={Icon.Wifi}
                shortcut={{ modifiers: ["cmd"], key: "return" }}
                onAction={() => launchGta6(item.preset, !privilegedByDefault, item.client)}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
