-- Alttab window switcher bindings (io.github.phiendp.alttab).
--
-- Load from ~/.config/hypr/bindings.lua:
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.phiendp.alttab/alttab.lua")
--
-- Every bind here uses Hyprland's `global` dispatcher, which delivers the
-- shortcut to the running Omarchy shell as a Wayland event. No process is
-- spawned per Tab press, so cycling stays snappy.

local alttab = "io.github.phiendp.alttab"

-- Omarchy ships SUPER+TAB / SUPER+SHIFT+TAB as next/previous workspace.
-- SUPER+CTRL+TAB ("former workspace") is left alone.
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")

o.bind("SUPER + TAB", "Window switcher: next window",
  hl.dsp.global(alttab .. ":next"), { repeating = true })
o.bind("SUPER + SHIFT + TAB", "Window switcher: previous window",
  hl.dsp.global(alttab .. ":prev"), { repeating = true })

-- Releasing Super switches to the highlighted window. Fires on every Super
-- release system-wide, but it is a single Wayland event and the overlay
-- ignores it unless it is open.
o.bind("SUPER + SUPER_L", nil, hl.dsp.global(alttab .. ":commit"), { release = true })
o.bind("SUPER + SUPER_R", nil, hl.dsp.global(alttab .. ":commit"), { release = true })
