import { Action, ActionPanel, Color, Detail, Icon } from "@raycast/api";
import { useEffect, useState } from "react";
import { DoctorResult, launchGta6, runDoctor } from "./lib";

export default function NetworkDoctorCommand() {
  const [data, setData] = useState<DoctorResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await runDoctor();
      setData(res);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void refresh();
  }, []);

  if (error) {
    return (
      <Detail
        markdown={`## Network Diagnostics Failed\n\n\`\`\`\n${error}\n\`\`\``}
        actions={
          <ActionPanel>
            <Action title="Retry" icon={Icon.ArrowClockwise} onAction={refresh} />
          </ActionPanel>
        }
      />
    );
  }

  const net = data?.network;
  const preset = data?.recommended_preset;
  const fw = data?.firewall;

  const warningsMd =
    net && net.warnings.length > 0
      ? `### Warnings\n${net.warnings.map((w) => `- ${w}`).join("\n")}`
      : "### Status\nNetwork looks clean and ready for PS5 Remote Play.";

  const fwMd = fw ? `\n\n### PSN & Firewall\n${fw.diagnosis}` : "";

  const markdown = data
    ? `## DualMac WAN & macOS Diagnostics\n\nRecommended preset: **${preset?.name}** (\`${preset?.resolution} @ ${preset?.fps}fps · ${preset?.bitrate_kbps} kbps · ${preset?.codec}\`)\n\n${warningsMd}${fwMd}`
    : "### Measuring WAN RTT, jitter, PSN firewall reachability, and macOS Wi-Fi AWDL...";

  return (
    <Detail
      isLoading={loading}
      markdown={markdown}
      metadata={
        data && net && preset ? (
          <Detail.Metadata>
            <Detail.Metadata.Label title="Probe Host" text={net.host} />
            <Detail.Metadata.Label
              title="RTT (Median / p95)"
              text={net.rtt_median_ms !== null ? `${net.rtt_median_ms} ms / ${net.rtt_p95_ms} ms` : "Unreachable"}
            />
            <Detail.Metadata.TagList title="Jitter (p95 - Median)">
              <Detail.Metadata.TagList.Item
                text={net.jitter_ms !== null ? `${net.jitter_ms} ms` : "-"}
                color={
                  net.jitter_ms === null
                    ? Color.SecondaryText
                    : net.jitter_ms < 8
                      ? Color.Green
                      : net.jitter_ms < 20
                        ? Color.Yellow
                        : Color.Red
                }
              />
            </Detail.Metadata.TagList>
            <Detail.Metadata.Label title="Packet Loss" text={`${net.packet_loss_pct}%`} />
            <Detail.Metadata.Label
              title="Interface"
              text={`${net.default_interface} (${net.is_wifi ? "Wi-Fi" : "Wired/Other"})`}
            />
            <Detail.Metadata.TagList title="AWDL (AirDrop Lag Risk)">
              <Detail.Metadata.TagList.Item
                text={net.awdl_active ? "ACTIVE (Lag Spike Risk)" : "Inactive"}
                color={net.awdl_active ? Color.Orange : Color.Green}
              />
            </Detail.Metadata.TagList>
            <Detail.Metadata.Separator />
            <Detail.Metadata.Label
              title="Sony RemotePlay"
              text={data.sony_app ? (data.sony_bundle_ready ? "Ready" : "Run `dualmac setup`") : "Not Installed"}
            />
            <Detail.Metadata.Label
              title="chiaki-ng"
              text={data.chiaki_app ? (data.patched_bundle_ready ? "Ready" : "Run `dualmac setup`") : "Not Installed"}
            />
          </Detail.Metadata>
        ) : undefined
      }
      actions={
        preset ? (
          <ActionPanel>
            <Action
              title="Launch Sony Remote Play (+ AWDL Fix)"
              icon={Icon.Play}
              onAction={() => launchGta6(preset.name, true, "sony")}
            />
            <Action
              title="Launch Sony Remote Play (Standard)"
              icon={Icon.GameController}
              onAction={() => launchGta6(preset.name, false, "sony")}
            />
            <Action
              title={`Launch chiaki-ng (${preset.name} + AWDL Fix)`}
              icon={Icon.Wifi}
              onAction={() => launchGta6(preset.name, true, "chiaki")}
            />
            <Action
              title="Re-Run Diagnostics"
              icon={Icon.ArrowClockwise}
              shortcut={{ modifiers: ["cmd"], key: "r" }}
              onAction={refresh}
            />
          </ActionPanel>
        ) : undefined
      }
    />
  );
}
