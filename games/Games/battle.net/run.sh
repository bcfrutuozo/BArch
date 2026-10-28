#!/bin/sh
# Battle.net (Proton-GE via umu-launcher), instância própria em ~/Games/battle.net.
# Caminho fixo: o arquivo vive no BArch e aqui fica só um link, então não dá para
# descobrir a pasta da instância a partir do próprio script.
DIR="$HOME/Games/battle.net"
export WINEPREFIX="$DIR/prefix"
export PROTONPATH="$DIR/proton/current"
export GAMEID=umu-battlenet STORE=battlenet
export PROTON_SET_GAME_DRIVE=0
export PROTON_ENABLE_WAYLAND=1
export PROTON_USE_NTSYNC=1
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1

# HDR: botão Game HDR do Control Center (vale ao abrir; padrão ligado)
if [ "$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/game-hdr" 2>/dev/null)" = off ]; then
    unset PROTON_ENABLE_HDR
else
    export PROTON_ENABLE_HDR=1
fi

# MangoHud sempre carregado; aparece ou some pelo botão Game HUD (sem reabrir o jogo)
command -v mangohud >/dev/null && export MANGOHUD=1

# sem argumentos abre o Battle.net; com argumento roda o .exe indicado
if [ $# -eq 0 ]; then
    set -- "$WINEPREFIX/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe"
fi

# gamemode: o ~/.config/gamemode.ini ignora os processos do Battle.net,
# então o modo desempenho só liga enquanto um jogo estiver aberto
if command -v gamemoderun >/dev/null; then
    exec gamemoderun umu-run "$@"
fi
exec umu-run "$@"
