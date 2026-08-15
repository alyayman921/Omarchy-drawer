import QtQuick
import Quickshell
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Widget drawer: collapse chosen bar widgets into a single menu button.
//
// Widgets listed in the `widgets` inline setting (or the manifest defaults)
// are removed from the bar layout but stay mounted here — invisibly, at the
// button's position in the bar — so clicking their entry in the drawer menu
// opens their own panel anchored to the bar, right underneath the drawer.
//
// Left-clicking the hamburger opens the menu with the hidden widgets; the
// "Add / remove widgets" footer switches to a manage list that moves plugins
// between the bar and the drawer.
BarWidget {
  id: root
  moduleName: "3lymn.plugin-drawer"

  // Registry of every enabled bar-widget plugin on this bar.
  readonly property var registryWidgets: root.bar && root.bar.barWidgetRegistry
    ? root.bar.barWidgetRegistry.widgets : ({})

  // Raw configured list, read from the live in-memory config so rapid
  // successive changes never read a stale `settings` snapshot. Falls back to
  // manifest defaults when the entry has no `widgets` key yet.
  readonly property var configuredIds: {
    var rev = root.manageRevision
    void rev
    var list = null
    var shell = root.bar && root.bar.shell
    var config = shell ? shell.shellConfig : null
    if (config && config.bar && config.bar.layout) {
      var sections = ["left", "center", "right"]
      for (var s = 0; s < sections.length; s++) {
        var arr = config.bar.layout[sections[s]]
        if (!Array.isArray(arr)) continue
        for (var i = 0; i < arr.length; i++) {
          if (arr[i] && String(arr[i].id || "") === root.moduleName) {
            if (Array.isArray(arr[i].widgets)) list = arr[i].widgets
            break
          }
        }
        if (list) break
      }
    }
    if (!Array.isArray(list)) {
      var defaults = root.defaultsFor(root.moduleName)
      list = defaults && Array.isArray(defaults.widgets) ? defaults.widgets : []
    }
    if (!Array.isArray(list)) return []
    var out = []
    for (var j = 0; j < list.length; j++) {
      var id = String(list[j] || "")
      if (id) out.push(id)
    }
    return out
  }

  // Configured ids that are actually registered, so the drawer can mount them.
  readonly property var hiddenIds: {
    var out = []
    var configured = root.configuredIds
    for (var i = 0; i < configured.length; i++) {
      var id = String(configured[i] || "")
      if (id && root.registryWidgets[id]) out.push(id)
    }
    return out
  }

  // Every registered bar widget except the drawer itself, for the manage list.
  // Widgets hidden in the drawer come first, then the rest alphabetically.
  readonly property var allPlugins: {
    var reg = root.registryWidgets
    var hidden = {}
    var configured = root.configuredIds
    for (var h = 0; h < configured.length; h++) hidden[configured[h]] = true
    var out = []
    for (var id in reg) if (id !== root.moduleName) out.push(id)
    out.sort(function(a, b) {
      var ah = hidden[a] ? 0 : 1
      var bh = hidden[b] ? 0 : 1
      if (ah !== bh) return ah - bh
      var na = root.displayName(a).toLowerCase()
      var nb = root.displayName(b).toLowerCase()
      return na < nb ? -1 : (na > nb ? 1 : 0)
    })
    return out
  }

  function defaultsFor(id) {
    var entry = root.registryWidgets[id]
    return entry && entry.metadata && entry.metadata.defaults ? entry.metadata.defaults : ({})
  }

  function displayName(id) {
    var entry = root.registryWidgets[id]
    if (entry && entry.metadata && entry.metadata.displayName) return String(entry.metadata.displayName)
    return id
  }

  // --- menu state ------------------------------------------------------------

  property bool menuOpen: false
  property bool manageMode: false

  // Bumped whenever the edit menu closes so the drawer/plugin lists re-evaluate
  // from the freshly persisted config instead of showing stale entries.
  property int manageRevision: 0

  // Staged drawer membership while the edit menu is open: toggling a checkbox
  // only changes this list, so nothing moves or persists until the user leaves
  // the menu. Leaving commits the diff and restarts the shell if it changed.
  property var pendingDrawerIds: []

  function isPending(id) {
    return root.pendingDrawerIds.indexOf(String(id || "")) !== -1
  }

  function togglePending(id) {
    var key = String(id || "")
    if (!key) return
    var list = root.pendingDrawerIds.slice()
    var idx = list.indexOf(key)
    if (idx === -1) list.push(key)
    else list.splice(idx, 1)
    root.pendingDrawerIds = list
  }

  // Move every staged difference between the drawer and the bar. Returns true
  // when anything changed, so the caller knows a shell restart is worthwhile.
  function commitDrawerChanges() {
    var current = root.configuredIds.slice()
    var pending = root.pendingDrawerIds.slice()
    var changed = false
    for (var i = 0; i < pending.length; i++) {
      if (current.indexOf(pending[i]) === -1) {
        root.setDrawer(pending[i], true)
        changed = true
      }
    }
    for (var j = 0; j < current.length; j++) {
      if (pending.indexOf(current[j]) === -1) {
        root.setDrawer(current[j], false)
        changed = true
      }
    }
    return changed
  }

  function scheduleShellRestart() {
    var bar = root.bar
    if (bar && typeof bar.run === "function") bar.run("omarchy-restart-shell")
  }

  // In-drawer drag state: the id being dragged, the insertion index (before
  // that row), and whether the cursor is in the "show on bar" zone above the
  // card (i.e. over the drawer button in the bar).
  property string dragId: ""
  property bool dragActive: false
  property bool dragStarted: false
  property int dragTargetIndex: -1
  property bool dragShowZone: false
  property real dragGhostX: 0
  property real dragGhostY: 0
  readonly property real dragThreshold: Style.space(6)

  function dragStart(id) {
    root.dragId = id
    root.dragActive = true
    root.dragStarted = false
    root.dragTargetIndex = -1
    root.dragShowZone = false
  }

  function dragMove(handle, mouseX, mouseY) {
    root.dragStarted = true
    var menuPos = menuColumn.mapFromItem(handle, mouseX, mouseY)
    root.dragGhostX = menuPos.x
    root.dragGhostY = menuPos.y

    // Disabled: dragging a drawer row out of the list used to mean "drop back
    // on the bar". Cross-bar drag moves are off; rows only reorder in-drawer.
    // var local = drawerColumn.mapFromItem(handle, mouseX, mouseY)
    // var insideList = local.x >= 0 && local.x <= drawerColumn.width &&
    //   local.y >= 0 && local.y <= drawerColumn.height
    // root.dragShowZone = !insideList
    // if (root.dragShowZone) {
    //   root.dragTargetIndex = -1
    //   return
    // }
    var local = drawerColumn.mapFromItem(handle, mouseX, mouseY)
    var count = root.hiddenIds.length
    var index = Math.floor(local.y / 34)
    if (index < 0) index = 0
    if (index > count) index = count
    root.dragTargetIndex = index
  }

  function dragEnd() {
    var id = root.dragId
    var show = root.dragShowZone
    var targetIndex = root.dragTargetIndex
    root.dragId = ""
    root.dragActive = false
    root.dragStarted = false
    root.dragTargetIndex = -1
    root.dragShowZone = false
    if (!id) return
    // if (show) root.setDrawer(id, false)
    root.moveWidgetToIndex(id, targetIndex)
  }

  function dragCancel() {
    root.dragId = ""
    root.dragActive = false
    root.dragStarted = false
    root.dragTargetIndex = -1
    root.dragShowZone = false
  }

  function open() {
    root.pendingDrawerIds = root.configuredIds.slice()
    root.menuOpen = true
    root.manageMode = false
  }
  function close() {
    var changed = root.commitDrawerChanges()
    root.menuOpen = false
    root.manageMode = false
    root.manageRevision++
    if (changed) root.scheduleShellRestart()
  }
  function closeForPopoutSwitch() {
    var changed = root.commitDrawerChanges()
    root.menuOpen = false
    root.manageMode = false
    root.manageRevision++
    if (changed) root.scheduleShellRestart()
  }
  function leaveManageMode() {
    var changed = root.commitDrawerChanges()
    root.manageMode = false
    root.manageRevision++
    if (changed) root.scheduleShellRestart()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Invisible host at the button's spot. Each hidden widget stays mounted here
  // (not on the bar) so its panel anchors to the bar window and opens right
  // underneath the drawer when picked from the menu.
  Item {
    id: hiddenHost
    anchors.fill: button
    visible: false

    Repeater {
      model: root.hiddenIds
      DrawerWidget {}
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf0c9"
    tooltipText: "Widget drawer"
    onPressed: function(b) {
      if (b !== Qt.LeftButton) return
      if (root.menuOpen) root.close()
      else root.open()
    }
  }

  // Mounted hidden widget instances, keyed by id, so menu rows can toggle
  // their panels.
  property var mountedMap: ({})

  function registerMounted(id, item) {
    var m = root.mountedMap
    m[id] = item
    root.mountedMap = m
  }

  function unregisterMounted(id) {
    var m = root.mountedMap
    delete m[id]
    root.mountedMap = m
  }

  function mountedItem(id) {
    return root.mountedMap[id]
  }

  function openWidget(id) {
    var w = root.mountedItem(id)
    if (w) {
      if (typeof w.toggle === "function") {
        w.toggle()
      } else if ("popupOpen" in w) {
        w.popupOpen = !w.popupOpen
      } else if ("opened" in w && typeof w.open === "function" && typeof w.close === "function") {
        if (w.opened) w.close()
        else w.open()
      }
    }
    root.menuOpen = false
    root.manageMode = false
  }

  component DrawerWidget: Item {
    id: slot
    required property int index
    required property var modelData
    readonly property string widgetId: String(modelData || "")
    readonly property var component: root.registryWidgets[widgetId] ? root.registryWidgets[widgetId].component : null

    implicitWidth: loader.item ? loader.item.implicitWidth : root.button.implicitWidth
    implicitHeight: loader.item ? loader.item.implicitHeight : root.button.implicitHeight

    Loader {
      id: loader
      anchors.fill: parent
      sourceComponent: slot.component
      onLoaded: {
        var w = loader.item
        if (!w) return
        if ("bar" in w) w.bar = root.bar
        if ("moduleName" in w) w.moduleName = slot.widgetId
        if ("settings" in w) w.settings = root.defaultsFor(slot.widgetId)
        // Panel-style widgets anchor their panel to this item; point them at
        // the drawer button (in the bar window) so the panel opens underneath
        // the drawer.
        if ("anchorItem" in w) w.anchorItem = root.button
        root.registerMounted(slot.widgetId, w)
      }
    }

    Component.onDestruction: {
      if (root) root.unregisterMounted(slot.widgetId)
    }
  }

  // --- menu ------------------------------------------------------------------

  PopupCard {
    id: menuPopup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.menuOpen
    contentWidth: menuPopup.fittedContentWidth(Style.space(300))
    contentHeight: menuPopup.fittedContentHeight(menuColumn.implicitHeight, Style.space(480))

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(6)

      Item {
        id: headerRow
        width: menuColumn.width
        implicitHeight: 22

        Text {
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.right: backButton.visible ? backButton.left : (penButton.visible ? penButton.left : parent.right)
          anchors.rightMargin: Style.space(8)
          text: root.manageMode ? "Add / remove widgets" : "Widget drawer"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Button {
          id: penButton
          visible: !root.manageMode
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "\uf040"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          horizontalPadding: 8
          verticalPadding: 3
          fontSize: Style.font.bodySmall
          onClicked: {
            root.pendingDrawerIds = root.configuredIds.slice()
            root.manageMode = true
          }
        }

        Button {
          id: backButton
          visible: root.manageMode
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "\u2039 Back"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          horizontalPadding: 8
          verticalPadding: 3
          fontSize: Style.font.bodySmall
          onClicked: root.leaveManageMode()
        }
      }

      Flickable {
        id: bodyFlick
        width: menuColumn.width
        height: root.manageMode
          ? Math.min(manageColumn.implicitHeight, Math.max(80, Style.space(300)))
          : drawerColumn.implicitHeight
        contentWidth: width
        contentHeight: root.manageMode ? manageColumn.implicitHeight : drawerColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: drawerColumn
          visible: !root.manageMode
          width: bodyFlick.width
          spacing: Style.space(4)

          Repeater {
            model: root.hiddenIds

            delegate: Item {
              id: drow
              required property string modelData
              width: drawerColumn.width
              implicitHeight: 30

              readonly property string rowId: drow.modelData
              property real pressX: 0
              property real pressY: 0
              property bool dragged: false

              opacity: root.dragId === drow.rowId ? 0.5 : 1.0

              Rectangle {
                anchors.fill: parent
                radius: Math.max(2, Style.cornerRadius)
                color: (!root.dragActive && drowMouse.containsMouse) ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, root.bar ? root.bar.foreground : Color.foreground) : "transparent"
              }

              Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 2
                radius: 1
                color: Color.accent
                visible: root.dragActive && !root.dragShowZone && root.dragId !== drow.rowId && root.dragTargetIndex === drow.index
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                text: root.displayName(drow.rowId)
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              MouseArea {
                id: drowMouse
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: root.dragStarted ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                onPressed: function(mouse) {
                  drow.dragged = false
                  drow.pressX = mouse.x
                  drow.pressY = mouse.y
                  root.dragStart(drow.rowId)
                }

                onPositionChanged: function(mouse) {
                  if (!(mouse.buttons & Qt.LeftButton)) return
                  if (!drow.dragged && (Math.abs(mouse.x - drow.pressX) + Math.abs(mouse.y - drow.pressY)) >= root.dragThreshold)
                    drow.dragged = true
                  if (drow.dragged) root.dragMove(drowMouse, mouse.x, mouse.y)
                }

                onReleased: {
                  if (root.dragActive) root.dragEnd()
                }

                onCanceled: {
                  root.dragCancel()
                }

                onClicked: {
                  if (!drow.dragged) root.openWidget(drow.rowId)
                }
              }
            }
          }

          Item {
            width: drawerColumn.width
            implicitHeight: Style.space(10)

            Rectangle {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: 2
              radius: 1
              color: Color.accent
              visible: root.dragActive && !root.dragShowZone && root.dragTargetIndex === root.hiddenIds.length
            }
          }

          Text {
            visible: root.hiddenIds.length === 0
            width: drawerColumn.width
            text: "No widgets hidden."
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }
        }

        Column {
          id: manageColumn
          visible: root.manageMode
          width: bodyFlick.width
          spacing: Style.space(4)

          Repeater {
            model: root.allPlugins

            delegate: Item {
              id: mrow
              required property string modelData
              width: manageColumn.width
              implicitHeight: 28

              readonly property string rowId: mrow.modelData
              readonly property bool checked: {
                var pending = root.pendingDrawerIds
                void pending
                return pending.indexOf(mrow.rowId) !== -1
              }

              Rectangle {
                anchors.fill: parent
                radius: Math.max(2, Style.cornerRadius)
                color: mrowMouse.containsMouse
                  ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, root.bar ? root.bar.foreground : Color.foreground)
                  : "transparent"
              }

              BorderSurface {
                id: checkbox
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                width: Style.space(16)
                height: Style.space(16)
                radius: Math.max(2, Style.cornerRadius / 2)
                color: mrow.checked
                  ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, root.bar ? root.bar.foreground : Color.foreground)
                  : "transparent"
                borderSpec: mrow.checked
                  ? Border.controlSpec("selected", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                  : Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)

                Text {
                  anchors.centerIn: parent
                  visible: mrow.checked
                  text: "\u2713"
                  color: Style.selectedStateColor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Math.round(checkbox.height * 0.85)
                  font.bold: true
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: checkbox.right
                anchors.right: parent.right
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                text: root.displayName(mrow.rowId)
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.italic: mrow.checked
                elide: Text.ElideRight
              }

              MouseArea {
                id: mrowMouse
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.togglePending(mrow.rowId)
              }
            }
          }
        }

        Rectangle {
          id: dragGhost
          visible: root.dragActive
          z: 20
          x: root.dragGhostX
          y: root.dragGhostY
          width: root.dragShowZone ? menuColumn.width : Math.min(menuColumn.width, Math.max(120, dragGhostText.implicitWidth + Style.space(16)))
          height: 30
          radius: Math.max(2, Style.cornerRadius)
          color: root.dragShowZone
            ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, root.bar ? root.bar.foreground : Color.foreground)
            : Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, root.bar ? root.bar.foreground : Color.foreground)
          border.width: root.dragShowZone ? 1 : 0
          border.color: Color.accent

          Text {
            id: dragGhostText
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            verticalAlignment: Text.AlignVCenter
            text: root.displayName(root.dragId)
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // --- config sync -----------------------------------------------------------
  //
  // A plugin listed in the drawer must not render on the bar, but it still
  // needs to stay *enabled* so its component stays loaded and its service
  // keeps running. The bar widget registry only holds enabled plugins, so
  // hiding a widget moves it out of the bar layout and into `plugins[]`
  // (enabled but not rendered); showing it does the reverse. On load we
  // reconcile once so an existing shell.json catches up automatically.

  function persistWidgets(list) {
    var shell = root.bar && root.bar.shell
    if (!shell || typeof shell.updateEntryInline !== "function") return
    shell.updateEntryInline(root.moduleName, { id: root.moduleName, widgets: list })
  }

  function moveWidgetToIndex(id, toIndex) {
    var list = root.configuredIds.slice()
    var fi = list.indexOf(id)
    if (fi === -1) return
    if (toIndex < 0) return
    if (toIndex > list.length) toIndex = list.length
    if (fi === toIndex || fi + 1 === toIndex) return
    list.splice(fi, 1)
    var insertAt = toIndex
    if (fi < toIndex) insertAt = toIndex - 1
    if (insertAt > list.length) insertAt = list.length
    list.splice(insertAt, 0, id)
    root.persistWidgets(list)
  }

  function mutateConfig(mutator) {
    var shell = root.bar && root.bar.shell
    if (!shell || typeof shell.mutateShellConfig !== "function") return
    shell.mutateShellConfig(mutator)
  }

  function layoutHas(id) {
    var key = String(id || "")
    var shell = root.bar && root.bar.shell
    var config = shell ? shell.shellConfig : null
    if (!config || !config.bar || !config.bar.layout) return false
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var arr = config.bar.layout[sections[s]]
      if (!Array.isArray(arr)) continue
      for (var i = 0; i < arr.length; i++) {
        if (arr[i] && String(arr[i].id || "") === key) return true
      }
    }
    return false
  }

  function pluginsHas(id) {
    var key = String(id || "")
    var shell = root.bar && root.bar.shell
    var config = shell ? shell.shellConfig : null
    if (!config || !Array.isArray(config.plugins)) return false
    for (var i = 0; i < config.plugins.length; i++) {
      if (config.plugins[i] && String(config.plugins[i].id || "") === key) return true
    }
    return false
  }

  function removeFromLayoutAndKeepEnabled(key) {
    var shell = root.bar && root.bar.shell
    if (!shell || !shell.shellConfig) return
    var inLayout = root.layoutHas(key)
    var inPlugins = root.pluginsHas(key)
    if (!inLayout && inPlugins) return
    var sections = ["left", "center", "right"]
    root.mutateConfig(function(c) {
      if (!c) return
      if (c.bar && c.bar.layout) {
        for (var s = 0; s < sections.length; s++) {
          var a = c.bar.layout[sections[s]]
          if (!Array.isArray(a)) continue
          var kept = []
          for (var j = 0; j < a.length; j++) {
            if (!(a[j] && String(a[j].id || "") === key)) kept.push(a[j])
          }
          c.bar.layout[sections[s]] = kept
        }
      }
      if (Array.isArray(c.plugins)) {
        var exists = false
        for (var k = 0; k < c.plugins.length; k++) {
          if (c.plugins[k] && String(c.plugins[k].id || "") === key) { exists = true; break }
        }
        if (!exists) c.plugins.push({ id: key })
      }
    })
  }

  function removeFromPluginsAndAddToLayout(key) {
    var shell = root.bar && root.bar.shell
    if (!shell || !shell.shellConfig) return
    var inLayout = root.layoutHas(key)
    var inPlugins = root.pluginsHas(key)
    if (inLayout && !inPlugins) return
    root.mutateConfig(function(c) {
      if (!c) return
      if (Array.isArray(c.plugins)) {
        var kept = []
        for (var j = 0; j < c.plugins.length; j++) {
          if (!(c.plugins[j] && String(c.plugins[j].id || "") === key)) kept.push(c.plugins[j])
        }
        c.plugins = kept
      }
      if (!inLayout && c.bar && c.bar.layout) {
        var right = c.bar.layout.right
        if (!Array.isArray(right)) right = []
        var insertAt = right.length
        for (var k = 0; k < right.length; k++) {
          if (right[k] && String(right[k].id || "") === "omarchy.power") { insertAt = k; break }
        }
        right.splice(insertAt, 0, { id: key })
        c.bar.layout.right = right
      }
    })
  }

  function setDrawer(id, hide) {
    var key = String(id || "")
    if (!key) return
    var list = root.configuredIds.slice()
    var idx = list.indexOf(key)
    if (hide && idx === -1) list.push(key)
    else if (!hide && idx !== -1) list.splice(idx, 1)
    if (hide) root.removeFromLayoutAndKeepEnabled(key)
    else root.removeFromPluginsAndAddToLayout(key)
    root.persistWidgets(list)
  }

  // Reconcile on load: every configured id leaves the bar layout and stays
  // enabled via plugins[]. Each step is guarded, so a hot-reload triggered by
  // the persist cannot loop.
  function syncHiddenFromLayout() {
    var configured = root.configuredIds
    for (var i = 0; i < configured.length; i++) {
      root.removeFromLayoutAndKeepEnabled(configured[i])
    }
  }

  // The drawer button acts as a bar drop zone: dragging a bar widget onto it
  // hides that widget into the drawer. The bar exposes registerDropZone for
  // this, and only widgets with a registry entry can be hidden (custom command
  // modules have no component to mount in the drawer).
  // property var zoneToken: null

  // function registerDropZone() {
  //   root.unregisterDropZone()
  //   var bar = root.bar
  //   if (!bar || typeof bar.registerDropZone !== "function") return
  //   root.zoneToken = {
  //     // The drop target is the drawer button plus the open menu card, in bar
  //     // window coordinates (menuPopup.relativeX/Y is its offset from the bar
  //     // window), so dragging a bar widget onto either hides it into the drawer.
  //     sceneRect: function() {
  //       var rects = []
  //       var bp = { x: 0, y: 0 }
  //       try {
  //         bp = button.mapToItem(null, 0, 0)
  //       } catch (e) {
  //       }
  //       if (button.width > 0 && button.height > 0)
  //         rects.push({ x: bp.x, y: bp.y, w: button.width, h: button.height })
  //       if (menuPopup.visible) {
  //         var rx = Number(menuPopup.relativeX) || 0
  //         var ry = Number(menuPopup.relativeY) || 0
  //         var rw = Number(menuPopup.width) || 0
  //         var rh = Number(menuPopup.height) || 0
  //         if (rw > 0 && rh > 0) rects.push({ x: rx, y: ry, w: rw, h: rh })
  //       }
  //       if (rects.length === 0) return null
  //       var minX = rects[0].x, minY = rects[0].y
  //       var maxX = rects[0].x + rects[0].w, maxY = rects[0].y + rects[0].h
  //       for (var i = 1; i < rects.length; i++) {
  //         minX = Math.min(minX, rects[i].x); minY = Math.min(minY, rects[i].y)
  //         maxX = Math.max(maxX, rects[i].x + rects[i].w); maxY = Math.max(maxY, rects[i].y + rects[i].h)
  //       }
  //       return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
  //     },
  //     drop: function(sourceSlot) {
  //       if (!sourceSlot || !sourceSlot.moduleName) return
  //       var key = String(sourceSlot.moduleName)
  //       if (key === root.moduleName) return
  //       if (!root.registryWidgets[key]) return
  //       if (!root.layoutHas(key)) return
  //       root.setDrawer(key, true)
  //     }
  //   }
  //   bar.registerDropZone(root.zoneToken)
  // }

  // function unregisterDropZone() {
  //   var bar = root.bar
  //   if (bar && root.zoneToken && typeof bar.unregisterDropZone === "function")
  //     bar.unregisterDropZone(root.zoneToken)
  //   root.zoneToken = null
  // }

  // onBarChanged: root.registerDropZone()

  Component.onCompleted: {
    root.syncHiddenFromLayout()
    // root.registerDropZone()
  }

  // Component.onDestruction: root.unregisterDropZone()
}
