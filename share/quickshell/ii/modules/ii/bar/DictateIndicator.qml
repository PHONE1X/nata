// whisper-dictate: модуль интеграции (управляется whisper-dictate-setup qs ii)
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell

MouseArea {
    id: dictateRoot

    readonly property var dictation: Persistent.states.dictation
    readonly property bool recording: dictation.active
    readonly property int queued: dictation.pending + dictation.ready
    readonly property bool working: dictation.pending > 0 || dictation.processing
    readonly property bool shouldShow: recording || queued > 0 || working
    property int nowEpoch: Date.now() / 1000
    readonly property int elapsedSeconds: recording ? Math.max(0, nowEpoch - dictation.startedAt) : 0
    readonly property color colText: Appearance.colors.colOnLayer0

    function formatTime(totalSeconds) {
        const mins = Math.floor(totalSeconds / 60);
        const secs = totalSeconds % 60;
        return String(mins).padStart(2, "0") + ":" + String(secs).padStart(2, "0");
    }

    visible: shouldShow
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    implicitWidth: contentRow.implicitWidth + 16
    implicitHeight: 30

    Timer {
        running: dictateRoot.recording
        repeat: true
        interval: 1000
        onTriggered: dictateRoot.nowEpoch = Date.now() / 1000
    }

    onClicked: mouse => {
        if (mouse.button === Qt.RightButton)
            Quickshell.execDetached(["whisper-dictate", "--cancel", dictateRoot.recording ? "recording" : "queue"]);
        else
            Quickshell.execDetached(["whisper-dictate"]);
    }

    RowLayout {
        id: contentRow
        anchors.centerIn: parent
        spacing: 6

        MaterialSymbol {
            text: dictateRoot.recording ? "mic" : (dictateRoot.working ? "sync" : "hourglass_top")
            iconSize: Appearance.font.pixelSize.larger
            color: dictateRoot.colText
        }

        StyledText {
            visible: dictateRoot.recording
            font.features: ({ "tnum": 1 })
            text: dictateRoot.formatTime(dictateRoot.elapsedSeconds)
            color: dictateRoot.colText
        }

        StyledText {
            visible: dictateRoot.queued > 1
            text: "×" + dictateRoot.queued
            font.weight: Font.Bold
            color: dictateRoot.colText
        }
    }

    StyledPopup {
        hoverTarget: dictateRoot

        ColumnLayout {
            anchors.centerIn: parent
            spacing: 4

            StyledPopupHeaderRow {
                icon: "mic"
                label: Translation.tr("Dictation")
            }

            StyledPopupValueRow {
                visible: dictateRoot.recording
                icon: "web_asset"
                label: Translation.tr("Target")
                value: dictateRoot.dictation.target || Translation.tr("Unknown window")
            }

            StyledPopupValueRow {
                visible: dictateRoot.recording
                icon: "translate"
                label: Translation.tr("Language")
                value: (dictateRoot.dictation.lang || "ru").toUpperCase()
            }

            StyledPopupValueRow {
                visible: dictateRoot.queued > 0
                icon: "pending"
                label: Translation.tr("In queue")
                value: String(dictateRoot.queued)
            }
        }
    }
}
