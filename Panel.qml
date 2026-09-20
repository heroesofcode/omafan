import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Omafan — a live temperature readout in the bar, plus the curve that drives
// the fan behind it.
//
// The panel never writes configuration and never touches the fan. It persists
// into its inline shell.json entry and shells out to omafan-apply, which owns
// the config file; the root daemon re-reads that file on its next tick. So the
// panel stays unprivileged and there is one place a setting can be wrong.
Panel {
  id: root
  moduleName: "io.github.heroesofcode.omafan"
  ipcTarget: "io.github.heroesofcode.omafan"

  readonly property string applyPath: Qt.resolvedUrl("omafan-apply").toString().replace("file://", "")
  readonly property string statusPath: Qt.resolvedUrl("omafan-status").toString().replace("file://", "")
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")

  readonly property bool fanOn: get("enabled") === true
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Last parsed omafan-status payload. Starts unsupported so the bar shows a
  // dash rather than a confident 0°C before the first poll lands.
  property var status: ({ supported: false })
  // Coerced with !!: before the first poll lands `status.service` is undefined,
  // and QML refuses to assign undefined to a bool property.
  readonly property bool installed: !!(status && status.service && status.service !== "absent")
  readonly property bool serviceRunning: !!(status && status.service === "active")

  property bool dropdownOwnsKeys: false

  // Effective value for a settings key: whatever the shell persisted, else the
  // plugin's own default. Every read goes through here so an unsaved key never
  // reads as empty and writes a nonsense curve.
  function get(key) { return root.setting(key, Model.defaultFor(key)) }

  function save(patch) {
    root.settings = Object.assign({}, root.settings, patch)
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    applyDebounce.restart()
  }

  function apply() {
    if (applyProc.running) { applyDebounce.restart(); return }
    applyProc.command = Model.commandFor(root.applyPath, root.get)
    applyProc.running = true
  }

  // Debounced so dragging a slider writes the config once at the end rather
  // than once per pixel. Nothing here reloads a service, so this is short.
  Timer {
    id: applyDebounce
    interval: 250
    onTriggered: root.apply()
  }

  Process {
    id: applyProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("omafan", text.trim())
    }
  }

  // ---------- live status ----------
  Process {
    id: statusProc
    command: ["bash", root.statusPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readStatus(text)
    }
  }

  function readStatus(text) {
    try {
      var parsed = JSON.parse(String(text || "").trim())
      if (parsed && typeof parsed === "object") root.status = parsed
    } catch (e) {
      // A malformed line means the machine changed under us (module unloaded,
      // for instance). Keep the last good reading rather than blanking the bar.
    }
  }

  function poll() { if (!statusProc.running) statusProc.running = true }

  // Faster while the panel is open, because that is when someone is watching a
  // number change; slower otherwise, because this runs all day.
  Timer {
    id: pollTimer
    interval: root.opened ? 2000 : 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  // Regenerate whenever the persisted settings change, including the moment
  // the shell first hands them over: a freshly enabled widget starts with an
  // empty object, so applying only at Component.onCompleted would write the
  // defaults and never revisit them.
  onSettingsChanged: applyDebounce.restart()
  Component.onCompleted: applyDebounce.restart()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barText(root.status)
    tooltipText: Model.summary(root.get, root.status)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.save({ enabled: !root.fanOn })
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.dropdownOwnsKeys
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroSwitch.implicitHeight)

            Text {
              id: heroIcon
              text: "󰈐"
              color: root.fanOn && root.serviceRunning ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Behavior on color { ColorAnimation { duration: 200 } }

              // Spin only while the fan is actually above its floor, so the
              // animation reports something instead of decorating.
              RotationAnimation on rotation {
                running: root.status.supported === true && root.status.rpm > (root.status.min || 0) + 150
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 1400
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: heroSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Omafan"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: Model.summary(root.get, root.status).toUpperCase()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            ToggleSwitch {
              id: heroSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.fanOn
              foreground: root.foreground
              onToggled: root.save({ enabled: !root.fanOn })
            }
          }

          // ---------- Not installed ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.status.supported === true && !root.installed

            PanelSeparator { foreground: root.foreground }

            Text {
              width: parent.width
              text: "The fan service is not installed yet. Nothing below has any effect until it is."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "Run this once, in a terminal:\n\nsudo " + root.pluginDir + "/omafan-install"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
            }
          }

          // ---------- Unsupported ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.status.supported === false

            PanelSeparator { foreground: root.foreground }

            Text {
              width: parent.width
              text: "No Apple SMC fan found on this machine. Omafan drives Apple hardware through the applesmc kernel module and has nothing to control here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.foreground; visible: root.status.supported === true }

          // ---------- Live readout ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.status.supported === true

            PanelSectionHeader {
              text: "RIGHT NOW"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: readout.implicitHeight

              Row {
                id: readout
                spacing: Style.space(22)

                Column {
                  spacing: Style.space(1)
                  Text {
                    text: (root.status.temp || 0) + "°C"
                    color: (root.status.temp || 0) >= root.get("tempHigh") ? "#e06c75" : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }
                  Text {
                    text: "HOTTEST SENSOR"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.1
                  }
                }

                Column {
                  spacing: Style.space(1)
                  Text {
                    text: (root.status.rpm || 0) + " RPM"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }
                  Text {
                    text: "FAN"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.1
                  }
                }

                Column {
                  spacing: Style.space(1)
                  Text {
                    text: (root.status.floor || 0) + " RPM"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }
                  Text {
                    text: "FLOOR"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.1
                  }
                }
              }
            }

            // Where the fan sits in its own range.
            Rectangle {
              width: parent.width
              height: Style.space(6)
              radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

              Rectangle {
                height: parent.height
                radius: parent.radius
                width: parent.width * Model.loadFraction(root.status.rpm || 0, root.status.min || 0, root.status.max || 0)
                color: root.foreground
                Behavior on width { NumberAnimation { duration: 400 } }
              }
            }

            Text {
              visible: root.installed && !root.serviceRunning
              width: parent.width
              text: "The service is installed but stopped, so the fan is back under the SMC's own control. Start it with: systemctl start omafan"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.foreground; visible: root.status.supported === true }

          // ---------- Curve ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.status.supported === true
            opacity: root.fanOn ? 1.0 : 0.45

            Behavior on opacity { NumberAnimation { duration: 160 } }

            PanelSectionHeader {
              text: "CURVE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SettingSlider {
              width: parent.width
              label: "Start ramping at"
              suffix: " °C"
              bar: root.bar
              minimum: 30
              maximum: 99
              step: 1
              boundValue: root.get("tempLow")
              onCommitted: function(v) { root.save({ tempLow: v }) }
            }

            SettingSlider {
              width: parent.width
              label: "Full speed at"
              suffix: " °C"
              bar: root.bar
              minimum: 31
              maximum: 100
              step: 1
              boundValue: root.get("tempHigh")
              onCommitted: function(v) { root.save({ tempHigh: v }) }
            }

            SettingSlider {
              width: parent.width
              label: "Fastest floor"
              suffix: " RPM"
              bar: root.bar
              minimum: root.status.min || 1200
              maximum: root.status.max || 6500
              step: 100
              boundValue: root.get("rpmMax")
              onCommitted: function(v) { root.save({ rpmMax: v }) }
            }

            Text {
              width: parent.width
              text: "At " + (root.status.temp || 0) + "°C this curve asks for a floor of "
                    + Model.floorFor(root.status.temp || 0, root.get) + " RPM."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "Omafan only raises the speed the fan is allowed to drop to. The SMC keeps control and can always go faster on its own — which is why a crashed daemon leaves the fan loud rather than silent."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.foreground; visible: root.status.supported === true }

          // ---------- Response ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.status.supported === true
            opacity: root.fanOn ? 1.0 : 0.45

            Behavior on opacity { NumberAnimation { duration: 160 } }

            PanelSectionHeader {
              text: "RESPONSE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SettingSlider {
              width: parent.width
              label: "Cool-down band"
              suffix: " °C"
              bar: root.bar
              minimum: 0
              maximum: 20
              step: 1
              boundValue: root.get("hysteresis")
              onCommitted: function(v) { root.save({ hysteresis: v }) }
            }

            Text {
              width: parent.width
              text: "The fan speeds up the moment the temperature calls for it, but slows down only after the machine has cooled this much further. Without a band it would surge and drop around every threshold."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            SettingSlider {
              width: parent.width
              label: "Check every"
              suffix: " s"
              bar: root.bar
              minimum: 1
              maximum: 60
              step: 1
              boundValue: root.get("interval")
              onCommitted: function(v) { root.save({ interval: v }) }
            }
          }
        }
      }
    }
  }

  // A labelled slider with its live value on the right.
  //
  // `value` is driven from `boundValue` through a handler rather than bound
  // straight to it: the slider assigns to its own `value` while dragging,
  // which would destroy a declarative binding and leave the control deaf to
  // any later change made elsewhere.
  component SettingSlider: Item {
    id: sliderRow
    property string label: ""
    property string suffix: ""
    property var bar: null
    property int minimum: 0
    property int maximum: 100
    property int step: 1
    property int boundValue: 0

    signal committed(int value)

    implicitHeight: rowLabel.implicitHeight + Style.space(6) + slider.implicitHeight

    Text {
      id: rowLabel
      anchors.left: parent.left
      text: sliderRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.right: parent.right
      anchors.baseline: rowLabel.baseline
      text: Math.round(slider.liveValue) + sliderRow.suffix
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    PanelSlider {
      id: slider
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: rowLabel.bottom
      anchors.topMargin: Style.space(6)
      bar: sliderRow.bar
      minimum: sliderRow.minimum
      maximum: sliderRow.maximum
      step: sliderRow.step
      integer: true
      value: sliderRow.boundValue
      onReleased: function(v) { sliderRow.committed(Math.round(v)) }
    }

    onBoundValueChanged: if (Math.round(slider.value) !== boundValue) slider.value = boundValue
  }
}
