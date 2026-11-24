/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Senza Directory (Optional) - Leave empty if installed via `make install` (~/.local/bin/senza), or pick your cloned senza folder */
  "projectDir": string,
  /** Home PS5 / WAN Probe Host - Optional home IP or DDNS hostname for latency/jitter probing (default: 1.1.1.1) */
  "homeHost": string,
  /** Pause Wi-Fi AWDL by Default - undefined */
  "privilegedByDefault": boolean
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `play-gta6` command */
  export type PlayGta6 = ExtensionPreferences & {}
  /** Preferences accessible in the `quick-play` command */
  export type QuickPlay = ExtensionPreferences & {}
  /** Preferences accessible in the `network-doctor` command */
  export type NetworkDoctor = ExtensionPreferences & {}
  /** Preferences accessible in the `restore-system` command */
  export type RestoreSystem = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `play-gta6` command */
  export type PlayGta6 = {}
  /** Arguments passed to the `quick-play` command */
  export type QuickPlay = {}
  /** Arguments passed to the `network-doctor` command */
  export type NetworkDoctor = {}
  /** Arguments passed to the `restore-system` command */
  export type RestoreSystem = {}
}

