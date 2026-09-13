.pragma library

// Pure helpers for the Alttab overlay. No Qt objects in here so the logic can
// be read (and tested) without the shell running.

// Hyprland prints window addresses as "0x563d8c9a2800" in `hyprctl clients`
// but as "563d8c9a2800" in IPC events. Compare them in one form.
function normalizeAddress(address) {
  var s = String(address === undefined || address === null ? "" : address).trim().toLowerCase()
  if (s.indexOf("0x") === 0) s = s.slice(2)
  return s
}

// Most-recently-used list maintenance. `mru` is an array of normalized
// addresses, most recent first. Both return a new array (QML only notices
// property changes when the object identity changes).
function bump(mru, address) {
  var a = normalizeAddress(address)
  if (!a) return mru
  var out = [a]
  for (var i = 0; i < mru.length; i++) if (mru[i] !== a) out.push(mru[i])
  return out.slice(0, 256)
}

function remove(mru, address) {
  var a = normalizeAddress(address)
  var out = []
  for (var i = 0; i < mru.length; i++) if (mru[i] !== a) out.push(mru[i])
  return out
}

// Order windows most-recent-first. Windows the MRU list has never seen (open
// since before the shell started) fall back to Hyprland's own focusHistoryID,
// then to title so the order is at least stable.
function orderWindows(windows, mru) {
  var rank = {}
  for (var i = 0; i < mru.length; i++) rank[mru[i]] = i
  var big = 1e9
  var decorated = windows.map(function(w, i) {
    var r = rank[w.address]
    var h = w.focusHistoryID
    return {
      w: w,
      mru: r === undefined ? big : r,
      hist: typeof h === "number" && h >= 0 ? h : big,
      i: i
    }
  })
  decorated.sort(function(a, b) {
    if (a.mru !== b.mru) return a.mru - b.mru
    if (a.hist !== b.hist) return a.hist - b.hist
    return a.i - b.i
  })
  return decorated.map(function(d) { return d.w })
}

// scope: "all" (default) | "monitor" | "workspace"
function inScope(w, scope, focusedMonitorName, focusedWorkspaceId) {
  if (scope === "monitor") return !focusedMonitorName || w.monitorName === focusedMonitorName
  if (scope === "workspace") return focusedWorkspaceId === undefined || focusedWorkspaceId === null || w.workspaceId === focusedWorkspaceId
  return true
}

function filterWindows(windows, scope, focusedMonitorName, focusedWorkspaceId, includeSpecial) {
  return windows.filter(function(w) {
    if (!includeSpecial && String(w.workspaceName || "").indexOf("special:") === 0) return false
    return inScope(w, scope, focusedMonitorName, focusedWorkspaceId)
  })
}

// Candidate icon names for a window class / app id, most specific first.
//   "google-chrome"                    -> google-chrome
//   "chrome-github.com__-Default"      -> (Omarchy web app) google-chrome
//   "org.gnome.Nautilus"               -> org.gnome.Nautilus, nautilus
//   "Alacritty"                        -> Alacritty, alacritty
function iconCandidates(appId) {
  var s = String(appId || "").trim()
  var out = []
  function add(v) { if (v && out.indexOf(v) === -1) out.push(v) }
  add(s)
  add(s.toLowerCase())
  if (/^chrome-/.test(s)) add("google-chrome")
  if (/^brave-/.test(s)) add("brave-browser")
  if (/^chromium-/.test(s)) add("chromium")
  var dot = s.lastIndexOf(".")
  if (dot > 0 && dot < s.length - 1) add(s.slice(dot + 1).toLowerCase())
  return out
}

function parsePayload(payloadJson) {
  var direction = 1
  try {
    var p = JSON.parse(payloadJson || "{}")
    if (p && typeof p.direction === "number" && p.direction < 0) direction = -1
  } catch (e) {}
  return { direction: direction }
}

// shell.json: { "plugins": [ { "id": "io.github.phiendp.alttab", "scope": "monitor", ... } ] }
// Everything on the entry except `id` is a setting.
function settingsFromShellJson(text, pluginId) {
  try {
    var cfg = JSON.parse(text || "{}")
    var list = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (!entry || entry.id !== pluginId) continue
      var out = {}
      for (var k in entry) if (k !== "id") out[k] = entry[k]
      return out
    }
  } catch (e) {}
  return {}
}

function workspaceLabel(w) {
  var name = String(w.workspaceName || "")
  if (name.indexOf("special:") === 0) return name.slice(8) || "special"
  if (name) return name
  return w.workspaceId !== undefined && w.workspaceId !== null ? String(w.workspaceId) : ""
}

function hotkeyFor(index) {
  return index < 9 ? String(index + 1) : ""
}
