import { showHUD, showToast, Toast } from "@raycast/api";
import { runRestore } from "./lib";

export default async function RestoreSystemCommand() {
  try {
    const output = await runRestore(false);
    await showHUD(`DualMac Restore: ${output.split("\n")[0]}`);
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Restore failed",
      message: e instanceof Error ? e.message : String(e),
    });
  }
}
