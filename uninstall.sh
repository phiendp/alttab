#!/bin/bash
# Remove the SUPER+TAB wiring (Omarchy's workspace cycling comes back) and disable the plugin.
set -euo pipefail
PLUGIN_ID=io.github.phiendp.alttab
BINDINGS=~/.config/hypr/bindings.lua
LOAD_LINE='dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.phiendp.alttab/alttab.lua")'

if [[ -f $BINDINGS ]] && grep -qF "$LOAD_LINE" "$BINDINGS"; then
  cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"
  # Drop the load line and the comment block install.sh wrote above it.
  python3 - "$BINDINGS" "$LOAD_LINE" <<'PY'
import sys
path, line = sys.argv[1], sys.argv[2]
src = open(path).read()
block = ("\n"
  "--------------------------------------------------------------------------\n"
  "-- Alttab window switcher (io.github.phiendp.alttab)\n"
  "--------------------------------------------------------------------------\n"
  "-- Takes SUPER+TAB / SUPER+SHIFT+TAB (were: next/previous workspace).\n"
  "-- Hold Super, tap Tab to cycle windows, release Super to switch.\n"
  + line + "\n")
if block in src:
    src = src.replace(block, "")
else:
    src = "\n".join(l for l in src.split("\n") if l.strip() != line)
open(path, "w").write(src)
PY
fi

omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
hyprctl reload >/dev/null || true
echo "SUPER+TAB is back to Omarchy's workspace cycling"
echo "plugin disabled; remove its folder with: omarchy plugin remove $PLUGIN_ID"
