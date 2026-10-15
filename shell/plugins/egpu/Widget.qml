import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omarchy.egpu"
  ipcTarget: "omarchy.egpu"
  manageIpc: false

  property var inventory: ({ gpus: [], models: [], operation: {} })
  property string managerPath: Qt.resolvedUrl("manager.py").toString().replace(/^file:\/\//, "")
  readonly property bool busy: ["offloading", "unloading", "loading"].indexOf(inventory.operation.status || "") >= 0

  function gib(bytes) {
    return bytes === null || bytes === undefined ? "unknown" : (bytes / 1073741824).toFixed(1) + " GiB"
  }

  function memoryLabel(gpu) {
    if (gpu.total === null || gpu.total === undefined) return "Memory telemetry unavailable"
    var label = gpu.memoryType === "shared" ? "Shared GPU memory" : "VRAM"
    return label + " " + gib(gpu.used) + " / " + gib(gpu.total)
  }

  function refresh() {
    if (!probe.running && !reconcile.running && !action.running) probe.running = true
  }

  function choices(model) {
    var result = []
    for (var i = 0; i < inventory.gpus.length; i++) {
      var gpu = inventory.gpus[i]
      if (!gpu.selectable) continue
      if (model.allowedDevices && model.allowedDevices.indexOf(gpu.id) < 0) continue
      var fit = model.fits && model.fits[gpu.id] ? model.fits[gpu.id] : { label: "GPU memory fit unknown" }
      result.push({ id: gpu.id, label: gpu.name + " · " + fit.label })
    }
    return result
  }

  function choiceIndex(model, candidates) {
    var selected = model.preferred || model.current
    for (var i = 0; i < candidates.length; i++) if (candidates[i].id === selected) return i
    return candidates.length ? 0 : -1
  }

  function applyPlacement(model, device) {
    if (!model || !device || probe.running || reconcile.running || action.running) return
    action.command = ["python3", "-B", managerPath, "apply", model, device]
    action.running = true
    refreshDelay.restart()
  }

  Component.onCompleted: {
    refresh()
  }

  Timer { interval: 15000; repeat: true; running: true; onTriggered: root.refresh() }
  Timer {
    id: reconcileTimer
    interval: 30000
    repeat: true
    running: true
    onTriggered: if (!probe.running && !reconcile.running && !action.running) reconcile.running = true
  }
  Timer { id: refreshDelay; interval: 250; onTriggered: root.refresh() }

  Process {
    id: probe
    command: ["python3", "-B", root.managerPath, "inventory"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.inventory = JSON.parse(text) }
        catch (error) { root.inventory = { gpus: [], models: [], operation: { status: "error", message: "GPU telemetry unavailable" } } }
      }
    }
  }

  Process { id: reconcile; command: ["python3", "-B", root.managerPath, "reconcile"]; onExited: root.refresh() }
  Process { id: action; onExited: root.refresh() }

  IpcHandler {
    target: "omarchy.egpu"
    function status(): string { return JSON.stringify(root.inventory) }
    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    bar: root.bar
    text: root.busy ? "󰚰" : "󰢮 " + root.inventory.gpus.length + (root.inventory.models.length ? " · AI " + root.inventory.models.length : "")
    tooltipText: root.inventory.operation.message || "GPUs and local models"
    onPressed: function(mouseButton) { if (mouseButton === Qt.LeftButton) { root.refresh(); root.toggle() } }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(Math.min(content.implicitHeight, Style.space(680)))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentHeight: content.implicitHeight
        clip: true

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: "GPUs & local models"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Rectangle {
            width: parent.width
            height: operationText.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            visible: !!root.inventory.operation.message
            color: root.inventory.operation.status === "error" ? Qt.rgba(0.55, 0.08, 0.08, 0.65) : Qt.rgba(0.1, 0.3, 0.45, 0.65)
            Text {
              id: operationText
              anchors.fill: parent
              anchors.margins: Style.space(8)
              text: root.inventory.operation.message || ""
              textFormat: Text.PlainText
              color: Color.foreground
              wrapMode: Text.Wrap
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          Text {
            text: "GPUS"
            color: Color.foreground
            opacity: 0.65
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Repeater {
            model: root.inventory.gpus
            delegate: Rectangle {
              required property var modelData
              width: content.width
              height: gpuText.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Qt.rgba(1, 1, 1, 0.04)
              Text {
                id: gpuText
                anchors.fill: parent
                anchors.margins: Style.space(8)
                text: modelData.name + "\n" + (modelData.external ? "External" : "Built-in / PCIe") + " · " + modelData.driver
                  + " · " + root.memoryLabel(modelData)
                textFormat: Text.PlainText
                color: Color.foreground
                wrapMode: Text.Wrap
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }

          Text {
            text: "LOCAL MODEL RUNTIMES"
            color: Color.foreground
            opacity: 0.65
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Repeater {
            model: root.inventory.models
            delegate: Rectangle {
              id: modelCard
              required property var modelData
              property var gpuChoices: root.choices(modelData)
              width: content.width
              height: modelColumn.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Qt.rgba(1, 1, 1, 0.04)

              Column {
                id: modelColumn
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  text: modelCard.modelData.name + " · " + modelCard.modelData.runtime
                  textFormat: Text.PlainText
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideMiddle
                }
                Text {
                  width: parent.width
                  text: "Current: " + (modelCard.modelData.current || "CPU / unverified")
                    + (modelCard.modelData.estimated ? " · Estimated need: " : " · Required: ")
                    + root.gib(modelCard.modelData.required)
                  textFormat: Text.PlainText
                  color: Color.foreground
                  opacity: 0.75
                  wrapMode: Text.Wrap
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                ComboBox {
                  id: gpuSelector
                  width: parent.width
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  model: modelCard.gpuChoices
                  textRole: "label"
                  valueRole: "id"
                  currentIndex: root.choiceIndex(modelCard.modelData, modelCard.gpuChoices)
                  enabled: modelCard.modelData.capable && !root.busy && modelCard.gpuChoices.length > 0
                }
                Rectangle {
                  id: applyButton
                  property bool available: modelCard.modelData.capable && !root.busy && gpuSelector.currentIndex >= 0
                  width: parent.width
                  height: Style.space(34)
                  radius: Style.cornerRadius
                  color: available ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.04)
                  opacity: available ? 1 : 0.55
                  Text {
                    anchors.centerIn: parent
                    text: "Apply & reload"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: applyButton.available
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.applyPlacement(modelCard.modelData.id, gpuSelector.currentValue)
                  }
                }
                Text {
                  width: parent.width
                  text: modelCard.modelData.reason || ""
                  textFormat: Text.PlainText
                  color: modelCard.modelData.capable ? Color.foreground : Color.urgent
                  opacity: modelCard.modelData.capable ? 0.7 : 1
                  wrapMode: Text.Wrap
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            visible: root.inventory.models.length === 0
            width: parent.width
            text: "No loaded local model runtime was detected."
            color: Color.foreground
            opacity: 0.7
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            text: "Changing a device unloads and reloads the model. miaOS verifies GPU allocation after reload; it does not attempt live GPU-memory migration."
            color: Color.foreground
            opacity: 0.6
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
