<p align="center">
  <img src="assets/banner.svg" alt="live-subtitle">
</p>

# 🔴 Live Chinese Subtitles · Local Recognition (Windows)

> **Your PC makes sound, Chinese subtitles appear at the bottom of the screen** — original line on top, Chinese below.
> **Player-agnostic, site-agnostic:** if your computer is playing audio, it can be translated.
> **Audio never leaves the machine:** recognition runs entirely on your own GPU.

[![platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D6?logo=windows&logoColor=white)](https://github.com/huanweide/live-subtitle)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/huanweide/live-subtitle)
[![no Python needed](https://img.shields.io/badge/Python-not%20required-brightgreen?logo=python&logoColor=white)](https://github.com/huanweide/live-subtitle)
[![CI](https://github.com/huanweide/live-subtitle/actions/workflows/ci.yml/badge.svg)](https://github.com/huanweide/live-subtitle/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**中文:** [README.md](README.md)

**Flow:** `system audio → whisper-stream (local) → four text stages → (optional) translation → always-on-top bar`

[30-Second Demo](#-30-second-demo) · [Features](#features) · [Quick Start](#quick-start) · [Controls](#controls) · [Architecture](#architecture) · [Comparison](#comparison) · [Star](#-star)

![subtitle bar](docs/screenshot-bar.png)

---

## 🎯 30-Second Demo

```text
Before · you want to watch a Japanese episode with no Chinese subs
─────────────────────────────────────────────
  browser plugins    only standard players; self-hosted players get nothing
  Win11 live captions  Chinese translation requires a Copilot+ PC (NPU >= 40 TOPS);
                       on a normal PC it only translates into English; absent on Win10
  record-then-transcribe  not live — you get text after the fact

After · double-click "Live Subtitles"
─────────────────────────────────────────────
$ powershell -ExecutionPolicy Bypass -File .\setup.ps1
  1 probe machine  2 detect GPU  3 fetch whisper.cpp  4 fetch model
  5 list capture devices  6 test tone  7 write config

$ double-click "launch subtitles"
  ┌────────────────────────────────────────┐
  │ 今日はいい天気ですね                      │  <- original (light blue)
  │ 今天天气真好啊                            │  <- Chinese (white)
  └─────────────── + − ◐ ✕ ⚙ ◢ ───────────┘
  ~1.5-2.5 s per line (measured on an RTX 5070 Laptop)
```

**One-line difference:** it never talks to the player — it taps **whatever your PC is outputting**, so any player and any site works.

---

## Features

- **Audio-tap pipeline (device agnostic)** — no player parsing, no page hooks. Self-hosted players, odd sites and game voice chat all work.
- **Local recognition gate (whisper.cpp)** — recognition is 100% on your machine (GPU path when an NVIDIA card is present); **audio is never uploaded**. Only the recognised line of text goes to translation.
- **Four-stage text pipeline (`lib/SubtitleText.ps1`)** — strip timestamps → filter hallucinations → glossary replace → split long lines. All four are pure functions shared by the main script and the tests, each switchable in config.
- **Hallucination blocklist (28 entries)** — Whisper tends to invent credits lines during silence; the blocklist drops them automatically (16 JP / 9 EN / 3 ZH).
- **Longest-match-first glossary (`subtitle-glossary.json`)** — single-pass replacement, **longest term wins**, so a term is never half-replaced or re-replaced. The glossary is never committed.
- **Keys by variable name (default)** — config stores *which environment variable to read*, **not the key itself**; a leaked or shared config file leaks nothing.
- **Pluggable translation** — SiliconFlow / OpenAI / local Ollama / custom endpoint; turn translation off and the tool is fully offline.
- **A bar that actually behaves** — draggable (auto-clamped to the screen), `+` `/` `−` scale the whole bar, `◐` cycles five opacity levels (**only the background fades; text stays opaque**), `Ctrl+Alt+Z` click-through, 4 theme presets.
- **Zero-dependency self-test (38 assertions)** — `tests/Invoke-SubtitleTests.ps1` runs with nothing installed; CI runs exactly the same thing.

---

## Quick Start

```powershell
git clone https://github.com/huanweide/live-subtitle.git
cd live-subtitle
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.ps1` does seven things: probe the machine → check the GPU (GPU vs CPU build) → download whisper.cpp (643 MB with an NVIDIA card, 8 MB without) → download the model (1.5 GB by default; **falls back to hf-mirror if HuggingFace is unreachable**) → list working capture devices → play a test tone → write the config.

Then double-click **`launch subtitles`** (or the `.bat`, which keeps a console for debugging).

```text
● subtitles started · waiting for audio...     <- grey: listening, no speech yet
今日はいい天気ですね / 今天天气真好啊             <- white Chinese + light-blue original: translating
back to grey after 10 s                        <- previous line expired
```

> ⚠️ **Run `setup.ps1` first.** If you reverse the order it will not fail silently — a dialog tells you exactly what is missing.
> **First launch takes 5-10 s** (loading the model into the GPU). On a fresh NVIDIA install the first run may take a minute or two to compile CUDA kernels — **that is not a hang**.

### Three-step quick setup

Right-click the tray icon → **Quick setup**:

```text
step 1 · what to listen to        → pick a capture device (usually "Stereo Mix")
step 2 · translate while listening → on / off (off = original text only, no network)
step 3 · target language          → Simplified Chinese by default, or EN/JA/KO/RU/FR/DE/ES
```

### Self-test

```powershell
.\tests\Invoke-SubtitleTests.ps1
```

```text
passed 38 / failed 0
```

---

## Controls

| You do | What happens |
|---|---|
| hover the bar | the button row lights up (always visible, just semi-transparent — no hidden gestures) |
| click `+` / `−` | scale the whole bar (width, height and font together), auto-saved |
| click `◐` | opacity `0.95 → 0.80 → 0.62 → 0.45 → 0.30`; **only the background fades, text stays opaque** |
| click `✕` | hide the bar (tray menu → show/hide brings it back) |
| click `⚙` | full settings (audio / appearance / translation / advanced) |
| drag `◢` (far right) | free-scale the bar; released size is remembered |
| drag the bar | move it; **clamped inside the screen** so it can never be lost |
| left-click tray icon | pause / resume (icon flips between a **green dot** and a **grey dot**) |
| right-click tray icon | quick setup · settings · show/hide · pause · environment check · exit |
| `Ctrl+Alt+Z` | toggle click-through (can be disabled in settings → advanced) |

**Recognition languages:** `ja` (default) / `en` / `ko` / `ru` / `fr` / `de` / `es` / `it` / `auto`.
**Target languages:** Simplified Chinese (default) / English / Japanese / Korean / Russian / French / German / Spanish. Changing the language restarts the recognition process for you — no manual restart.

---

## Architecture

**In one line:** a **polling loop over a file**. The recognition engine is a separate process that writes a txt; the main script reads it every 0.8 s, runs four pure functions, and paints an always-on-top window. Low-tech, and stable.

### Primitives

| Concept | Meaning |
|---|---|
| Audio tap | capture the system output (usually "Stereo Mix"); independent of player or site |
| Local recognition (whisper-stream) | whisper.cpp's streaming binary, GPU-backed, emits original text |
| File bridge (ws-live.txt) | the only channel between the two processes: one writes, one reads |
| Four stages | strip → filter → replace → split; all pure functions |
| Hallucination blocklist | credits lines the model invents during silence; 28 entries auto-dropped |
| Key by variable name | config stores which env var to read, never the key |
| Subtitle bar | borderless topmost window: draggable, scalable, translucent, click-through |

### Flow

```text
audio from the video
   ↓ whisper-stream.exe captures the device (local GPU)
original text
   ↓ written to ws-live.txt
   ↓ main script reads every 0.8 s
   ↓ ① strip timestamps  – otherwise one line with different timecodes gets translated repeatedly (wasted money)
   ↓ ② filter hallucinations – drop anything on the 28-entry blocklist
   ↓ ③ replace glossary terms – longest-match-first, single pass, no cross-contamination
   ↓ ④ split long lines – break on punctuation and show the parts in order
Chinese translation (optional; off = fully offline)
   ↓ painted onto a borderless topmost window
```

### Core Files

| File | Responsibility |
|---|---|
| `live subtitles.ps1` (main script) | bar window, tray menu, settings UI, translation |
| `setup.ps1` | one-shot install: GPU detection, engine, model, device probe, config |
| `lib/SubtitleText.ps1` | the four pure text functions, shared by script and tests |
| `tests/Invoke-SubtitleTests.ps1` | 38 unit assertions, no dependencies |
| `tools/ci-checks.ps1` | full CI gate: syntax / BOM / workflow ASCII / tests / reference integrity / secret scan |
| `launch (no window).vbs` | **recommended entry point** — runs in the background, no console |
| `launch.bat` | legacy entry point, keeps a console for debugging |
| `subtitle-config.json` | your settings (**not committed**) |
| `subtitle-config.example.json` | settings template |
| `subtitle-glossary.json` | your glossary (**not committed**) |
| `ws-live.txt` / `debug.log` | raw engine output / troubleshooting log |

---

## After you change the text pipeline

All four stages live in `lib/SubtitleText.ps1` as pure functions. Add a rule, then run the tests:

```powershell
function Test-SubtitleHallucination {
    param([string]$Text)
    $blocklist = @('感谢您的观看', 'ご視聴ありがとうございました', 'Thanks for watching')
    foreach ($b in $blocklist) { if ($Text -match [regex]::Escape($b)) { return $true } }
    return $false
}
```

```powershell
.\tests\Invoke-SubtitleTests.ps1    # passed 38 / failed 0, exit code 0 = green
```

CI (`tools/ci-checks.ps1`) additionally enforces: every `.ps1` must carry a **UTF-8 BOM** (Windows PowerShell 5.1 decodes BOM-less files as ANSI and dies on mojibake), the `run:` blocks of `ci.yml` must stay **pure ASCII**, and the main script must still dot-source the library.

---

## Comparison

|  | **this project** | LiveCaptions-Translator | Vibe | RaelTimeTrans |
|---|:---:|:---:|:---:|:---:|
| captures system audio | ✅ | ✅ | ✅ | ✅ |
| multi-language recognition | ✅ ja/en/ko/ru/fr/de/es/it | ⚠️ depends on OS captions | ✅ | ✅ |
| **translates into Chinese** | ✅ | ❌ English only | ❌ English only | ✅ |
| bar floats over the video | ✅ draggable / click-through | ❌ | ❌ own window only | ✅ |
| live (~2 s) | ✅ | ✅ | ❌ after recording | ✅ |
| needs Python? | **no** | no | no | **yes** |
| code size | **~35 KB** | — | — | — |
| hallucination filtering | ✅ 28 entries | — | — | — |

> Competitor capabilities move with their releases; the table reflects each repo's current documentation.

### Where Windows' built-in live captions stand

This is the reason the project exists, so here is the honest picture:

| What you want | Windows built-in live captions |
|---|---|
| Recognise Japanese, show Japanese text | ✅ yes. Win 11 22H2+ with the language pack; local, offline |
| **Live-translate into Simplified Chinese** | ⚠️ **Copilot+ PC only** (NPU ≥ 40 TOPS + Win 11 24H2+). On a normal PC it only translates into English |
| Use it on Windows 10 | ❌ no — it is a Windows 11 feature |
| Custom bar (free drag / click-through / fonts) | ❌ limited to a few system styles |

Sources: [Windows 11 specifications · Copilot+ PC](https://www.microsoft.com/windows/windows-11-specifications) and [Microsoft Learn · Live Captions](https://learn.microsoft.com/en-gb/training/modules/prepare-for-the-future-of-ai/4-unique-experiences).

> Honestly: if you already own a Copilot+ PC and only need English, the built-in feature is less work — install nothing.
> This project is for **machines without an NPU, anyone still on Windows 10, and anyone who wants the bar and the glossary under their own control**.

---

## Security Boundary

- **Audio never leaves the machine.** Recognition runs locally in whisper.cpp; no audio upload.
- **Keys are not stored in config.** Only the environment variable name is stored; nothing sensitive lands in a file or in Git.
- **Fully offline capable.** Turn off live translation and no external API is called at all.
- **Ships no video content and downloads no video** — it only turns what you are already playing into text.
- Use it for personal viewing and accessibility, and follow local law and platform rules.

---

## Roadmap

- ✅ `setup.ps1` one-shot install, capture-device detection and picker
- ✅ 9 recognition languages + 8 target languages, auto-restart on language change
- ✅ bar scaling / dragging / opacity / click-through / 4 themes
- ✅ three-step quick setup, switchable translation (SiliconFlow / OpenAI / Ollama / custom)
- ✅ windowless launcher, tray toggle, environment self-check report
- ✅ four-stage text pipeline as a pure-function library + 38 dependency-free tests + real CI
- ⬜ **fully offline mode (local translation model)** — currently the only way to keep even the text local
- ⬜ more UI languages, glossary import/export

---

## Contributing

1. Fork → branch → change
2. Run `.\tests\Invoke-SubtitleTests.ps1` (38 assertions, no dependencies)
3. **New `.ps1` files must carry a UTF-8 BOM** (Windows PowerShell 5.1 decodes BOM-less files as ANSI and breaks — CI blocks it)
4. Keep `run:` blocks in `ci.yml` **pure ASCII** (also enforced by CI)
5. Keys come from environment variables only — never write one into a file

---

## License

MIT — see [LICENSE](LICENSE).

Built on [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) and the [Whisper](https://github.com/openai/whisper) models (MIT). Default translation provider is SiliconFlow; bring your own key.

---

## ⭐ Star

If this tool saved you time squinting at subtitles, **a star is the biggest support you can give**.

**Author:** ReTri ([github.com/huanweide](https://github.com/huanweide)) · MIT

More tools: [bili-subtitle-universal](https://github.com/huanweide/bili-subtitle-universal) · [bili-subtitle-extractor](https://github.com/huanweide/bili-subtitle-extractor) · [novel-smith](https://github.com/huanweide/novel-smith) · [all repos](https://github.com/huanweide?tab=repositories)
