# helium

Settings for the [Helium](https://helium.computer) browser (`helium-browser`
cask). Helium keeps its config in mutable Chromium JSON files under
`~/Library/Application Support/net.imput.helium`, so nothing here is
symlinked; `settings.json` lists the keys to enforce and `setup/helium.sh`
(`make helium`, part of `make setup`) merges them in with `jq`.

What it turns on: the translucent window frame ("native frame materials").
That takes two keys, both required:

- `local_state.enabled_labs_experiments` gets `helium-native-frame-materials@1`
  (the `helium://flags` entry set to Enabled), written to `Local State`.
- `preferences.helium.browser.native_frame_materials = true` (the
  Settings > Appearance toggle the flag reveals), written to every profile's
  `Preferences`.

Helium rewrites these files on exit, so the script refuses to run while
Helium is open. Quit Helium, run `make helium`, relaunch. On a machine where
Helium has never launched, the script seeds `Local State` only; launch Helium
once, quit, and rerun to set the profile pref.

The frame's opacity/material is fixed upstream; there is no setting for it.
