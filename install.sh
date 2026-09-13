#!/bin/bash
# Install alttab: enable the Omarchy shell plugin and wire SUPER+TAB to it.
set -euo pipefail
PLUGIN_ID=io.github.phiendp.alttab
PLUGIN_DIR=~/.config/omarchy/plugins/$PLUGIN_ID
BINDINGS=~/.config/hypr/bindings.lua
LOAD_LINE='dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.phiendp.alttab/alttab.lua")'
here=$(cd "$(dirname "$0")" && pwd -P)

# `omarchy plugin add <git-url>` clones straight into $PLUGIN_DIR. When this
# script runs from a checkout elsewhere, copy the plugin there first (symlinks
# are rejected inside plugin folders, so a real copy is required).
if [[ $here != "$(readlink -f "$PLUGIN_DIR")" ]]; then
  mkdir -p "$PLUGIN_DIR"
  cp -a "$here"/. "$PLUGIN_DIR"/
fi

omarchy plugin validate "$PLUGIN_DIR"
omarchy-shell shell rescanPlugins >/dev/null
omarchy plugin list --json | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id and .enabled)' >/dev/null \
  || omarchy plugin enable "$PLUGIN_ID"

# Wire the keybindings. Appended once; the loaded file owns the unbinds.
if ! grep -qF "$LOAD_LINE" "$BINDINGS" 2>/dev/null; then
  cat >> "$BINDINGS" <<LUA

--------------------------------------------------------------------------
-- Alttab window switcher (io.github.phiendp.alttab)
--------------------------------------------------------------------------
-- Takes SUPER+TAB / SUPER+SHIFT+TAB (were: next/previous workspace).
-- Hold Super, tap Tab to cycle windows, release Super to switch.
$LOAD_LINE
LUA
fi

hyprctl reload >/dev/null
errors=$(hyprctl configerrors)
if [[ -n $errors && $errors != "no errors" ]]; then
  echo "hyprctl configerrors:" >&2
  echo "$errors" >&2
  exit 1
fi

echo "plugin:   $PLUGIN_ID (enabled)"
echo "bindings: SUPER+TAB next, SUPER+SHIFT+TAB previous, release Super to switch"
echo "settings: add \"scope\": \"monitor\" or \"workspace\" to the plugin entry in ~/.config/omarchy/shell.json to narrow the list"
