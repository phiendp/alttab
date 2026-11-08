import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Ui
import "AlttabModel.js" as Model

// Alttab overlay: hold Super, tap Tab to cycle windows (most recent first),
// release Super to switch. Live window previews via the Hyprland toplevel
// export protocol (ScreencopyView).
//
// Driven by Hyprland global shortcuts, so a Tab press reaches this item as a
// Wayland event with no process spawn in between (see alttab.lua):
//   SUPER + TAB          -> global io.github.phiendp.alttab:next
//   SUPER + SHIFT + TAB  -> global io.github.phiendp.alttab:prev
//   Super released       -> global io.github.phiendp.alttab:commit
//                           (an input.keyboard.key hook in alttab.lua)
// The overlay also commits itself when it sees the Super key released while
// it holds keyboard focus; whichever signal arrives first wins.
//
// Also reachable over IPC for scripting and tests:
//   omarchy-shell shell summon io.github.phiendp.alttab '{"direction": 1}'
//   omarchy-shell shell call   io.github.phiendp.alttab step 1
//   omarchy-shell shell call   io.github.phiendp.alttab commit ""
//   omarchy-shell shell call   io.github.phiendp.alttab debug ""
Item {
  id: root

  // Injected by omarchy-shell after the Loader resolves (see shell.qml).
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.phiendp.alttab"

  property bool opened: false
  property var windows: []
  property int selectedIndex: 0
  property bool cursorActive: true
  property var targetScreen: null

  // The window commit() picked, waiting for the overlay to leave the screen.
  property var pendingFocus: null

  // Most-recently-used window addresses, maintained from Hyprland IPC events
  // so the order is right the instant Tab is pressed (no round trip).
  property var mru: []

  // Settings come from this plugin's entry in shell.json:
  //   { "id": "io.github.phiendp.alttab", "scope": "all|monitor|workspace",
  //     "includeSpecial": false, "liveThumbnails": true, "thumbnailHeight": 150 }
  property var settings: ({})
  readonly property string scope: String(root.settings.scope || "all")
  readonly property bool includeSpecial: root.settings.includeSpecial === true
  readonly property bool liveThumbnails: root.settings.liveThumbnails !== false
  readonly property bool showHints: root.settings.showHints !== false

  // Theme tokens: share the [menu] surface so themes that style the Omarchy
  // menu style this overlay too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  // Geometry.
  property int contentMargin: Style.spacing.panelPadding
  property int cellPadding: Style.spacing.md
  property int cellSpacing: Style.spacing.lg
  property int thumbHeight: Style.space(Number(root.settings.thumbnailHeight || 150))
  property int thumbMinWidth: Style.space(110)
  property int thumbMaxWidth: Style.space(290)
  property int iconSize: Style.space(18)
  property int badgeSize: Style.space(28)
  property int labelHeight: Math.max(root.iconSize, Style.font.body) + Style.spacing.xs
  property int captionHeight: Style.font.caption + Style.spacing.xs
  property int cellHeight: root.cellPadding * 2 + root.thumbHeight + Style.spacing.sm + root.labelHeight + root.captionHeight
  property int footerHeight: root.showHints ? Style.font.caption + Style.spacing.sm : 0
  property int maxCardWidth: panel.width - Style.space(80)
  property int cardWidth: Math.max(root.thumbMinWidth, Math.min(row.implicitWidth + root.contentMargin * 2, root.maxCardWidth))
  property int cardHeight: root.contentMargin * 2 + root.cellHeight + (root.showHints ? Style.spacing.md + root.footerHeight : 0)

  // ---------------------------------------------------------------- lifecycle

  // Shell contract. summon() lands here with an optional {"direction": -1}.
  function open(payloadJson) {
    var p = Model.parsePayload(payloadJson)
    root.step(p.direction)
  }

  // Called by the shell on `hide`.
  function close() {
    root.cancel()
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.step(1)
  }

  // Open if needed, then move the cursor. `delta` may arrive as a string over IPC.
  function step(delta) {
    var d = Number(delta)
    if (isNaN(d) || d === 0) d = 1
    d = d < 0 ? -1 : 1
    if (!root.opened) {
      if (root.pendingFocus) root.flushPendingFocus()
      var list = root.collect()
      if (list.length === 0) return "no windows"
      root.windows = list
      root.selectedIndex = 0
      strip.contentX = 0
      root.cursorActive = true
      root.targetScreen = root.focusedScreen()
      root.opened = true
      // Reconcile titles/classes for windows that predate the shell; the
      // list itself is already ordered from the MRU cache.
      Hyprland.refreshToplevels()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
    root.move(d)
    return "ok"
  }

  function move(delta) {
    var n = root.windows.length
    if (n === 0) return
    root.cursorActive = true
    root.selectedIndex = (root.selectedIndex + delta + n) % n
    root.ensureVisible(root.selectedIndex)
  }

  function select(index) {
    var i = Number(index)
    if (isNaN(i) || i < 0 || i >= root.windows.length) return
    root.cursorActive = true
    root.selectedIndex = i
    root.ensureVisible(i)
  }

  // Focus the highlighted window and close. Idempotent: the Super release can
  // arrive both as a key event and as a global shortcut.
  function commit() {
    if (!root.opened) return "closed"
    var w = root.windows[root.selectedIndex]
    root.finish()
    if (!w) return "nothing selected"
    // Not focused yet: the overlay's layer surface holds exclusive keyboard
    // focus until Hyprland has unmapped it, a few frames after `opened` goes
    // false. Hyprland refuses window focus while such a layer is mapped and,
    // once it unmaps, hands focus back to the window that had it before, so a
    // focus dispatched right here was lost about half the time. Focus on the
    // layer's closelayer event instead (see onRawEvent), with a timer in case
    // the surface never got mapped and no such event comes.
    root.pendingFocus = w
    focusFallback.restart()
    return "ok"
  }

  function flushPendingFocus() {
    focusFallback.stop()
    var w = root.pendingFocus
    root.pendingFocus = null
    if (w) root.focusWindow(w)
  }

  // Hyprland with a Lua config parses dispatch requests as Lua, so the plain
  // "focuswindow address:..." form is a syntax error there. Omarchy's own
  // omarchy-launch-or-focus uses the same Lua selector.
  function focusWindow(w) {
    if (!w) return
    if (Hyprland.usingLua) Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + w.address + '" })')
    else Hyprland.dispatch("focuswindow address:0x" + w.address)
  }

  // Dev helpers: focus the Nth window of the current list by either path.
  function focusLua(index) {
    var w = root.collect()[Number(index)]
    root.focusWindow(w)
    return w ? w.address : "none"
  }
  function activateWayland(index) {
    var w = root.collect()[Number(index)]
    if (!w || !w.wayland) return "no handle"
    w.wayland.activate()
    return w.address
  }

  function choose(index) {
    root.select(index)
    return root.commit()
  }

  function cancel() {
    root.finish()
  }

  function dismiss() {
    root.cancel()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function finish() {
    root.opened = false
    // Drop the model so every ScreencopyView stops capturing.
    root.windows = []
  }

  // ---------------------------------------------------------------- data

  function focusedScreen() {
    var mon = Hyprland.focusedMonitor
    var name = mon ? mon.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function collect() {
    var raw = []
    var values = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < values.length; i++) {
      var t = values[i]
      if (!t) continue
      var w = t.wayland
      var ws = t.workspace
      var mon = t.monitor
      var ipc = t.lastIpcObject || {}
      // Skip windows Hyprland is not showing: unmapped or hidden ones, and
      // transient surfaces (menus, popups) that carry neither class nor title.
      if (ipc.mapped === false || ipc.hidden === true) continue
      var appId = (w && w.appId) || ipc["class"] || ipc.initialClass || ""
      var title = t.title || (w ? w.title : "") || ipc.title || ""
      if (!appId && !title) continue
      raw.push({
        address: Model.normalizeAddress(t.address),
        title: title,
        appId: appId,
        icon: root.iconFor(appId),
        workspaceId: ws ? ws.id : (ipc.workspace ? ipc.workspace.id : undefined),
        workspaceName: ws ? ws.name : (ipc.workspace ? ipc.workspace.name : ""),
        monitorName: mon ? mon.name : "",
        focusHistoryID: typeof ipc.focusHistoryID === "number" ? ipc.focusHistoryID : -1,
        toplevel: t,
        wayland: w
      })
    }
    var fmon = Hyprland.focusedMonitor
    var fws = Hyprland.focusedWorkspace
    var filtered = Model.filterWindows(raw, root.scope, fmon ? fmon.name : "", fws ? fws.id : undefined, root.includeSpecial)
    return Model.orderWindows(filtered, root.mru)
  }

  function iconFor(appId) {
    var candidates = Model.iconCandidates(appId)
    for (var i = 0; i < candidates.length; i++) {
      try {
        var entry = DesktopEntries.heuristicLookup(candidates[i])
        if (entry && entry.icon) {
          var p = Quickshell.iconPath(entry.icon, true)
          if (p) return p
        }
      } catch (e) {}
    }
    for (var j = 0; j < candidates.length; j++) {
      var direct = Quickshell.iconPath(candidates[j], true)
      if (direct) return direct
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  function removeWindow(address) {
    var a = Model.normalizeAddress(address)
    root.mru = Model.remove(root.mru, a)
    if (!root.opened) return
    var next = root.windows.filter(function(w) { return w.address !== a })
    if (next.length === root.windows.length) return
    if (next.length === 0) { root.dismiss(); return }
    var keep = root.windows[root.selectedIndex]
    root.windows = next
    var idx = keep ? next.findIndex(function(w) { return w.address === keep.address }) : -1
    root.selectedIndex = idx >= 0 ? idx : Math.min(root.selectedIndex, next.length - 1)
  }

  // Scroll the strip so the highlighted cell is in view. Deferred, because
  // step() calls this in the same tick that sets the model, before the
  // Flickable has its final width; clamped so a short list never scrolls.
  function ensureVisible(index) {
    Qt.callLater(function() {
      var item = cells.itemAt(index)
      if (!item || strip.width <= 0) return
      var maxX = Math.max(0, strip.contentWidth - strip.width)
      var x = strip.contentX
      var left = item.x, right = item.x + item.width
      if (right > x + strip.width) x = right - strip.width
      if (left < x) x = left
      strip.contentX = Math.max(0, Math.min(maxX, x))
    })
  }

  // Dev helpers.
  //   omarchy-shell shell call io.github.phiendp.alttab debug ""
  //   omarchy-shell shell call io.github.phiendp.alttab snapshot /tmp/alttab.png
  function debug() {
    return JSON.stringify({
      rev: 5,
      opened: root.opened,
      selectedIndex: root.selectedIndex,
      scope: root.scope,
      settings: root.settings,
      mru: root.mru,
      screen: root.targetScreen ? root.targetScreen.name : null,
      windows: (root.opened ? root.windows : root.collect()).map(function(w) {
        return { address: w.address, appId: w.appId, title: w.title, ws: Model.workspaceLabel(w), monitor: w.monitorName, icon: w.icon, hist: w.focusHistoryID }
      })
    })
  }

  function snapshot(path) {
    if (!root.opened || !path) return "not open"
    var ok = card.grabToImage(function(result) {
      var saved = result.saveToFile(String(path))
      console.log("alttab snapshot", saved ? "saved" : "FAILED", path)
    })
    return ok ? "ok" : "grab failed"
  }

  // ---------------------------------------------------------------- wiring

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event.name
      if (name === "activewindowv2") root.mru = Model.bump(root.mru, event.data)
      else if (name === "closewindow") root.removeWindow(event.data)
      else if (name === "closelayer" && event.data === "omarchy-alttab") root.flushPendingFocus()
    }
  }

  // Seed the MRU list from Hyprland's own focus history on load, so windows
  // opened before the shell started still come out in a sensible order.
  Component.onCompleted: {
    Hyprland.refreshToplevels()
    seedTimer.start()
  }
  Timer {
    id: seedTimer
    interval: 400
    onTriggered: {
      if (root.mru.length > 0) return
      var values = Hyprland.toplevels ? Hyprland.toplevels.values : []
      var pairs = []
      for (var i = 0; i < values.length; i++) {
        var ipc = values[i].lastIpcObject || {}
        if (typeof ipc.focusHistoryID === "number") pairs.push({ a: Model.normalizeAddress(values[i].address), h: ipc.focusHistoryID })
      }
      pairs.sort(function(x, y) { return x.h - y.h })
      root.mru = pairs.map(function(p) { return p.a })
    }
  }

  Timer {
    id: focusFallback
    interval: 150
    onTriggered: root.flushPendingFocus()
  }

  GlobalShortcut {
    appid: root.pluginId
    name: "next"
    description: "Window switcher: next window"
    onPressed: root.step(1)
  }
  GlobalShortcut {
    appid: root.pluginId
    name: "prev"
    description: "Window switcher: previous window"
    onPressed: root.step(-1)
  }
  GlobalShortcut {
    appid: root.pluginId
    name: "commit"
    description: "Window switcher: switch to the highlighted window"
    onPressed: root.commit()
    onReleased: root.commit()
  }

  FileView {
    id: shellConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    onFileChanged: shellConfig.reload()
    onLoaded: root.settings = Model.settingsFromShellJson(shellConfig.text(), root.pluginId)
  }

  // ---------------------------------------------------------------- surface

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-alttab"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var back = (event.modifiers & Qt.ShiftModifier) !== 0
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
          } else if (event.key === Qt.Key_Tab) {
            root.move(back ? -1 : 1)
          } else if (event.key === Qt.Key_Backtab) {
            root.move(-1)
          } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down || event.key === Qt.Key_L || event.key === Qt.Key_J) {
            root.move(1)
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up || event.key === Qt.Key_H || event.key === Qt.Key_K) {
            root.move(-1)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.commit()
          } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            var i = event.key - Qt.Key_1
            if (i < root.windows.length) root.choose(i)
          } else {
            return
          }
          event.accepted = true
        }
        // Letting go of Super is the switch.
        Keys.onReleased: function(event) {
          if (event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R) {
            root.commit()
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        Flickable {
          id: strip
          width: parent.width
          height: root.cellHeight
          contentWidth: row.implicitWidth
          contentHeight: height
          clip: true
          interactive: false
          boundsBehavior: Flickable.StopAtBounds
          Behavior on contentX { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

          Row {
            id: row
            spacing: root.cellSpacing
            // Center the strip when it is narrower than the card.
            x: Math.max(0, (strip.width - row.implicitWidth) / 2)

            Repeater {
              id: cells
              model: root.windows

              delegate: Rectangle {
                id: cell
                required property int index
                required property var modelData
                readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
                readonly property real aspect: thumb.hasContent && thumb.sourceSize.height > 0
                  ? thumb.sourceSize.width / thumb.sourceSize.height : 16 / 10
                readonly property int thumbWidth: Math.round(Math.max(root.thumbMinWidth, Math.min(root.thumbMaxWidth, root.thumbHeight * aspect)))
                // Fit the capture inside the thumbnail box, preserving aspect.
                readonly property int fitWidth: Math.round(Math.min(thumbWidth, root.thumbHeight * aspect))
                readonly property int fitHeight: Math.round(Math.min(root.thumbHeight, fitWidth / aspect))

                width: thumbWidth + root.cellPadding * 2
                height: root.cellHeight
                radius: root.cornerRadius
                color: hasCursor ? root.selectedBackground : "transparent"

                Column {
                  anchors.fill: parent
                  anchors.margins: root.cellPadding
                  spacing: Style.spacing.sm

                  Item {
                    width: cell.thumbWidth
                    height: root.thumbHeight

                    Rectangle {
                      anchors.fill: parent
                      radius: Math.max(2, root.cornerRadius / 2)
                      color: Util.alpha(cell.hasCursor ? root.selectedText : root.foreground, 0.08)
                    }

                    ScreencopyView {
                      id: thumb
                      anchors.centerIn: parent
                      width: cell.fitWidth
                      height: cell.fitHeight
                      captureSource: cell.modelData.wayland || null
                      live: root.liveThumbnails && root.opened
                      paintCursor: false
                      constraintSize: Qt.size(root.thumbMaxWidth * 2, root.thumbHeight * 2)
                    }

                    // No capture yet (or the compositor cannot export this
                    // window): show a big app icon instead of an empty box.
                    Image {
                      anchors.centerIn: parent
                      visible: !thumb.hasContent
                      width: Style.space(48)
                      height: width
                      source: cell.modelData.icon || ""
                      sourceSize: Qt.size(width * 2, height * 2)
                      fillMode: Image.PreserveAspectFit
                      smooth: true
                      opacity: 0.85
                    }

                    // App icon badge over the preview.
                    Image {
                      visible: thumb.hasContent && !!cell.modelData.icon
                      anchors.right: parent.right
                      anchors.bottom: parent.bottom
                      anchors.margins: Style.spacing.xs
                      width: root.badgeSize
                      height: width
                      source: cell.modelData.icon || ""
                      sourceSize: Qt.size(width * 2, height * 2)
                      fillMode: Image.PreserveAspectFit
                      smooth: true
                    }

                    // Hotkey badge, top-left.
                    Rectangle {
                      visible: Model.hotkeyFor(cell.index) !== ""
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.margins: Style.spacing.xs
                      width: Style.space(20)
                      height: width
                      radius: Math.max(2, root.cornerRadius / 2)
                      color: Util.alpha(root.background, 0.75)
                      border.width: 1
                      border.color: Util.alpha(cell.hasCursor ? root.selectedText : root.foreground, cell.hasCursor ? 0.9 : 0.4)
                      Text {
                        anchors.centerIn: parent
                        text: Model.hotkeyFor(cell.index)
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  Row {
                    width: cell.thumbWidth
                    height: root.labelHeight
                    spacing: Style.spacing.sm
                    Image {
                      anchors.verticalCenter: parent.verticalCenter
                      width: root.iconSize
                      height: width
                      source: cell.modelData.icon || ""
                      sourceSize: Qt.size(width * 2, height * 2)
                      fillMode: Image.PreserveAspectFit
                      smooth: true
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - root.iconSize - parent.spacing
                      textFormat: Text.PlainText
                      text: cell.modelData.title || cell.modelData.appId || "(untitled)"
                      color: cell.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    width: cell.thumbWidth
                    height: root.captionHeight
                    textFormat: Text.PlainText
                    text: (Model.workspaceLabel(cell.modelData) ? "workspace " + Model.workspaceLabel(cell.modelData) : "")
                      + (cell.modelData.appId ? "  ·  " + cell.modelData.appId : "")
                    color: cell.hasCursor ? root.selectedText : root.foreground
                    opacity: 0.58
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.select(cell.index)
                  onClicked: root.choose(cell.index)
                }
              }
            }
          }
        }

        Text {
          visible: root.showHints
          width: parent.width
          height: root.footerHeight
          textFormat: Text.PlainText
          text: "Tab / Shift+Tab move   release Super to switch   ↵ select   1-9 quick pick   Esc cancel"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
    }
  }
}
