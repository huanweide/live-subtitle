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
    [string]$ModelPath      = 'C:\Users\Administrator\AppData\Local\github.com.thewh1teagle.vibe\ggml-large-v3-turbo.bin',
    [string]$WhisperStream  = 'D:\Retri\subtitle-toolkit\whispercpp-gpu\Release\whisper-stream.exe',
    [int]   $CaptureDevice  = 2,
    [string]$SourceLang     = 'ja',   # 默认识别语言；配置文件里的 sourceLang 优先
    [string]$ApiKeyFile     = 'D:\Retri\sf_review_fast.py',
    [string]$ApiUrl         = 'https://api.siliconflow.cn/v1/chat/completions',
    [string]$TranslateModel = 'Qwen/Qwen2.5-7B-Instruct',
    [switch]$TestMode
)

$script:Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DbgPath = Join-Path $script:Root 'debug.log'
Remove-Item $script:DbgPath -ErrorAction SilentlyContinue

function Dbg([string]$m) {
    try {
        Add-Content -LiteralPath $script:DbgPath -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8
    } catch { }
}

Dbg "脚本开始，Root=$script:Root  TestMode=$TestMode"

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
        mode           = 'both'  # both=双语 / zhOnly=只有中文 / jaOnly=只有原文
        clickThrough   = $false  # 默认能被鼠标点中（能拖、能滚轮）；看片时从托盘打开穿透
        captureDevice  = $CaptureDevice  # 录音设备编号；换电脑时装在这台机器上的值说了算
        modelPath      = "$ModelPath"    # 识别模型文件路径；同上
        whisperStream  = "$WhisperStream"  # 识别引擎路径；同上
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
    $script:EffDevice = if ($null -ne $cfg.captureDevice) { [int]$cfg.captureDevice } else { [int]$CaptureDevice }
    $script:EffModel  = if ("$($cfg.modelPath)" -ne '')     { "$($cfg.modelPath)" }     else { "$ModelPath" }
    $script:EffWs     = if ("$($cfg.whisperStream)" -ne '') { "$($cfg.whisperStream)" } else { "$WhisperStream" }
    Dbg "生效设备=$($script:EffDevice) 模型=$($script:EffModel) 引擎=$($script:EffWs)"

    function Save-Cfg {
        try { $cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $script:CfgPath -Encoding UTF8 } catch { }
    }
    # 启动就落一次盘：保证配置文件一定存在，也方便直接改文件
    Save-Cfg

    # ---------- 2. 取翻译密钥（不回显） ----------
    $script:ApiKey = $env:SILICONFLOW_API_KEY
    if (-not $script:ApiKey -and (Test-Path $ApiKeyFile)) {
        $m = [regex]::Match((Get-Content $ApiKeyFile -Raw), 'KEY\s*=\s*"([^"]+)"')
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
        if ($lang -eq 'auto' -or -not $script:LangNames.Contains($lang)) {
            $ask = "把下面这句字幕翻译成简体中文。只输出译文本身，不要解释、不要加引号、不要保留原文："
        } else {
            $nm = $script:LangNames[$lang]
            $ask = "把下面这句${nm}字幕翻译成简体中文。只输出译文本身，不要解释、不要加引号、不要保留${nm}原文："
        }
        $prompt = $ask + "`n" + $text
        $body = @{
            model       = $TranslateModel
            messages    = @(@{ role = 'user'; content = $prompt })
            max_tokens  = 300
            temperature = 0.1
            stream      = $false
        } | ConvertTo-Json -Depth 6 -Compress
        try {
            $r = Invoke-RestMethod -Uri $ApiUrl -Method Post `
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
        if (-not (Test-Path $script:EffWs))    { throw "找不到 whisper-stream.exe：$($script:EffWs)" }
        if (-not (Test-Path $script:EffModel)) { throw "找不到模型文件：$($script:EffModel)" }
        Remove-Item $script:TxtPath -ErrorAction SilentlyContinue
        Start-Whisper
    }

    # ---------- 5. 窗口 ----------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = '实时字幕'
    $form.FormBorderStyle = 'None'
    $form.TopMost         = $true
    $form.ShowInTaskbar   = $false
    $form.BackColor       = [Drawing.ColorTranslator]::FromHtml($cfg.bgColor)
    $form.Opacity         = [double]$cfg.opacity
    $form.StartPosition   = 'Manual'
    $form.Location        = New-Object Drawing.Point([int]$cfg.left, [int]$cfg.top)
    $form.Size            = New-Object Drawing.Size([int]$cfg.width, [int]$cfg.height)
    Dbg "窗体属性设置完成"

    $lblJa               = New-Object System.Windows.Forms.Label
    $lblJa.Dock          = 'Top'
    $lblJa.Height        = 56
    $lblJa.AutoSize      = $false
    $lblJa.TextAlign     = 'MiddleCenter'
    $lblJa.ForeColor     = [Drawing.ColorTranslator]::FromHtml($cfg.jaColor)
    $lblJa.BackColor     = [Drawing.Color]::Transparent
    $lblJa.Font          = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeJa)
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
    $lblZh.ForeColor     = $script:IdleColor
    $lblZh.BackColor     = [Drawing.Color]::Transparent
    $lblZh.Font          = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeZh, [Drawing.FontStyle]::Bold)
    $lblZh.Text          = $script:IdleText

    $form.Controls.Add($lblZh)
    $form.Controls.Add($lblJa)
    Dbg "标签创建完成"

    # 按模式决定谁显示
    function Apply-Mode {
        switch ("$($cfg.mode)") {
            'zhOnly' { $lblJa.Visible = $false; $lblZh.Visible = $true }
            'jaOnly' { $lblJa.Visible = $true;  $lblZh.Visible = $false }
            default  { $lblJa.Visible = [bool]$cfg.showJapanese; $lblZh.Visible = $true }
        }
    }
    Apply-Mode

    # 拖动
    $script:Dragging = $false
    $script:DragPt   = New-Object Drawing.Point(0, 0)
    $onDown = {
        $script:Dragging = $true
        $script:DragPt   = [System.Windows.Forms.Cursor]::Position
    }
    $onMove = {
        if ($script:Dragging) {
            $p = [System.Windows.Forms.Cursor]::Position
            $form.Location = New-Object Drawing.Point(
                ($form.Location.X + $p.X - $script:DragPt.X),
                ($form.Location.Y + $p.Y - $script:DragPt.Y))
            $script:DragPt = $p
        }
    }
    $onUp = { $script:Dragging = $false }
    foreach ($c in @($form, $lblJa, $lblZh)) {
        $c.Add_MouseDown($onDown)
        $c.Add_MouseMove($onMove)
        $c.Add_MouseUp($onUp)
    }

    # 滚轮调字号
    $onWheel = {
        $d = [Math]::Sign($_.Delta)
        $cfg.fontSizeZh = [Math]::Max(14, [Math]::Min(80, [int]$cfg.fontSizeZh + $d * 2))
        $cfg.fontSizeJa = [Math]::Max(10, [Math]::Min(50, [int]$cfg.fontSizeJa + $d))
        $lblZh.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeZh, [Drawing.FontStyle]::Bold)
        $lblJa.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeJa)
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
    })
    Dbg "托盘菜单完成"

    $tray           = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon      = [System.Drawing.SystemIcons]::Application
    $tray.Text      = '实时字幕（右键设置）'
    $tray.ContextMenuStrip = $menu
    $tray.Visible   = $true
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

    function Show-Settings {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text            = '实时字幕 · 设置'
        $dlg.ClientSize      = New-Object Drawing.Size(520, 524)
        $dlg.StartPosition   = 'CenterScreen'
        $dlg.TopMost         = $true
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox     = $false
        $dlg.MinimizeBox     = $false
        $dlg.Font            = New-Object Drawing.Font('微软雅黑', 10)

        $ly = 20
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
        $ly += 46

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
        $ly += 46

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
        $ly += 46

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
        $ly += 46

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
        $ly += 46

        $ck1 = New-Object System.Windows.Forms.CheckBox
        $ck1.Text = '鼠标点不到字幕条（看片时开；开了它就拖不动）'
        $ck1.Location = New-Object Drawing.Point(20, $ly); $ck1.Size = New-Object Drawing.Size(470,26)
        $ck1.Checked = [bool]$cfg.clickThrough
        $dlg.Controls.Add($ck1)
        $ly += 40

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = '应用并保存'
        $btnOk.Location = New-Object Drawing.Point(120, $ly); $btnOk.Size = New-Object Drawing.Size(140, 34)
        $dlg.Controls.Add($btnOk)
        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = '关闭'
        $btnClose.Location = New-Object Drawing.Point(290, $ly); $btnClose.Size = New-Object Drawing.Size(110, 34)
        $dlg.Controls.Add($btnClose)

        $tip = New-Object System.Windows.Forms.Label
        $tip.Text = '改完点「应用并保存」，立刻生效。字幕条可以按住拖动。'
        $tip.Location = New-Object Drawing.Point(20, ($ly+50)); $tip.Size = New-Object Drawing.Size(470, 24)
        $tip.ForeColor = [Drawing.Color]::Gray
        $dlg.Controls.Add($tip)

        $btnOk.Add_Click({
            $cfg.fontSizeZh  = [int]$n1.Value
            $cfg.fontSizeJa  = [int]$n2.Value
            $cfg.holdSeconds = [int]$n3.Value
            $cfg.opacity     = [double]$n4.Value
            if ($r2.Checked) { $cfg.mode = 'zhOnly' }
            elseif ($r3.Checked) { $cfg.mode = 'jaOnly' }
            else { $cfg.mode = 'both'; $cfg.showJapanese = $true }
            Set-ClickThrough ([bool]$ck1.Checked)
            $form.Opacity = [double]$cfg.opacity
            $lblZh.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeZh, [Drawing.FontStyle]::Bold)
            $lblJa.Font = New-Object Drawing.Font('微软雅黑', [float]$cfg.fontSizeJa)
            Apply-Mode

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
        $btnClose.Add_Click({ $dlg.Close() })

        [void]$dlg.ShowDialog($form)
    }

    # ---------- 5e. 字幕条自己也能右键 / 双击 ----------
    # 之前右键菜单只挂在托盘图标上，在黑条上点右键当然没反应
    foreach ($c in @($form, $lblJa, $lblZh)) { $c.ContextMenuStrip = $menu }
    foreach ($c in @($form, $lblJa, $lblZh)) {
        $c.Add_DoubleClick({ try { Show-Settings } catch { Dbg "设置窗口出错: $($_.Exception.Message)" } })
    }
    Dbg "字幕条右键菜单 / 双击设置已挂上"

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
            $zh = & $script:DoTranslate $last
            if ($zh) { $lblZh.Text = $zh } else { $lblZh.Text = '（翻译未返回）' }
            Dbg "译文: $zh"
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
        $script:HotKeyOk = [W.HK]::RegisterHotKey($form.Handle, 1, 0x0001 -bor 0x0002, 0x5A)
        Dbg "全局热键 Ctrl+Alt+Z 注册: $($script:HotKeyOk)"
    } catch { Dbg "热键初始化失败: $($_.Exception.Message)" }

    # 窗口真正显示后再设穿透
    $form.Add_Shown({
        if ([bool]$cfg.clickThrough) { Set-ClickThrough $true }
        Dbg "穿透已应用: $($cfg.clickThrough)"
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
