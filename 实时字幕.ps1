#Requires -Version 5.1
<#
    实时字幕：任意语言 → 简体中文
    ---------------------------------------------------------------
    原理（三段）：
      1. whisper.cpp 的 whisper-stream.exe 抓「立体声混音」设备，
         每 2 秒出一段识别结果（默认日语，可在设置里换成英语、韩语等），写进一个 txt 文件。
      2. 本脚本每 0.8 秒读一次那个 txt，发现新句子就发给硅基流动翻译。
      3. 翻译结果 + 原文，显示在一个置顶的无边框窗口里。

    窗口是「点击穿透」的：鼠标点上去会直接落到下面的播放器，
    所以不会挡住你的播放/暂停按钮。设置改从右下角托盘的图标点。
    测试模式：-TestMode 不抓声音，循环喂预设句子，用来看字幕长什么样。
#>
param(
    # 路径类参数一律留空 —— 真正的默认值在下面按「脚本自己所在的目录」算出来，
    # 这样别人把项目 clone 到任何盘、任何文件夹都能直接跑，不用改代码。
    # 优先级：命令行参数  >  subtitle-config.json（setup.ps1 探测后写进去的）  >  按脚本目录推算
    [string]$ModelPath      = '',
    [string]$WhisperStream  = '',
    [int]   $CaptureDevice  = -1,     # -1 = 还没定，等配置文件或 setup.ps1 说话
    [string]$SourceLang     = 'ja',   # 默认识别语言；配置文件里的 sourceLang 优先
    [string]$ApiKeyFile     = '',     # 可选的密钥兜底文件；留空就不读
    [string]$ApiUrl         = 'https://api.siliconflow.cn/v1/chat/completions',
    [string]$TranslateModel = 'Qwen/Qwen2.5-7B-Instruct',
    [switch]$TestMode
)

$script:Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DbgPath = Join-Path $script:Root 'debug.log'
Remove-Item $script:DbgPath -ErrorAction SilentlyContinue

# 默认路径按「脚本自己所在目录」算 —— 不写死任何人的盘符和用户名。
# 有独显的机器 setup.ps1 把引擎装在 whispercpp-gpu\，没独显的装在 whispercpp\，
# 所以两个位置都记下来，后面哪个存在就用哪个。
$script:PathWsGpu = Join-Path $script:Root 'whispercpp-gpu\Release\whisper-stream.exe'
$script:PathWsCpu = Join-Path $script:Root 'whispercpp\bin\Release\whisper-stream.exe'
$script:PathModel = Join-Path $script:Root 'models\ggml-large-v3-turbo.bin'

function Dbg([string]$m) {
    try {
        Add-Content -LiteralPath $script:DbgPath -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8
    } catch { }
}

# 按「进程 → 用户 → 机器」三级去找环境变量。
# 为什么不能只用 $env:XXX：那只看「当前进程」那一份。而用户一般是在系统设置里加的变量
# （那是用户级），已经开着的进程不会自动刷新，结果就是「我明明设了，它却说没设」。
# 三级都找一遍，对别人最友好。
function Get-EnvAny([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $v = [Environment]::GetEnvironmentVariable($name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $null
}

Dbg "脚本开始，Root=$script:Root  TestMode=$TestMode"

# ============ 高 DPI 适配 ============
# Windows 在 125% / 150% 缩放下，会把没声明「自己会缩放」的程序整个当图片放大，
# 字就是拉伸出来的、边缘发虚。这里先声明 DPI 感知，再算出缩放比，
# 后面窗口的尺寸、位置都乘这个比例 —— 视觉大小和原来一样，但字按物理像素重新渲染，边缘干净。
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DpiAware {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")]  static extern int GetDeviceCaps(IntPtr dc, int index);
    public static int ScreenDpi() {
        IntPtr dc = GetDC(IntPtr.Zero);
        int dpi = GetDeviceCaps(dc, 88);
        ReleaseDC(IntPtr.Zero, dc);
        return dpi;
    }
}
"@
$script:Dpi   = 96
$script:Scale = 1.0
try {
    [void][DpiAware]::SetProcessDPIAware()
    $script:Dpi = [DpiAware]::ScreenDpi()
    if ($script:Dpi -ge 96) { $script:Scale = [Math]::Round($script:Dpi / 96.0, 3) }
} catch { }
Dbg "DPI=$script:Dpi  缩放比例=$script:Scale"

# ============ 语言表 ============
# 键是 whisper 的 -l 语言代码，值是界面上显示的中文名。加语言就往这里加一行。
$script:LangNames = [ordered]@{
    'ja'   = '日语'
    'en'   = '英语'
    'ko'   = '韩语'
    'ru'   = '俄语'
    'fr'   = '法语'
    'de'   = '德语'
    'es'   = '西班牙语'
    'it'   = '意大利语'
    'auto' = '自动检测'
}

# 2026-10-05 新：翻译目标语言表（快速设置第 3 步「翻成什么」用）
$script:TargetLangs = [ordered]@{ zh='简体中文'; en='英语'; ja='日语'; ko='韩语'; ru='俄语'; fr='法语'; de='德语'; es='西班牙语' }

# ============ 外观主题 ============
# 设置窗口里那个「外观主题」下拉框用这几套。要加主题就往这里加一行。
# 只改配色和透明度，不动字号和大小 —— 字号管「看不看得清」，配色管「看着舒不舒服」，两件事分开。
$script:Themes = [ordered]@{
    'classic'  = @{ name = '经典黑';     bg = '#101010'; zh = '#FFFFFF'; ja = '#9AD0FF'; op = 0.72 }
    'contrast' = @{ name = '纯黑高对比'; bg = '#000000'; zh = '#FFFFFF'; ja = '#D8D8D8'; op = 0.95 }
    'cinema'   = @{ name = '深蓝影院';   bg = '#0B1A2B'; zh = '#F5F0E6'; ja = '#8FB8DE'; op = 0.80 }
    'night'    = @{ name = '极淡夜航';   bg = '#000000'; zh = '#FFFFFF'; ja = '#BFD8F0'; op = 0.28 }
}
$script:ThemeKeys = @('classic', 'contrast', 'cinema', 'night')

# ============ 翻译接口预设 ============
# 设置窗口里那个「翻译接口」下拉框用这几套。要加就照抄一行。
# ★ env 这一栏存的是「环境变量的名字」，不是密钥本身 ——
#   配置文件会被截图、也可能误传到仓库；密钥留在系统环境变量里才泄露不了。别改成直接存 key。
$script:Apis = [ordered]@{
    'siliconflow' = @{ name = '硅基流动';    url = 'https://api.siliconflow.cn/v1/chat/completions'; model = 'Qwen/Qwen2.5-7B-Instruct'; env = 'SILICONFLOW_API_KEY' }
    'openai'      = @{ name = 'OpenAI';      url = 'https://api.openai.com/v1/chat/completions';    model = 'gpt-4o-mini';             env = 'OPENAI_API_KEY' }
    'ollama'      = @{ name = '本地 Ollama'; url = 'http://127.0.0.1:11434/v1/chat/completions';    model = 'qwen2.5:7b';              env = '' }
    'custom'      = @{ name = '自定义';      url = '';                                                model = '';                        env = '' }
}
$script:ApiKeys = @('siliconflow', 'openai', 'ollama', 'custom')

# ============ 幻觉黑名单 ============
# whisper 对「静音」会自己编句子，最常见的编造内容就是视频片尾语。
# 命中这些，一律不显示。列表按语言分组，加语言时往对应组里补。
$script:Hallucinations = @(
    # ---- 日语 ----
    'ご視聴ありがとうございました', 'ご視聴ありがとうございます', 'ご視聴いただきありがとうございました',
    'ご覧いただきありがとうございました', 'ありがとうございました', 'ありがとうございます',
    'チャンネル登録', 'チャンネル登録をお願いします', 'おやすみなさい', 'お疲れ様でした',
    'おわり', '終わり', 'ご視聴ありがとう', 'またね', 'バイバイ', 'おめでとうございます',
    # ---- 英语 ----
    'Thank you for watching', 'Thanks for watching', 'Thank you for watching this video',
    'Thanks for watching this video', 'Please subscribe', 'Subscribe to my channel',
    'Like and subscribe', 'See you next time', 'Subtitles by the Amara.org community',
    # ---- 中文（whisper 偶尔直接吐中文）----
    '字幕', '字幕由 Amara.org 社群提供', '请不吝点赞订阅转发打赏支持明镜与点点栏目'
)
function Test-Hallucination([string]$t) {
    if ([string]::IsNullOrWhiteSpace($t)) { return $true }
    $s = ($t -replace '[\s。、！？!?.,，．…]', '')
    if ($s.Length -eq 0) { return $true }
    foreach ($h in $script:Hallucinations) {
        # 两边都去掉空格和标点再比 —— 否则 'Thank you for watching' 这种带空格的永远命中不了
        if ($s -eq ($h -replace '[\s。、！？!?.,，．…]', '')) { return $true }
    }
    return $false
}

# 单例：已经在跑就不再开第二个
if (-not $TestMode) {
    $already = Get-Process whisper-stream -ErrorAction SilentlyContinue
    if ($already) {
        Dbg "已有 whisper-stream 在运行（PID $($already[0].Id)），本实例退出"
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("字幕已经在运行了`n`n它浮在屏幕下方。如果找不到，鼠标移到右下角托盘，右键那个小图标 → 退出。", "实时字幕")
        exit
    }
}

try {
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Dbg "WinForms 已加载"

    # 点击穿透需要的系统调用
    $script:USER32 = @'
using System;
using System.Runtime.InteropServices;
public class Win32CS {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
'@
    Add-Type -TypeDefinition $script:USER32
    $script:WS_EX_LAYERED     = 0x00080000
    $script:WS_EX_TRANSPARENT = 0x00000020
    Dbg "穿透 API 已加载"

    # ---------- 1. 读配置 ----------
    $script:CfgPath = Join-Path $script:Root 'subtitle-config.json'
    $script:TxtPath = Join-Path $script:Root 'ws-live.txt'

    $defaults = [ordered]@{
        fontSizeZh     = 32
        fontSizeJa     = 18
        zhColor        = '#FFFFFF'
        jaColor        = '#9AD0FF'
        bgColor        = '#101010'
        opacity        = 0.72
        left           = 200
        top            = 800
        width          = 1500
        height         = 190
        showJapanese   = $true
        holdSeconds    = 10      # 一句话在屏幕上至少留这么久
        sourceLang     = "$SourceLang"   # 识别语言：ja/en/ko/ru/fr/de/es/it/auto
        translateEnabled = $true  # 是否边听边翻译（关掉＝只显示识别出的原文）
        targetLang     = 'zh'     # 翻译成哪种语言，默认简体中文
        mode           = 'both'  # both=双语 / zhOnly=只有中文 / jaOnly=只有原文
        clickThrough   = $false  # 默认能被鼠标点中（能拖、能滚轮）；看片时从托盘打开穿透
        captureDevice  = $CaptureDevice  # 录音设备编号；setup.ps1 探测后写进配置文件
        modelPath      = if ("$ModelPath" -ne '')     { "$ModelPath" }     else { "$script:PathModel" }
        whisperStream  = if ("$WhisperStream" -ne '') { "$WhisperStream" } else { "$script:PathWsGpu" }
        apiUrl         = "$ApiUrl"         # 翻译接口地址；换别家模型服务时改这里（设置窗口里也能改）
        translateModel = "$TranslateModel" # 翻译用的模型名
        apiKeyEnv      = 'SILICONFLOW_API_KEY'  # 从哪个环境变量取密钥。★ 这里只存变量名，不存密钥本身
        hotkeyEnabled  = $true   # 全局热键 Ctrl+Alt+Z 开关。嫌组合键难记就在设置里关掉，其它功能不受影响
    }
    if (Test-Path $script:CfgPath) {
        $saved = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($defaults.Keys)) {
            if ($null -ne $saved.$k) { $defaults[$k] = $saved.$k }
        }
    }
    $cfg = [pscustomobject]$defaults
    # 生效语言：配置文件里的 sourceLang 说了算；值不认识就退回 ja
    $script:EffLang = "$($cfg.sourceLang)"
    if (-not $script:LangNames.Contains($script:EffLang)) { $script:EffLang = 'ja' }
    Dbg "配置读取完成，识别语言=$($script:EffLang)"
    # 生效设备与模型：配置文件里写了就用它，没写就用启动参数里的默认值
    # （setup.ps1 装到别的电脑上时只写配置文件，不动源码）
    $script:EffDevice = if ($null -ne $cfg.captureDevice -and [int]$cfg.captureDevice -ge 0) { [int]$cfg.captureDevice } else { [int]$CaptureDevice }
    $script:EffModel  = if ("$($cfg.modelPath)" -ne '')     { "$($cfg.modelPath)" }     else { "$script:PathModel" }
    $script:EffWs     = if ("$($cfg.whisperStream)" -ne '') { "$($cfg.whisperStream)" } else { "$script:PathWsGpu" }

    # 兜底：配置文件里的路径不存在时（换了电脑、换了盘符、或者 setup 装在别的位置），
    # 就在项目目录里自己找一遍 —— 引擎 GPU 版优先、其次 CPU 版；模型挑 models\ 下最大的那个 .bin。
    if (-not (Test-Path $script:EffWs)) {
        foreach ($cand in @($script:PathWsGpu, $script:PathWsCpu)) {
            if (Test-Path $cand) { $script:EffWs = $cand; Dbg "引擎路径自动改为: $cand"; break }
        }
    }
    if (-not (Test-Path $script:EffModel)) {
        $mf = Get-ChildItem (Join-Path $script:Root 'models') -Filter '*.bin' -File -ErrorAction SilentlyContinue |
              Sort-Object Length -Descending | Select-Object -First 1
        if ($mf) { $script:EffModel = $mf.FullName; Dbg "模型路径自动改为: $($mf.FullName)" }
    }
    Dbg "生效设备=$($script:EffDevice) 模型=$($script:EffModel) 引擎=$($script:EffWs)"

    function Save-Cfg {
        try { $cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $script:CfgPath -Encoding UTF8 } catch { }
    }
    # 启动就落一次盘：保证配置文件一定存在，也方便直接改文件
    Save-Cfg

    # ---------- 2. 取翻译密钥（不回显） ----------
    # 环境变量名从配置里来（默认 SILICONFLOW_API_KEY）。取不到会返回 $null，走下面的文件兜底。
    $script:ApiKey = Get-EnvAny -name "$($cfg.apiKeyEnv)"
    # 注意：$ApiKeyFile 默认是空串，而 Test-Path 收到空串会直接抛异常（不是返回 false），
    # 所以必须先判空 —— 这个坑是改了默认值之后才暴露出来的。
    if (-not $script:ApiKey -and "$ApiKeyFile" -ne '' -and (Test-Path -LiteralPath $ApiKeyFile)) {
        $m = [regex]::Match((Get-Content -LiteralPath $ApiKeyFile -Raw), 'KEY\s*=\s*"([^"]+)"')
        if ($m.Success) { $script:ApiKey = $m.Groups[1].Value }
    }
    $script:HasApi = [bool]$script:ApiKey
    Dbg "密钥就绪: $($script:HasApi)"

    # ---------- 3. 翻译函数（脚本作用域，供事件调用） ----------
    $script:DoTranslate = {
        param([string]$text)
        if (-not $script:HasApi -or [string]::IsNullOrWhiteSpace($text)) { return '' }
        # 提示词跟着识别语言走：选英语就是「把这句英语字幕翻译成简体中文」
        $lang = "$($script:EffLang)"
        # 2026-10-05：目标语言由配置决定（快速设置第 3 步）
        $tgtKey = "$($cfg.targetLang)"
        if (-not $script:TargetLangs.Contains($tgtKey)) { $tgtKey = 'zh' }
        $tgt = "$($script:TargetLangs[$tgtKey])"
        if ($lang -eq 'auto' -or -not $script:LangNames.Contains($lang)) {
            $ask = "把下面这句字幕翻译成${tgt}。只输出译文本身，不要解释、不要加引号、不要保留原文："
        } else {
            $nm = $script:LangNames[$lang]
            $ask = "把下面这句${nm}字幕翻译成${tgt}。只输出译文本身，不要解释、不要加引号、不要保留${nm}原文："
        }
        $prompt = $ask + "`n" + $text
        $body = @{
            model       = "$($cfg.translateModel)"
            messages    = @(@{ role = 'user'; content = $prompt })
            max_tokens  = 300
            temperature = 0.1
            stream      = $false
        } | ConvertTo-Json -Depth 6 -Compress
        try {
            $r = Invoke-RestMethod -Uri "$($cfg.apiUrl)" -Method Post `
                 -Headers @{ Authorization = "Bearer $($script:ApiKey)" } `
                 -ContentType 'application/json; charset=utf-8' `
                 -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 25
            return ($r.choices[0].message.content).Trim()
        } catch {
            return ''
        }
    }

    # ---------- 4. 启动 whisper-stream（测试模式跳过） ----------
    $script:Ws = $null
    # 抽成函数：设置窗口里换语言时，要能把它掐掉、按新语言重开一个
    function Start-Whisper {
        if ($script:Ws -and -not $script:Ws.HasExited) {
            try { $script:Ws.Kill() } catch { }
            Start-Sleep -Milliseconds 600
        }
        # -vth 是「音量门槛」：低于它的片段不送识别。太高会漏掉小声的对白，太低会多出幻觉，
        # 折中取 0.65（程序默认 0.60）；漏进来的少量幻觉由黑名单兜底
        $script:Ws = Start-Process -FilePath $script:EffWs `
            -ArgumentList @('-m', $script:EffModel, '-l', $script:EffLang, '-t', '10',
                            '-c', "$($script:EffDevice)", '--step', '2000', '--length', '6000',
                            '-vth', '0.65', '-f', $script:TxtPath) `
            -RedirectStandardOutput (Join-Path $script:Root 'ws-stdout.log') `
            -RedirectStandardError  (Join-Path $script:Root 'ws-stderr.log') `
            -NoNewWindow -PassThru
        Dbg "whisper-stream 已启动 PID=$($script:Ws.Id) 语言=$($script:EffLang)"
    }
    if ($TestMode) {
        Dbg "测试模式：不启动 whisper-stream"
    } else {
        # 缺文件时不要闷声 throw —— 程序是隐藏窗口启动的，throw 出去用户什么都看不见，
        # 只会觉得「双击了没反应」。这里改成弹一个看得见的窗口，告诉他下一步该做什么。
        $missing = @()
        if (-not (Test-Path $script:EffWs)) {
            $missing += "识别引擎 whisper-stream.exe`n      找的位置：$($script:EffWs)"
        }
        if (-not (Test-Path $script:EffModel)) {
            $missing += "识别模型 $([IO.Path]::GetFileName($script:EffModel))`n      找的位置：$($script:EffModel)"
        }
        if ($missing.Count -gt 0) {
            $msg = "还差这些文件，所以现在跑不起来：`n`n  · " + ($missing -join "`n`n  · ") +
                   "`n`n请先运行一次安装脚本（只需一次）：`n" +
                   "    右键 setup.ps1  →  使用 PowerShell 运行`n`n" +
                   "它会自动下载引擎和模型、探出你的录音设备、把路径写进配置文件。`n" +
                   "装好之后再双击「启动字幕.bat」，就不会再看到这个提示了。"
            Dbg "缺少运行文件，已弹窗提示（缺 $($missing.Count) 项）"
            try {
                Add-Type -AssemblyName System.Windows.Forms
                [void][System.Windows.Forms.MessageBox]::Show($msg, '实时字幕 · 还没装好', 'OK', 'Warning')
            } catch { Dbg "弹窗失败: $($_.Exception.Message)" }
            exit
        }
        Remove-Item $script:TxtPath -ErrorAction SilentlyContinue
        Start-Whisper
    }

    # ---------- 5. 窗口 ----------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = '实时字幕'
    $form.FormBorderStyle = 'None'
    $form.TopMost         = $true
    $form.ShowInTaskbar   = $false
    $form.AutoScaleMode   = 'None'

    # 只让「背景」半透明，文字保持 100% 不透明。
    # 坑：WinForms 默认禁止控件用带透明度的背景色（直接抛「控件不支持透明的背景色」），
    # 得先打开 SupportsTransparentBackColor 这个内部开关 —— AllowTransparency 不保证帮你开，
    # 所以这里用反射调受保护的 SetStyle；真开不了就退回「整窗调透明度」的老办法，不至于打不开。
    $script:BgColor   = [Drawing.ColorTranslator]::FromHtml($cfg.bgColor)
    $script:AlphaBgOk = $false
    try {
        $form.AllowTransparency = $true
        $bf = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
        $mi = [System.Windows.Forms.Control].GetMethod('SetStyle', $bf)
        $null = $mi.Invoke($form, @([System.Windows.Forms.ControlStyles]::SupportsTransparentBackColor, $true))
        $script:AlphaBgOk = $true
    } catch {
        Dbg "半透明背景不可用，退回整窗透明度: $($_.Exception.Message)"
        try { $form.AllowTransparency = $false } catch { }
    }

    function Get-BgArgb {
        $a = [int][Math]::Round([double]$cfg.opacity * 255)
        if ($a -lt 18)  { $a = 18 }   # 2026-10-05：下限放到 18（约 7%），背景能更透；文字不透明不受影响
        if ($a -gt 255) { $a = 255 }
        return [Drawing.Color]::FromArgb($a, $script:BgColor.R, $script:BgColor.G, $script:BgColor.B)
    }
    function Apply-Bg {
        if ($script:AlphaBgOk) {
            $form.BackColor = Get-BgArgb
        } else {
            $form.BackColor = $script:BgColor
            try { $form.Opacity = [double]$cfg.opacity } catch { }
        }
    }
    Apply-Bg
    $form.StartPosition   = 'Manual'
    # 配置里的数字一律按「逻辑像素」存，显示时乘屏幕缩放 —— 换台不同缩放的电脑，字幕条大小位置不变
    $form.Location        = New-Object Drawing.Point(
                                [int]([int]$cfg.left   * $script:Scale),
                                [int]([int]$cfg.top    * $script:Scale))
    $form.Size            = New-Object Drawing.Size(
                                [int]([int]$cfg.width  * $script:Scale),
                                [int]([int]$cfg.height * $script:Scale))

    # 圆角：把一个圆角矩形当窗口的形状掩膜，四个直角被削掉
    $script:CornerR = [int](18 * $script:Scale)
    function Set-RoundedRegion {
        $r = $script:CornerR
        $w = $form.Width
        $h = $form.Height
        $gp = New-Object Drawing.Drawing2D.GraphicsPath
        $gp.AddArc(0, 0, $r, $r, 180, 90)
        $gp.AddArc(($w - $r), 0, $r, $r, 270, 90)
        $gp.AddArc(($w - $r), ($h - $r), $r, $r, 0, 90)
        $gp.AddArc(0, ($h - $r), $r, $r, 90, 90)
        $gp.CloseFigure()
        $form.Region = New-Object Drawing.Region($gp)
        $gp.Dispose()
    }
    Set-RoundedRegion
    Dbg ("窗体属性设置完成  尺寸=" + $form.Width + "x" + $form.Height + "  位置=" + $form.Location.X + "," + $form.Location.Y)

    $lblJa               = New-Object System.Windows.Forms.Label
    $lblJa.Dock          = 'Top'
    $lblJa.Height        = [int](56 * $script:Scale)
    $lblJa.AutoSize      = $false
    $lblJa.TextAlign     = 'MiddleCenter'
    $lblJa.Padding       = New-Object System.Windows.Forms.Padding(0, [int](4 * $script:Scale), 0, 0)
    $lblJa.ForeColor     = [Drawing.ColorTranslator]::FromHtml($cfg.jaColor)
    $lblJa.BackColor     = [Drawing.Color]::Transparent
    $lblJa.Font          = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeJa)
    $lblJa.UseCompatibleTextRendering = $true   # 透明背景上用 GDI+ 渲染，笔画抗锯齿更平滑
    $lblJa.Text          = ''
    $lblJa.Visible       = [bool]$cfg.showJapanese

    # 空闲时在黑条上留一行灰字，让人一眼看出「程序活着，只是在等声音」
    $script:IdleText  = '● 实时字幕已启动 · 在等声音…（右键右下角托盘图标可调设置）'
    $script:IdleColor = [Drawing.ColorTranslator]::FromHtml('#8A8A8A')
    $script:LiveColor = [Drawing.ColorTranslator]::FromHtml($cfg.zhColor)

    $lblZh               = New-Object System.Windows.Forms.Label
    $lblZh.Dock          = 'Fill'
    $lblZh.AutoSize      = $false
    $lblZh.TextAlign     = 'MiddleCenter'
    $lblZh.Padding       = New-Object System.Windows.Forms.Padding(
                               [int](16 * $script:Scale), [int](6 * $script:Scale),
                               [int](16 * $script:Scale), [int](10 * $script:Scale))
    $lblZh.ForeColor     = $script:IdleColor
    $lblZh.BackColor     = [Drawing.Color]::Transparent
    $lblZh.Font          = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeZh, [Drawing.FontStyle]::Bold)
    $lblZh.UseCompatibleTextRendering = $true   # 同上
    $lblZh.Text          = $script:IdleText

    $form.Controls.Add($lblZh)
    $form.Controls.Add($lblJa)

    # ---------- 4b. 看得见的把手：不用记任何快捷键 ----------
    # 为什么加这个：滚轮 / Ctrl+滚 这类手势要求用户先「知道」、再「记住」，
    # 记不住就等于没有。改成看得见的控件后，鼠标扫过去它就亮起来，
    # 等于它自己告诉用户「我能拖」——这叫可发现性。
    $script:GripSize   = [int](22 * $script:Scale)
    $script:GripActive = $false      # 拖拽中：别让 MouseLeave 把它藏起来

    $grip               = New-Object System.Windows.Forms.Label
    $grip.Text          = [string][char]0x25E2   # ◢ 右下角三角：一眼看出"拖这里"
    $grip.AutoSize      = $false
    $grip.Size          = New-Object Drawing.Size($script:GripSize, $script:GripSize)
    $grip.TextAlign     = 'MiddleCenter'
    $grip.Font          = New-Object Drawing.Font('微软雅黑', [float][Math]::Max(8, 9 * $script:Scale))
    $grip.BackColor     = [Drawing.Color]::Transparent
    $grip.ForeColor     = [Drawing.Color]::FromArgb(130, 255, 255, 255)
    $grip.Cursor        = [System.Windows.Forms.Cursors]::SizeNWSE
    $grip.Visible       = $true                  # 常驻可见（2026-10-05：藏起来＝用户找不到入口）

    $gear               = New-Object System.Windows.Forms.Label
    $gear.Text          = [string][char]0x2699   # ⚙ 齿轮＝设置
    $gear.AutoSize      = $false
    $gear.Size          = New-Object Drawing.Size($script:GripSize, $script:GripSize)
    $gear.TextAlign     = 'MiddleCenter'
    $gear.Font          = New-Object Drawing.Font('微软雅黑', [float][Math]::Max(9, 10 * $script:Scale))
    $gear.BackColor     = [Drawing.Color]::Transparent
    $gear.ForeColor     = [Drawing.Color]::FromArgb(130, 255, 255, 255)
    $gear.Cursor        = [System.Windows.Forms.Cursors]::Hand
    $gear.Visible       = $true                  # 常驻可见（同上）
    $gear.Add_Click({ try { Show-Settings } catch { Dbg "设置窗口出错: $($_.Exception.Message)" } })

    # ---------- 2026-10-05 新：右侧一排「看得见、点得动」的快捷按钮 ----------
    # 放大缩小 / 透明度 / 关闭 是最常用的三件事，原来都得先进设置窗口找，
    # 而设置入口本身又是隐形的。现在做成条子上直接可点的按钮。
    function New-BarButton([string]$text) {
        $b = New-Object System.Windows.Forms.Label
        $b.Text = $text
        $b.AutoSize = $false
        $b.Size = New-Object Drawing.Size($script:GripSize, $script:GripSize)
        $b.TextAlign = 'MiddleCenter'
        $b.Font = New-Object Drawing.Font('微软雅黑', [float][Math]::Max(9, 10 * $script:Scale))
        $b.BackColor = [Drawing.Color]::Transparent
        $b.ForeColor = [Drawing.Color]::FromArgb(115, 255, 255, 255)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $b.Visible = $true
        return $b
    }
    $bClose = New-BarButton ([string][char]0x2715)                 # ✕ 隐藏字幕条
    $bAlpha = New-BarButton ([string][char]0x25D0)                 # ◐ 透明度循环
    $bUp    = New-BarButton '+'
    $bDown  = New-BarButton ([string][char]0x2212)                 # − 缩小

    $bUp.Add_Click({   try { Scale-Bar 1.08 }      catch { Dbg "放大失败: $($_.Exception.Message)" } })
    $bDown.Add_Click({ try { Scale-Bar (1/1.08) }  catch { Dbg "缩小失败: $($_.Exception.Message)" } })
    $bAlpha.Add_Click({
        try {
            $steps = @(0.95, 0.80, 0.62, 0.45, 0.30)
            $cur = [double]$cfg.opacity
            $idx = 0
            for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i] -le $cur + 0.001) { $idx = $i } }
            $idx = ($idx + 1) % $steps.Count
            $cfg.opacity = $steps[$idx]
            Apply-Bg
            Save-Cfg
            Dbg ("透明度 -> " + $cfg.opacity)
        } catch { Dbg "透明度调整失败: $($_.Exception.Message)" }
    })
    $bClose.Add_Click({
        try {
            $form.Hide()
            Dbg "字幕条已隐藏（托盘菜单可恢复）"
        } catch { Dbg "隐藏失败: $($_.Exception.Message)" }
    })

    function Update-HandlePos {
        # 右下角一排按钮，从右往左：◢缩放把手 ⚙设置 ✕隐藏 ◐透明度 +放大 −缩小
        $g = $script:GripSize
        $w = $form.ClientSize.Width
        $h = $form.ClientSize.Height
        $y = $h - $g
        $grip.Location   = New-Object Drawing.Point(($w - $g), $y)
        $gear.Location   = New-Object Drawing.Point([Math]::Max(0, $w - $g * 2 - 2), $y)
        $bClose.Location = New-Object Drawing.Point([Math]::Max(0, $w - $g * 3 - 4), $y)
        $bAlpha.Location = New-Object Drawing.Point([Math]::Max(0, $w - $g * 4 - 6), $y)
        $bUp.Location    = New-Object Drawing.Point([Math]::Max(0, $w - $g * 5 - 8), $y)
        $bDown.Location  = New-Object Drawing.Point([Math]::Max(0, $w - $g * 6 - 10), $y)
    }
    foreach ($b in @($grip, $gear, $bClose, $bAlpha, $bUp, $bDown)) { $form.Controls.Add($b); $b.BringToFront() }
    Update-HandlePos

    function Show-Handles([bool]$on) {
        # 常驻显示 + 悬停高亮（2026-10-05 改）
        foreach ($b in @($grip, $gear, $bClose, $bAlpha, $bUp, $bDown)) {
            if ($on) {
                $b.ForeColor = [Drawing.Color]::FromArgb(240,255,255,255)
                $b.BackColor = [Drawing.Color]::FromArgb(85,255,255,255)
            } else {
                $b.ForeColor = [Drawing.Color]::FromArgb(115,255,255,255)
                $b.BackColor = [Drawing.Color]::Transparent
            }
            $b.Visible = $true
            $b.BringToFront()
        }
    }
    # 鼠标进条子 → 把手出现；离开 → 收起（不挡字幕，但永远找得到）
    foreach ($c in @($form, $lblZh, $lblJa, $grip, $gear, $bClose, $bAlpha, $bUp, $bDown)) {
        $c.Add_MouseEnter({ Show-Handles $true })
        $c.Add_MouseLeave({ Show-Handles $false })
    }
    Dbg "标签创建完成（含右下角缩放把手与设置按钮）"


    # 按模式决定谁显示
    function Apply-Mode {
        # 2026-10-05：关掉「实时翻译」时只显示原文那一行（主行直接承载原文）
        if (-not [bool]$cfg.translateEnabled) {
            $lblJa.Visible = $false
            $lblZh.Visible = $true
            return
        }
        switch ("$($cfg.mode)") {
            'zhOnly' { $lblJa.Visible = $false; $lblZh.Visible = $true }
            'jaOnly' { $lblJa.Visible = $true;  $lblZh.Visible = $false }
            default  { $lblJa.Visible = [bool]$cfg.showJapanese; $lblZh.Visible = $true }
        }
    }
    Apply-Mode

    # 拖动
    # 老实现有个坑：鼠标在字幕条上按下、移到条子外面再松开，MouseUp 收不到，
    # Dragging 就永远停在 true —— 之后鼠标每次划过字幕条，窗口都跟着跑，还能跑到屏幕外面去。
    # 现在三重保险：按下时抓住鼠标、每次移动都确认左键还按着、松手和启动时都把位置夹回屏幕内。
    $script:Dragging  = $false
    $script:DragMoved = $false
    $script:DragPt    = New-Object Drawing.Point(0, 0)

    function Save-Pos {
        # 配置里存逻辑像素，除以屏幕缩放
        $cfg.left = [int][Math]::Round($form.Location.X / $script:Scale)
        $cfg.top  = [int][Math]::Round($form.Location.Y / $script:Scale)
        Save-Cfg
    }
    function Clamp-Pos {
        # 至少留 120×60 逻辑像素在屏幕里，免得拖出去找不回来
        $vs   = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $keepX = [int](120 * $script:Scale)
        $keepY = [int](60  * $script:Scale)
        $x = $form.Location.X
        $y = $form.Location.Y
        # 2026-10-05 改：原来只要求「留 120x60 在屏幕里」，条子可以大半跑到屏幕外——
        # 而右下角那排按钮就跟着跑到屏幕外，用户看不见也点不到。现在整条夹在屏幕内。
        $margin = [int](10 * $script:Scale)
        if ($x -gt ($vs.Right  - $form.Width  - $margin)) { $x = $vs.Right  - $form.Width  - $margin }
        if ($x -lt ($vs.Left + $margin))                  { $x = $vs.Left + $margin }
        if ($y -gt ($vs.Bottom - $form.Height - $margin)) { $y = $vs.Bottom - $form.Height - $margin }
        if ($y -lt ($vs.Top + $margin))                   { $y = $vs.Top + $margin }
        if ($x -ne $form.Location.X -or $y -ne $form.Location.Y) {
            $form.Location = New-Object Drawing.Point($x, $y)
            Dbg "位置超出屏幕，已拉回: $x,$y"
        }
    }

    $onDown = {
        $script:Dragging  = $true
        $script:DragMoved = $false
        $script:DragPt    = [System.Windows.Forms.Cursor]::Position
        try { $form.Capture = $true } catch { }   # 抓住鼠标，条子外面松手也能收到 MouseUp
    }
    $onMove = {
        if (-not $script:Dragging) { return }
        $down = ([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -ne 0
        if (-not $down) {
            # 左键已经松了（多半是在条子外面松的）→ 立刻收尾，别再跟着鼠标跑
            $script:Dragging = $false
            try { $form.Capture = $false } catch { }
            Clamp-Pos
            if ($script:DragMoved) { Save-Pos; Dbg ("位置已记住: " + $cfg.left + "," + $cfg.top) }
            return
        }
        $p  = [System.Windows.Forms.Cursor]::Position
        $dx = $p.X - $script:DragPt.X
        $dy = $p.Y - $script:DragPt.Y
        if ($dx -ne 0 -or $dy -ne 0) {
            $form.Location    = New-Object Drawing.Point(($form.Location.X + $dx), ($form.Location.Y + $dy))
            $script:DragPt    = $p
            $script:DragMoved = $true
        }
    }
    $onUp = {
        try { $form.Capture = $false } catch { }
        if ($script:Dragging) {
            $script:Dragging = $false
            if ($script:DragMoved) {
                Clamp-Pos
                Save-Pos
                Dbg ("位置已记住: " + $cfg.left + "," + $cfg.top)
            }
        }
    }
    foreach ($c in @($form, $lblJa, $lblZh)) {
        $c.Add_MouseDown($onDown)
        $c.Add_MouseMove($onMove)
        $c.Add_MouseUp($onUp)
    }
    Clamp-Pos   # 上次要是被拖到屏幕外了，启动就拉回来

    # ---------- 4c. 拖右下角把手 = 整条等比缩放 ----------
    # 这是"主入口"：不用记任何键，看见就能拖。滚轮保留为快捷方式。
    $script:GripDrag  = $false
    $script:GripPt    = New-Object Drawing.Point(0, 0)
    $script:GripBaseW = 0
    $script:GripBaseH = 0
    $script:GripBaseZ = 0
    $script:GripBaseJ = 0

    $gripDown = {
        # 只认左键：右键要留给和托盘一致的菜单
        if (([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -eq 0) { return }
        $script:GripDrag   = $true
        $script:GripActive = $true
        $script:GripPt     = [System.Windows.Forms.Cursor]::Position
        $script:GripBaseW  = [int]$cfg.width
        $script:GripBaseH  = [int]$cfg.height
        $script:GripBaseZ  = [int]$cfg.fontSizeZh
        $script:GripBaseJ  = [int]$cfg.fontSizeJa
        try { $grip.Capture = $true } catch { }
    }
    $gripMove = {
        if (-not $script:GripDrag) { return }
        $down = ([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -ne 0
        if (-not $down) {
            # 在条子外面松的手，也要收尾
            $script:GripDrag   = $false
            $script:GripActive = $false
            try { $grip.Capture = $false } catch { }
            Save-Cfg
            Dbg ("拖拽缩放完成: " + $cfg.width + "x" + $cfg.height)
            return
        }
        $p     = [System.Windows.Forms.Cursor]::Position
        $dxLog = ($p.X - $script:GripPt.X) / $script:Scale
        $ratio = ($script:GripBaseW + $dxLog) / [double]$script:GripBaseW
        if ($ratio -lt 0.3) { $ratio = 0.3 }
        if ($ratio -gt 5.0) { $ratio = 5.0 }

        $newW  = [Math]::Max(400,  [Math]::Min(3840, [int][Math]::Round($script:GripBaseW * $ratio)))
        $newH  = [Math]::Max(80,   [Math]::Min(800,  [int][Math]::Round($script:GripBaseH * $ratio)))
        $newZh = [Math]::Max(14,   [Math]::Min(80,   [int][Math]::Round($script:GripBaseZ * $ratio)))
        $newJa = [Math]::Max(10,   [Math]::Min(50,   [int][Math]::Round($script:GripBaseJ * $ratio)))
        if ($newW -eq [int]$cfg.width -and $newH -eq [int]$cfg.height -and
            $newZh -eq [int]$cfg.fontSizeZh -and $newJa -eq [int]$cfg.fontSizeJa) { return }

        $cfg.width      = $newW
        $cfg.height     = $newH
        $cfg.fontSizeZh = $newZh
        $cfg.fontSizeJa = $newJa
        # 原文那一行是 Dock=Top 的固定高度，按新条高的 30% 一起长，否则条子大了它还那么薄
        $lblJa.Height = [int][Math]::Max(24, [Math]::Min(400, [int]($newH * 0.30)))
        $lblZh.Font   = New-Object Drawing.Font('微软雅黑', [float]$newZh, [Drawing.FontStyle]::Bold)
        $lblJa.Font   = New-Object Drawing.Font('微软雅黑', [float]$newJa)
        try {
            $form.Size = New-Object Drawing.Size([int]($newW * $script:Scale), [int]($newH * $script:Scale))
            Set-RoundedRegion
            Update-HandlePos
            Clamp-Pos
        } catch { Dbg "拖拽缩放失败: $($_.Exception.Message)" }
    }
    $grip.Add_MouseDown($gripDown)
    $grip.Add_MouseMove($gripMove)
    $grip.Add_MouseUp({
        if ($script:GripDrag) {
            $script:GripDrag   = $false
            $script:GripActive = $false
            try { $grip.Capture = $false } catch { }
            Save-Cfg
            Dbg ("拖拽缩放完成: " + $cfg.width + "x" + $cfg.height)
        }
    })
    Dbg "右下角把手拖拽绑定完成"

    # 2026-10-05：把「整条缩放」抽成函数，滚轮与 +/− 按钮共用同一套上下限
    function Scale-Bar([double]$step) {
        $maxBarW = [int]([System.Windows.Forms.SystemInformation]::VirtualScreen.Width / $script:Scale) - 20
        $newW  = [Math]::Max(400,  [Math]::Min($maxBarW, [int][Math]::Round([int]$cfg.width  * $step)))
        $newH  = [Math]::Max(80,   [Math]::Min(800,  [int][Math]::Round([int]$cfg.height * $step)))
        $newZh = [Math]::Max(14,   [Math]::Min(80,   [int][Math]::Round([int]$cfg.fontSizeZh * $step)))
        $newJa = [Math]::Max(10,   [Math]::Min(50,   [int][Math]::Round([int]$cfg.fontSizeJa * $step)))
        if ($newW -eq [int]$cfg.width -and $newH -eq [int]$cfg.height) { return }
        $cfg.width = $newW; $cfg.height = $newH
        $cfg.fontSizeZh = $newZh; $cfg.fontSizeJa = $newJa
        $lblJa.Height = [int][Math]::Max(24, [Math]::Min(400, [double]$lblJa.Height * $step))
        $lblZh.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeZh, [Drawing.FontStyle]::Bold)
        $lblJa.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeJa)
        try {
            $form.Size = New-Object Drawing.Size([int]($cfg.width * $script:Scale), [int]($cfg.height * $script:Scale))
            Set-RoundedRegion
            Update-HandlePos
            Clamp-Pos
        } catch { Dbg "缩放失败: $($_.Exception.Message)" }
        Save-Cfg
    }

    # 滚轮（保留为快捷方式）：滚 = 整条放大缩小。
    # Ctrl+滚 那套已经删掉——它要求用户先知道、再记住组合键，新手根本发现不了；
    # 「只想调字号」现在去设置窗口的滑块里做，而且看得见当前值。
    # 位置不动（只往右下长），滚过头了有 Clamp-Pos 兜底，不会跑出屏幕。
    $onWheel = {
        $up = $_.Delta -gt 0

        # —— 整条缩放：宽、高、两行字号按同一比例变 ——
        $step  = if ($up) { 1.08 } else { 1 / 1.08 }
        $maxBarW = [int]([System.Windows.Forms.SystemInformation]::VirtualScreen.Width / $script:Scale) - 20
        $newW  = [Math]::Max(400,  [Math]::Min($maxBarW, [int][Math]::Round([int]$cfg.width  * $step)))
        $newH  = [Math]::Max(80,   [Math]::Min(800,  [int][Math]::Round([int]$cfg.height * $step)))
        $newZh = [Math]::Max(14,   [Math]::Min(80,   [int][Math]::Round([int]$cfg.fontSizeZh * $step)))
        $newJa = [Math]::Max(10,   [Math]::Min(50,   [int][Math]::Round([int]$cfg.fontSizeJa * $step)))
        # 宽高都已经顶到上下限，就什么也不做 —— 免得滚到底还在反复重排
        if ($newW -eq [int]$cfg.width -and $newH -eq [int]$cfg.height) { return }

        $cfg.width      = $newW
        $cfg.height     = $newH
        $cfg.fontSizeZh = $newZh
        $cfg.fontSizeJa = $newJa
        # 原文那一行是 Dock=Top 的固定高度（不是撑满），得跟着一起长，否则条子大了它还是那么薄
        $lblJa.Height = [int][Math]::Max(24, [Math]::Min(400, [double]$lblJa.Height * $step))
        $lblZh.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeZh, [Drawing.FontStyle]::Bold)
        $lblJa.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeJa)
        try {
            $form.Size = New-Object Drawing.Size([int]($cfg.width * $script:Scale), [int]($cfg.height * $script:Scale))
            Set-RoundedRegion
            Update-HandlePos
            Clamp-Pos
        } catch { Dbg "滚轮缩放失败: $($_.Exception.Message)" }
        Save-Cfg
    }
    foreach ($c in @($form, $lblJa, $lblZh)) { $c.Add_MouseWheel($onWheel) }
    Dbg "交互事件绑定完成"

    # ---------- 5b. 点击穿透开关 ----------
    function Set-ClickThrough([bool]$on) {
        try {
            $ex = [Win32CS]::GetWindowLong($form.Handle, -20)
            if ($on) {
                $ex = $ex -bor $script:WS_EX_TRANSPARENT -bor $script:WS_EX_LAYERED
            } else {
                $ex = $ex -band (-bnot $script:WS_EX_TRANSPARENT)
            }
            [void][Win32CS]::SetWindowLong($form.Handle, -20, $ex)
            $cfg.clickThrough = $on
        } catch { Dbg "穿透切换失败: $($_.Exception.Message)" }
    }

    # ---------- 5c. 托盘菜单（穿透后只能从这里操作） ----------
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $miBoth = $menu.Items.Add('双语字幕（原文 + 中文）')
    $miBoth.Add_Click({
        $cfg.mode = 'both'; $cfg.showJapanese = $true; Apply-Mode; Save-Cfg
    })
    $miZh = $menu.Items.Add('只看中文翻译')
    $miZh.Add_Click({
        $cfg.mode = 'zhOnly'; Apply-Mode; Save-Cfg
    })
    $miJa = $menu.Items.Add('只看原文')
    $miJa.Add_Click({
        $cfg.mode = 'jaOnly'; Apply-Mode; Save-Cfg
    })

    $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miThrough = $menu.Items.Add('字幕条能被鼠标点中：开')
    $miThrough.Add_Click({
        Set-ClickThrough (-not [bool]$cfg.clickThrough)
        Save-Cfg
    })

    $miHold = $menu.Items.Add('字幕停留时间')
    $miHold.Add_Click({
        $cfg.holdSeconds = if ([int]$cfg.holdSeconds -ge 20) { 10 } else { 20 }
        Save-Cfg
    })

    $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miQuick = $menu.Items.Add('🚀 快速设置（三步）')
    $miQuick.Add_Click({ try { Show-QuickSetup } catch { Dbg "快速设置出错: $($_.Exception.Message)" } })
    $miSet = $menu.Items.Add('⚙ 打开设置…')
    $miSet.Add_Click({ try { Show-Settings } catch { Dbg "设置窗口出错: $($_.Exception.Message)" } })
    $miShow = $menu.Items.Add('显示 / 隐藏字幕条')
    $miShow.Add_Click({
        if ($form.Visible) { $form.Hide() } else { $form.Show(); $form.BringToFront() }
    })
    $miPause = $menu.Items.Add('暂停字幕')
    $miPause.Add_Click({ Set-Running (-not $script:Running) })

    $miDiag = $menu.Items.Add('环境自检…')
    $miDiag.Add_Click({ try { Show-Diagnose } catch { Dbg "自检出错: $($_.Exception.Message)" } })

    $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $null = $menu.Items.Add('保存当前设置', $null, { Save-Cfg })
    $null = $menu.Items.Add('退出', $null, { $form.Close() })

    # 每次拉开菜单前，把当前状态写进菜单文字，省得不知道现在是开还是关
    $menu.Add_Opening({
        $miBoth.Checked = ("$($cfg.mode)" -eq 'both')
        $miZh.Checked   = ("$($cfg.mode)" -eq 'zhOnly')
        $miJa.Checked   = ("$($cfg.mode)" -eq 'jaOnly')
        if ([bool]$cfg.clickThrough) {
            $miThrough.Text = '字幕条能被鼠标点中：关  ← 点这里就能拖'
        } else {
            $miThrough.Text = '字幕条能被鼠标点中：开  ← 点这里就不挡播放器'
        }
        $nxt = if ([int]$cfg.holdSeconds -ge 20) { 10 } else { 20 }
        $miHold.Text = "字幕停留时间：$($cfg.holdSeconds) 秒（点这里改成 $nxt 秒）"
        $miPause.Text = if ($script:Running) { '暂停字幕' } else { '继续字幕' }
    })
    Dbg "托盘菜单完成"

    # ---------- 5c-2. 托盘图标：左键当开关键用 ----------
    # 以前图标是 Windows 的默认图标，点它没反应，只能右键。
    # 现在左键点一下 = 暂停/继续，图标跟着变色（绿=在跑、灰=暂停）。
    # 图标不用外部 .ico 文件，现场用 GDI+ 画一个圆点 —— 仓库里少一个二进制文件。
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32Icon {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
    function New-DotIcon([System.Drawing.Color]$color) {
        $bmp = New-Object Drawing.Bitmap 16, 16
        $g   = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([Drawing.Color]::Transparent)
        $br = New-Object Drawing.SolidBrush $color
        $g.FillEllipse($br, 2, 2, 12, 12)
        $br.Dispose(); $g.Dispose()
        $h = $bmp.GetHicon()
        # 必须 Clone 一份：FromHandle 借的是位图的句柄，位图一销毁图标就废了
        $ico = [System.Drawing.Icon]([System.Drawing.Icon]::FromHandle($h).Clone())
        [void][Win32Icon]::DestroyIcon($h)
        $bmp.Dispose()
        return $ico
    }
    $script:IconOn  = New-DotIcon ([Drawing.Color]::FromArgb(64, 200, 96))    # 绿：在跑
    $script:IconOff = New-DotIcon ([Drawing.Color]::FromArgb(132, 132, 132))  # 灰：暂停
    $script:Running = $true

    function Set-Running([bool]$on) {
        try {
            if ($on) {
                if (-not $TestMode) { Start-Whisper }
                $timer.Start()
                $tray.Icon = $script:IconOn
                $tray.Text = '实时字幕：开着（左键暂停 / 右键设置）'
                $lblJa.Text = ''
                $lblZh.ForeColor = $script:IdleColor
                $lblZh.Text = $script:IdleText
                Dbg "字幕已开启"
            } else {
                if ($script:Ws -and -not $script:Ws.HasExited) { try { $script:Ws.Kill() } catch { } }
                $script:Ws = $null
                $timer.Stop()
                $tray.Icon = $script:IconOff
                $tray.Text = '实时字幕：已暂停（左键继续 / 右键设置）'
                $lblJa.Text = ''
                $lblZh.ForeColor = $script:IdleColor
                $lblZh.Text = '● 字幕已暂停 · 左键点托盘小图标继续'
                Dbg "字幕已暂停"
            }
            $script:Running = $on
        } catch { Dbg "开关失败: $($_.Exception.Message)" }
    }

    $tray           = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon      = $script:IconOn
    $tray.Text      = '实时字幕：开着（左键暂停 / 右键设置）'
    $tray.ContextMenuStrip = $menu
    $tray.Visible   = $true
    $tray.Add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Set-Running (-not $script:Running) }
    })
    Dbg "托盘图标已显示"
    # Windows 11 默认把新图标折进「隐藏的图标」里，弹个气泡告诉他去哪找
    try {
        $tray.ShowBalloonTip(8000, '实时字幕已启动', "右键右下角托盘里的这个小图标，可以调字幕模式、大小、位置、停留时间。`n快捷键 Ctrl+Alt+Z：一键切换「挡不挡鼠标」。", [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { Dbg "气泡提示失败: $($_.Exception.Message)" }

    # ---------- 5d-2. 设置窗口（双击字幕条打开） ----------
    # 列正在工作的录音设备；Windows 没有现成命令，只能翻注册表
    function Get-CaptureDevices {
        $out = New-Object System.Collections.ArrayList
        try {
            $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
            foreach ($k in @(Get-ChildItem $base -ErrorAction SilentlyContinue)) {
                $st = (Get-ItemProperty -LiteralPath $k.PSPath -Name DeviceState -ErrorAction SilentlyContinue).DeviceState
                if ($st -ne 1) { continue }
                $nm = $null
                $props = Get-ItemProperty -LiteralPath (Join-Path $k.PSPath 'Properties') -ErrorAction SilentlyContinue
                if ($props) { $nm = $props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2' }
                if ([string]::IsNullOrWhiteSpace($nm)) { $nm = '未知设备' }
                [void]$out.Add("$nm")
            }
        } catch { Dbg "列录音设备失败: $($_.Exception.Message)" }
        return $out.ToArray()
    }

    # ---------- 5d-1. 环境自检 ----------
    # 为什么要有这个：别人的电脑上显卡、声卡、密钥各不相同，出问题时只能干瞪眼。
    # 这里一次性把该查的都查一遍，明确告诉用户「哪项 OK、哪项不行、不行该去动哪里」。
    # 这正是「对任何机器都能给出正确反应」—— 能不能跑是硬件决定的，说不说得清是我的事。
    function Show-Diagnose {
        $L = New-Object System.Collections.ArrayList
        function Mk([bool]$b) { if ($b) { '[OK]' } else { '[!!]' } }

        [void]$L.Add('实时字幕 · 环境自检')
        [void]$L.Add('时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        [void]$L.Add('')

        # 1. 配置文件
        if (Test-Path -LiteralPath $script:CfgPath) {
            [void]$L.Add("$(Mk $true)  配置文件      $script:CfgPath")
        } else {
            [void]$L.Add("$(Mk $false)  配置文件      还没生成（第一次运行时会自动建）")
        }

        # 2. 识别引擎
        if (Test-Path -LiteralPath $script:EffWs) {
            [void]$L.Add("$(Mk $true)  识别引擎      $script:EffWs")
        } else {
            [void]$L.Add("$(Mk $false)  识别引擎      找不到：$script:EffWs")
            [void]$L.Add('        先跑一次 setup.ps1 把引擎装好')
        }

        # 3. 识别模型
        if (Test-Path -LiteralPath $script:EffModel) {
            $mb = [math]::Round((Get-Item -LiteralPath $script:EffModel).Length / 1MB, 1)
            [void]$L.Add("$(Mk $true)  识别模型      $script:EffModel")
            [void]$L.Add("        大小 $mb MB")
        } else {
            [void]$L.Add("$(Mk $false)  识别模型      找不到：$script:EffModel")
            [void]$L.Add('        先跑一次 setup.ps1，或者手动把 .bin 放进 models\ 目录')
        }

        # 4. 录音设备（最容易出问题的一项）
        $devs   = @(Get-CaptureDevices)
        $stereo = -1
        for ($i = 0; $i -lt $devs.Count; $i++) {
            if ("$($devs[$i])" -match '立体声混音|Stereo Mix|What U Hear|Wave Out|loopback') { $stereo = $i; break }
        }
        if ($devs.Count -eq 0) {
            [void]$L.Add("$(Mk $false)  录音设备      一个都没找到")
            [void]$L.Add('        右键任务栏喇叭 → 声音设置 → 更多声音设置 → 录制 → 右键空白处勾「显示禁用的设备」')
        } elseif ($stereo -ge 0) {
            [void]$L.Add("$(Mk $true)  录音设备      第 $stereo 号是「$($devs[$stereo])」")
            [void]$L.Add('        录「电脑正在放的声音」就用它')
            if ([int]$script:EffDevice -ne $stereo) {
                [void]$L.Add("        注意：配置里现在用的是第 $($script:EffDevice) 号 —— 想换成它，去设置窗口的「录音设备」改")
            }
        } else {
            [void]$L.Add("$(Mk $false)  录音设备      有 $($devs.Count) 个，但没有「立体声混音」")
            [void]$L.Add('        这台机器的声卡驱动可能不提供它；用耳机听的话，可以选名字带「耳机」的那个试试')
            for ($i = 0; $i -lt [Math]::Min($devs.Count, 8); $i++) { [void]$L.Add("          [$i] $($devs[$i])") }
        }

        # 5. 翻译密钥
        if ($script:HasApi) {
            [void]$L.Add("$(Mk $true)  翻译密钥      环境变量 $($cfg.apiKeyEnv) 里找到了")
        } else {
            [void]$L.Add("$(Mk $false)  翻译密钥      环境变量 $($cfg.apiKeyEnv) 里没找到")
            [void]$L.Add('        原文照样会显示，但不会出中文。设好这个变量后重启程序')
        }
        [void]$L.Add("        接口：$($cfg.apiUrl)")
        [void]$L.Add("        模型：$($cfg.translateModel)")

        # 6. 显卡
        try {
            $vc = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
            foreach ($v in $vc) { [void]$L.Add("        显卡：$($v.Name)") }
            $nv = @($vc | Where-Object { "$($_.Name)" -match 'NVIDIA' })
            if ($nv.Count -gt 0) {
                [void]$L.Add("$(Mk $true)  显卡加速      检测到 N 卡，走 GPU 路线（一句约 1.5～2.5 秒）")
            } else {
                [void]$L.Add("$(Mk $true)  显卡加速      没检测到 N 卡 —— 只能走 CPU，一句大约 5～8 秒")
            }
        } catch {
            [void]$L.Add("$(Mk $false)  显卡加速      读不到显卡信息：$($_.Exception.Message)")
        }

        [void]$L.Add('')
        [void]$L.Add('说明：[OK] 正常    [!!] 有问题，看它下面那行提示')

        # 顺手存一份，出问题时可以直接把这个文件发给别人看
        try { ($L -join "`r`n") | Set-Content -LiteralPath (Join-Path $script:Root '自检报告.txt') -Encoding UTF8 } catch { }

        # 弹窗显示
        $dg = New-Object System.Windows.Forms.Form
        $dg.Text          = '实时字幕 · 环境自检'
        $dg.ClientSize    = New-Object Drawing.Size(660, 470)
        $dg.StartPosition = 'CenterScreen'
        $dg.Font          = New-Object Drawing.Font('微软雅黑', 9)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline  = $true
        $tb.ReadOnly   = $true
        $tb.ScrollBars = 'Both'
        $tb.WordWrap   = $false
        $tb.Dock       = 'Fill'
        $tb.Font       = New-Object Drawing.Font('Consolas', 9)
        $tb.Text       = ($L -join "`r`n")
        $dg.Controls.Add($tb)
        $bd = New-Object System.Windows.Forms.Button
        $bd.Text = '关闭'
        $bd.Dock = 'Bottom'
        $bd.Height = 34
        $bd.Add_Click({ $dg.Close() })
        $dg.Controls.Add($bd)
        $dg.AcceptButton = $bd
        $dg.CancelButton = $bd
        Dbg '环境自检已打开'
        [void]$dg.ShowDialog($form)
    }

    # ---------- 2026-10-05 新：快速设置 · 三步向导 ----------
    # 斯瑞要的形态：「点击去进行设置，选择识别语音 - 是否实时翻译 - 对应中文（默认开启）」
    # 独立小窗，不改动原来那个大设置窗，风险最小；三步之间用大标题分隔，一眼知道先点哪。
    function Show-QuickSetup {
        $q = New-Object System.Windows.Forms.Form
        $q.Text            = '快速设置 · 三步搞定'
        $q.FormBorderStyle = 'FixedDialog'
        $q.MaximizeBox     = $false
        $q.MinimizeBox     = $false
        $q.StartPosition   = 'CenterScreen'
        $q.ClientSize      = New-Object Drawing.Size([int](560 * $script:Scale), [int](480 * $script:Scale))
        $q.Font            = New-Object Drawing.Font('微软雅黑', [float](10 * $script:Scale))
        $q.BackColor       = [Drawing.Color]::FromArgb(250, 250, 252)
        $S = $script:Scale

        function QT([string]$txt, [int]$yy, [bool]$bold) {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $txt
            $l.Location = New-Object Drawing.Point([int](24 * $S), $yy)
            $l.AutoSize = $true
            if ($bold) {
                $l.Font = New-Object Drawing.Font('微软雅黑', [float](12 * $S), [Drawing.FontStyle]::Bold)
                $l.ForeColor = [Drawing.Color]::FromArgb(30, 90, 180)
            } else {
                $l.Font = New-Object Drawing.Font('微软雅黑', [float](10 * $S))
                $l.ForeColor = [Drawing.Color]::FromArgb(70, 70, 70)
            }
            $q.Controls.Add($l)
        }

        $y = [int](18 * $S)
        QT '第 1 步 · 听什么声音' $y $true; $y += [int](34 * $S)
        QT '选一个能听到电脑声音的设备（一般选「立体声混音」）' $y $false; $y += [int](28 * $S)
        $cbDev = New-Object System.Windows.Forms.ComboBox
        $cbDev.DropDownStyle = 'DropDownList'
        $cbDev.Location = New-Object Drawing.Point([int](28 * $S), $y)
        $cbDev.Size = New-Object Drawing.Size([int](490 * $S), [int](30 * $S))
        $devNames = @()
        try { $devNames = @(Get-CaptureDevices) } catch { }
        $devCount = if ($devNames.Count -gt 0) { $devNames.Count } else { 6 }
        for ($i = 0; $i -lt $devCount; $i++) {
            $nm = if ($i -lt $devNames.Count) { $devNames[$i] } else { '（未知设备）' }
            [void]$cbDev.Items.Add(("{0} · {1}" -f $i, $nm))
        }
        $curDev = [int]$script:EffDevice
        if ($curDev -lt 0 -or $curDev -ge $devCount) { $curDev = 0 }
        $cbDev.SelectedIndex = $curDev
        $q.Controls.Add($cbDev)
        $y += [int](44 * $S)

        QT '第 2 步 · 要不要边听边翻译' $y $true; $y += [int](34 * $S)
        $ckTr = New-Object System.Windows.Forms.CheckBox
        $ckTr.Text = '边听边翻译（关掉就只显示识别出来的原文）'
        $ckTr.Checked = [bool]$cfg.translateEnabled
        $ckTr.Location = New-Object Drawing.Point([int](28 * $S), $y)
        $ckTr.AutoSize = $true
        $q.Controls.Add($ckTr)
        $y += [int](44 * $S)

        QT '第 3 步 · 翻译成哪种语言（默认中文）' $y $true; $y += [int](34 * $S)
        $cbTgt = New-Object System.Windows.Forms.ComboBox
        $cbTgt.DropDownStyle = 'DropDownList'
        $cbTgt.Location = New-Object Drawing.Point([int](28 * $S), $y)
        $cbTgt.Size = New-Object Drawing.Size([int](250 * $S), [int](30 * $S))
        foreach ($k in $script:TargetLangs.Keys) { [void]$cbTgt.Items.Add("$($script:TargetLangs[$k])|$k") }
        $tgtCur = "$($cfg.targetLang)"
        if (-not $script:TargetLangs.Contains($tgtCur)) { $tgtCur = 'zh' }
        for ($i = 0; $i -lt $cbTgt.Items.Count; $i++) {
            if ("$($cbTgt.Items[$i])" -like "*|$tgtCur") { $cbTgt.SelectedIndex = $i; break }
        }
        if ($cbTgt.SelectedIndex -lt 0) { $cbTgt.SelectedIndex = 0 }
        $q.Controls.Add($cbTgt)
        $y += [int](56 * $S)

        $hint = New-Object System.Windows.Forms.Label
        $hint.Text = '识别语言（日语 / 英语…）在「完整设置」里改；这个小窗只管最常用的三件事。'
        $hint.Location = New-Object Drawing.Point([int](24 * $S), $y)
        $hint.AutoSize = $true
        $hint.ForeColor = [Drawing.Color]::FromArgb(135, 135, 135)
        $q.Controls.Add($hint)
        $y += [int](42 * $S)

        $bOk = New-Object System.Windows.Forms.Button
        $bOk.Text = '保存并开始'
        $bOk.Location = New-Object Drawing.Point([int](28 * $S), $y)
        $bOk.Size = New-Object Drawing.Size([int](200 * $S), [int](42 * $S))
        $q.Controls.Add($bOk)
        $bOpenAll = New-Object System.Windows.Forms.Button
        $bOpenAll.Text = '打开完整设置'
        $bOpenAll.Location = New-Object Drawing.Point([int](240 * $S), $y)
        $bOpenAll.Size = New-Object Drawing.Size([int](160 * $S), [int](42 * $S))
        $q.Controls.Add($bOpenAll)
        $bNo = New-Object System.Windows.Forms.Button
        $bNo.Text = '取消'
        $bNo.Location = New-Object Drawing.Point([int](412 * $S), $y)
        $bNo.Size = New-Object Drawing.Size([int](110 * $S), [int](42 * $S))
        $q.Controls.Add($bNo)

        $bOk.Add_Click({
            try {
                $sel = "$($cbDev.SelectedItem)"
                if ($sel -match '^(\d+)') {
                    $newDev = [int]$Matches[1]
                    if ($newDev -ne [int]$cfg.captureDevice) {
                        $cfg.captureDevice = $newDev
                        $script:EffDevice  = $newDev
                        Dbg "录音设备已改为 $newDev"
                    }
                }
                $before = [bool]$cfg.translateEnabled
                $cfg.translateEnabled = [bool]$ckTr.Checked
                $ts = "$($cbTgt.SelectedItem)"
                if ($ts -match '\|([a-z]{2})$') { $cfg.targetLang = $Matches[1] }
                Apply-Mode
                Save-Cfg
                Dbg ("快速设置已保存: 设备=" + $cfg.captureDevice + " 翻译=" + $cfg.translateEnabled + " 目标=" + $cfg.targetLang)
            } catch { Dbg "快速设置保存失败: $($_.Exception.Message)" }
            $q.Close()
        })
        $bOpenAll.Add_Click({ $q.Close(); try { Show-Settings } catch { Dbg "设置窗口出错: $($_.Exception.Message)" } })
        $bNo.Add_Click({ $q.Close() })
        [void]$q.ShowDialog()
    }

    function Show-Settings {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text            = '实时字幕 · 设置'
        $dlg.ClientSize      = New-Object Drawing.Size(520, 674)
        $dlg.StartPosition   = 'CenterScreen'
        $dlg.TopMost         = $true
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox     = $false
        $dlg.MinimizeBox     = $false
        $dlg.Font            = New-Object Drawing.Font('微软雅黑', 10)

        $ly = 16

        # 分区标题：一眼看出「这一块是管什么的」。
        # 为什么分区：以前 20 多个控件平铺下来，找一项要来回扫。
        # 现在按「你什么时候会用到」分四组，不用记顺序。
        function New-SectionTitle([string]$t, [int]$y) {
            $lb = New-Object System.Windows.Forms.Label
            $lb.Text = "── $t ──"
            $lb.Location = New-Object Drawing.Point(20, $y)
            $lb.Size = New-Object Drawing.Size(470, 22)
            $lb.Font = New-Object Drawing.Font('微软雅黑', 10, [Drawing.FontStyle]::Bold)
            $lb.ForeColor = [Drawing.Color]::FromArgb(70, 110, 180)
            $dlg.Controls.Add($lb)
            return 22
        }
        $ly += (New-SectionTitle '语音' $ly)

        # 识别语言：换完按「应用并保存」会自动重开一次 whisper-stream
        $lbLang = New-Object System.Windows.Forms.Label
        $lbLang.Text = '识别语言'; $lbLang.Location = New-Object Drawing.Point(20, ($ly+5)); $lbLang.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lbLang)
        $cbLang = New-Object System.Windows.Forms.ComboBox
        $cbLang.DropDownStyle = 'DropDownList'
        $cbLang.Location = New-Object Drawing.Point(120, $ly); $cbLang.Size = New-Object Drawing.Size(150,28)
        $script:LangKeys = @('ja','en','ko','ru','fr','de','es','it','auto')
        foreach ($k in $script:LangKeys) { [void]$cbLang.Items.Add("$($script:LangNames[$k])|$k") }
        $curIdx = [array]::IndexOf($script:LangKeys, "$($cfg.sourceLang)")
        $cbLang.SelectedIndex = if ($curIdx -ge 0) { $curIdx } else { 0 }
        $dlg.Controls.Add($cbLang)
        $lbLangTip = New-Object System.Windows.Forms.Label
        $lbLangTip.Text = '（换语言会重开一次识别）'
        $lbLangTip.Location = New-Object Drawing.Point(280, ($ly+5)); $lbLangTip.Size = New-Object Drawing.Size(230,24)
        $lbLangTip.ForeColor = [Drawing.Color]::Gray
        $dlg.Controls.Add($lbLangTip)
        $ly += 40

        # 录音设备：字幕不出字的时候，换一个编号再试
        $devNames = @(Get-CaptureDevices)
        $lbDev = New-Object System.Windows.Forms.Label
        $lbDev.Text = '录音设备'; $lbDev.Location = New-Object Drawing.Point(20, ($ly+5)); $lbDev.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lbDev)
        $cbDev = New-Object System.Windows.Forms.ComboBox
        $cbDev.DropDownStyle = 'DropDownList'
        $cbDev.Location = New-Object Drawing.Point(120, $ly); $cbDev.Size = New-Object Drawing.Size(280,28)
        $devCount = if ($devNames.Count -gt 0) { $devNames.Count } else { 6 }
        for ($i = 0; $i -lt $devCount; $i++) {
            $nmDev = if ($i -lt $devNames.Count) { $devNames[$i] } else { '（未知设备）' }
            [void]$cbDev.Items.Add(("{0} · {1}" -f $i, $nmDev))
        }
        $curDev = [int]$script:EffDevice
        if ($curDev -lt 0 -or $curDev -ge $devCount) { $curDev = 0 }
        $cbDev.SelectedIndex = $curDev
        $dlg.Controls.Add($cbDev)
        $lbDevTip = New-Object System.Windows.Forms.Label
        $lbDevTip.Text = '（不出字就换一个）'
        $lbDevTip.Location = New-Object Drawing.Point(410, ($ly+5)); $lbDevTip.Size = New-Object Drawing.Size(110,24)
        $lbDevTip.ForeColor = [Drawing.Color]::Gray
        $dlg.Controls.Add($lbDevTip)
        $ly += 40

        $ly += (New-SectionTitle '外观' $ly)

        $lb1 = New-Object System.Windows.Forms.Label
        $lb1.Text = '中文字号'; $lb1.Location = New-Object Drawing.Point(20, ($ly+5)); $lb1.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lb1)
        $n1 = New-Object System.Windows.Forms.NumericUpDown
        $n1.Minimum = 14; $n1.Maximum = 80; $n1.Value = [int]$cfg.fontSizeZh
        $n1.Location = New-Object Drawing.Point(120, $ly); $n1.Size = New-Object Drawing.Size(90,28)
        $dlg.Controls.Add($n1)
        $lb2 = New-Object System.Windows.Forms.Label
        $lb2.Text = '原文字号'; $lb2.Location = New-Object Drawing.Point(240, ($ly+5)); $lb2.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lb2)
        $n2 = New-Object System.Windows.Forms.NumericUpDown
        $n2.Minimum = 10; $n2.Maximum = 50; $n2.Value = [int]$cfg.fontSizeJa
        $n2.Location = New-Object Drawing.Point(340, $ly); $n2.Size = New-Object Drawing.Size(90,28)
        $dlg.Controls.Add($n2)
        $ly += 40

        # 字幕条整体宽高：字调大了条子也得跟着长，不然字被切掉
        $lb6 = New-Object System.Windows.Forms.Label
        $lb6.Text = '字幕条宽高'; $lb6.Location = New-Object Drawing.Point(20, ($ly+5)); $lb6.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lb6)
        $n5 = New-Object System.Windows.Forms.NumericUpDown
        $n5.Minimum = 600; $n5.Maximum = 3840; $n5.Increment = 50; $n5.Value = [int]$cfg.width
        $n5.Location = New-Object Drawing.Point(120, $ly); $n5.Size = New-Object Drawing.Size(90,28)
        $dlg.Controls.Add($n5)
        $lb6b = New-Object System.Windows.Forms.Label
        $lb6b.Text = '×'; $lb6b.Location = New-Object Drawing.Point(216, ($ly+4)); $lb6b.Size = New-Object Drawing.Size(18,24)
        $dlg.Controls.Add($lb6b)
        $n6 = New-Object System.Windows.Forms.NumericUpDown
        $n6.Minimum = 100; $n6.Maximum = 800; $n6.Increment = 10; $n6.Value = [int]$cfg.height
        $n6.Location = New-Object Drawing.Point(240, $ly); $n6.Size = New-Object Drawing.Size(90,28)
        $dlg.Controls.Add($n6)
        $lb6c = New-Object System.Windows.Forms.Label
        $lb6c.Text = '（逻辑像素）'
        $lb6c.Location = New-Object Drawing.Point(340, ($ly+5)); $lb6c.Size = New-Object Drawing.Size(120,24)
        $lb6c.ForeColor = [Drawing.Color]::Gray
        $dlg.Controls.Add($lb6c)
        $ly += 40

        $lb3 = New-Object System.Windows.Forms.Label
        $lb3.Text = '停留秒数'; $lb3.Location = New-Object Drawing.Point(20, ($ly+5)); $lb3.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lb3)
        $n3 = New-Object System.Windows.Forms.NumericUpDown
        $n3.Minimum = 3; $n3.Maximum = 60; $n3.Value = [int]$cfg.holdSeconds
        $n3.Location = New-Object Drawing.Point(120, $ly); $n3.Size = New-Object Drawing.Size(90,28)
        $dlg.Controls.Add($n3)
        $lb4 = New-Object System.Windows.Forms.Label
        $lb4.Text = '不透明度'; $lb4.Location = New-Object Drawing.Point(240, ($ly+5)); $lb4.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lb4)
        $n4 = New-Object System.Windows.Forms.NumericUpDown
        $n4.DecimalPlaces = 2; $n4.Minimum = 0.2; $n4.Maximum = 1.0; $n4.Increment = 0.05; $n4.Value = [decimal]$cfg.opacity
        $n4.Location = New-Object Drawing.Point(340, $ly); $n4.Size = New-Object Drawing.Size(90,28)
        $dlg.Controls.Add($n4)
        $ly += 40

        $lb5 = New-Object System.Windows.Forms.Label
        $lb5.Text = '显示模式'; $lb5.Location = New-Object Drawing.Point(20, ($ly+5)); $lb5.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lb5)
        $r1 = New-Object System.Windows.Forms.RadioButton
        $r1.Text = '双语(原文+中文)'; $r1.Location = New-Object Drawing.Point(120, $ly); $r1.Size = New-Object Drawing.Size(140,26)
        $r2 = New-Object System.Windows.Forms.RadioButton
        $r2.Text = '只看中文'; $r2.Location = New-Object Drawing.Point(265, $ly); $r2.Size = New-Object Drawing.Size(100,26)
        $r3 = New-Object System.Windows.Forms.RadioButton
        $r3.Text = '只看原文'; $r3.Location = New-Object Drawing.Point(370, $ly); $r3.Size = New-Object Drawing.Size(100,26)
        switch ("$($cfg.mode)") {
            'zhOnly' { $r2.Checked = $true }
            'jaOnly' { $r3.Checked = $true }
            default  { $r1.Checked = $true }
        }
        foreach ($r in @($r1,$r2,$r3)) { $dlg.Controls.Add($r) }
        $ly += 40

        # 外观主题：一键换配色（只动颜色和透明度，字号、大小都不碰）
        $lbTheme = New-Object System.Windows.Forms.Label
        $lbTheme.Text = '外观主题'; $lbTheme.Location = New-Object Drawing.Point(20, ($ly+5)); $lbTheme.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lbTheme)
        $cbTheme = New-Object System.Windows.Forms.ComboBox
        $cbTheme.DropDownStyle = 'DropDownList'
        $cbTheme.Location = New-Object Drawing.Point(120, $ly); $cbTheme.Size = New-Object Drawing.Size(150,28)
        $allThemeKeys = @($script:ThemeKeys) + @('custom')
        foreach ($tk in @($script:ThemeKeys)) { [void]$cbTheme.Items.Add("$($script:Themes[$tk].name)|$tk") }
        [void]$cbTheme.Items.Add('自定义（你手动调的那套）|custom')
        # 当前配色跟哪套预设完全一样就选哪套，都对不上就选「自定义」
        $curTheme = 'custom'
        foreach ($tk in @($script:ThemeKeys)) {
            $tt = $script:Themes[$tk]
            if ("$($cfg.bgColor)" -eq "$($tt.bg)" -and "$($cfg.zhColor)" -eq "$($tt.zh)" -and
                "$($cfg.jaColor)" -eq "$($tt.ja)" -and
                [Math]::Abs([double]$cfg.opacity - [double]$tt.op) -lt 0.005) { $curTheme = $tk; break }
        }
        $cbTheme.SelectedIndex = [array]::IndexOf($allThemeKeys, $curTheme)
        if ($cbTheme.SelectedIndex -lt 0) { $cbTheme.SelectedIndex = 0 }
        $dlg.Controls.Add($cbTheme)
        $lbThemeTip = New-Object System.Windows.Forms.Label
        $lbThemeTip.Text = '（选完立刻变）'
        $lbThemeTip.Location = New-Object Drawing.Point(280, ($ly+5)); $lbThemeTip.Size = New-Object Drawing.Size(230,24)
        $lbThemeTip.ForeColor = [Drawing.Color]::Gray
        $dlg.Controls.Add($lbThemeTip)
        $ly += 40

        $ly += (New-SectionTitle '翻译' $ly)

        # 翻译接口：选预设会自动把下面的地址和变量名填好；换完点「应用并保存」才真的换。
        $lbApi = New-Object System.Windows.Forms.Label
        $lbApi.Text = '翻译接口'; $lbApi.Location = New-Object Drawing.Point(20, ($ly+5)); $lbApi.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lbApi)
        $cbApi = New-Object System.Windows.Forms.ComboBox
        $cbApi.DropDownStyle = 'DropDownList'
        $cbApi.Location = New-Object Drawing.Point(120, $ly); $cbApi.Size = New-Object Drawing.Size(150,28)
        $allApiKeys = @($script:ApiKeys)
        foreach ($ak in @($script:ApiKeys)) { [void]$cbApi.Items.Add("$($script:Apis[$ak].name)|$ak") }
        # 当前地址跟哪个预设一样就选哪个，对不上就是「自定义」
        $curApi = 'custom'
        foreach ($ak in @($script:ApiKeys)) {
            $aa = $script:Apis[$ak]
            if ("$($cfg.apiUrl)" -eq "$($aa.url)" -and "$($aa.url)" -ne '') { $curApi = $ak; break }
        }
        $cbApi.SelectedIndex = [array]::IndexOf($allApiKeys, $curApi)
        if ($cbApi.SelectedIndex -lt 0) { $cbApi.SelectedIndex = $script:ApiKeys.Count - 1 }
        $dlg.Controls.Add($cbApi)
        $lbApiTip = New-Object System.Windows.Forms.Label
        $lbApiTip.Text = '（换完点「应用并保存」）'
        $lbApiTip.Location = New-Object Drawing.Point(280, ($ly+5)); $lbApiTip.Size = New-Object Drawing.Size(230,24)
        $lbApiTip.ForeColor = [Drawing.Color]::Gray
        $dlg.Controls.Add($lbApiTip)
        $ly += 40

        # 密钥变量名 + 接口地址：都能手填，方便接自己的服务
        $lbKey = New-Object System.Windows.Forms.Label
        $lbKey.Text = '密钥变量名'; $lbKey.Location = New-Object Drawing.Point(20, ($ly+5)); $lbKey.Size = New-Object Drawing.Size(90,24)
        $dlg.Controls.Add($lbKey)
        $tbKey = New-Object System.Windows.Forms.TextBox
        $tbKey.Text = "$($cfg.apiKeyEnv)"
        $tbKey.Location = New-Object Drawing.Point(120, $ly); $tbKey.Size = New-Object Drawing.Size(150,28)
        $dlg.Controls.Add($tbKey)
        $lbUrl = New-Object System.Windows.Forms.Label
        $lbUrl.Text = '接口地址'; $lbUrl.Location = New-Object Drawing.Point(285, ($ly+5)); $lbUrl.Size = New-Object Drawing.Size(70,24)
        $dlg.Controls.Add($lbUrl)
        $tbUrl = New-Object System.Windows.Forms.TextBox
        $tbUrl.Text = "$($cfg.apiUrl)"
        $tbUrl.Location = New-Object Drawing.Point(355, $ly); $tbUrl.Size = New-Object Drawing.Size(155,28)
        $dlg.Controls.Add($tbUrl)
        $ly += 40
        $lbKeyNote = New-Object System.Windows.Forms.Label
        $lbKeyNote.Text = '密钥本身不写进配置文件，只写「从哪个环境变量取」——这样配置文件泄露也不会丢密钥。'
        $lbKeyNote.Location = New-Object Drawing.Point(20, ($ly+2)); $lbKeyNote.Size = New-Object Drawing.Size(490,22)
        $lbKeyNote.ForeColor = [Drawing.Color]::Gray
        $dlg.Controls.Add($lbKeyNote)
        $ly += 30

        # ---------- 高级：默认收起 ----------
        # 放进来的都是「出问题才回来动」的项，平时不该占视线。
        $ly += (New-SectionTitle '高级（出问题再打开）' $ly)

        $ckAdv = New-Object System.Windows.Forms.CheckBox
        $ckAdv.Text = '显示高级选项'
        $ckAdv.Location = New-Object Drawing.Point(20, $ly); $ckAdv.Size = New-Object Drawing.Size(220, 26)
        $ckAdv.Checked = $false
        $dlg.Controls.Add($ckAdv)
        $ly += 34

        $ck1 = New-Object System.Windows.Forms.CheckBox
        $ck1.Text = '鼠标点不到字幕条（看片时开；开了它就拖不动）'
        $ck1.Location = New-Object Drawing.Point(20, $ly); $ck1.Size = New-Object Drawing.Size(470,26)
        $ck1.Checked = [bool]$cfg.clickThrough
        $ck1.Visible = $false
        $dlg.Controls.Add($ck1)
        $ly += 40

        $ckHot = New-Object System.Windows.Forms.CheckBox
        $ckHot.Text = '启用全局热键 Ctrl+Alt+Z（一键切换「挡不挡鼠标」）'
        $ckHot.Location = New-Object Drawing.Point(20, $ly); $ckHot.Size = New-Object Drawing.Size(470,26)
        $ckHot.Checked = [bool]$cfg.hotkeyEnabled
        $ckHot.Visible = $false
        $dlg.Controls.Add($ckHot)
        $ly += 40

        $advCtrls = @($ck1, $ckHot)
        $ckAdv.Add_CheckedChanged({
            $on = [bool]$ckAdv.Checked
            $ckAdv.Text = if ($on) { '收起高级选项' } else { '显示高级选项' }
            foreach ($c in $advCtrls) { $c.Visible = $on }
        })

        $btnDiag = New-Object System.Windows.Forms.Button
        $btnDiag.Text = '环境自检'
        $btnDiag.Location = New-Object Drawing.Point(20, $ly); $btnDiag.Size = New-Object Drawing.Size(90, 34)
        $btnDiag.Add_Click({ try { Show-Diagnose } catch { Dbg "自检出错: $($_.Exception.Message)" } })
        $dlg.Controls.Add($btnDiag)

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = '应用并保存'
        $btnOk.Location = New-Object Drawing.Point(120, $ly); $btnOk.Size = New-Object Drawing.Size(140, 34)
        $dlg.Controls.Add($btnOk)
        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = '关闭（不保存）'
        $btnClose.Location = New-Object Drawing.Point(285, $ly); $btnClose.Size = New-Object Drawing.Size(130, 34)
        $dlg.Controls.Add($btnClose)

        $tip = New-Object System.Windows.Forms.Label
        $tip.Text = '调字号 / 不透明度 / 显示模式，字幕条立刻就变。「应用并保存」才算数；点「关闭（不保存）」全部退回原样。'
        $tip.Location = New-Object Drawing.Point(20, ($ly+38)); $tip.Size = New-Object Drawing.Size(470, 24)
        $tip.ForeColor = [Drawing.Color]::Gray
        $dlg.Controls.Add($tip)

        # ---------- 实时预览 ----------
        # 以前改字号得先点保存、再看黑条、不满意再打开设置，来回好几趟。
        # 现在一边调一边就能看见效果。代价是「关闭」得负责把预览退回去，所以先记一份原始值。
        $snapZh      = [int]$cfg.fontSizeZh
        $snapJa      = [int]$cfg.fontSizeJa
        $snapOpacity = [double]$cfg.opacity
        $snapMode    = "$($cfg.mode)"
        $snapShowJa  = [bool]$cfg.showJapanese
        $snapW       = [int]$cfg.width
        $snapH       = [int]$cfg.height
        $snapBg      = "$($cfg.bgColor)"
        $snapZhC     = "$($cfg.zhColor)"
        $snapJaC     = "$($cfg.jaColor)"
        $snapApiUrl  = "$($cfg.apiUrl)"
        $snapApiEnv  = "$($cfg.apiKeyEnv)"
        $snapApiMdl  = "$($cfg.translateModel)"
        $snapHotkey  = [bool]$cfg.hotkeyEnabled

        $n1.Add_ValueChanged({
            $lblZh.Font = New-Object Drawing.Font('微软雅黑', [float]$n1.Value, [Drawing.FontStyle]::Bold)
        })
        $n2.Add_ValueChanged({
            $lblJa.Font = New-Object Drawing.Font('微软雅黑', [float]$n2.Value)
        })
        $n4.Add_ValueChanged({
            $cfg.opacity = [double]$n4.Value
            Apply-Bg
        })
        foreach ($rb in @($r1, $r2, $r3)) {
            $rb.Add_CheckedChanged({
                if     ($r2.Checked) { $cfg.mode = 'zhOnly' }
                elseif ($r3.Checked) { $cfg.mode = 'jaOnly' }
                else                 { $cfg.mode = 'both'; $cfg.showJapanese = $true }
                Apply-Mode
            })
        }
        $n5.Add_ValueChanged({
            try {
                $form.Size = New-Object Drawing.Size([int]($n5.Value * $script:Scale), $form.Height)
                Set-RoundedRegion
            } catch { }
        })
        $n6.Add_ValueChanged({
            try {
                $form.Size = New-Object Drawing.Size($form.Width, [int]($n6.Value * $script:Scale))
                Set-RoundedRegion
            } catch { }
        })
        # 外观主题：选完立刻换色。字号和条子大小都不动 —— 那两样归别的控件管。
        $cbTheme.Add_SelectedIndexChanged({
            $tk = ("$($cbTheme.SelectedItem)" -split '\|')[-1]
            if ($tk -eq 'custom' -or -not $script:Themes.Contains($tk)) { return }
            $tt = $script:Themes[$tk]
            $cfg.bgColor = "$($tt.bg)"
            $cfg.zhColor = "$($tt.zh)"
            $cfg.jaColor = "$($tt.ja)"
            $cfg.opacity = [double]$tt.op
            $script:BgColor   = [Drawing.ColorTranslator]::FromHtml("$($tt.bg)")
            $script:LiveColor = [Drawing.ColorTranslator]::FromHtml("$($tt.zh)")
            $lblJa.ForeColor  = [Drawing.ColorTranslator]::FromHtml("$($tt.ja)")
            if ($lblZh.Text -ne $script:IdleText) { $lblZh.ForeColor = $script:LiveColor }
            try { $n4.Value = [decimal]$tt.op } catch { }
            Apply-Bg
            Dbg "主题预览: $($tt.name)"
        })
        # 翻译接口：选了预设就把地址和变量名填进去（还没保存，点「应用并保存」才算数）
        $cbApi.Add_SelectedIndexChanged({
            $ak = ("$($cbApi.SelectedItem)" -split '\|')[-1]
            if ($ak -eq 'custom' -or -not $script:Apis.Contains($ak)) { return }
            $aa = $script:Apis[$ak]
            $tbUrl.Text = "$($aa.url)"
            $tbKey.Text = "$($aa.env)"
            Dbg "翻译接口预览: $($aa.name)"
        })

        $btnOk.Add_Click({
            $cfg.fontSizeZh  = [int]$n1.Value
            $cfg.fontSizeJa  = [int]$n2.Value
            $cfg.holdSeconds = [int]$n3.Value
            $cfg.width       = [int]$n5.Value
            $cfg.height      = [int]$n6.Value
            $cfg.opacity     = [double]$n4.Value
            if ($r2.Checked) { $cfg.mode = 'zhOnly' }
            elseif ($r3.Checked) { $cfg.mode = 'jaOnly' }
            else { $cfg.mode = 'both'; $cfg.showJapanese = $true }
            Set-ClickThrough ([bool]$ck1.Checked)
            $cfg.hotkeyEnabled = [bool]$ckHot.Checked

            # 翻译接口：地址和变量名以输入框为准；模型名跟着预设走（选「自定义」就保持原样）
            $cfg.apiUrl    = "$($tbUrl.Text)".Trim()
            $cfg.apiKeyEnv = "$($tbKey.Text)".Trim()
            $akSel = ("$($cbApi.SelectedItem)" -split '\|')[-1]
            if ($script:Apis.Contains($akSel)) {
                $aaSel = $script:Apis[$akSel]
                if ("$($aaSel.model)" -ne '') { $cfg.translateModel = "$($aaSel.model)" }
            }
            # 换接口后立刻按新变量名再取一次密钥 —— 不然得重启程序才生效
            $newKey = Get-EnvAny -name "$($cfg.apiKeyEnv)"
            if ($newKey) { $script:ApiKey = $newKey; $script:HasApi = $true }
            Dbg "翻译接口 -> $($cfg.apiUrl) / 变量 $($cfg.apiKeyEnv) / 模型 $($cfg.translateModel) / 密钥就绪 $($script:HasApi)"

            Apply-Bg
            $lblZh.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeZh, [Drawing.FontStyle]::Bold)
            $lblJa.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeJa)
            Apply-Mode

            # 宽高改了：把字幕条重摆一次（配置存逻辑像素，乘上屏幕缩放）
            try {
                $form.Size = New-Object Drawing.Size([int]($cfg.width * $script:Scale), [int]($cfg.height * $script:Scale))
                Set-RoundedRegion
                Update-HandlePos
                Clamp-Pos
            } catch { Dbg "应用尺寸失败: $($_.Exception.Message)" }

            # 语言变了 / 录音设备变了：清屏 + 重开识别进程（只重开一次）
            $newLang = ("$($cbLang.SelectedItem)" -split '\|')[-1]
            $newDev  = $cbDev.SelectedIndex
            $needRestart = $false
            if ($newLang -and $newLang -ne "$($cfg.sourceLang)") {
                $cfg.sourceLang = $newLang
                $script:EffLang = $newLang
                $needRestart = $true
            }
            if ($newDev -ge 0 -and $newDev -ne [int]$script:EffDevice) {
                $cfg.captureDevice = $newDev
                $script:EffDevice = $newDev
                $needRestart = $true
            }
            if ($needRestart) {
                $script:LastLine = ''
                $lblZh.Text = $script:IdleText
                $lblJa.Text = ''
                if (-not $TestMode) {
                    Dbg "设置变更 -> 语言 $($script:EffLang) / 设备 $($script:EffDevice)，重启 whisper-stream"
                    try { Start-Whisper } catch { Dbg "重启识别失败: $($_.Exception.Message)" }
                }
            }
            Save-Cfg
            Dbg "设置窗口：已应用并保存"
            $dlg.Close()
        })
        $btnClose.Add_Click({
            # 不保存 = 把刚才预览出来的样子全部退回去
            $lblZh.Font = New-Object Drawing.Font('微软雅黑', [float]$snapZh, [Drawing.FontStyle]::Bold)
            $lblJa.Font = New-Object Drawing.Font('微软雅黑', [float]$snapJa)
            $cfg.opacity      = $snapOpacity
            $cfg.mode         = $snapMode
            $cfg.showJapanese = $snapShowJa
            $cfg.width        = $snapW
            $cfg.height       = $snapH
            # 主题预览出来的颜色也要退回去（透明度那行上面已经退过了）
            $cfg.bgColor = $snapBg
            $cfg.zhColor = $snapZhC
            $cfg.jaColor = $snapJaC
            $script:BgColor   = [Drawing.ColorTranslator]::FromHtml($snapBg)
            $script:LiveColor = [Drawing.ColorTranslator]::FromHtml($snapZhC)
            $lblJa.ForeColor  = [Drawing.ColorTranslator]::FromHtml($snapJaC)
            if ($lblZh.Text -ne $script:IdleText) { $lblZh.ForeColor = $script:LiveColor }
            # 翻译接口那两行也可能被点过，一起退回原样
            $cfg.apiUrl         = $snapApiUrl
            $cfg.apiKeyEnv      = $snapApiEnv
            $cfg.translateModel = $snapApiMdl
            $cfg.hotkeyEnabled  = $snapHotkey
            try {
                $form.Size = New-Object Drawing.Size([int]($snapW * $script:Scale), [int]($snapH * $script:Scale))
                Set-RoundedRegion
                Update-HandlePos
                Clamp-Pos
            } catch { }
            Apply-Bg
            Apply-Mode
            Dbg "设置窗口：关闭，未保存（已退回原样）"
            $dlg.Close()
        })

        # ---------- 高 DPI：把整个设置窗口按屏幕缩放放大一遍 ----------
        # 主字幕条从一开始就乘了 Scale，设置窗口没有。150% 缩放的屏幕上，
        # 字是点单位会自己变大、框还是老尺寸 —— 于是字挤在框里、行距发紧。
        # 显示前统一乘一遍，最省事也最不容易漏。
        if ($script:Scale -ne 1.0) {
            $dlg.ClientSize = New-Object Drawing.Size([int](520 * $script:Scale), [int](674 * $script:Scale))
            foreach ($c in @($dlg.Controls)) {
                $c.Location = New-Object Drawing.Point([int]($c.Location.X * $script:Scale), [int]($c.Location.Y * $script:Scale))
                $c.Size     = New-Object Drawing.Size([int]($c.Size.Width * $script:Scale), [int]($c.Size.Height * $script:Scale))
            }
            Dbg ("设置窗口已按 " + $script:Scale + " 倍放大，尺寸=" + $dlg.Width + "x" + $dlg.Height)
        }
        # 居中显示，但要保证整扇窗落在屏幕里（CenterScreen 在多屏 / 缩放环境算歪过）
        $dlg.StartPosition = 'Manual'
        try {
            $vs2 = [System.Windows.Forms.SystemInformation]::VirtualScreen
            $wx  = $dlg.Width; $wy = $dlg.Height
            $px  = [int]($vs2.Left + [Math]::Max(0, ($vs2.Width  - $wx) / 2))
            $py  = [int]($vs2.Top  + [Math]::Max(0, ($vs2.Height - $wy) / 2))
            if (($px + $wx) -gt $vs2.Right)  { $px = $vs2.Right  - $wx }
            if (($py + $wy) -gt $vs2.Bottom) { $py = $vs2.Bottom - $wy }
            if ($px -lt $vs2.Left) { $px = $vs2.Left }
            if ($py -lt $vs2.Top)  { $py = $vs2.Top }
            $dlg.Location = New-Object Drawing.Point($px, $py)
        } catch { Dbg "设置窗口定位失败: $($_.Exception.Message)" }

        [void]$dlg.ShowDialog($form)
    }

    # ---------- 5e. 字幕条自己也能右键 / 双击 ----------
    # 之前右键菜单只挂在托盘图标上，在黑条上点右键当然没反应
    foreach ($c in @($form, $lblJa, $lblZh, $grip, $gear)) { $c.ContextMenuStrip = $menu }
    foreach ($c in @($form, $lblJa, $lblZh)) {
        $c.Add_DoubleClick({ try { Show-Settings } catch { Dbg "设置窗口出错: $($_.Exception.Message)" } })
    }
    Dbg "字幕条右键菜单 / 双击设置 / 右下角把手已挂上"

    # ---------- 6. 轮询 / 测试喂句 ----------
    $script:LastLine    = ''
    $script:Busy        = $false
    $script:LastNewTime = Get-Date
    # 测试句跟着识别语言走：-TestMode 时能看到对应语言的字幕长什么样
    $script:TestLinesJa = @(
        'こんにちは、今日はいい天気ですね。',
        '彼女は僕の先生です。',
        'ご視聴ありがとうございました。',
        'これは字幕のテストです。長い文章が来たら、こんなふうに自動で折り返して表示されます。',
        'おやすみなさい。'
    )
    $script:TestLinesEn = @(
        'Hello, the weather is really nice today.',
        'She used to be my teacher.',
        'This is a test of the live subtitle bar. When a long sentence comes in, it wraps onto the next line automatically, just like this.',
        'Good night.'
    )
    $script:TestLines = if ("$($script:EffLang)" -eq 'en') { $script:TestLinesEn } else { $script:TestLinesJa }
    $script:TestIdx = 0

    $timer           = New-Object System.Windows.Forms.Timer
    $timer.Interval  = 800
    $timer.Add_Tick({
        # 停留时间到了就清空（不再一直挂着上一句）
        if ($lblZh.Text -ne $script:IdleText -and ((Get-Date) - $script:LastNewTime).TotalSeconds -gt [double]$cfg.holdSeconds) {
            $lblZh.ForeColor = $script:IdleColor
            $lblZh.Text = $script:IdleText
            $lblJa.Text = ''
            Dbg "停留超时，回到待机提示"
        }

        if ($script:Busy) { return }

        # ---- 取新句 ----
        $last = ''
        if ($TestMode) {
            if (((Get-Date) - $script:LastNewTime).TotalSeconds -gt 4) {
                $last = $script:TestLines[$script:TestIdx % $script:TestLines.Count]
                $script:TestIdx++
            }
        } else {
            if (-not (Test-Path $script:TxtPath)) { return }
            if ((Get-Item $script:TxtPath).Length -eq 0) { return }
            $lines = Get-Content $script:TxtPath -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $lines) { return }
            $last = ($lines | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
            if (-not $last) { return }
            $last = $last.Trim()
            if ($last -eq $script:LastLine) { return }
            $script:LastLine = $last
        }
        if (-not $last) { return }

        # ---- 幻觉过滤：静音时 whisper 会自己编片尾语，丢掉 ----
        if (Test-Hallucination $last) {
            Dbg "丢弃（幻觉/空白）: $last"
            return
        }

        $script:LastNewTime = Get-Date
        $lblJa.Text = $last
        $lblZh.ForeColor = $script:LiveColor
        Dbg "新句子: $last"
        $script:Busy = $true
        try {
            if ([bool]$cfg.translateEnabled) {
                $zh = & $script:DoTranslate $last
                if ($zh) { $lblZh.Text = $zh } else { $lblZh.Text = '（翻译未返回）' }
                Dbg "译文: $zh"
            } else {
                # 关掉翻译：不调接口，主行直接显示识别出的原文
                $lblZh.Text = $last
                $lblJa.Text = ''
                Dbg "翻译已关闭，只显示原文"
            }
        } finally { $script:Busy = $false }
    })
    $timer.Start()
    Dbg "定时器已启动"

    # ---------- 5d. 全局热键 Ctrl+Alt+Z：一键切换「挡不挡鼠标」 ----------
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;
public class HKFilter : IMessageFilter {
    public static Action HotKeyAction;
    public bool PreFilterMessage(ref Message m) {
        if (m.Msg == 0x0312) { if (HotKeyAction != null) HotKeyAction(); return true; }
        return false;
    }
}
'@ -ReferencedAssemblies 'System.Windows.Forms'
        Add-Type -Namespace W -Name HK -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
'@
        $script:Filter = New-Object HKFilter
        [System.Windows.Forms.Application]::AddMessageFilter($script:Filter)
        [HKFilter]::HotKeyAction = [Action]{
            try {
                Set-ClickThrough (-not [bool]$cfg.clickThrough)
                Save-Cfg
                $tip = if ([bool]$cfg.clickThrough) { '已开启穿透：不再挡播放器' } else { '已关闭穿透：现在可以拖字幕条' }
                $tray.ShowBalloonTip(2500, '实时字幕', $tip, [System.Windows.Forms.ToolTipIcon]::Info)
            } catch { }
        }
        # 按配置决定要不要注册：嫌组合键难记，可以在「设置 → 高级」里关掉
        if ([bool]$cfg.hotkeyEnabled) {
            $script:HotKeyOk = [W.HK]::RegisterHotKey($form.Handle, 1, 0x0001 -bor 0x0002, 0x5A)
            Dbg "全局热键 Ctrl+Alt+Z 注册: $($script:HotKeyOk)"
        } else {
            $script:HotKeyOk = $false
            Dbg "全局热键已在设置里关闭，跳过注册"
        }
    } catch { Dbg "热键初始化失败: $($_.Exception.Message)" }

    # 窗口真正显示后再设穿透
    $form.Add_Shown({
        if ([bool]$cfg.clickThrough) { Set-ClickThrough $true }
        Dbg "穿透已应用: $($cfg.clickThrough)"
        if ($TestMode) {
            $script:ShotTimer = New-Object Windows.Forms.Timer
            $script:ShotTimer.Interval = 4000
            $script:ShotTimer.Add_Tick({
                $script:ShotTimer.Stop()
                Dbg "截图模式：自动打开设置窗口"
                try { Show-Settings } catch { Dbg "截图模式打开设置失败: $($_.Exception.Message)" }
            })
            $script:ShotTimer.Start()
        }
    })

    # 退出时收拾干净
    $form.Add_FormClosing({
        Dbg "窗体关闭中"
        $timer.Stop()
        Save-Cfg
        try { $tray.Visible = $false; $tray.Dispose() } catch { }
        if ($script:Ws -and -not $script:Ws.HasExited) { $script:Ws.Kill() }
    })

    [void]$form.Show()
    Dbg "窗体已 Show，进入消息循环"
    [System.Windows.Forms.Application]::Run($form)
    Dbg "消息循环结束，脚本退出"
}
catch {
    Dbg ("致命异常: " + $_.Exception.ToString())
    if ($script:Ws -and -not $script:Ws.HasExited) { try { $script:Ws.Kill() } catch { } }
}
