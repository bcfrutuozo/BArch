#!/usr/bin/env bash
# O que está usando microfone, câmera e tela agora (usado pelo PrivacyWidget), em JSON:
#   {"mic":["Firefox"],"cam":["zoom"],"screen":["Screen"]}
# - microfone: streams de captura de áudio ativos no PipeWire (ignora medidores de volume
#   e capturas do som do sistema, que não são o microfone);
# - câmera: processos com /dev/video* aberto (navegadores e apps que não passam pelo PipeWire)
#   e câmeras do PipeWire em uso;
# - tela: compartilhamentos ativos pelo portal do Hyprland (xdg-desktop-portal-hyprland).
# Depende de: pipewire (pw-dump), jq.

IGNORE='pavucontrol|PulseAudio Volume Control|cava|easyeffects|quickshell|wireplumber'

pw=$(timeout 3 pw-dump 2>/dev/null || echo '[]')

# processos com a câmera aberta (só os do seu usuário são visíveis, o que basta)
cam_procs=$(
  find /proc/[0-9]*/fd -maxdepth 1 -lname '/dev/video*' 2>/dev/null \
    | cut -d/ -f3 | sort -u \
    | while read -r pid; do cat "/proc/$pid/comm" 2>/dev/null; done \
    | sort -u | jq -R -s 'split("\n") | map(select(length > 0))'
)

jq -c --arg ignore "$IGNORE" --argjson camprocs "${cam_procs:-[]}" '
  [ .[] | select(.type == "PipeWire:Interface:Node") | { state: .info.state, p: (.info.props // {}) } ] as $n
  | {
      mic: ( [ $n[]
             | select(.p."media.class" == "Stream/Input/Audio" and .state == "running")
             | select((.p."stream.capture.sink" // false) != true and (.p."stream.monitor" // false) != true)
             | (.p."application.name" // .p."application.process.binary" // .p."node.name" // "Unknown") ]
           | map(select(test($ignore; "i") | not)) | unique ),
      cam: ( ( ($camprocs | map(select(test("^(pipewire|wireplumber)$") | not)))
             + ( if ([ $n[] | select(.p."media.class" == "Video/Source" and .state == "running"
                                     and ((.p."device.api" // "") | test("v4l2|libcamera"))) ] | length) > 0
                 then ["Camera"] else [] end ) )
           | unique
           | if length > 1 then map(select(. != "Camera")) else . end ),
      screen: ( [ $n[] | select((.p."node.name" // "") | test("^xdph-streaming")) | "Screen" ] | unique )
    }
' <<<"$pw" 2>/dev/null || echo '{"mic":[],"cam":[],"screen":[]}'
