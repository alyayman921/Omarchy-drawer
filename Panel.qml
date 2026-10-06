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

  // Since Omarchy 4.0.3 ("Quattro"), a bar-widget-kind plugin's `bar.shell` is
  // a capability-scoped PluginShellApi that no longer exposes `shellConfig`
  // (see Omarchy-drawer#2). `bar.layoutConfig`, however, is unconditionally
  // handed to every bar widget (first- or third-party alike) as a read-only
  // snapshot of the whole bar's left/center/right entries, so it is the one
  // reliable source left for inspecting *other* widgets' placement. Falls
  // back to the old `shellConfig` path for hosts that still provide it.
  function barLayoutSections() {
    var cfg = root.bar ? root.bar.layoutConfig : null
    if (cfg && (Array.isArray(cfg.left) || Array.isArray(cfg.center) || Array.isArray(cfg.right)))
      return cfg
    var shell = root.bar && root.bar.shell
    var config = shell ? shell.shellConfig : null
    return config && config.bar && config.bar.layout ? config.bar.layout : null
  }

  // Raw configured list. Read straight off this plugin's own injected
  // `settings` (always kept current by the host regardless of capability
  // scoping) instead of re-scanning a config object that may not be reachable
  // any more. Falls back to manifest defaults when the entry has no
  // `widgets` key yet.
  readonly property var configuredIds: {
    var rev = root.manageRevision
    void rev
    var list = Array.isArray(root.settings.widgets) ? root.settings.widgets : null
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
  //
  // True when the host still exposes the full plugin catalog. Since Omarchy
  // 4.0.3, a bar-widget-kind plugin's pluginRegistry facade
  // (PluginRegistryApi) is scoped to itself only (Omarchy-drawer#2): its
  // `installedPlugins` is always a plain object, so a naive truthiness check
  // never falls back — it just silently contains zero or one entries. This
  // checks the actual contents instead of the container.
  readonly property bool hasFullRegistry: {
    var reg = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
    var installed = reg && reg.installedPlugins ? reg.installedPlugins : null
    if (!installed) return false
    var keys = Object.keys(installed)
    return !(keys.length <= 1 && (keys.length === 0 || keys[0] === root.moduleName))
  }

  readonly property var allPlugins: {
    var hidden = {}
    var configured = root.configuredIds
    for (var h = 0; h < configured.length; h++) hidden[configured[h]] = true
    var out = []
    if (root.hasFullRegistry) {
      var installed = root.bar.shell.pluginRegistry.installedPlugins
      for (var id in installed) if (id !== root.moduleName) out.push(id)
    } else {
      // Sandboxed bar-widget context: the full catalog isn't reachable, so
      // fall back to widgets already sitting in the bar's public layout
      // snapshot (always exposed via bar.layoutConfig). This restores the
      // "which currently-on-bar widgets are hidden" checklist, though
      // discovering installed-but-not-placed plugins stays unavailable here.
      var sections = root.barLayoutSections()
      var seen = {}
      var names = ["left", "center", "right"]
      if (sections) {
        for (var s = 0; s < names.length; s++) {
          var arr = sections[names[s]]
          if (!Array.isArray(arr)) continue
          for (var i = 0; i < arr.length; i++) {
            var wid = arr[i] && String(arr[i].id || "")
            if (wid && wid !== root.moduleName && !seen[wid]) { seen[wid] = true; out.push(wid) }
          }
        }
      }
      // Widgets already configured into the drawer (so already off the live
      // bar) still belong in the checklist so they can be unchecked.
      for (var c = 0; c < configured.length; c++) {
        if (!seen[configured[c]]) { seen[configured[c]] = true; out.push(configured[c]) }
      }
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
    if (manifest) return !!(Array.isArray(manifest.kinds) && manifest.kinds.indexOf("bar-widget") !== -1)
    if (root.hasFullRegistry) return false
    // No manifest reachable (sandboxed bar-widget context, see
    // hasFullRegistry above): anything present in the bar's public layout
    // snapshot, or already configured into this drawer, is by definition
    // already a bar widget.
    return root.layoutHas(id) || root.configuredIds.indexOf(String(id || "")) !== -1
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

  // --- view + hide state -----------------------------------------------------

  property string viewMode: "grid"
  property bool showHidden: false

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string ffont: root.bar ? root.bar.fontFamily : Style.font.family

  // Window scaling is a sub-setting on the drawer entry (`scale` now expressed
  // as 10%–100% of the screen width); the sizing math is unchanged, just the
  // allowed range. Default 50% matches the previous behaviour.
  property real windowScale: Math.max(0.1, Math.min(1.0, root.entrySetting("scale", 0.5)))
  property int gridColumnSetting: Math.max(1, Math.round(root.entrySetting("gridColumns", 3)))

  readonly property int tileSize: Style.space(64)
  readonly property int tileGap: Style.space(10)
  readonly property int tileHeight: Style.space(74)

  // Columns and stretched cell width derived from the actual grid width, so the
  // tiles fill the row instead of leaving a gap on the right.
  readonly property int gridCols: Math.max(1, root.gridColumnSetting)
  readonly property real gridCellW: {
    var cols = root.gridCols
    if (cols < 1) cols = 1
    var w = drawerGrid.width
    if (w <= 0) return root.tileSize
    return (w - (cols - 1) * root.tileGap) / cols
  }

  // Plugin ids the user has hidden from the drawer view (a subset of the
  // configured drawer widgets). They stay mounted but are not shown unless
  // showHidden is on. Persisted on the drawer entry as `hidden`.
  readonly property var hiddenViewIds: {
    var rev = root.manageRevision
    void rev
    var list = Array.isArray(root.settings.hidden) ? root.settings.hidden : null
    if (!Array.isArray(list)) return []
    var out = []
    for (var j = 0; j < list.length; j++) {
      var hid = String(list[j] || "")
      if (hid) out.push(hid)
    }
    return out
  }

  // Configured widgets that are not hidden from the view.
  readonly property var drawerVisibleIds: {
    var hv = {}
    var h = root.hiddenViewIds
    for (var i = 0; i < h.length; i++) hv[h[i]] = true
    var out = []
    var cfg = root.configuredIds
    for (var j = 0; j < cfg.length; j++) {
      var cid = cfg[j]
      if (!root.registryWidgets[cid]) continue
      if (!hv[cid]) out.push(cid)
    }
    return out
  }

  // What the drawer actually renders: visible widgets first, then (only while
  // showHidden is on) the hidden ones, dimmed, so they can be unhidden.
  readonly property var drawerDisplayIds: {
    var out = []
    var vis = root.drawerVisibleIds
    for (var i = 0; i < vis.length; i++) out.push({ id: vis[i], hidden: false })
    if (root.showHidden) {
      var hv = root.hiddenViewIds
      var cfgSet = {}
      for (var c = 0; c < root.configuredIds.length; c++) cfgSet[root.configuredIds[c]] = true
      for (var k = 0; k < hv.length; k++) {
        if (!root.registryWidgets[hv[k]]) continue
        if (cfgSet[hv[k]]) out.push({ id: hv[k], hidden: true })
      }
    }
    return out
  }

  function isHiddenView(id) {
    return root.hiddenViewIds.indexOf(String(id || "")) !== -1
  }

  function persistHidden(list) {
    root.persistOwnSettings({ hidden: list.slice() })
  }

  function toggleHiddenView(id) {
    var key = String(id || "")
    if (!key) return
    var list = root.hiddenViewIds.slice()
    var idx = list.indexOf(key)
    if (idx === -1) list.push(key)
    else list.splice(idx, 1)
    root.persistHidden(list)
    root.manageRevision++
  }

  function pluginGlyph(id) {
    var name = root.displayName(id)
    if (!name) return "\uf1b2"
    return name.charAt(0).toUpperCase()
  }

  // Generic reader for a sub-setting stored on the drawer's own entry in the
  // bar layout config. `root.settings` is this plugin's own injected inline
  // config, kept current by the host regardless of capability scoping.
  function entrySetting(name, fallback) {
    var rev = root.manageRevision
    void rev
    if (root.settings && name in root.settings
        && root.settings[name] !== undefined && root.settings[name] !== null)
      return root.settings[name]
    return fallback
  }

  // Persists a change to the drawer's own bar-layout entry via
  // shell.updateEntryInline, the one write path a bar-widget-kind plugin
  // keeps under Omarchy 4.0.3's capability sandbox (Omarchy-drawer#2):
  // it is scoped to a plugin's own entry (pluginOwnsTarget), unlike
  // shell.mutateShellConfig below, which now requires the manifest to
  // declare kind "bar" and silently no-ops for bar-widget plugins like this
  // one. updateEntryInline replaces the whole entry, so every existing field
  // has to be carried over alongside the override.
  function persistOwnSettings(overrides) {
    var shell = root.bar && root.bar.shell
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    var next = ({})
    for (var k in root.settings) if (k !== "id") next[k] = root.settings[k]
    for (var o in overrides) next[o] = overrides[o]
    return shell.updateEntryInline(root.moduleName, next)
  }

  function persistEntrySetting(name, value) {
    var o = ({})
    o[name] = value
    root.persistOwnSettings(o)
  }

  function setGridColumns(n) {
    n = Math.max(1, Math.min(8, Math.round(n)))
    if (n === root.gridColumnSetting) return
    root.gridColumnSetting = n
    root.persistEntrySetting("gridColumns", n)
    root.manageRevision++
  }

  function setWindowScale(n) {
    n = Math.max(0.1, Math.min(1.0, Math.round(n * 100) / 100))
    if (Math.abs(n - root.windowScale) < 0.001) return
    root.windowScale = n
    root.persistEntrySetting("scale", n)
    root.manageRevision++
  }

  // The component the widget renders in the bar. Used as the tile's live
  // preview so the grid shows the plugin's real bar appearance, falling back
  // to the first-letter monogram when there is no component.
  function widgetComponent(c) {
    var entry = root.registryWidgets[String(c || "")]
    return entry && entry.component ? entry.component : null
  }

  // Drawer width adapts to the screen: the grid expands to fill most of the
  // available width (so cells can stretch), while the list view stays compact.
  function drawerContentWidth() {
    var avail = menuPopup.availableCardWidth
    if (!avail || avail <= 0) avail = Style.space(560)
    var w = avail * root.windowScale
    if (w < Style.space(280)) w = Style.space(280)
    return menuPopup.fittedContentWidth(w)
  }

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
    var count = root.drawerVisibleIds.length
    if (root.viewMode === "grid") {
      // Index follows the cursor in row-major reading order across the Flow,
      // using the stretched cell size so the ghost lands in the right slot.
      var cell = root.gridCellW + root.tileGap
      var cols = root.gridCols
      var local = drawerGrid.mapFromItem(handle, mouseX, mouseY)
      var col = Math.floor(local.x / cell)
      var row = Math.floor(local.y / cell)
      if (col < 0) col = 0
      if (col > cols - 1) col = cols - 1
      if (row < 0) row = 0
      var index = row * cols + col
      if (index > count) index = count
      root.dragTargetIndex = index
      root.dragGhostX = col * cell
      root.dragGhostY = row * cell
    } else {
      root.dragGhostX = 0
      var llocal = drawerColumn.mapFromItem(handle, mouseX, mouseY)
      var pitch = 34
      var rowIndex = Math.floor(llocal.y / pitch)
      var index2
      if (rowIndex < 0) index2 = 0
      else if (rowIndex >= count) index2 = count
      else index2 = (llocal.y - rowIndex * pitch) < 15 ? rowIndex : rowIndex + 1
      if (index2 > count) index2 = count
      root.dragTargetIndex = index2
      // The ghost snaps to the slot it will land in so the drop position is
      // obvious instead of trailing the cursor.
      root.dragGhostY = Math.max(0, Math.min(count - 1, index2)) * pitch
    }
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
    contentWidth: root.drawerContentWidth()
    contentHeight: menuPopup.fittedContentHeight(menuColumn.implicitHeight, Style.space(480))

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(6)

Item {
          id: headerRow
          width: menuColumn.width
          implicitHeight: 32

          Row {
            id: titleGroup
            visible: !root.manageMode
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: penButton.left
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(10)
            clip: true

            Text {
              id: titleText
              anchors.verticalCenter: parent.verticalCenter
              text: "Plugin Drawer"
              color: root.fg
              font.family: root.ffont
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }
          }

          Row {
            id: manageControls
            visible: root.manageMode
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(12)

            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Grid"
                color: root.fg
                font.family: root.ffont
                font.pixelSize: Style.font.caption
              }

              Button {
                width: 20
                height: 18
                text: "-"
                horizontalPadding: 0
                verticalPadding: 0
                fontSize: 12
                tooltipText: "Smaller grid"
                onClicked: root.setGridColumns(root.gridColumnSetting - 1)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                horizontalAlignment: Text.AlignHCenter
                text: root.gridColumnSetting + "x" + root.gridColumnSetting
                color: root.fg
                font.family: root.ffont
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Button {
                width: 20
                height: 18
                text: "+"
                horizontalPadding: 0
                verticalPadding: 0
                fontSize: 12
                tooltipText: "Larger grid"
                onClicked: root.setGridColumns(root.gridColumnSetting + 1)
              }
            }

            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Window"
                color: root.fg
                font.family: root.ffont
                font.pixelSize: Style.font.caption
              }

              Button {
                width: 20
                height: 18
                text: "-"
                horizontalPadding: 0
                verticalPadding: 0
                fontSize: 12
                tooltipText: "Smaller window"
                onClicked: root.setWindowScale(root.windowScale - 0.1)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(40)
                horizontalAlignment: Text.AlignHCenter
                text: Math.round(root.windowScale * 100) + "%"
                color: root.fg
                font.family: root.ffont
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Button {
                width: 20
                height: 18
                text: "+"
                horizontalPadding: 0
                verticalPadding: 0
                fontSize: 12
                tooltipText: "Larger window"
                onClicked: root.setWindowScale(root.windowScale + 0.1)
              }
            }
          }

          Button {
            id: viewModeButton
            visible: !root.manageMode
            anchors.right: eyeButton.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: root.viewMode === "grid" ? "\uf0ca" : "\uf009"
            tooltipText: root.viewMode === "grid" ? "Switch to list view" : "Switch to grid view"
            foreground: root.fg
            horizontalPadding: 8
            verticalPadding: 3
            fontSize: Style.font.bodySmall
            onClicked: root.viewMode = root.viewMode === "grid" ? "list" : "grid"
          }

          Button {
            id: eyeButton
            visible: !root.manageMode
            anchors.right: penButton.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: root.showHidden ? "\uf06e" : "\uf070"
            tooltipText: root.showHidden ? "Hide hidden plugins" : "Show hidden plugins"
            foreground: root.showHidden ? Color.accent : root.fg
            horizontalPadding: 8
            verticalPadding: 3
            fontSize: Style.font.bodySmall
            onClicked: root.showHidden = !root.showHidden
          }

          Button {
            id: penButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf040"
            foreground: root.fg
            horizontalPadding: 8
            verticalPadding: 3
            fontSize: Style.font.bodySmall
            onClicked: {
              root.pendingDrawerIds = root.configuredIds.slice()
              root.manageMode = !root.manageMode
            }
          }
        }

       Flickable {
        id: bodyFlick
        width: menuColumn.width
        height: root.manageMode
          ? Math.min(manageColumn.implicitHeight, Math.max(80, Style.space(300)))
          : (root.viewMode === "grid" ? drawerGrid.implicitHeight : drawerColumn.implicitHeight)
        contentWidth: width
        contentHeight: root.manageMode ? manageColumn.implicitHeight : (root.viewMode === "grid" ? drawerGrid.implicitHeight : drawerColumn.implicitHeight)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: drawerColumn
          visible: !root.manageMode && root.viewMode === "list"
          width: bodyFlick.width
          spacing: Style.space(4)

          Repeater {
            model: root.drawerDisplayIds

            delegate: Item {
              id: drow
              required property var modelData
              width: drawerColumn.width
              implicitHeight: 30

              readonly property string rowId: drow.modelData.id
              readonly property bool isHiddenItem: drow.modelData.hidden
              property real pressX: 0
              property real pressY: 0
              property bool dragged: false

              opacity: (root.dragId === drow.rowId ? 0.4 : 1.0) * (drow.isHiddenItem ? 0.5 : 1.0)

              Rectangle {
                anchors.fill: parent
                radius: Math.max(2, Style.cornerRadius)
                color: root.dragActive && root.dragTargetIndex === drow.index
                  ? Util.alpha(Color.accent, 0.18)
                  : (!root.dragActive && drowMouse.containsMouse
                      ? Style.hoverFillFor(root.fg, root.fg)
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
                color: root.fg
                font.family: root.ffont
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
                  if (drow.isHiddenItem || root.showHidden) return
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
                  if (!drow.dragged) {
                    if (drow.isHiddenItem) root.toggleHiddenView(drow.rowId)
                    else root.openWidget(drow.rowId)
                  }
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
                visible: root.dragActive && !root.dragShowZone && root.dragTargetIndex === root.drawerVisibleIds.length
              }
            }

            Text {
              visible: root.configuredIds.length === 0
              width: drawerColumn.width
              text: "No widgets hidden."
              color: Qt.darker(root.fg, 1.5)
              font.family: root.ffont
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }
        }

        Flow {
          id: drawerGrid
          visible: !root.manageMode && root.viewMode === "grid"
          width: bodyFlick.width
          spacing: root.tileGap
          flow: Flow.LeftToRight

          Repeater {
            model: root.drawerDisplayIds

            delegate: Item {
              id: gtile
              required property var modelData
              width: root.gridCellW
              height: root.tileHeight

              readonly property string rowId: gtile.modelData.id
              readonly property bool isHiddenItem: gtile.modelData.hidden
              readonly property bool isDragTarget: root.dragActive && !root.dragShowZone && root.dragId !== gtile.rowId && root.dragTargetIndex === gtile.index
              property real pressX: 0
              property real pressY: 0
              property bool dragged: false

              opacity: (root.dragId === gtile.rowId ? 0.4 : 1.0) * (gtile.isHiddenItem ? 0.5 : 1.0)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: gtile.isDragTarget
                  ? Util.alpha(Color.accent, 0.18)
                  : (gtileMouse.containsMouse ? Style.hoverFillFor(root.fg, root.fg) : "transparent")
              }

              Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 3
                radius: 1.5
                color: Color.accent
                visible: gtile.isDragTarget
              }

              Text {
                id: label
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(6)
                width: parent.width - Style.space(8)
                horizontalAlignment: Text.AlignHCenter
                text: root.displayName(gtile.rowId)
                color: root.fg
                font.family: root.ffont
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                wrapMode: Text.Wrap
                maximumLineCount: 2
              }

              Loader {
                id: preview
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: label.top
                anchors.bottomMargin: Style.space(2)
                clip: true
                sourceComponent: root.viewMode === "grid" ? root.widgetComponent(gtile.rowId) : null
                onLoaded: {
                  var w = preview.item
                  if (!w) return
                  if ("bar" in w) w.bar = root.bar
                  if ("moduleName" in w) w.moduleName = gtile.rowId
                  if ("settings" in w) w.settings = root.defaultsFor(gtile.rowId)
                }
              }

              Text {
                id: gtileGlyph
                visible: preview.status !== Loader.Ready || preview.item === null
                anchors.fill: preview
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: root.pluginGlyph(gtile.rowId)
                color: root.fg
                font.family: root.ffont
                font.pixelSize: Style.space(22)
                font.bold: true
              }

              MouseArea {
                id: gtileMouse
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: root.dragStarted ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                onPressed: function(mouse) {
                  gtile.dragged = false
                  if (gtile.isHiddenItem || root.showHidden) return
                  gtile.pressX = mouse.x
                  gtile.pressY = mouse.y
                  root.dragStart(gtile.rowId)
                }

                onPositionChanged: function(mouse) {
                  if (!(mouse.buttons & Qt.LeftButton)) return
                  if (!gtile.dragged && (Math.abs(mouse.x - gtile.pressX) + Math.abs(mouse.y - gtile.pressY)) >= root.dragThreshold)
                    gtile.dragged = true
                  if (gtile.dragged) root.dragMove(gtileMouse, mouse.x, mouse.y)
                }

                onReleased: {
                  if (root.dragActive) root.dragEnd()
                }

                onCanceled: {
                  root.dragCancel()
                }

                onClicked: {
                  if (!gtile.dragged) {
                    if (gtile.isHiddenItem) root.toggleHiddenView(gtile.rowId)
                    else root.openWidget(gtile.rowId)
                  }
                }
              }
            }
          }

          Text {
            visible: root.configuredIds.length === 0
            width: drawerGrid.width
            text: "No widgets hidden."
            color: Qt.darker(root.fg, 1.5)
            font.family: root.ffont
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }
        }

        Column {
          id: manageColumn
          visible: root.manageMode
          width: bodyFlick.width
          spacing: Style.space(4)

          Text {
            visible: !root.hasFullRegistry
            width: manageColumn.width
            text: "Showing bar widgets only — enabling, disabling or adding other plugins needs a newer Omarchy plugin API (see project issue #2)."
            color: Qt.darker(root.fg, 1.5)
            font.family: root.ffont
            font.pixelSize: Style.font.caption
            font.italic: true
            wrapMode: Text.Wrap
          }

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
                  visible: root.configuredIds.indexOf(mrow.rowId) !== -1
                  text: root.isHiddenView(mrow.rowId) ? "\uf070" : "\uf06e"
                  tooltipText: root.isHiddenView(mrow.rowId) ? "Hidden — click to show in drawer" : "Hide from drawer"
                  foreground: root.isHiddenView(mrow.rowId) ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                  horizontalPadding: 0
                  verticalPadding: 0
                  onClicked: root.toggleHiddenView(mrow.rowId)
                }

                Button {
                  width: 24
                  height: 24
                  visible: root.hasFullRegistry
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
                  visible: root.hasFullRegistry
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
                  visible: root.hasFullRegistry
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
          width: root.viewMode === "grid" ? root.gridCellW : drawerColumn.width
          height: root.viewMode === "grid" ? root.tileHeight : 30
          radius: Math.max(2, Style.cornerRadius)
          color: Util.alpha(Color.accent, 0.25)
          border.width: 1.5
          border.color: Color.accent

          Text {
            id: dragGhostText
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            horizontalAlignment: root.viewMode === "grid" ? Text.AlignHCenter : Text.AlignLeft
            verticalAlignment: Text.AlignVCenter
            text: root.displayName(root.dragId)
            color: root.fg
            font.family: root.ffont
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
    root.persistOwnSettings({ widgets: list.slice() })
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

  // Broad, whole-config mutation. Since Omarchy 4.0.3, shell.mutateShellConfig
  // requires the caller's manifest to declare kind "bar" (a full replacement
  // bar) — a bar-widget-kind plugin like this one now gets `false` back and
  // nothing is written (Omarchy-drawer#2). Kept for hosts/contexts where it
  // still works; callers below that rely on it for moving *other* widgets on
  // or off the bar are a known gap until Omarchy exposes a narrower
  // capability for that. Persisting this plugin's own entry does not need
  // this path any more — see persistOwnSettings above.
  function mutateConfig(mutator) {
    var shell = root.bar && root.bar.shell
    if (!shell || typeof shell.mutateShellConfig !== "function") return
    shell.mutateShellConfig(mutator)
  }

  function layoutHas(id) {
    var key = String(id || "")
    var sections = root.barLayoutSections()
    if (!sections) return false
    var names = ["left", "center", "right"]
    for (var s = 0; s < names.length; s++) {
      var arr = sections[names[s]]
      if (!Array.isArray(arr)) continue
      for (var i = 0; i < arr.length; i++) {
        if (arr[i] && String(arr[i].id || "") === key) return true
      }
    }
    return false
  }

  // config.plugins[] (the disabled-but-installed list) isn't part of the
  // public bar.layoutConfig snapshot, so this only works where shellConfig is
  // still reachable; it degrades to "not found" otherwise, which is the safe
  // default here (see the callers below).
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
      if (dir && pluginsDir) scripts.push(root.removeScript(key, dir, pluginsDir))
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
    var pluginsDirQ = q(pluginsDir)
    var parts = ["set -e"]
    // Symlinks are only unlinked (never followed), so that is always safe.
    parts.push("if [ -L " + dirQ + " ]; then rm -f " + dirQ + ";")
    // For real directories, confine the action to a direct child of the
    // plugin registry so a forged/stale __sourceDir cannot delete or move
    // anything outside it.
    parts.push("else")
    parts.push("  base_canon=$(realpath -m " + pluginsDirQ + ")")
    parts.push("  target=$(realpath -m " + dirQ + ")")
    parts.push("  rel=${target#\"$base_canon/\"}")
    parts.push("  if [ \"$rel\" = \"$target\" ] || [ \"$rel\" != \"${rel#*/}\" ]; then echo 'plugin-drawer: refusing non-registry path: '\"$target\"; exit 1; fi")
    parts.push("  if [ -d " + dirQ + "/.git ]; then rm -rf " + dirQ + ";")
    parts.push("  elif [ -d " + dirQ + " ]; then mv " + dirQ + " " + q(pluginsDir + "/." + key + ".bak.") + "$(date +%s)")
    parts.push("  fi")
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
