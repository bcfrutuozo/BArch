#!/usr/bin/env bash
# What barch-voice needs besides the repo, and whether it is there. Run by install.sh and by
# `barch voice setup`; without --install it only reports (exit 1 when something is missing).
#   whisper-cpp + ggml-cuda (extra)        the words, on the GPU
#   whisper.cpp-model-large-v3-turbo-q5_0  the model (AUR; any ggml model works, see config.json)
#   piper-tts (AUR)                        the voice; the pt_BR voice itself is downloaded here
#   python-numpy                           the VAD
# --install asks paru for the missing packages (needs the sudo password, so it is interactive).
set -uo pipefail

VOICE_DIR=${PIPER_DATA_DIR:-$HOME/.local/share/piper}
cfg=$(dirname "$(readlink -f "$0")")/config.json
VOICE=$(jq -r '.tts_voice // "pt_BR-faber-medium"' "$cfg" 2>/dev/null || echo pt_BR-faber-medium)
PKGS_REPO=(whisper-cpp ggml-cuda python-numpy)
PKGS_AUR=(whisper.cpp-model-large-v3-turbo-q5_0 piper-tts)
install=0
[[ ${1:-} == --install ]] && install=1

missing=()
for p in "${PKGS_REPO[@]}" "${PKGS_AUR[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p"); done
if ((${#missing[@]})); then
  if ((install)) && command -v paru >/dev/null; then
    paru -S --needed "${missing[@]}" || { echo "voice: some packages did not install" >&2; exit 1; }
  else
    echo "voice: missing packages: ${missing[*]}" >&2
    echo "       paru -S --needed ${missing[*]}" >&2
    [[ $(systemd-detect-virt 2>/dev/null) != none ]] && echo "       (a VM has no GPU: whisper runs on the CPU, slowly)" >&2
    ((install)) || exit 1
  fi
fi

# the Brazilian Portuguese voice (piper 1.x: the package installs `piper-tts`; `python -m piper.download_voices`
# fetches the .onnx + .json from Hugging Face the first time)
if command -v piper-tts >/dev/null || command -v piper >/dev/null; then
  if compgen -G "$VOICE_DIR/$VOICE.onnx" >/dev/null || compgen -G "$VOICE_DIR/*/$VOICE.onnx" >/dev/null; then
    echo "voice: piper voice $VOICE ready"
  else
    mkdir -p "$VOICE_DIR"
    if python3 -m piper.download_voices --download-dir "$VOICE_DIR" "$VOICE" >/dev/null 2>&1 \
       && compgen -G "$VOICE_DIR/$VOICE.onnx" >/dev/null; then
      echo "voice: piper voice $VOICE downloaded to ${VOICE_DIR/#$HOME/\~}"
    else
      echo "voice: could not download the piper voice $VOICE (network? try: python3 -m piper.download_voices --download-dir $VOICE_DIR $VOICE)" >&2
      exit 1
    fi
  fi
fi

if command -v whisper-cli >/dev/null || command -v whisper-server >/dev/null; then
  if compgen -G "/usr/share/whisper.cpp-model-*/*.bin" >/dev/null || compgen -G "$HOME/.local/share/whisper.cpp/models/*.bin" >/dev/null; then
    echo "voice: whisper.cpp and a model found"
  else
    echo "voice: whisper.cpp is installed but no model was found (whisper.cpp-model-large-v3-turbo-q5_0 from the AUR, or a .bin in ~/.local/share/whisper.cpp/models)" >&2
    exit 1
  fi
fi
exit 0
