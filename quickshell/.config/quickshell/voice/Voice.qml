// Voice.qml — estado do controle por voz (voice.py, serviço barch-voice.service) para a barra:
// lê ~/.local/state/barch/voice/state.json, que o daemon reescreve a cada mudança (listening,
// wake, hearing, processing, thinking, speaking, followup, paused, error, off), e pergunta ao systemd se o
// serviço está ligado. Liga/desliga o serviço e pausa a escuta (socket do daemon, via voice.py).
// Usado pelo VoiceWidget (ilha da barra), pelo tile Voice do Control Center e pelo barch (IPC "voice").
// O idioma (languages.json: os do whisper, com a voz do Piper de cada um) vem no state.json e é
// trocado por `voice.py language <code>`.
pragma Singleton

pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string script: Quickshell.shellDir + "/voice/voice.py"
    readonly property string stateFile: Quickshell.env("HOME") + "/.local/state/barch/voice/state.json"
    readonly property string unit: "barch-voice.service"

    property bool running: false            // o serviço está ativo
    property bool enabled: false            // o serviço está habilitado (liga com a sessão)
    property string state: "off"            // o que o daemon está fazendo
    property bool paused: false
    property string heard: ""               // a última frase entendida (sem o "barch")
    property string said: ""                // a última resposta falada
    property string error: ""
    property bool whisper: false            // whisper.cpp e o modelo encontrados
    property bool tts: false                // piper encontrado
    property string model: ""
    property real changed: 0                // quando o estado mudou (ms), para o texto sumir sozinho
    property string language: "pt"          // o idioma em que escuta e responde (código do whisper, ou "auto")
    property string languageName: "Portuguese"
    property string languageNative: "Português"
    property bool voiceReady: true          // a voz do Piper desse idioma está baixada
    property string downloading: ""         // a voz sendo baixada agora
    property var languages: []              // languages.json: [{ code, name, native, voice, latin }]
    property bool busy: false

    // o que o daemon diz só vale com o serviço de pé (o state.json fica para trás quando ele morre)
    readonly property string current: running ? state : "off"
    readonly property bool active: running && state !== "off"
    readonly property bool awake: state === "wake" || state === "hearing" || state === "processing" || state === "thinking" || state === "followup"
    readonly property bool speaking: state === "speaking"
    readonly property bool degraded: running && (state === "error" || !whisper)

    readonly property string label: !running ? "Off"
                                  : state === "error" ? (error || "Error")
                                  : !whisper ? "whisper.cpp missing"
                                  : paused || state === "paused" ? "Paused"
                                  : state === "wake" ? "Listening…"
                                  : state === "followup" ? "Still listening (no \"barch\" needed)"
                                  : state === "hearing" ? "Hearing…"
                                  : state === "processing" ? "Understanding…"
                                  : state === "thinking" ? "Asking Claude…"
                                  : state === "speaking" ? "Speaking"
                                  : state === "starting" ? "Starting…"
                                  : "Say \"barch\""

    FileView {
        id: stateView
        path: root.stateFile
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const s = JSON.parse(text())
                root.state = s.state || "off"
                root.paused = s.paused === true
                root.heard = s.heard || ""
                root.said = s.said || ""
                root.error = s.error || ""
                root.whisper = s.whisper === true
                root.tts = s.tts === true
                root.model = s.model || ""
                if (s.language) {
                    root.language = s.language
                    root.languageName = s.language_name || s.language
                    root.languageNative = s.language_native || ""
                    root.voiceReady = s.voice_ready !== false
                    root.downloading = s.downloading || ""
                }
                root.changed = Date.now()
            } catch (e) {}
        }
    }

    FileView {
        path: Quickshell.shellDir + "/voice/languages.json"
        printErrors: false
        onLoaded: { try { root.languages = JSON.parse(text()).languages || [] } catch (e) {} }
    }
    function languageLabel(code) {
        const e = languages.find(l => l.code === code)
        return !e ? code : e.code === "auto" ? "Automatic" : e.name === e.native ? e.name : e.name + " · " + e.native
    }

    Process {
        id: unitProc
        command: ["sh", "-c", "systemctl --user is-active " + root.unit + "; systemctl --user is-enabled " + root.unit]
        stdout: StdioCollector {
            onStreamFinished: {
                const l = text.trim().split("\n")
                const was = root.running
                root.running = l[0] === "active" || l[0] === "activating"
                root.enabled = (l[1] || "").trim() === "enabled"
                if (root.running && !was) stateView.reload()     // the daemon's first state.json may predate the watch
            }
        }
    }
    Timer { interval: root.busy ? 1000 : 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { id: later; interval: 1500; onTriggered: root.refresh() }

    function refresh() { if (!unitProc.running) unitProc.running = true }

    Process {
        id: action
        onExited: { root.busy = false; root.refresh(); later.restart() }
    }
    function control(args) {
        if (action.running) return
        root.busy = true
        action.command = args
        action.running = true
    }
    function start() { control(["systemctl", "--user", "start", unit]) }
    function stop() { control(["systemctl", "--user", "stop", unit]) }
    function toggleService() { if (running) stop(); else start() }
    function pause() { control(["python3", "-I", script, "pause"]) }
    function resume() { control(["python3", "-I", script, "resume"]) }
    function togglePause() { if (paused) resume(); else pause() }
    function say(text) { Quickshell.execDetached(["python3", "-I", script, "say", text]) }
    function setLanguage(code) {
        if (!languages.some(l => l.code === code)) return false
        root.language = code                  // na hora; o state.json confirma
        root.languageName = (languages.find(l => l.code === code) || {}).name || code
        control(["python3", "-I", script, "language", code])
        return true
    }

    // ---- IPC (barch voice ...) ----
    function status() {
        return { ok: true, running: running, enabled: enabled, state: current, paused: paused, heard: heard, said: said,
                 error: error, whisper: whisper, tts: tts, model: model, label: label,
                 language: language, language_name: languageName, voice_ready: voiceReady, downloading: downloading }
    }
    IpcHandler {
        target: "voice"
        function status(): string { root.refresh(); return JSON.stringify(root.status()) }
        function on(): string { root.start(); return JSON.stringify(root.status()) }
        function off(): string { root.stop(); return JSON.stringify(root.status()) }
        function toggle(): string { root.toggleService(); return JSON.stringify(root.status()) }
        function pause(): string { root.pause(); return JSON.stringify(root.status()) }
        function resume(): string { root.resume(); return JSON.stringify(root.status()) }
        function language(code: string): string {
            if (!root.setLanguage(code)) return JSON.stringify({ ok: false, error: "unknown language " + code })
            return JSON.stringify(root.status())
        }
        function languages(): string {
            return JSON.stringify({ ok: true, language: root.language, languages: root.languages.map(l => ({ code: l.code, name: l.name, native: l.native, voice: l.voice })) })
        }
    }
}
