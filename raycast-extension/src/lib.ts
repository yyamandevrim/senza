import { closeMainWindow, getPreferenceValues, showHUD, showToast, Toast } from "@raycast/api";
import { execFile, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface Preferences {
  projectDir?: string;
  homeHost?: string;
  privilegedByDefault?: boolean;
}

export interface DoctorResult {
  network: {
    host: string;
    rtt_median_ms: number | null;
    rtt_p95_ms: number | null;
    jitter_ms: number | null;
    packet_loss_pct: number;
    ipv4_ok: boolean;
    mtu_1500_ok: boolean | null;
    default_interface: string;
    is_wifi: boolean;
    awdl_active: boolean;
    noisy_processes: string[];
    warnings: string[];
  };
  firewall?: {
    psn_sys_tls_ok: boolean;
    psn_cf_tls_ok: boolean;
    udp_high_port_ok: boolean;
    diagnosis: string;
  };
  recommended_preset: {
    name: string;
    resolution: string;
    fps: number;
    bitrate_kbps: number;
    codec: string;
    audio_buffer_size: number;
  };
  sony_app?: string | null;
  sony_bundle_ready?: boolean;
  chiaki_app: string | null;
  patched_bundle_ready: boolean;
}

function resolveDualMacCli(projectDirPref?: string): { cliPath: string; cwd: string } {
  const home = process.env.HOME || os.homedir();
  const candidates: string[] = [];

  if (projectDirPref && projectDirPref.trim().length > 0) {
    const expanded = projectDirPref.trim().replace(/^~/, home);
    candidates.push(path.join(expanded, "bin", "dualmac"));
  }

  candidates.push(
    path.join(home, ".local", "bin", "dualmac"),
    "/opt/homebrew/bin/dualmac",
    "/usr/local/bin/dualmac"
  );

  for (const cand of candidates) {
    if (fs.existsSync(cand)) {
      const real = fs.realpathSync(cand);
      const repoRoot = path.dirname(path.dirname(real));
      return { cliPath: cand, cwd: fs.existsSync(repoRoot) ? repoRoot : home };
    }
  }

  const fallback = candidates[0] || path.join(home, ".local", "bin", "dualmac");
  return { cliPath: fallback, cwd: home };
}

export function getCliContext() {
  const prefs = getPreferenceValues<Preferences>();
  const { cliPath, cwd } = resolveDualMacCli(prefs.projectDir);
  const host = (prefs.homeHost || "1.1.1.1").trim() || "1.1.1.1";
  const home = process.env.HOME || os.homedir();
  const env = {
    ...process.env,
    PATH: `${home}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${process.env.PATH || ""}`,
  };
  return { cliPath, cwd, host, privilegedByDefault: Boolean(prefs.privilegedByDefault), env };
}

export async function runDoctor(): Promise<DoctorResult> {
  const { cliPath, cwd, host, env } = getCliContext();
  if (!fs.existsSync(cliPath)) {
    throw new Error(`DualMac CLI not found at ${cliPath}. Run \`make install\` in your DualMac folder first.`);
  }
  const { stdout } = await execFileAsync(cliPath, ["doctor", "--host", host, "--json"], {
    cwd,
    env,
    timeout: 25000,
  });
  return JSON.parse(stdout) as DoctorResult;
}

export async function launchGta6(
  preset: string,
  privileged: boolean,
  client: "sony" | "chiaki" = "sony"
): Promise<void> {
  const { cliPath, cwd, host, env } = getCliContext();
  if (!fs.existsSync(cliPath)) {
    await showToast({
      style: Toast.Style.Failure,
      title: "DualMac CLI not found",
      message: "Run `make install` in your DualMac directory or set the folder in preferences.",
    });
    return;
  }

  const logDir = path.join(process.env.HOME || os.homedir(), ".local", "share", "dualmac");
  fs.mkdirSync(logDir, { recursive: true });
  const logFd = fs.openSync(path.join(logDir, "raycast-launch.log"), "a");

  const args = ["start", "--client", client, "--profile", "gta6", "--preset", preset, "--host", host];
  if (privileged) {
    args.push("--privileged", "--gui-sudo");
  }

  const child = spawn(cliPath, args, {
    cwd,
    env,
    detached: true,
    stdio: ["ignore", logFd, logFd],
  });
  child.unref();
  fs.closeSync(logFd);

  const label = client === "sony" ? "PS Remote Play (Sony)" : `chiaki-ng (${preset})`;
  await closeMainWindow();
  await showHUD(
    privileged
      ? `DualMac [${label} + AWDL Fix] — Capture: '0' · Aim: CapsLock/Ctrl · Car: G · Air: O`
      : `DualMac [${label}] — Capture: '0' · Aim: CapsLock/Ctrl · Car: G · Air: O`
  );
}

export async function runRestore(restorePlist: boolean): Promise<string> {
  const { cliPath, cwd, env } = getCliContext();
  const args = ["restore", "--gui-sudo"];
  if (restorePlist) {
    args.push("--plist");
  }
  const { stdout } = await execFileAsync(cliPath, args, {
    cwd,
    env,
    timeout: 20000,
  });
  return stdout.trim() || "System is already clean.";
}

export const MACBOOK_CONTROLS_MD = `
### GTA 6 MacBook Trackpad + Keyboard Controls (Official Scheme + ✦ Smart Pack)

| Input | Action |
|---|---|
| **\`0\` (Zero)** | **Toggle Capture ON / OFF** *(auto-releases on window switch)* |
| **\`F\` / \`G\` / \`O\`** | \`F\`: Enter/Exit (\`△\` + Auto Foot↔Car) · \`G\`: Manual Car · \`O\`: **Aircraft / Heli Mode** |
| **\`U\` / \`I\` / \`Y\` (Hold)** | \`U\`: Hotwire (\`◡\`) · \`I\`: **360° Full-Circle (\`R\`)** · \`Y\`: Sticky Right-Stick |
| **\`L\` (Hold)** | **Rapid-Tap \`✕\` (12.5 Hz)** — Bicycle / Swim / QTE Assist |
| **2-Finger Scroll** | Normal: **DualSense Touchpad Swipe** · Aiming (\`L2\`): **Sniper Zoom** (\`D-Pad ↑/↓\`) |
| **\`-\` / \`=\`** | **Live Sensitivity** (\`±0.10\`, auto-saved to \`gta6.json\`) |
| **\`[\` / \`;\` / \`H\` / \`T\`** | **PS5 Mic Mute** · **Live Ping/AWDL Pill** · Compact HUD · Smart Mode |
| **\`]\` (Toggle)** | Auto-Sprint (On-Foot) · Cruise Control (Car) · Cruise Throttle (Air) |
| **Trackpad Swipe** | Right Analog Stick (Camera & Aim — auto-sticky radial wheel on \`Tab\`/\`Q\`) |
| **Trackpad Click / \`J\`** | **R2** (Shoot) · Car: \`L1\` (Drive-By) · Air: \`✕\` (Fire) |
| **\`Caps Lock\` (Ctrl) / \`K\`** | **L2** (Aim / Interact — hold \`+Z\` for **Precision Sniper Aim**) |
| **\`W / A / S / D\`** | On-Foot: Move (\`Z\` Walk) · Car: Gas/Brake/Smooth Steer · Air: Throttle/Roll |
| **Aircraft Pitch / Yaw** | \`↑ / ↓\` (or \`Shift / C\`): Pitch (\`LY\`) · \`Q / E\` (or \`← / →\`): Rudder (\`L1 / R1\`) · \`R\`: Gear (\`L3\`) |
| **\`Shift\` / \`Space\` / \`C\`** | Sprint (\`L3\`) / Jump-Climb (\`✕\`; Car Handbrake \`R1\`) / Crouch (\`◯\`) |
| **\`E\` / \`R\`-\`V\` / \`Q\` / \`Tab\`** | Pure Interact (\`△\`) / Melee (\`▢\`) / Cover (\`R1\`) / Weapon Wheel (\`L1\`) |
| **\`M\` / \`Esc\` / \`Enter\` / \`⌫\`** | Map (\`Touchpad\`) / Pause (\`Options\`) / Confirm (\`✕\`) / Back (\`◯\`) |
`;
