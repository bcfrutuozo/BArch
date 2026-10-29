// Wallpaper.qml — o papel de parede de cada monitor, desenhado pelo bar numa camada "background"
// do layer-shell (no lugar do hyprpaper, aposentado em 2026-10-28). Segue o modo claro/escuro
// do tema (Wallpapers.path) com um crossfade: a imagem nova carrega atrás, em segundo plano, e
// só então aparece por cima da antiga. Sem arquivo, fica a cor de fundo do tema.

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"

Scope {
    id: root

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "barch-wallpaper"
            exclusionMode: ExclusionMode.Ignore
            anchors { top: true; bottom: true; left: true; right: true }
            color: Theme.base

            readonly property string file: Wallpapers.path(modelData.name)
            property Item shown: null           // a imagem visível
            property Item pending: null         // a que está carregando para substituí-la

            component Layer: Image {
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false                    // o arquivo pode ter sido regenerado com o mesmo nome
                smooth: true
                opacity: 0
                Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.InOutQuad } }
                onStatusChanged: {
                    if (win.pending !== this) return
                    if (status === Image.Ready) win.swapTo(this)
                    else if (status === Image.Error) { console.warn("wallpaper: cannot load", source); win.pending = null }
                }
            }
            Layer { id: a }
            Layer { id: b }

            function load() {
                const back = shown === a ? b : a
                pending = back
                back.source = ""
                back.source = "file://" + file
            }
            function swapTo(img) {
                const old = shown
                pending = null
                shown = img
                img.z = 1
                img.opacity = 1
                if (old) { old.z = 0; old.opacity = 0; release.restart() }
            }
            // libera a imagem antiga da memória quando o fade termina (4K = 33 MB cada)
            Timer { id: release; interval: 700; onTriggered: { const old = win.shown === a ? b : a; if (win.pending !== old) old.source = "" } }

            Component.onCompleted: load()
            onFileChanged: load()
        }
    }
}
