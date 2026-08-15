import QtQuick
import Quickshell
import Quickshell.Io
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Plugin Drawer: collapse chosen bar widgets into a single menu button.
//
// Widgets listed in the `widgets` inline setting (or the manifest defaults)
// are removed from the bar layout but stay mounted here — invisibly, at the
// button's position in the bar — so clicking their entry in the drawer menu
// opens their own panel anchored to the bar, right underneath the drawer.
//
// Left-clicking the hamburger opens the menu with the hidden widgets; the
// "Edit plugins" footer switches to a manage list that moves plugins between
// the bar and the drawer, enables/disables them, and removes third-party ones.
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

  // Every discovered plugin except the drawer itself, for the manage list. Read
  // from the plugin registry (not just the bar widget registry) so plugins that
  // are disabled — or not bar widgets at all — can still be enabled, disabled,
  // or removed here. Drawer-configured widgets come first, then enabled
  // plugins, then the rest; alphabetical within each group. Plugins that can't
  // sit on the bar (custom, non bar-widgets) come next, and first-party
  // plugins (which can't be removed) are pushed to the very bottom.
  readonly property var allPlugins: {
    var hidden = {}
    var configured = root.configuredIds
    for (var h = 0; h < configured.length; h++) hidden[configured[h]] = true
    var reg = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
    var installed = reg && reg.installedPlugins ? reg.installedPlugins : null
    var out = []
    if (installed) {
      for (var id in installed) if (id !== root.moduleName) out.push(id)
    } else {
      var widgets = root.registryWidgets
      for (var wid in widgets) if (wid !== root.moduleName) out.push(wid)
    }
    out.sort(function(a, b) {
      function rank(x) {
        if (hidden[x]) return 0
        var firstParty = root.isFirstPartyPlugin(x)
        var isWidget = root.isBarWidgetPlugin(x)
        if (firstParty) return 5
        if (!isWidget) return 4
        return root.pluginEnabled(x) ? 1 : 2
      }
      var ra = rank(a)
      var rb = rank(b)
      if (ra !== rb) return ra - rb
      var na = root.displayName(a).toLowerCase()
      var nb = root.displayName(b).toLowerCase()
      return na < nb ? -1 : (na > nb ? 1 : 0)
    })
    return out
  }

  function defaultsFor(id) {
    var entry = root.registryWidgets[id]
    if (entry && entry.metadata && entry.metadata.defaults) return entry.metadata.defaults
    var manifest = root.pluginManifest(id)
    return manifest && manifest.barWidget && manifest.barWidget.defaults
      ? manifest.barWidget.defaults : ({})
  }

  function displayName(id) {
    var entry = root.registryWidgets[id]
    if (entry && entry.metadata && entry.metadata.displayName) return String(entry.metadata.displayName)
    var manifest = root.pluginManifest(id)
    if (manifest && manifest.name) return String(manifest.name)
    return id
  }

  // Manifest lookup falls back to the plugin registry so disabled plugins (no
  // bar registry entry) still show their real name and kinds in the edit list.
  function pluginManifest(id) {
    var reg = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
    return reg && reg.installedPlugins ? (reg.installedPlugins[String(id || "")] || null) : null
  }

  function pluginEnabled(id) {
    var reg = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
    if (!reg || typeof reg.isEnabled !== "function") return false
    return reg.isEnabled(String(id || ""))
  }

  function isBarWidgetPlugin(id) {
    var manifest = root.pluginManifest(id)
    return !!(manifest && Array.isArray(manifest.kinds) && manifest.kinds.indexOf("bar-widget") !== -1)
  }

  function isFirstPartyPlugin(id) {
    var manifest = root.pluginManifest(id)
    return !!(manifest && manifest.__isFirstParty)
  }

  // A widget-style disable (take it off the bar / out of the drawer) is only
  // meaningful while the plugin is referenced in the config. A first-party
  // non-widget is always loadable, so it disables via disabledPlugins[].
  function canDisable(id) {
    var key = String(id || "")
    if (!key) return false
    if (root.isBarWidgetPlugin(key)) return root.layoutHas(key) || root.pluginsHas(key)
    return root.pluginEnabled(key)
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

  // Plugin ids the user has marked for removal in the manage list. They are
  // only deleted when the drawer is dismissed (close / leaveManageMode /
  // closeForPopoutSwitch), so several can be queued up at once.
  property var pendingRemoveIds: []

  // Plugin ids whose config still needs cleaning once the file deletion
  // process (started when removals are committed) has finished. Kept as a
  // property so the Process's onExited handler — which fires after the
  // deletion actually completes — can finish the job without the in-flight rm
  // being killed by the config-change triggered bar rebuild.
  property var pendingCleanIds: []

  function isRemovePending(id) {
    return root.pendingRemoveIds.indexOf(String(id || "")) !== -1
  }

  function toggleRemovePending(id) {
    var key = String(id || "")
    if (!key || root.isFirstPartyPlugin(key)) return
    var list = root.pendingRemoveIds.slice()
    var i = list.indexOf(key)
    if (i === -1) list.push(key)
    else list.splice(i, 1)
    root.pendingRemoveIds = list
    root.manageRevision++
  }

  // Move every staged difference between the drawer and the bar. Returns true
  // when anything changed (the config mutation itself triggers the hot reload
  // and the drawer's auto-reconcile; no shell restart is required).
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
    root.dragGhostX = 0
    // Insertion boundary follows the cursor within the row: the top half of a
    // row means "before it", the bottom half "after it". Rows are 30px tall
    // with 4px spacing, so the pitch is 34.
    var local = drawerColumn.mapFromItem(handle, mouseX, mouseY)
    var count = root.hiddenIds.length
    var pitch = 34
    var rowIndex = Math.floor(local.y / pitch)
    var index
    if (rowIndex < 0) index = 0
    else if (rowIndex >= count) index = count
    else index = (local.y - rowIndex * pitch) < 15 ? rowIndex : rowIndex + 1
    if (index > count) index = count
    root.dragTargetIndex = index
    // The ghost snaps to the slot it will land in so the drop position is
    // obvious instead of trailing the cursor.
    root.dragGhostY = Math.max(0, Math.min(count - 1, index)) * pitch
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
    root.commitRemoveChanges()
    root.commitDrawerChanges()
    root.menuOpen = false
    root.manageMode = false
    root.manageRevision++
  }
  function closeForPopoutSwitch() {
    root.commitRemoveChanges()
    root.commitDrawerChanges()
    root.menuOpen = false
    root.manageMode = false
    root.manageRevision++
  }
  function leaveManageMode() {
    root.commitRemoveChanges()
    root.commitDrawerChanges()
    root.manageMode = false
    root.manageRevision++
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
    tooltipText: "Plugin Drawer"
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
      var toggled = false
      // Panel-style widgets and most clones expose a root toggle().
      if (typeof w.toggle === "function") {
        w.toggle()
        toggled = true
      } else if ("popupOpen" in w) {
        // Widgets that own a popupOpen boolean (prayer-times, kanban, ...).
        w.popupOpen = !w.popupOpen
        toggled = true
      } else if ("opened" in w && typeof w.open === "function" && typeof w.close === "function") {
        if (w.opened) w.close()
        else w.open()
        toggled = true
      } else if ("menuOpen" in w && typeof w.open === "function" && typeof w.close === "function") {
        if (w.menuOpen) w.close()
        else w.open()
        toggled = true
      } else if (typeof w.open === "function" && typeof w.close === "function") {
        // Plain open/close pair with no exposed state property.
        w.open()
        toggled = true
      }
      if (!toggled && root.bar && typeof root.bar.shell.toggle === "function") {
        // Last resort: route through the shell's canonical toggle so any
        // widget with a registered IPC handler still responds.
        root.bar.shell.toggle(id, "{}")
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
          text: root.manageMode ? "Edit plugins" : "Plugin Drawer"
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
                color: root.dragActive && root.dragTargetIndex === drow.index
                  ? Util.alpha(Color.accent, 0.18)
                  : (!root.dragActive && drowMouse.containsMouse
                      ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, root.bar ? root.bar.foreground : Color.foreground)
                      : "transparent")
              }

              Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 3
                radius: 1.5
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
              height: 3
              radius: 1.5
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
              implicitHeight: 34

              readonly property string rowId: mrow.modelData
              readonly property bool isWidget: root.isBarWidgetPlugin(mrow.rowId)
              readonly property bool enabled: root.pluginEnabled(mrow.rowId)
              readonly property bool checked: root.isPending(mrow.rowId)

              Rectangle {
                anchors.fill: parent
                radius: Math.max(2, Style.cornerRadius)
                color: root.isRemovePending(mrow.rowId)
                  ? Util.alpha(Color.urgent, 0.18)
                  : (mrowMouse.containsMouse
                    ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, root.bar ? root.bar.foreground : Color.foreground)
                    : "transparent")
              }

              BorderSurface {
                id: checkbox
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                width: Style.space(16)
                height: Style.space(16)
                radius: Math.max(2, Style.cornerRadius / 2)
                visible: mrow.isWidget
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
                anchors.right: rowActions.left
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
                onClicked: {
                  if (mrow.isWidget) root.togglePending(mrow.rowId)
                }
              }

              Row {
                id: rowActions
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Button {
                  width: 24
                  height: 24
                  text: "\uf00c"
                  tooltipText: mrow.enabled ? "Already enabled" : "Enable plugin"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  opacity: mrow.enabled ? 0.35 : 1.0
                  horizontalPadding: 0
                  verticalPadding: 0
                  onClicked: {
                    if (!mrow.enabled) root.enablePluginNow(mrow.rowId)
                  }
                }

                Button {
                  width: 24
                  height: 24
                  text: "\uf00d"
                  tooltipText: root.canDisable(mrow.rowId) ? "Disable plugin" : "Cannot disable"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  opacity: root.canDisable(mrow.rowId) ? 1.0 : 0.35
                  horizontalPadding: 0
                  verticalPadding: 0
                  onClicked: {
                    if (root.canDisable(mrow.rowId)) root.disablePluginNow(mrow.rowId)
                  }
                }

                Button {
                  width: 24
                  height: 24
                  text: "\uf1f8"
                  tooltipText: root.isFirstPartyPlugin(mrow.rowId)
                    ? "Built-in plugin, cannot be removed"
                    : (root.isRemovePending(mrow.rowId) ? "Marked for removal — click to cancel" : "Remove plugin")
                  foreground: root.isRemovePending(mrow.rowId)
                    ? Color.accent
                    : Color.foreground
                  opacity: root.isFirstPartyPlugin(mrow.rowId) ? 0.35 : 1.0
                  horizontalPadding: 0
                  verticalPadding: 0
                  onClicked: {
                    if (!root.isFirstPartyPlugin(mrow.rowId)) root.toggleRemovePending(mrow.rowId)
                  }
                }
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
          width: drawerColumn.width
          height: 30
          radius: Math.max(2, Style.cornerRadius)
          color: Util.alpha(Color.accent, 0.25)
          border.width: 1.5
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
            font.bold: true
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
    var id = root.moduleName
    root.mutateConfig(function(c) {
      if (!c || !c.bar || !c.bar.layout) return
      var sections = ["left", "center", "right"]
      for (var s = 0; s < sections.length; s++) {
        var arr = c.bar.layout[sections[s]]
        if (!Array.isArray(arr)) continue
        for (var k = 0; k < arr.length; k++) {
          if (arr[k] && String(arr[k].id || "") === id) {
            arr[k].widgets = list.slice()
            return
          }
        }
      }
    })
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

  // --- plugin enable / disable / remove -------------------------------------
  //
  // Beyond drawer membership, the edit menu toggles a plugin's *enabled*
  // state. Bar-widget plugins are enabled into the drawer (config-only, so
  // the bar is not rebuilt and the open menu survives); everything else goes
  // through the plugin registry's setEnabled. Removal is staged like drawer
  // membership: the bin click only marks the plugin (icon turns grey), and
  // everything marked is deleted together when the user leaves edit mode —
  // config references cleaned, plugin directory removed (backing up non-git
  // dirs), then one registry reload.

  Process {
    id: removeProcess
    stdout: StdioCollector { id: removeStdout; waitForEnd: true }
    stderr: StdioCollector { id: removeStderr; waitForEnd: true }
    onExited: {
      // Files are gone now, so the config cleanup below is safe: the bar rebuild
      // it triggers can no longer interrupt an in-flight file deletion.
      for (var k = 0; k < root.pendingCleanIds.length; k++) root.cleanPluginConfig(root.pendingCleanIds[k])
      root.pendingCleanIds = []
      root.reloadPlugins()
    }
  }

  function removeFromDisabledPlugins(key) {
    root.mutateConfig(function(c) {
      if (!c || !Array.isArray(c.disabledPlugins)) return
      var kept = []
      for (var i = 0; i < c.disabledPlugins.length; i++) {
        if (String(c.disabledPlugins[i] || "") !== key) kept.push(c.disabledPlugins[i])
      }
      c.disabledPlugins = kept
    })
  }

  function enablePluginNow(id) {
    var key = String(id || "")
    if (!key || root.pluginEnabled(key)) return
    if (root.isBarWidgetPlugin(key)) {
      root.setDrawer(key, true)
      root.removeFromDisabledPlugins(key)
      if (root.pendingDrawerIds.indexOf(key) === -1)
        root.pendingDrawerIds = root.pendingDrawerIds.concat([key])
    } else {
      var reg = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
      if (reg && typeof reg.setEnabled === "function") reg.setEnabled(key, true)
    }
    root.manageRevision++
  }

  function disablePluginNow(id) {
    var key = String(id || "")
    if (!key || !root.canDisable(key)) return
    var pending = root.pendingDrawerIds.slice()
    var pi = pending.indexOf(key)
    if (pi !== -1) { pending.splice(pi, 1); root.pendingDrawerIds = pending }
    var configured = root.configuredIds.slice()
    var ci = configured.indexOf(key)
    if (ci !== -1) { configured.splice(ci, 1); root.persistWidgets(configured) }
    var reg = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
    if (reg && typeof reg.setEnabled === "function") reg.setEnabled(key, false)
    root.manageRevision++
  }

  // Strip every config reference to a plugin: bar layout, plugins[],
  // disabledPlugins[], the drawer's widget list, and any staged membership.
  function cleanPluginConfig(key) {
    var pending = root.pendingDrawerIds.slice()
    var pending = root.pendingDrawerIds.slice()
    var pi = pending.indexOf(key)
    if (pi !== -1) { pending.splice(pi, 1); root.pendingDrawerIds = pending }
    var configured = root.configuredIds.slice()
    var ci = configured.indexOf(key)
    if (ci !== -1) { configured.splice(ci, 1); root.persistWidgets(configured) }
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
        var pk = []
        for (var k = 0; k < c.plugins.length; k++) {
          if (!(c.plugins[k] && String(c.plugins[k].id || "") === key)) pk.push(c.plugins[k])
        }
        c.plugins = pk
      }
      if (Array.isArray(c.disabledPlugins)) {
        var dk = []
        for (var d = 0; d < c.disabledPlugins.length; d++) {
          if (String(c.disabledPlugins[d] || "") !== key) dk.push(c.disabledPlugins[d])
        }
        c.disabledPlugins = dk
      }
    })
    root.manageRevision++
  }

  // Remove a plugin immediately on bin click. The file deletion runs first and
  // config cleanup happens in the Process's onExited, i.e. only after the rm has
  // actually finished. A config mutation (cleanPluginConfig → persistShellConfig)
  // triggers a bar rebuild via onShellConfigChanged → syncPluginWidgets, and that
  // rebuild destroys this drawer instance and kills any still-running child
  // Process — so cleaning config synchronously here would tear the rm down
  // mid-flight, leave the plugin's files on disk, and let the next rescan
  // re-register it.
  // Apply every staged removal. File deletion runs first (one bash script
  // deletes all marked plugin dirs); config cleanup happens in the Process's
  // onExited handler, i.e. only after the rm has actually finished. A config
  // mutation (cleanPluginConfig → persistShellConfig) triggers a bar rebuild
  // via onShellConfigChanged → syncPluginWidgets, and that rebuild destroys
  // this drawer instance and kills any still-running child Process — so
  // cleaning config synchronously here would tear the rm down mid-flight,
  // leave the plugin's files on disk, and let the next rescan re-register it.
  function commitRemoveChanges() {
    var ids = root.pendingRemoveIds
    if (!ids || ids.length === 0) return
    var reg = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
    var pluginsDir = reg ? String(reg.pluginsDir || "") : ""
    var scripts = []
    var all = []
    for (var i = 0; i < ids.length; i++) {
      var key = String(ids[i] || "")
      if (!key) continue
      all.push(key)
      var manifest = root.pluginManifest(key)
      var dir = manifest ? String(manifest.__sourceDir || "") : ""
      if (dir) scripts.push(root.removeScript(key, dir, pluginsDir))
    }
    root.pendingRemoveIds = []
    root.pendingCleanIds = all
    if (scripts.length) {
      removeProcess.command = ["bash", "-c", scripts.join("\n")]
      removeProcess.running = true
    } else {
      for (var k = 0; k < root.pendingCleanIds.length; k++) root.cleanPluginConfig(root.pendingCleanIds[k])
      root.pendingCleanIds = []
      root.reloadPlugins()
    }
  }

  function reloadPlugins() {
    var shell = root.bar && root.bar.shell
    if (shell && typeof shell.reloadPlugins === "function") shell.reloadPlugins()
    else {
      var reg = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
      if (reg && typeof reg.rescan === "function") reg.rescan()
    }
  }

  // Shell command that removes a plugin's files: symlinks are unlinked, git
  // clones deleted outright, anything else moved aside as a dot-hidden backup
  // so a manual undo stays possible.
  function removeScript(key, dir, pluginsDir) {
    function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    var dirQ = q(dir)
    var parts = ["set -e"]
    parts.push("if [ -L " + dirQ + " ]; then rm -f " + dirQ + ";")
    parts.push("elif [ -d " + dirQ + "/.git ]; then rm -rf " + dirQ + ";")
    parts.push("elif [ -d " + dirQ + " ]; then mv " + dirQ + " " + q(pluginsDir + "/." + key + ".bak.") + "$(date +%s)")
    parts.push("fi")
    return parts.join("\n")
  }

  // Reconcile on load: every configured id stays enabled via plugins[] so the
  // drawer can mount it. This only *enables*; it never moves a widget off the
  // bar — if the user placed a configured widget on the bar, it stays there.
  function syncHiddenFromLayout() {
    var configured = root.configuredIds
    for (var i = 0; i < configured.length; i++) {
      root.ensureConfiguredEnabled(configured[i])
    }
  }

  // Ensure a configured widget is enabled (in plugins[]) so the drawer can
  // mount it. Bar placement is never touched here.
  function ensureConfiguredEnabled(key) {
    var shell = root.bar && root.bar.shell
    if (!shell || !shell.shellConfig) return
    if (root.layoutHas(key)) return
    if (root.pluginsHas(key)) return
    root.mutateConfig(function(c) {
      if (!c) return
      if (!Array.isArray(c.plugins)) c.plugins = []
      var exists = false
      for (var k = 0; k < c.plugins.length; k++) {
        if (c.plugins[k] && String(c.plugins[k].id || "") === key) { exists = true; break }
      }
      if (!exists) c.plugins.push({ id: key })
    })
  }

  // Auto-park: whenever the plugin registry or config changes (plugin enabled
  // on the bar from outside the drawer, a rescan, a shell.json reload), make
  // sure every configured drawer widget is off the bar and parked in plugins[]
  // so it stays enabled and the drawer can mount it. Debounced so a burst of
  // config mutations from a single drawer edit settles into one pass; the
  // guarded mutations make repeat passes no-ops.
  property var reconcileRegistry: root.bar ? root.bar.shell.pluginRegistry : null

  onBarChanged: root.reconcileRegistry = root.bar ? root.bar.shell.pluginRegistry : null

  Connections {
    target: root.reconcileRegistry
    function onPluginsChanged() { reconcileTimer.restart() }
  }

  Timer {
    id: reconcileTimer
    interval: 150
    onTriggered: root.syncHiddenFromLayout()
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
