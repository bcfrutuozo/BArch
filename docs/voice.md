# Voice control

Always-on voice control: the bar's microphone and the daemon behind it.

## In the bar

**Voice control** (`quickshell/voice/`, `barch voice`, tile **Voice** in the Control Center): the
microphone is always open, like in a car, and nothing happens until a sentence starts with
"barch" (see [The daemon](#the-daemon) below). A microphone shows in the bar while the service runs: dim while it
only listens, pulsing in the accent color after "barch" alone (it chimes and waits for the
sentence), steady while it understands or asks Claude, green while it speaks, red when
whisper.cpp or the microphone is missing; what it understood shows next to it for a few
seconds. Click pauses and resumes the listening, right-click shows the last sentence and answer
and the **language** it listens in (a list with a filter: every language whisper knows, see [The daemon](#the-daemon)).

## The daemon

`barch-voice.service` (`quickshell/voice/voice.py`) keeps the fifine open through PipeWire (its own
node, `barch-voice`, which the privacy indicator ignores) and cuts the audio into sentences with an
energy VAD. Everything runs on this machine: the first two seconds of every sentence go through
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) (`whisper-server`, kept warm, on the GPU
through `ggml-cuda`) only to see whether it starts with **"barch"**; everything else in the room is
dropped right there. A sentence that does start with it is transcribed whole and goes through
`commands.json`, a table of intents in Portuguese (regexes over the sentence normalized to lower
case without accents, fillers like "por favor" removed) that reach `barch`, `hyprctl dispatch`,
`uwsm app`, `wpctl`, `playerctl` and the bar's IPC without any AI: themes and palettes, wallpapers,
HDR and SDR brightness, side monitor, caffeine, night light, Do Not Disturb, Anonymous Mode and VPN
(with the region: "entra no modo anônimo na alemanha"), windows (close, fullscreen, float, minimize,
pin, swap, focus), workspaces (go, move, next, scratchpad), volume and media, apps ("abre o spotify",
by the name in its `.desktop`, plus the aliases in `app_aliases`: navegador, terminal, arquivos,
mixer, pacotes…), projects ("abre o claude no fragmenta" opens a terminal in `~/Source/Fragmenta`
running `claude`; also a plain terminal, Neovim or the folder of any repo under `~/Source`,
`~/Projects` and `~/BArch`), the bar (launcher, clipboard, notes, shortcuts, overview), lock, suspend,
reboot and shutdown (the last three ask "Confirma?" and wait for a "sim"), the time, the date,
the agenda, updates, disk, what is playing, reminders ("me lembra em dez minutos de tirar o bolo"
through `systemd-run`), and "para de escutar" (pause). "barch" alone chimes and waits up to eight
seconds for the sentence, as in a car.

What the table does not know goes to **Claude** (`claude -p`, `dontAsk`, the tools limited to `barch`,
`hyprctl`, `uwsm app`, `qs ipc`, `wpctl`, `playerctl`, `foot`, `xdg-open`, `systemctl --user` and
reading; `voice/fallback.md` is the prompt, `claude_model` in `config.json` the model, Sonnet by
default), which acts and answers with one spoken sentence; "pergunta ao claude …" forces it. Those
sentences are logged in `~/.local/state/barch/voice/unmatched.log`, which is where new intents come
from. It keeps a short memory, so it works like a conversation: after every answer the microphone
stays open for a few seconds (`followup_s`, 8 by default; the bar's mic pulses slowly) and the next
sentence needs no "barch", but in that window only sentences the table knows are acted on, so talk
in the room is dropped instead of reaching Claude (a follow-up to an answer Claude *understood*
does reach him, with the previous exchanges as context: "como está o tempo" … "e amanhã?"; after a
"não entendi" the window only takes the table, so one false wake cannot chain a conversation in
the room into six answers, as happened on 2026-11-07). A lone "sim" or "não" with nothing to
confirm is dropped too. "Ele", "ela", "essa
janela", "isso" are the window it opened or acted on last ("abre o spotify" … "coloca ele no
workspace dois" … "fecha ele"; the window of an app just launched is found by watching for the
new client), and windows can be named ("fecha o spotify", "volta pro brave", "cadê o terminal":
class, alias or a word of the title). "Mais", "menos", "de novo" repeat the last command a step
further or in the other direction (volume, SDR brightness, tracks, workspaces: `adjust`,
`inverse` and `direction` in `commands.json`); the same answer twice in a row becomes a chime. When
the fallback is about to do something he may regret (close or kill something, suspend, leave
Anonymous Mode, change Hyprland options, delete files) Claude does not act: it answers with
`confirm`, the daemon says it with "Confirma?" and only a "sim" in the follow-up window sends the
request back, confirmed. Answers are spoken with [Piper](https://github.com/OHF-Voice/piper1-gpl) (`pt_BR-faber-medium`,
downloaded once into `~/.local/share/piper`); commands that need no answer only get a short chime
(`confirm_sound` in `config.json`), the ones that do (anonymous mode, VPN, the time, errors) a
sentence. While the session is locked every sentence is ignored.

**Other languages.** The microphone's panel in the bar (right-click) has a **Language** list with
a filter, the same as `barch voice lang <code>`: Portuguese, Automatic, and every other language
whisper knows (`voice/languages.json`: whisper's hundred, each with the Piper voice that speaks
it, null for the ones Piper has no voice for). The choice is kept in
`~/.local/state/barch/voice/language` and goes to whisper with every sentence. Only Portuguese
has the command table: in any other language the sentence goes, as whisper wrote it, to Claude,
who acts and answers in that language (`language` in the context of `fallback.md`, the
"Confirm?" question written by him too), read by that language's voice, downloaded with
`piper.download_voices` the first time the language is picked (a few seconds; a language
without a voice answers in a notification). The wake word stays "barch": in a language whisper
does not write in Latin letters the start of the sentence is transcribed in English to find it.
**Automatic** transcribes the start in Portuguese, takes the language whisper detects there and
transcribes the whole sentence in it: Portuguese uses the table, anything else goes to Claude
(a short command can be detected as the wrong language, which is why it is not the default).
`tts_voices` in `config.json` (`{"en": "en_US-lessac-high"}`) picks another voice for a language. Nothing is done while the daemon
itself speaks, so it does not hear itself.

```bash
barch voice setup --install        # whisper-cpp, ggml-cuda, the model (AUR), piper-tts (AUR), the pt_BR voice
barch voice match "liga o hdr"     # hdr (exec): barch hdr on        — tests commands.json, runs nothing
barch voice test "que horas são"   # runs it for real, as if heard (no "barch" needed)
barch voice say "Pronto."          # the voice
barch voice status · log · pause · resume · reload
BARCH_VOICE_DEBUG=1 python3 quickshell/.config/quickshell/voice/voice.py   # in a terminal: every utterance and what whisper heard
```

Packages: `whisper-cpp` and `ggml-cuda` (extra), `whisper.cpp-model-large-v3-turbo-q5_0` and
`piper-tts` (AUR); another ggml model works with `whisper_model` in `config.json`. Thresholds of the
VAD (`vad_min_rms`, `vad_floor_mult`, `vad_end_ms`), the wake spellings whisper tends to write
("bartch", "bark", "barque"…; matched exactly, plus the shapes `bar(ch|tch|k|que|sh…)` and a
first word within `wake_min_ratio` of "barch" itself, 0.85: the looser match of before woke on
"parece", "para que", "base", "parque"), the microphone (`mic_target`, empty = default source)
and the Claude fallback (`claude: false` turns it off) are in `config.json`. A first word that came
close to the wake word without waking it goes to `~/.local/state/barch/voice/wake-misses.log`
(`barch voice misses`): if "barch" ever fails to wake it, that is where whisper's spelling of it
shows up, to add to `wake`; `voice/tests/test_wake.py` keeps the spellings and the room talk apart. `whisper_prompt` must stay a bare
"Barch.": whisper writes the prompt back word for word when it hears only noise, so a prompt
with example commands in it runs them (that is how a keyboard click once closed a window); what
it writes to silence ("Obrigado", the prompt, subtitle credits) is dropped before matching. A new
command is an entry in `commands.json`: `patterns` (what is said, normalized), a `kind` (`exec`, `spawn`, `hypr`, `app`,
`project`, `palette`, `scene`, `region`, `confirm`, `say`, `remind`, `claude`…) and what to run, with
`{group}` placeholders from the pattern's named groups (`n_` prefix: a number, in words or digits);
`barch voice reload` picks it up. The state the bar shows is `~/.local/state/barch/voice/state.json`;
every sentence handled is appended to `history.log` there.
