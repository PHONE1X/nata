// whisper-dictate: модуль интеграции (управляется whisper-dictate-setup qs ii)
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ContentPage {
    id: page
    forceWidth: true

    readonly property string confPath: Quickshell.env("HOME") + "/.config/whisper-dictate/dictate.conf"
    property var conf: ({})
    readonly property string sttMode: (conf.STT ?? "").startsWith("openrouter") ? "openrouter" : "local"

    function parseConf(text) {
        let result = {};
        for (const line of text.split("\n")) {
            const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/);
            if (m) result[m[1]] = m[2].replace(/^["']|["']$/g, "");
        }
        return result;
    }

    function setConf(key, value) {
        Quickshell.execDetached(["whisper-dictate-setup", "conf", key, value]);
        let updated = Object.assign({}, page.conf);
        updated[key] = value;
        page.conf = updated;
    }

    FileView {
        path: page.confPath
        watchChanges: true
        onFileChanged: this.reload()
        onLoaded: page.conf = page.parseConf(this.text())
        onLoadFailed: page.conf = ({})
    }

    ContentSection {
        icon: "mic"
        title: Translation.tr("Speech recognition")

        ConfigSelectionArray {
            currentValue: page.sttMode
            onSelected: newValue => {
                if (newValue === "local") page.setConf("STT", "local");
                else if (page.sttMode !== "openrouter") page.setConf("STT", "openrouter:openai/gpt-4o-transcribe");
            }
            options: [
                { displayName: Translation.tr("Local (whisper.cpp)"), icon: "computer", value: "local" },
                { displayName: Translation.tr("Cloud (OpenRouter)"), icon: "cloud", value: "openrouter" }
            ]
        }

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            text: Translation.tr("Cloud recognition needs an OpenRouter key. If the cloud does not answer, the piece is recognized locally.")
        }
    }

    ContentSection {
        icon: "translate"
        title: Translation.tr("Translation")

        ConfigSelectionArray {
            currentValue: page.conf.TRANSLATE_PROVIDER ?? ""
            onSelected: newValue => page.setConf("TRANSLATE_PROVIDER", newValue)
            options: [
                { displayName: Translation.tr("Off"), icon: "block", value: "" },
                { displayName: "Gemini", icon: "auto_awesome", value: "gemini" },
                { displayName: "DeepL", icon: "language", value: "deepl" },
                { displayName: Translation.tr("Local"), icon: "computer", value: "local" }
            ]
        }
    }

    ContentSection {
        icon: "tune"
        title: Translation.tr("Models and keys")

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            text: Translation.tr("Whisper model: %1").arg(page.conf.MODEL || Translation.tr("not set"))
        }

        RippleButton {
            buttonText: Translation.tr("Open whisper-dictate setup")
            onClicked: Quickshell.execDetached(["whisper-dictate-gui"])
        }
    }
}
