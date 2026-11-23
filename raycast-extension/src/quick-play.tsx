import { getCliContext, launchGta6 } from "./lib";

export default async function QuickPlayCommand() {
  const { privilegedByDefault } = getCliContext();
  await launchGta6("auto", privilegedByDefault, "sony");
}
