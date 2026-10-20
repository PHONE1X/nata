// whisper-dictate: самостоятельный индикатор диктовки (запуск: qs -c whisper-dictate)
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

PanelWindow {
    id: root

    property var dictation: ({})
    readonly property bool recording: dictation.active === true
    readonly property int queued: (dictation.pending ?? 0) + (dictation.ready ?? 0)
    readonly property bool working: dictation.processing === true || (dictation.pending ?? 0) > 0
    readonly property bool shouldShow: recording || queued > 0 || working
    property real nowEpoch: Date.now() / 1000
    readonly property int elapsedSeconds: recording ? Math.max(0, Math.floor(nowEpoch - (dictation.startedAt ?? 0))) : 0

    function formatTime(total) {
        const mins = Math.floor(total / 60);
        const secs = total % 60;
        return String(mins).padStart(2, "0") + ":" + String(secs).padStart(2, "0");
    }

    anchors {
        top: true
        right: true
    }
    margins {
        top: 8
        right: 8
    }
    implicitWidth: row.implicitWidth + 24
    implicitHeight: 32
    exclusiveZone: 0
    color: "transparent"
    visible: shouldShow

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/quickshell/states.json"
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: {
            try {
                root.dictation = JSON.parse(this.text()).dictation ?? ({});
            } catch (e) {
                root.dictation = ({});
            }
        }
        onLoadFailed: root.dictation = ({})
    }

    Timer {
        running: root.recording
        repeat: true
        interval: 1000
        onTriggered: root.nowEpoch = Date.now() / 1000
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: "#cc1e1e2e"

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton)
                    Quickshell.execDetached(["whisper-dictate", "--cancel", root.recording ? "recording" : "queue"]);
                else
                    Quickshell.execDetached(["whisper-dictate"]);
            }
        }

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: 6

            Text {
                text: root.recording ? "mic" : (root.working ? "sync" : "hourglass_top")
                font.family: "Material Symbols Rounded"
                font.pixelSize: 18
                color: "#f5f5f5"
            }

            Text {
                visible: root.recording
                text: root.formatTime(root.elapsedSeconds)
                font.pixelSize: 14
                font.features: ({ "tnum": 1 })
                color: "#f5f5f5"
            }

            Text {
                visible: root.queued > 1
                text: "×" + root.queued
                font.pixelSize: 14
                font.bold: true
                color: "#f5f5f5"
            }
        }
    }
}
