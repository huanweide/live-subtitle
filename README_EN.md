**中文** · [README.md](./README.md)

<p align="center">
  <img src="assets/banner.svg" alt="live-subtitle — real-time Chinese subtitles, local recognition">
</p>

# Real-Time Chinese Subtitles, Recognized Locally (Windows)

> Chinese subtitles float at the bottom of your screen the moment your PC makes a sound — original text on top, Chinese below.
> It does not care which player or website you use: as long as your computer is playing audio, it can translate it.
> Your audio never leaves this machine: recognition runs entirely on your local GPU.

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D6?logo=windows&logoColor=white)](https://github.com/huanweide/live-subtitle)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/huanweide/live-subtitle)
[![No Python](https://img.shields.io/badge/Python-no%20install-brightgreen?logo=python&logoColor=white)](https://github.com/huanweide/live-subtitle)
[![100% Local](https://img.shields.io/badge/speech%20recognition-100%25%20local-blue)](https://github.com/huanweide/live-subtitle)
[![CI](https://github.com/huanweide/live-subtitle/actions/workflows/ci.yml/badge.svg)](https://github.com/huanweide/live-subtitle/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**Pipeline**: `system audio → whisper-stream local recognition → four-stage text cleanup → (optional) translation → always-on-top subtitle bar`

[30-Second Overview](#30-second-overview) · [What It Does](#what-it-does) · [Features](#features) · [Quick Start](#quick-start) · [How It Works](#how-it-works) · [How It Compares](#how-it-compares) · [Roadmap](#roadmap)

![Subtitle bar screenshot](docs/screenshot-bar.png)

---

## Who Should Use This

- **Windows 10 / 11 users** watching foreign-language video with no built-in subtitles — Japanese anime, English livestreams, online courses, anything playing through your speakers.
- **People without an NPU / Copilot+ PC** who still want foreign audio translated into Simplified Chinese in real time.
- **Privacy-conscious viewers** who don't want their audio uploaded to any cloud for recognition.
- **Anyone who wants a subtitle bar they control** — drag it anywhere, set your own terminology, tweak size, color and transparency.

## Who Should NOT

- **macOS or Linux users** — this is Windows 10 / 11 only (it relies on Windows audio capture and PowerShell 5.1).
- **People who want a saved subtitle file** — this tool shows live text on screen; it does not export `.srt`/`.vtt` or download any video. It contains no video content and provides no video downloading.
- **Copilot+ PC owners who only ever need English** — Windows' built-in Live Captions already does that with zero install. This tool targets everyone else.

---

## 30-Second Overview

```text
BEFORE · you want to watch a Japanese show with no Chinese subtitles
─────────────────────────────────────────────
  Browser extensions     only hook standard players; sites with custom players are missed
  Win11 Live Captions    Chinese output needs a Copilot+ PC (NPU ≥ 40 TOPS); plain PCs get English only; Win10 has none
  Record-then-transcribe not real time; you get text only after finishing

AFTER · double-click "实时字幕" (Live Subtitle)
─────────────────────────────────────────────
$ powershell -ExecutionPolicy Bypass -File .\setup.ps1
  ① probe machine ② detect GPU ③ fetch whisper.cpp ④ fetch model ⑤ list input devices ⑥ test audio ⑦ write config

$ double-click "启动字幕.bat"
  ┌────────────────────────────────────────┐
  │ 今日はいい天気ですね                      │  ← original (light blue)
  │ 今天天气真好啊                            │  ← Chinese (white)
  └─────────────── + − ◐ ✕ ⚙ ◢ ───────────┘
  latency ≈ 1.5–2.5s per sentence (measured on an RTX 5070 Laptop)
```

**The one-line difference**: it never talks to the player. It taps the **audio your PC is currently playing** — so any player, any website works.

---

## What It Does

**Scenario 1 · Foreign film / livestream / online course**

```text
You: double-click the "实时字幕" icon
  → whisper-stream.exe captures the recording device (runs on your local GPU, audio never leaves)
  → original text is written to ws-live.txt; the main script reads it every 0.8s
  → strip timestamp → filter hallucination → glossary replace → sentence split
  → optional: send that original line to a translation endpoint (SiliconFlow by default; switchable to OpenAI / Ollama / custom)
  → drawn onto an always-on-top borderless subtitle bar
```

**Scenario 2 · Original text only, no internet**

```text
You: Settings → turn off "real-time translation"
  → no translation endpoint is called; the bar shows only recognized original text
  → neither audio nor text leaves this machine
```

**Scenario 3 · Stuck and don't know which step failed**

```text
You: right-click the tray icon → "Environment Self-Check…"
  → lists config file / engine / model / input device / translation key / GPU acceleration item by item
  → the [!!] line tells you exactly what to do; the same report is saved as 自检报告.txt
```

---

## Features

- **Audio-device capture (player-independent)** — no player parsing, no web-page hooking. It records system audio directly; custom players, odd sites and game voice chat all work.
- **Local recognition gate (whisper.cpp)** — recognition runs 100% on your machine (GPU if you have an N card), **audio is never uploaded**; only the recognized text line is sent to translation.
- **Four-stage text pipeline (`lib/SubtitleText.ps1`)** — strip timestamp → filter hallucination → glossary replace → sentence split. All four are pure functions shared by the main script and the tests; each can be disabled in config.
- **Hallucination blacklist (28 entries)** — Whisper invents filler like "Thanks for watching" during silence; a built-in blacklist blocks it automatically (Japanese 16 / English 9 / Chinese 3).
- **Long-word-priority glossary (`subtitle-glossary.json`)** — single-pass replacement with **longest-match priority**, so "阿梓的森林" is never torn apart or double-replaced; the glossary is not committed to Git.
- **Keys stored as variable names only (by default)** — the config stores *which environment variable* holds the key, **never the key itself**; a leaked or mis-shared config exposes nothing.
- **Pluggable translation** — SiliconFlow / OpenAI / local Ollama / custom endpoint, switchable in settings; turn translation off for full offline use.
- **A subtitle bar that genuinely works** — free drag (auto-clamped to screen), `+` / `−` whole-bar scaling, `◐` five opacity levels (background only — **text stays fully opaque**), `Ctrl+Alt+Z` click-through, 4 theme presets.
- **Zero-dependency self-test (38 assertions)** — `tests/Invoke-SubtitleTests.ps1` runs with nothing installed; CI runs the very same file.

---

## Quick Start

### Step 1 · Get the files

```powershell
git clone https://github.com/huanweide/live-subtitle.git
cd live-subtitle
```

No Git? Click **Code → Download ZIP** at the top right and extract.

### Step 2 · Run the installer

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

It does seven things on its own: probe the machine → check the GPU for GPU/CPU build → download whisper.cpp (643 MB with an N card, 8 MB without) → download the recognition model (default 1.5 GB; **auto-switches to hf-mirror if HuggingFace is unreachable**) → list active input devices → play a test tone → write the config file.

### Step 3 · Launch

Double-click **`启动字幕.bat`** (or the "实时字幕" desktop icon, which uses a `.vbs` windowless launcher).

```text
● Live subtitle started · waiting for sound…   ← grey: listening, no speech detected
今日はいい天気ですね / 今天天气真好啊            ← white Chinese + light-blue original: translating
returns to grey after 10s idle                 ← previous sentence expired
```

> ⚠️ **Run `setup.ps1` first, then double-click to launch.** Order reversed won't fail silently — a missing engine or model pops a window telling you what's absent.
> **First launch takes 5–10s** (model loads into the GPU); on a fresh N-card install the first run may spend a minute or two compiling the CUDA kernel — don't assume it hung.

### Three-step quick setup (recommended for first run)

Right-click the tray icon → **"🚀 Quick Setup (3 steps)"**:

```text
Step 1 · what to listen to     → pick an input device (usually "Stereo Mix")
Step 2 · translate while listening? → check / uncheck (unchecked = original only, no internet)
Step 3 · translate into which language → Simplified Chinese by default; also EN / JA / KO / RU / FR / DE / ES
```

### Self-test

```powershell
.\tests\Invoke-SubtitleTests.ps1
```

```text
Passed 38 / Failed 0
```

---

## Controls at a Glance

| You do | What happens |
|---|---|
| Hover the subtitle bar | the button row at bottom-right lights up (always faintly visible, no gestures to memorize) |
| Click `+` / `−` | scale the whole bar (width, height, font together), auto-saved |
| Click `◐` | opacity `0.95 → 0.80 → 0.62 → 0.45 → 0.30`, **background only, text stays opaque** |
| Click `✕` | hide the bar (bring it back from the tray menu "Show / Hide bar") |
| Click `⚙` | open full settings (Speech / Appearance / Translation / Advanced) |
| Drag `◢` (far right) | freely resize the bar, remembered on release |
| Drag the bar | move it, remembered on release; **always clamped inside the screen** |
| Left-click tray icon | pause / resume (icon toggles **green dot** / **grey dot**) |
| Right-click tray icon | 🚀 Quick setup · ⚙ Settings · Show/hide · Pause · Self-check · Exit |
| Press `Ctrl+Alt+Z` | toggle whether the bar blocks the mouse (can be disabled in Settings → Advanced) |

**Recognition language** (Settings → "Recognition language"): `ja` (default) / `en` / `ko` / `ru` / `fr` / `de` / `es` / `it` / `auto`.
**Target language**: Simplified Chinese (default) / English / Japanese / Korean / Russian / French / German / Spanish. Changing language restarts the recognition process on "Apply and Save" — no manual restart needed.

---

## How It Works

**One sentence**: a **file-polling loop** — the recognition engine is a separate process that writes a txt file; the main script reads it every 0.8s, runs it through four pure functions, then draws it onto an always-on-top window. Simple, but stable.

### Concepts

| Concept | Meaning |
|---|---|
| Audio capture | grab a recording device (usually "Stereo Mix"); independent of player/website |
| Local recognition (whisper-stream) | whisper.cpp's streaming binary, runs on the GPU, outputs original text |
| File bridge (ws-live.txt) | the only channel between the engine and the main script: it writes, the script reads |
| Four-stage processing | strip timestamp → filter hallucination → glossary replace → sentence split, all pure functions |
| Hallucination blacklist | filler the model invents during silence; 28 entries auto-blocked |
| Variable-name key lookup | config stores only *which env var to read*, never the key itself |
| Subtitle bar | always-on-top borderless window: draggable, scalable, transparent, click-through |

### Main flow

```text
Film audio
   ↓ whisper-stream.exe captures the input device (local GPU)
original text
   ↓ written to ws-live.txt
   ↓ main script reads every 0.8s
   ↓ ① strip timestamp  — without it, the same line gets re-sent to translation per timecode (wasted calls)
   ↓ ② filter hallucination — dropped on 28-entry blacklist hit
   ↓ ③ glossary replace — longest-match first, single pass, no cascade
   ↓ ④ sentence split — if one line won't fit, split on punctuation and show in sequence
Chinese translation (optional; off = fully offline)
   ↓ drawn onto the always-on-top borderless window
```

### Core Files

| File | Responsibility |
|---|---|
| `实时字幕.ps1` | main program: subtitle bar window, tray menu, settings UI, translation |
| `setup.ps1` | one-click install: find GPU, fetch engine, fetch model, probe devices, write config |
| `lib/SubtitleText.ps1` | the four-stage pure functions, shared by main script and tests |
| `tests/Invoke-SubtitleTests.ps1` | 38 unit-test assertions, runs with nothing installed |
| `tools/ci-checks.ps1` | full CI gate: syntax / BOM / workflow ASCII / tests / reference integrity / credential scan |
| `启动字幕（无窗口）.vbs` | **recommended entry**: runs in background, no black console window |
| `启动字幕.bat` | legacy entry: runs in a terminal, handy for watching output while debugging |
| `subtitle-config.json` | your settings (**not in Git**) |
| `subtitle-config.example.json` | settings template |
| `subtitle-glossary.json` | your glossary (**not in Git**) |
| `ws-live.txt` / `debug.log` | raw engine output / troubleshooting log |

---

## Changing the Text Pipeline

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
.\tests\Invoke-SubtitleTests.ps1    # Passed 38 / Failed 0, exit code 0 = all green
```

CI (`tools/ci-checks.ps1`) additionally enforces: every `.ps1` must carry a **UTF-8 BOM** (otherwise Windows PowerShell 5.1 decodes as ANSI and mojibakes), the `run:` blocks in `ci.yml` must be **pure ASCII**, and the main script must still dot-source the function library.

---

## How It Compares

|  | **This project** | LiveCaptions-Translator | Vibe | RaelTimeTrans |
|---|:---:|:---:|:---:|:---:|
| Captures system audio | ✅ | ✅ | ✅ | ✅ |
| Multi-language recognition | ✅ JA/EN/KO/RU/FR/DE/ES/IT | ⚠️ depends on system captions | ✅ | ✅ |
| **Translate into Chinese** | ✅ | ❌ English only | ❌ English only | ✅ |
| Subtitle over the video | ✅ draggable / click-through | ❌ | ❌ own window only | ✅ |
| Real time (as-you-speak) | ✅ ~2s | ✅ | ❌ record-then-transcribe | ✅ |
| Python required | **No** | No | No | **Yes** |
| Code size | **~35 KB** | — | — | — |
| Hallucination filter | ✅ 28-entry blacklist | — | — | — |

> Competitor capabilities change with versions; the table reflects each project's current description.

### Where Windows' Built-in Live Captions Stand Today

This is the reason the project exists, stated clearly so you don't install it for nothing:

| What you want | Windows built-in Live Captions |
|---|---|
| Recognize Japanese, output Japanese original | ✅ Yes. Win 11 22H2+ with a language pack; local, offline-capable |
| Translate foreign audio into Simplified Chinese **in real time** | ⚠️ **Only on a Copilot+ PC** (NPU ≥ 40 TOPS + Win 11 24H2+); plain PCs get English only |
| Use on Windows 10 | ❌ No, it's a Win 11 feature |
| Custom subtitle bar (free drag / click-through / font & color) | ❌ limited to a few system styles |

Sources: Microsoft's [Windows 11 specs & system requirements · Copilot+ PC](https://www.microsoft.com/windows/windows-11-specifications) and [Microsoft Learn · Live Captions](https://learn.microsoft.com/en-gb/training/modules/prepare-for-the-future-of-ai/4-unique-experiences).

> Honestly: if you happen to own a Copilot+ PC and only need English, the built-in captions are the easier choice — nothing to install.
> This project is for people **without an NPU, still on Windows 10, or who want the subtitle bar and terminology in their own hands**.

---

## FAQ

**Q: Subtitles never show up?** Right-click the tray icon → **"Environment Self-Check…"**; it lists each item, the `[!!]` line tells you what to do, and the report is also saved as `自检报告.txt`.

**Q: Which input device should I pick?** Headphones → pick the one named with "耳机" / "Headphones" or "Stereo Mix"; speakers → pick "Stereo Mix (Stereo Mix)". The first item (`0 · 麦克风阵列`) usually captures **your own voice**. If "Stereo Mix" is missing, right-click empty space in the **Recording** tab → check "Show Disabled Devices" → enable it.

**Q: The bar is all black with no text?** That means **no speech is being heard**, not an error. Confirm the video is actually playing → check the last lines of `debug.log` → try a different input-device number (this is the most common snag).

**Q: "Thanks for watching" pops up occasionally?** Whisper's hallucination on **silence**; the built-in 28-entry blacklist blocks it automatically. File an Issue for any that slip through.

**Q: Will my audio be sent online?** **No.** Audio stays on your PC the whole time. Only the recognized **text** line is sent to the translation endpoint; turn off "real-time translation" and even the text stays local.

**Q: The bar blocks player buttons?** Press `Ctrl+Alt+Z`, or right-click → "mouse can't click the bar".

---

## Security Boundaries

- **Audio never leaves the machine**: recognition runs in local whisper.cpp; audio is never uploaded.
- **Keys never land in config files**: config stores only environment-variable names; the key itself is never written to a file or committed to Git.
- **Can run fully offline**: turn off real-time translation and no external endpoint is called.
- **Contains no video content and provides no video downloading** — it only turns the audio you are playing into text.
- Use it for personal viewing and accessibility assistance, and comply with local laws and platform rules.

---

## Roadmap

- ✅ `setup.ps1` one-click install, automatic input-device detection and graphical picker
- ✅ 9 recognition languages + 8 target languages, language switch auto-restarts recognition
- ✅ subtitle bar scaling / drag / opacity / click-through / 4 themes
- ✅ three-step quick-setup wizard, switchable translation (SiliconFlow / OpenAI / Ollama / custom)
- ✅ windowless launcher + tray toggle + environment self-check report
- ✅ four-stage processing split into a pure-function library + 38 zero-dependency unit tests + real GitHub Actions CI
- ⬜ **Fully offline mode (local translation model)** — the only path where even the text never leaves
- ⬜ more UI languages and glossary import/export

Tell us in [Issues](https://github.com/huanweide/live-subtitle/issues) which one you want most.

---

## Contributing

1. Fork → branch → change code
2. Run `.\tests\Invoke-SubtitleTests.ps1` (38 assertions, zero dependencies)
3. **New `.ps1` files must carry a UTF-8 BOM** (Windows PowerShell 5.1 decodes as ANSI without it — CI blocks it)
4. When editing `ci.yml`, keep the `run:` blocks **pure ASCII** (also enforced by CI)
5. Keys always go through environment variables; never write them into any file

---

## License

MIT — see [LICENSE](LICENSE).

This project uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) and the [Whisper](https://github.com/openai/whisper) model (MIT); the default translation endpoint is SiliconFlow, bring your own key.

---

## Star

If this tool saved you time hunting for subtitles, **a Star is the biggest support**.

**Author**: huanweide ([github.com/huanweide](https://github.com/huanweide)) · MIT

**Other tools by the same author**:

- 🎬 [bili-subtitle-universal](https://github.com/huanweide/bili-subtitle-universal) · grab subtitles from any video site (one browser click, YouTube included)
- 🐍 [bili-subtitle-extractor](https://github.com/huanweide/bili-subtitle-extractor) · Bilibili subtitle CLI (batch / scriptable)
- 📚 [novel-smith](https://github.com/huanweide/novel-smith) · AI novel workshop (local-first)
- 🎓 [zhihuishu-helper](https://github.com/huanweide/zhihuishu-helper) · Zhihuishu / Zhidao course assistant
- 📦 [All repositories](https://github.com/huanweide?tab=repositories)
