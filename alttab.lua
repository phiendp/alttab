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

-- Set when SUPER+TAB opens or steps the switcher, cleared when Super goes up.
local armed = false

local function shortcut(name)
  return function()
    armed = true
    hl.dispatch(hl.dsp.global(alttab .. ":" .. name))
  end
end

o.bind("SUPER + TAB", "Window switcher: next window", shortcut("next"), { repeating = true })
o.bind("SUPER + SHIFT + TAB", "Window switcher: previous window", shortcut("prev"), { repeating = true })

-- Releasing Super switches to the highlighted window.
--
-- A release bind on SUPER_L does not work for this: Hyprland never fires it
-- after another bind (SUPER+TAB) was used during the same hold, so it never
-- committed once in testing. The overlay also commits when it sees Super go up,
-- but only once its layer surface has keyboard focus, ~50-70ms after Tab. A
-- quick flick releases Super before that and the overlay stayed open until the
-- next SUPER+TAB, which then switched one window too far.
--
-- So watch the key itself, compositor-side, which sees every release whatever
-- has keyboard focus. Only a release that follows a SUPER+TAB commits; any
-- other Super release costs one table lookup. The global shortcut queues behind
-- the next/prev ones on the same connection, so the overlay has always opened
-- by the time it arrives. Keycodes: evdev 125/126 (Super_L/R), xkb 133/134.
local SUPER_KEYS = { [125] = true, [126] = true, [133] = true, [134] = true }

hl.on("input.keyboard.key", function(keycode, _, state)
  if armed and state == 0 and SUPER_KEYS[keycode] then
    armed = false
    hl.dispatch(hl.dsp.global(alttab .. ":commit"))
  end
end)

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
