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

-- Arrow keys while the switcher is open. Hyprland binds SUPER+LEFT/RIGHT to
-- "focus window left/right" and consumes them before the overlay can see
-- them, so take the keys here and decide per press: the overlay's layer
-- surface exists only while it is on screen (Omarchy's capture-region binds
-- key off the same fact), so a lookup by namespace is the open/closed test.
-- Closed, the default focus-left/right behaviour is kept.
local function alttab_open()
  return #hl.get_layers({ namespace = "omarchy-alttab" }) > 0
end

local function alttab_or(shortcut, fallback)
  return function()
    if alttab_open() then
      hl.dispatch(hl.dsp.global(alttab .. ":" .. shortcut))
    else
      hl.dispatch(fallback)
    end
  end
end

hl.unbind("SUPER + LEFT")
hl.unbind("SUPER + RIGHT")
o.bind("SUPER + LEFT", "Window switcher: previous window / focus on left window",
  alttab_or("prev", hl.dsp.focus({ direction = "l" })), { repeating = true })
o.bind("SUPER + RIGHT", "Window switcher: next window / focus on right window",
  alttab_or("next", hl.dsp.focus({ direction = "r" })), { repeating = true })
