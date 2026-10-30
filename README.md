<p align="center">
  <img src="assets/banner.svg" alt="live-subtitle — 实时中文字幕 · 本地识别">
</p>

# 🔴 实时中文字幕 · 本地识别（Windows）

> **电脑在响，屏幕底部就实时浮出中文字幕**——原文在上，中文在下。
> **不挑播放器、不挑网站**：只要电脑在出声，就能翻。
> **声音不出这台电脑**：识别全程在你本机显卡上跑。

[![平台](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D6?logo=windows&logoColor=white)](https://github.com/huanweide/live-subtitle)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/huanweide/live-subtitle)
[![不用装 Python](https://img.shields.io/badge/Python-%E4%B8%8D%E7%94%A8%E8%A3%85-brightgreen?logo=python&logoColor=white)](https://github.com/huanweide/live-subtitle)
[![识别本地跑](https://img.shields.io/badge/%E8%AF%AD%E9%9F%B3%E8%AF%86%E5%88%AB-100%25%20%E6%9C%AC%E5%9C%B0-blue)](https://github.com/huanweide/live-subtitle)
[![CI](https://github.com/huanweide/live-subtitle/actions/workflows/ci.yml/badge.svg)](https://github.com/huanweide/live-subtitle/actions/workflows/ci.yml)
[![许可](https://img.shields.io/badge/license-MIT-green)](LICENSE)


**自动流程**：`系统声音 → whisper-stream 本机识别 → 四道文字处理 →（可选）翻译 → 置顶字幕条`

[30 秒看懂](#30-秒看懂) · [它能做什么](#它能做什么) · [特性](#特性-features) · [快速开始](#快速开始-quick-start) · [架构](#架构-architecture) · [和别家比](#和别家比) · [路线图](#路线图-roadmap)

![字幕条实拍](docs/screenshot-bar.png)

---

## 30 秒看懂

```text
之前 · 想看一集没有中字的日语片
─────────────────────────────────────────────
  网页插件       只认标准播放器，自建播放器的站点抓不到
  Win11 实时字幕 翻成中文要 Copilot+ PC（NPU ≥ 40 TOPS）；普通 PC 只能翻英文；Win10 干脆没有
  录完再转       不是实时，看完才有字

之后 · 双击「实时字幕」
─────────────────────────────────────────────
$ powershell -ExecutionPolicy Bypass -File .\setup.ps1
  ① 探机器 ② 看显卡 ③ 下 whisper.cpp ④ 下模型 ⑤ 列录音设备 ⑥ 试音 ⑦ 写配置

$ 双击「启动字幕.bat」
  ┌────────────────────────────────────────┐
  │ 今日はいい天気ですね                      │  ← 原文（浅蓝）
  │ 今天天气真好啊                            │  ← 中文（白字）
  └─────────────── + − ◐ ✕ ⚙ ◢ ───────────┘
  延迟约 1.5～2.5 秒一句（RTX 5070 Laptop 实测）
```

**一句话差别**：它不跟播放器打交道，直接**把你电脑正在放的声音接出来**——所以什么播放器、什么网站都吃。

---

## 它能做什么

**场景 1 · 外语影片 / 直播 / 网课**

```
User: 双击「实时字幕」图标
  → whisper-stream.exe 抓录音设备（本机显卡上跑，声音不外传）
  → 原文写进 ws-live.txt，主脚本每 0.8 秒读一次
  → 剥时间戳 → 过滤幻觉 → 术语替换 → 断句分包
  → 可选：把原文那行文字送翻译接口（默认硅基流动，可换 OpenAI / Ollama / 自定义）
  → 画在置顶无边框字幕条上
```

**场景 2 · 只想看原文，不想联网**

```
User: 设置 → 关掉「是否实时翻译」
  → 不调任何翻译接口，字幕条只显示识别出的原文
  → 声音和文字都不出这台电脑
```

**场景 3 · 卡住了不知道哪一步出问题**

```
User: 右键托盘小图标 → 「环境自检…」
  → 逐项列出配置文件 / 识别引擎 / 模型 / 录音设备 / 翻译密钥 / 显卡加速
  → [!!] 那一项下面直接给你该怎么办；同一份报告存成 自检报告.txt
```

---

## 特性 / Features

- **声卡接管线（设备无关）** — 不解析播放器、不 hook 网页，直接录系统声音；自建播放器、奇怪站点、游戏语音一样吃。
- **本地识别闸门（whisper.cpp）** — 识别 100% 在你本机跑（有 N 卡走 GPU），**声音从不上传**；只有识别出来的那行文字会送翻译。
- **四道文字处理管线 (`lib/SubtitleText.ps1`)** — 剥时间戳 → 过滤幻觉 → 术语替换 → 断句分包；四步是纯函数，主脚本和测试共用同一份，每步都能在配置里关。
- **幻觉黑名单 (28 条)** — Whisper 遇到静音会自己编「感谢您的观看」这类片尾语；内置黑名单自动挡掉（日语 16 / 英语 9 / 中文 3）。
- **长词优先术语表 (`subtitle-glossary.json`)** — 单次扫描替换，**长词优先**，不会出现「阿梓的森林」被拆开、替换结果被二次替换的串味问题；术语表不进 Git。
- **密钥只存变量名（默认）** — 配置文件里只写「从哪个环境变量取密钥」，**密钥本身不进配置文件**；配置被看到或误传也不泄露。
- **翻译接口可插拔** — 硅基流动 / OpenAI / 本地 Ollama / 自定义端点，设置里换；关掉翻译就完全离线。
- **字幕条是真的能用的窗口** — 自由拖动（自动夹在屏幕内）、`+` `/` `−` 整体缩放、`◐` 五档透明度（只有背景透明，**文字始终不透明**）、`Ctrl+Alt+Z` 点击穿透、4 套主题预设。
- **零依赖自测 (38 断言)** — `tests/Invoke-SubtitleTests.ps1` 不装任何东西就能跑，CI 跑的也是这一条。

---

## 快速开始 / Quick Start

### 第 1 步 · 拿文件

```powershell
git clone https://github.com/huanweide/live-subtitle.git
cd live-subtitle
```

没有 Git 就点右上角 **Code → Download ZIP** 解压。

### 第 2 步 · 跑安装脚本

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

它会自己做七件事：探机器底子 → 看显卡决定 GPU/CPU 版 → 下 whisper.cpp（有 N 卡 643 MB，没有 8 MB）→ 下识别模型（默认 1.5 GB，**国内连不上 HuggingFace 会自动换 hf-mirror**）→ 列出正在工作的录音设备 → 放一段试音 → 写配置文件。

### 第 3 步 · 启动

双击 **`启动字幕.bat`**（或桌面上的「实时字幕」图标，走 `.vbs` 无窗口启动器）。

```text
● 实时字幕已启动 · 在等声音…        ← 灰字：在听，但没听到人说话
今日はいい天気ですね / 今天天气真好啊  ← 白字中文 + 浅蓝原文：正在翻译
停 10 秒后回到灰字                  ← 上一句已过期
```

> ⚠️ **先跑 `setup.ps1`，再双击启动。** 顺序反了也不会闷声失败——缺引擎或缺模型会**弹窗**告诉你差什么。
> **第一次启动要等 5～10 秒**（模型读进显卡）；有 N 卡且全新装，第一次可能要一两分钟编译 CUDA 内核，**别以为卡死了**。

### 三步快速设置（第一次用就点这个）

右键托盘小图标 → **「🚀 快速设置（三步）」**：

```text
第 1 步 · 听什么声音       → 选录音设备（一般选「立体声混音」）
第 2 步 · 要不要边听边翻译 → 打勾 / 取消（取消就只显示原文，不联网）
第 3 步 · 翻译成哪种语言   → 默认简体中文，也可选英 / 日 / 韩 / 俄 / 法 / 德 / 西
```

### 自测

```powershell
.\tests\Invoke-SubtitleTests.ps1
```

```text
通过 38 / 失败 0
```

---

## 操作速查

| 你做什么 | 会怎样 |
|---|---|
| 鼠标移到字幕条上 | 右下角一排按钮变亮（平时半透明但**一直看得见**，不用记手势） |
| 点 `+` / `−` | 整条放大 / 缩小（宽、高、字号一起变），自动保存 |
| 点 `◐` | 透明度 `0.95 → 0.80 → 0.62 → 0.45 → 0.30`，**只有背景变透明，文字始终不透明** |
| 点 `✕` | 隐藏字幕条（托盘菜单「显示 / 隐藏字幕条」叫回来） |
| 点 `⚙` | 打开完整设置（语音 / 外观 / 翻译 / 高级 四组） |
| 拖 `◢`（最右） | 自由缩放整条，松手记住 |
| 按住字幕条拖动 | 挪位置，松手记住；**整条会被夹在屏幕内**，不会拖出去找不回来 |
| 左键点托盘小图标 | 暂停 / 继续（图标在**绿点**和**灰点**之间切换） |
| 右键托盘小图标 | 🚀 快速设置 · ⚙ 设置 · 显示/隐藏 · 暂停 · 环境自检 · 退出 |
| 按 `Ctrl+Alt+Z` | 切换「字幕条挡不挡鼠标」（设置 → 高级 里可关） |

**识别语言**（设置 →「识别语言」）：`ja`（默认）/ `en` / `ko` / `ru` / `fr` / `de` / `es` / `it` / `auto`。
**目标语言**：简体中文（默认）/ 英语 / 日语 / 韩语 / 俄语 / 法语 / 德语 / 西班牙语。换语言不用重开程序，点「应用并保存」会自己重启识别进程。

---

## 架构 / Architecture

**一句话**：一个**读文件的轮询循环**——识别引擎是独立进程，写 txt；主脚本每 0.8 秒读一次，过四道纯函数，再画到置顶窗口上。土办法，但稳。

### 概念表 / Primitives

| 概念 | 含义 |
|---|---|
| 声音接管 | 抓录音设备（一般「立体声混音」），与播放器/网站无关 |
| 本地识别 (whisper-stream) | whisper.cpp 的流式程序，在显卡上跑，输出原文文字 |
| 文件桥 (ws-live.txt) | 独立进程与主脚本之间唯一的通信方式：它写、主脚本读 |
| 四道处理 | 剥时间戳 → 过滤幻觉 → 术语替换 → 断句分包，均为纯函数 |
| 幻觉黑名单 | 静音时模型爱编的片尾语，28 条自动挡 |
| 变量名取密钥 | 配置只存「从哪个环境变量读」，不存密钥本身 |
| 字幕条 | 置顶无边框窗口：可拖、可缩放、可透明、可点击穿透 |

### 主流程

```text
影片的声音
   ↓ whisper-stream.exe 抓录音设备（本机显卡）
原文文字
   ↓ 写进 ws-live.txt
   ↓ 主脚本每 0.8 秒读一次
   ↓ ① 剥时间戳     —— 不剥会让同一句因时间码不同被反复送去翻译（白烧钱）
   ↓ ② 过滤幻觉     —— 命中 28 条黑名单直接丢
   ↓ ③ 替换术语     —— 长词优先，单次扫描，不串味
   ↓ ④ 断句分包     —— 一行塞不下就按标点切开依次显示
中文译文（可选，关掉就完全离线）
   ↓ 画在置顶无边框窗口上
```

### 核心文件 / Core Files

| 文件 | 职责 |
|---|---|
| `实时字幕.ps1` | 主程序：字幕条窗口、托盘菜单、设置界面、翻译 |
| `setup.ps1` | 一键安装：找显卡、下引擎、下模型、探设备、写配置 |
| `lib/SubtitleText.ps1` | 四道文字处理的纯函数，主脚本与测试共用同一份 |
| `tests/Invoke-SubtitleTests.ps1` | 38 条单元测试，不装任何东西就能跑 |
| `tools/ci-checks.ps1` | CI 全量门禁：语法 / BOM / 工作流 ASCII / 测试 / 引用完整性 / 凭据扫描 |
| `启动字幕（无窗口）.vbs` | **推荐入口**：后台运行，不出现黑窗口 |
| `启动字幕.bat` | 老入口：在终端里跑，方便看输出调试 |
| `subtitle-config.json` | 你的设置（**不进 Git**） |
| `subtitle-config.example.json` | 设置模板 |
| `subtitle-glossary.json` | 你的术语表（**不进 Git**） |
| `ws-live.txt` / `debug.log` | 识别引擎原始输出 / 排错日志 |

---

## 改文字处理逻辑之后

四道处理都在 `lib/SubtitleText.ps1`，是纯函数，加一条规则后直接跑测试：

```powershell
function Test-SubtitleHallucination {
    param([string]$Text)
    $blocklist = @('感谢您的观看', 'ご視聴ありがとうございました', 'Thanks for watching')
    foreach ($b in $blocklist) { if ($Text -match [regex]::Escape($b)) { return $true } }
    return $false
}
```

```powershell
.\tests\Invoke-SubtitleTests.ps1    # 通过 38 / 失败 0，退出码 0 即全绿
```

CI（`tools/ci-checks.ps1`）还会额外检查：所有 `.ps1` 必须带 **UTF-8 BOM**（否则 Windows PowerShell 5.1 按 ANSI 解码直接乱码）、`ci.yml` 的 `run:` 段必须纯 ASCII、主脚本必须仍然 dot-source 函数库。

---

## 和别家比

|  | **本项目** | LiveCaptions-Translator | Vibe | RaelTimeTrans |
|---|:---:|:---:|:---:|:---:|
| 抓系统声音 | ✅ | ✅ | ✅ | ✅ |
| 多语言识别 | ✅ 日/英/韩/俄/法/德/西/意 | ⚠️ 依赖系统字幕 | ✅ | ✅ |
| **翻成中文** | ✅ | ❌ 只翻英文 | ❌ 只翻英文 | ✅ |
| 字幕浮在影片上 | ✅ 可拖 / 可穿透 | ❌ | ❌ 只在自己窗口 | ✅ |
| 实时（边说边出） | ✅ 约 2 秒 | ✅ | ❌ 录完再转 | ✅ |
| 要不要装 Python | **不用** | 不用 | 不用 | **要** |
| 代码体积 | **约 35 KB** | — | — | — |
| 幻觉过滤 | ✅ 28 条黑名单 | — | — | — |

> 竞品能力会跟着版本变，上表以各自仓库当前说明为准。

### Windows 自带实时字幕，现在到哪一步了

这一条是这个项目存在的理由，必须说清楚，免得你装完才发现白装：

| 你想做的事 | Windows 自带实时字幕 |
|---|---|
| 识别日语、出日语原文 | ✅ 能。Win 11 22H2 以上装语言包即可，本地跑、可离线 |
| 把外语**实时翻成简体中文** | ⚠️ **只有 Copilot+ PC 能**（NPU ≥ 40 TOPS + Win 11 24H2+）；普通 PC 只能翻成英文 |
| 在 Windows 10 上用 | ❌ 不行，这是 Win 11 才有的功能 |
| 自定义字幕条（自由拖动 / 穿透 / 字号颜色） | ❌ 有限，只能用系统给的几项样式 |

依据见微软官方文档：[Windows 11 规格与系统需求 · Copilot+ PC](https://www.microsoft.com/windows/windows-11-specifications) 与 [Microsoft Learn · Live Captions](https://learn.microsoft.com/en-gb/training/modules/prepare-for-the-future-of-ai/4-unique-experiences)。

> 说句实在的：如果你手上正好是台 Copilot+ PC，只想翻成英文，那系统自带确实更省事，什么都不用装。
> 本项目是给**没有 NPU、还在用 Windows 10、或者想把字幕条和术语攥在自己手里**的人准备的。

---

## 常见问题

**Q：字幕一直不出来？** 右键托盘图标 → **「环境自检…」**，逐项列清单，`[!!]` 那项下面直接告诉你该怎么办；报告也会存成 `自检报告.txt`。

**Q：录音设备该选哪个？** 用耳机听 → 选名字带「耳机」的或「立体声混音」；外放 → 选「立体声混音（Stereo Mix）」。列表第一个（`0 · 麦克风阵列`）通常录的是**你说话的声音**。看不到「立体声混音」就在**录制**选项卡空白处右键 → 勾选「显示禁用的设备」→ 启用。

**Q：字幕条全黑一个字都没有？** 那是**没听到人说话**，不是在报错。确认影片确实在响 → 看 `debug.log` 最后几行 → 换一个录音设备编号再试（这一项最常出问题）。

**Q：偶尔冒出「感谢您的观看」？** Whisper 对**静音**的幻觉，内置 28 条黑名单自动挡；有漏网的欢迎提 Issue。

**Q：声音会被传到网上吗？** **不会。** 声音全程在你电脑里。只有识别出的那行**文字**会发到翻译接口；关掉「是否实时翻译」就连文字也不外传。

**Q：字幕条挡住播放器按钮？** 按 `Ctrl+Alt+Z`，或右键 → 「鼠标点不到字幕条」。

---

## 安全边界

- **声音不出本机**：识别在 whisper.cpp 本地跑，从不上传音频。
- **密钥不落配置文件**：配置里只写环境变量名，密钥本身不进文件、不进 Git。
- **可完全离线**：关掉实时翻译，就不调任何外部接口。
- **不含任何影片内容，也不提供影片下载**——它只把你正在播放的声音转成文字。
- 请用于个人观看与无障碍辅助，遵守当地法律与平台规则。

---

## 路线图 / Roadmap

- ✅ `setup.ps1` 一键安装、录音设备自动识别与图形化选择
- ✅ 9 种识别语言 + 8 种目标语言、换语言自动重启识别进程
- ✅ 字幕条缩放 / 拖动 / 透明度 / 点击穿透 / 4 套主题
- ✅ 三步快速设置向导、翻译接口可切换（硅基流动 / OpenAI / Ollama / 自定义）
- ✅ 无窗口启动器 + 托盘开关键 + 环境自检报告
- ✅ 四道文字处理拆成纯函数库 + 38 条零依赖单测 + GitHub Actions 真 CI
- ⬜ **完全离线模式（本地翻译模型）**——目前唯一能连文字都不外传的方案
- ⬜ 更多界面语言与术语表导入导出

欢迎在 [Issues](https://github.com/huanweide/live-subtitle/issues) 里说你最想要哪一个。

---

## 贡献 / Contributing

1. Fork → 建分支 → 改代码
2. 跑 `.\tests\Invoke-SubtitleTests.ps1`（38 条断言，零依赖）
3. **新增 `.ps1` 必须带 UTF-8 BOM**（Windows PowerShell 5.1 会按 ANSI 解码，无 BOM 直接乱码——CI 会拦）
4. 改 `ci.yml` 时 `run:` 段保持**纯 ASCII**（同样由 CI 拦）
5. 密钥一律走环境变量，禁止写进任何文件

---

## License

MIT — 详见 [LICENSE](LICENSE)。

本项目用到：[whisper.cpp](https://github.com/ggml-org/whisper.cpp)（MIT）、[Whisper](https://github.com/openai/whisper) 模型（MIT）；翻译接口默认硅基流动，密钥自备。

---

## Star

如果这个工具帮你省下了看字幕的时间，**给个 Star 就是最大的支持**。

**作者**：huanweide（[github.com/huanweide](https://github.com/huanweide)）· MIT

**同一作者的其他工具**：

- 🎬 [bili-subtitle-universal](https://github.com/huanweide/bili-subtitle-universal) · 全网视频字幕提取（浏览器点一下，含 YouTube）
- 🐍 [bili-subtitle-extractor](https://github.com/huanweide/bili-subtitle-extractor) · B 站字幕 Python 命令行版（批量 / 可脚本化）
- 📚 [novel-smith](https://github.com/huanweide/novel-smith) · AI 小说工坊（本地优先）
- 🎓 [zhihuishu-helper](https://github.com/huanweide/zhihuishu-helper) · 智慧树网课助手
- 📦 [全部仓库](https://github.com/huanweide?tab=repositories)
