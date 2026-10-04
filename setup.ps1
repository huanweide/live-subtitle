#Requires -Version 5.1
<#
    实时字幕 · 一键安装
    ==========================================================
    这个脚本替你把三件最麻烦的事办完：
        1. 下载识别引擎（whisper.cpp 官方预编译包）
        2. 下载识别模型（默认 large-v3-turbo，约 1.55 GB）
        3. 翻出你电脑上的录音设备，把配置文件写好

    怎么用：
        右键这个文件 →「使用 PowerShell 运行」
        或者在这个目录里执行：
            powershell -ExecutionPolicy Bypass -File .\setup.ps1

    可选开关（普通人不用管）：
        -Cpu              强制按「没有独显」处理，不下 643 MB 的 CUDA 包
        -ModelName small  换模型。可选 large-v3-turbo / medium / small / base
        -DeviceId 3       手动指定录音设备编号，跳过自动探测
        -Yes              全部按默认答案走，不问你
        -SkipEngine       引擎已经装好了，只补模型
        -SkipModel        模型已经下好了，只补引擎

    断点续传：
        下载中途断了没关系，重新跑一次这个脚本，它会接着下。
#>
[CmdletBinding()]
param(
    [switch]$Cpu,
    [string]$ModelName = '',
    [int]   $DeviceId  = -1,
    [switch]$Yes,
    [switch]$SkipEngine,
    [switch]$SkipModel
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
Set-Location -LiteralPath $Root

$script:TotalStep = 7

# ============================================================
# 0. 输出和询问
# ============================================================
function Say  { param([string]$m = '') Write-Host $m }
function Step {
    param([int]$No, [string]$Title)
    Write-Host ''
    Write-Host ("──── 第 {0} 步 / {1}：{2}" -f $No, $script:TotalStep, $Title) -ForegroundColor Cyan
}
function Ok   { param([string]$m) Write-Host "   [OK] $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "   [!]  $m" -ForegroundColor Yellow }
function Bad  { param([string]$m) Write-Host "   [X]  $m" -ForegroundColor Red }
function Note { param([string]$m) Write-Host "        $m" -ForegroundColor DarkGray }

function Confirm-Step {
    param([string]$Question, [bool]$Default = $true)
    if ($Yes) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        Write-Host ''
        Write-Host "   $Question $hint " -NoNewline
        $a = Read-Host
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        if ($a -match '^(y|Y|yes|YES|是|好|行|嗯|对)') { return $true }
        if ($a -match '^(n|N|no|NO|否|不|别)')       { return $false }
    }
}

# ============================================================
# 1. 下载（带进度条 + 断点续传）
# ============================================================
function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Label = '文件'
    )
    $tmp  = "$Dest.part"
    $have = 0
    if (Test-Path -LiteralPath $tmp) {
        $have = (Get-Item -LiteralPath $tmp).Length
        if ($have -gt 0) { Warn ("发现上次没下完的临时文件（{0:N1} MB），接着下" -f ($have / 1MB)) }
    }

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent            = 'subtitle-toolkit-setup/1.0'
    $req.Timeout              = 30000
    $req.ReadWriteTimeout     = 600000
    $req.AllowAutoRedirect    = $true
    $req.KeepAlive            = $true
    if ($have -gt 0) { [void]$req.AddRange([long]$have) }

    $resp = $null
    try { $resp = $req.GetResponse() }
    catch {
        if ($have -gt 0) {
            Warn '上次的临时文件服务器接不上，从头下一遍'
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return Get-RemoteFile -Url $Url -Dest $Dest -Label $Label
        }
        throw
    }

    try {
        $code = [int]$resp.StatusCode
        if ($have -gt 0 -and $code -ne 206) {
            $resp.Close()
            Warn '服务器不支持断点续传，从头下一遍'
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return Get-RemoteFile -Url $Url -Dest $Dest -Label $Label
        }

        $remain = [long]$resp.ContentLength
        $whole  = $remain + $have
        if ($whole -gt 0) {
            Note ("一共 {0:N0} MB，目标文件：{1}" -f ($whole / 1MB), (Split-Path $Dest -Leaf))
        }

        $stream = $resp.GetResponseStream()
        $fs = if ($have -gt 0) {
            [System.IO.File]::Open($tmp, [System.IO.FileMode]::Append)
        } else {
            [System.IO.File]::Create($tmp)
        }

        try {
            $buf  = New-Object byte[] (1048576)
            $done = $have
            $sw   = [System.Diagnostics.Stopwatch]::StartNew()
            $lastBytes = $have
            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n)
                $done += $n
                if ($sw.ElapsedMilliseconds -ge 800) {
                    $spd = ($done - $lastBytes) / 1MB / ($sw.ElapsedMilliseconds / 1000.0)
                    $lastBytes = $done
                    $sw.Restart()
                    $pct = if ($whole -gt 0) { [int]($done * 100 / $whole) } else { 0 }
                    if ($pct -gt 100) { $pct = 100 }
                    $st = "{0:N1} / {1:N1} MB   {2:N1} MB/s" -f ($done / 1MB), ($whole / 1MB), $spd
                    try {
                        Write-Progress -Activity "$Label" -Status $st -PercentComplete $pct
                    } catch { }
                }
            }
        } finally {
            $fs.Close()
            $stream.Close()
            try { Write-Progress -Activity "$Label" -Completed } catch { }
        }
    } finally {
        try { $resp.Close() } catch { }
    }

    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
    Move-Item -LiteralPath $tmp -Destination $Dest -Force
    Ok ("$Label 下好了（{0:N1} MB）" -f ((Get-Item -LiteralPath $Dest).Length / 1MB))
}

# ============================================================
# 2. 去 GitHub 找带安装包的那一版 whisper.cpp
#    坑：whisper.cpp 会先发一个只有版本号的「空壳」release（assets 是 0），
#        安装包挂在紧随其后的另一个 tag 下面。所以不能直接用 releases/latest。
# ============================================================
function Find-EngineAsset {
    param([string]$AssetName)
    $api = 'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=20'
    Note '正在问 GitHub：whisper.cpp 有哪些版本…'
    $rels = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'subtitle-toolkit-setup' } -TimeoutSec 30
    foreach ($r in $rels) {
        foreach ($a in @($r.assets)) {
            if ("$($a.name)" -eq $AssetName) {
                return [pscustomobject]@{
                    Tag  = $r.tag_name
                    Name = "$($a.name)"
                    Size = [long]$a.size
                    Url  = "$($a.browser_download_url)"
                }
            }
        }
    }
    return $null
}

# ============================================================
# 3. 列录音设备（只列正在工作的）
#    Windows 没有现成命令，只能翻注册表。
# ============================================================
function Get-CaptureDeviceList {
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
    $out  = New-Object System.Collections.ArrayList
    if (-not (Test-Path $base)) { return @() }
    foreach ($k in @(Get-ChildItem $base -ErrorAction SilentlyContinue)) {
        $state = $null
        try { $state = (Get-ItemProperty -LiteralPath $k.PSPath -Name DeviceState -ErrorAction Stop).DeviceState } catch { }
        if ($state -ne 1) { continue }        # 1 = 正在工作；其余是没插、被禁用、已拔出
        $nm = $null
        try {
            $props = Get-ItemProperty -LiteralPath (Join-Path $k.PSPath 'Properties') -ErrorAction SilentlyContinue
            if ($props) { $nm = $props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2' }
        } catch { }
        if (-not [string]::IsNullOrWhiteSpace($nm)) {
            [void]$out.Add([pscustomobject]@{ Name = "$nm"; Key = $k.PSChildName })
        }
    }
    return $out.ToArray()
}

# ============================================================
# 4. 试某个设备编号：放一段英文测试音，看能不能识别出来
# ============================================================
function Test-CaptureDevice {
    param(
        [int]$Id,
        [string]$WsExe,
        [string]$Model,
        [int]$WaitSeconds = 9
    )
    $tag  = "selftest-$Id"
    $txt  = Join-Path $env:TEMP "$tag.txt"
    $outL = Join-Path $env:TEMP "$tag-out.log"
    $errL = Join-Path $env:TEMP "$tag-err.log"
    foreach ($f in @($txt, $outL, $errL)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

    $speaker = $null
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $speaker.Rate   = -1
        $speaker.Volume = 100
    } catch { }

    $p = $null
    try {
        $p = Start-Process -FilePath $WsExe `
             -ArgumentList @('-m', $Model, '-l', 'en', '-t', '8', '-c', "$Id",
                             '--step', '1500', '--length', '4000', '-vth', '0.45', '-f', $txt) `
             -PassThru -WindowStyle Hidden -RedirectStandardOutput $outL -RedirectStandardError $errL
    } catch {
        return ''
    }

    if ($speaker) {
        Start-Sleep -Milliseconds 2600        # 等模型加载完再出声
        try { $speaker.Speak('good morning. this is a test of the subtitle device. one two three four five.') } catch { }
    }
    Start-Sleep -Seconds $WaitSeconds
    if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } }
    try { if ($speaker) { $speaker.Dispose() } } catch { }
    Start-Sleep -Milliseconds 500

    $got = ''
    if (Test-Path -LiteralPath $txt) {
        try { $got = (Get-Content -LiteralPath $txt -Raw -Encoding UTF8) } catch { }
    }
    return "$got"
}

# ============================================================
# 5. 找找机器上是不是已经躺着模型了（省 1.55 GB 下载）
# ============================================================
function Find-ExistingModel {
    param([string]$FileName)
    $cands = @(
        (Join-Path $Root "models\$FileName"),
        (Join-Path $env:LOCALAPPDATA "github.com.thewh1teagle.vibe\$FileName"),
        (Join-Path $env:USERPROFILE ".cache\whisper\$FileName")
    )
    foreach ($c in $cands) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return ''
}

# ============================================================
#                        主流程
# ============================================================
Clear-Host
Write-Host ''
Write-Host '  实时字幕 · 一键安装' -ForegroundColor White
Write-Host '  --------------------------------' -ForegroundColor DarkGray
Say  '  这个脚本会下载两个大文件、找出你的录音设备、写好配置。'
Say  '  全程不需要你懂技术，遇到问题它会说清楚哪一步不对。'

# ---------- 第 1 步：摸家底 ----------
Step 1 '先看看这台电脑'
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Bad "需要 PowerShell 5.1 或更高，你这里是 $($PSVersionTable.PSVersion)"
    exit 1
}
Ok "PowerShell $($PSVersionTable.PSVersion)"
if (-not [Environment]::Is64BitOperatingSystem) {
    Bad '需要 64 位 Windows'
    exit 1
}
Ok '64 位 Windows'
Note "安装位置：$Root"

$free = $null
try {
    $d = (Get-Item -LiteralPath $Root).PSDrive
    $free = (Get-PSDrive -Name $d.Name -ErrorAction Stop).Free
} catch { }
if ($free) {
    Ok ("这个盘还剩 {0:N1} GB 空间" -f ($free / 1GB))
    if ($free -lt 4GB) {
        Warn '空间可能不够（引擎 + 模型加起来最多约 2.3 GB），建议先清点空间'
    }
}

# ---------- 第 2 步：下引擎 ----------
Step 2 '看显卡，决定下哪个识别引擎'

$hasNv = $false
$nvName = ''
try {
    $vc = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
    foreach ($v in $vc) { Note ("显卡：" + $v.Name) }
    $nv = @($vc | Where-Object { "$($_.Name)" -match 'NVIDIA' })
    if ($nv.Count -gt 0) { $hasNv = $true; $nvName = "$($nv[0].Name)" }
} catch {
    Warn "读显卡信息失败：$($_.Exception.Message)"
}
if ($Cpu) { $hasNv = $false; Note '（你指定了 -Cpu，按没有独显处理）' }

if ($hasNv) {
    Ok "找到 NVIDIA 显卡：$nvName"
    Note '走显卡路线，识别快，能做到实时'
    $engineZip = 'whisper-cublas-12.4.0-bin-x64.zip'
    $engineDir = 'whispercpp-gpu'
} else {
    Warn '没找到 NVIDIA 显卡'
    Note '走 CPU 路线，能跑但慢一些，模型也会自动换小一号'
    $engineZip = 'whisper-bin-x64.zip'
    $engineDir = 'whispercpp'
}

$wsExe     = Join-Path $Root "$engineDir\Release\whisper-stream.exe"
$engineZipPath = Join-Path $Root $engineZip
$needEngine = $true

if ($SkipEngine) {
    $needEngine = $false
    Note '（你说了跳过引擎下载）'
} elseif (Test-Path -LiteralPath $wsExe) {
    Ok "识别引擎已经在了：$wsExe"
    $needEngine = $false
    if (Confirm-Step '要不要重新下载一份覆盖它？' $false) { $needEngine = $true }
}

if ($needEngine) {
    Note "要下的文件：$engineZip"
    $url = $null
    try {
        $found = Find-EngineAsset -AssetName $engineZip
        if ($found) {
            $url = $found.Url
            Ok ("找到安装包，来自 {0} 版（{1:N1} MB）" -f $found.Tag, ($found.Size / 1MB))
        } else {
            Bad "在最近 20 个版本里没找到 $engineZip"
        }
    } catch {
        Bad "连不上 GitHub：$($_.Exception.Message)"
        Note '如果你这台机器需要代理才能上 GitHub，先把代理打开再跑一次'
    }
    if (-not $url) {
        Bad '引擎没下成，装不下去了'
        Say  '  你可以手动下：打开 https://github.com/ggml-org/whisper.cpp/releases'
        Say  "  找到带 $engineZip 的那一版，下下来放到这个目录，再跑一次本脚本。"
        exit 1
    }

    if (Test-Path -LiteralPath $engineZipPath) { Remove-Item -LiteralPath $engineZipPath -Force }
    Get-RemoteFile -Url $url -Dest $engineZipPath -Label '识别引擎'
}

# ---------- 第 3 步：解压 ----------
Step 3 '把引擎解开'

if ($needEngine) {
    if (-not (Test-Path -LiteralPath $engineZipPath)) {
        Bad "压缩包不见了：$engineZipPath"
        exit 1
    }
    $destDir = Join-Path $Root $engineDir
    if (Test-Path -LiteralPath $destDir) {
        Note "清掉旧的 $engineDir 目录"
        Remove-Item -LiteralPath $destDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($engineZipPath, $destDir)
        Ok '解压完成'
    } catch {
        Bad "解压失败：$($_.Exception.Message)"
        exit 1
    }
    Remove-Item -LiteralPath $engineZipPath -Force -ErrorAction SilentlyContinue
    Note '删掉了压缩包，省空间'
} else {
    Note '引擎没动，跳过这步'
}

if (-not (Test-Path -LiteralPath $wsExe)) {
    Bad "没看到引擎主程序：$wsExe"
    if ($SkipEngine) { Note '去掉 -SkipEngine 再跑一次，让它自动下载引擎' }
    else { Note '可能是这个版本的目录结构和预期不一样，请把上面的路径贴给作者' }
    exit 1
}
Ok "引擎就位：$wsExe"

# ---------- 第 4 步：下模型 ----------
Step 4 '下识别模型'

if ([string]::IsNullOrWhiteSpace($ModelName)) {
    $ModelName = if ($hasNv) { 'large-v3-turbo' } else { 'small' }
}
$modelMap = @{
    'large-v3-turbo' = 'ggml-large-v3-turbo.bin'
    'large'          = 'ggml-large-v3.bin'
    'medium'         = 'ggml-medium.bin'
    'small'          = 'ggml-small.bin'
    'base'           = 'ggml-base.bin'
}
if (-not $modelMap.ContainsKey($ModelName)) {
    Warn "不认识的模型名 $ModelName，改用 small"
    $ModelName = 'small'
}
$modelFile = $modelMap[$ModelName]
Note "选定模型：$ModelName（$modelFile）"
if ($hasNv) { Note '大模型更准，你显卡扛得住' } else { Note 'CPU 机器用小模型才跟得上语速' }

$modelDir  = Join-Path $Root 'models'
$modelFull = Join-Path $modelDir $modelFile
$needModel = $true

# 这台机器上是不是已经有这个模型了？项目目录、Vibe 的缓存目录都会翻一遍
$existing = Find-ExistingModel -FileName $modelFile

if ($SkipModel) {
    if ($existing) {
        $modelFull = $existing
        Ok "用现成的模型：$modelFull"
    } else {
        Bad "你说了跳过下载，可这台机器上没找到 $modelFile"
        Note '去掉 -SkipModel 再跑一次，让它自己下'
        exit 1
    }
    $needModel = $false
} elseif ($existing) {
    if ("$existing" -eq "$modelFull") {
        Ok "模型已经在了：$modelFull"
        if (Confirm-Step '要不要重新下载一份覆盖它？' $false) { $needModel = $true } else { $needModel = $false }
    } else {
        Ok "在这台机器上找到了现成的模型：$existing"
        if (Confirm-Step '直接用它，省掉 1.5 GB 下载？' $true) {
            $modelFull = $existing
            $needModel = $false
        }
    }
}

if ($needModel) {
    if (-not (Test-Path -LiteralPath $modelDir)) { New-Item -ItemType Directory -Path $modelDir -Force | Out-Null }
    $modelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$modelFile"
    Note '下载源：HuggingFace 官方（模型文件本身来自 OpenAI，MIT 许可）'
    Note '国内如果太慢，可以手动去 hf-mirror.com 下同一个文件，放进来再跑一次'
    try {
        Get-RemoteFile -Url $modelUrl -Dest $modelFull -Label '识别模型'
    } catch {
        Bad "模型没下成：$($_.Exception.Message)"
        Say  '  重新跑一次这个脚本就能接着下（断点续传）。'
        exit 1
    }
}

# ---------- 第 5 步：找录音设备 ----------
Step 5 '找出你的录音设备'

$pick = -1
if ($DeviceId -ge 0) {
    $pick = $DeviceId
    Ok "你指定了设备编号 $pick"
} else {
    $devs = @(Get-CaptureDeviceList)
    if ($devs.Count -eq 0) {
        Bad '没找到任何正在工作的录音设备'
        Note '先确认「立体声混音」开着：右键任务栏喇叭 → 声音设置 → 更多声音设置 → 录制'
        exit 1
    }
    Say  ''
    Say  ("  你电脑上正在工作的录音设备有 {0} 个：" -f $devs.Count)
    for ($i = 0; $i -lt $devs.Count; $i++) {
        Say ("     [{0}] {1}" -f $i, $devs[$i].Name)
    }
    Say  ''
    Note '想要录「电脑自己放出来的声音」，应该选「立体声混音」'
    Note '如果列表里没有它：右键任务栏喇叭 → 声音设置 → 更多声音设置 → 录制 → 右键空白处 → 显示已禁用的设备 → 把「立体声混音」启用'

    $prefer = -1
    for ($i = 0; $i -lt $devs.Count; $i++) {
        if ($devs[$i].Name -match '立体声混音|Stereo Mix|What U Hear|Wave Out|loopback') { $prefer = $i; break }
    }
    if ($prefer -ge 0) { Ok ("默认帮你选好了：[{0}] {1}" -f $prefer, $devs[$prefer].Name) }

    if ($Yes) {
        $pick = if ($prefer -ge 0) { $prefer } else { 0 }
    } else {
        Say ''
        Say  "  请输入编号（直接回车 = $prefer ）：" -NoNewline
        $ans = Read-Host
        if ([string]::IsNullOrWhiteSpace($ans) -and $prefer -ge 0) {
            $pick = $prefer
        } elseif ($ans -match '^\d+$') {
            $pick = [int]$ans
        } else {
            $pick = if ($prefer -ge 0) { $prefer } else { 0 }
        }
        Ok "用编号 $pick"
    }

    # 自检：放一段英文，看这个编号到底有没有声音进来。
    # 说明：系统列设备的顺序和识别引擎内部的编号不保证一一对应，所以要真试。
    Say ''
    $tested = $false
    $good   = -1
    if (Confirm-Step '要不要现在真试一下这个编号？（放一段英文，约 10 秒）' $true) {
        $tested = $true
        $order = @($pick)
        for ($i = 0; $i -lt $devs.Count; $i++) { if ($i -ne $pick) { $order += $i } }
        $good = -1
        foreach ($id in $order) {
            Say ("     试编号 {0}（{1}）…" -f $id, $devs[$id].Name)
            $r = Test-CaptureDevice -Id $id -WsExe $wsExe -Model $modelFull
            if ($r -match '\w') {
                Ok ("编号 {0} 能听到声音，识别出：{1}" -f $id, ($r.Trim() -replace "`r?`n", ' '))
                $good = $id
                break
            }
        }
        if ($good -ge 0) {
            $pick = $good
        } else {
            Warn '逐个试过了，都没听到声音'
            Note '常见原因：系统正在放声音才有得录；或者「立体声混音」没启用'
            Note '先用现在这个编号，回头在设置里换也行'
        }
    }
}

# ---------- 第 6 步：写配置 ----------
Step 6 '写配置文件'

$cfgPath = Join-Path $Root 'subtitle-config.json'
$defaults = [ordered]@{
    fontSizeZh    = 32
    fontSizeJa    = 18
    zhColor       = '#FFFFFF'
    jaColor       = '#9AD0FF'
    bgColor       = '#101010'
    opacity       = 0.72
    left          = 200
    top           = 800
    width         = 1500
    height        = 190
    showJapanese  = $true
    holdSeconds   = 10
    sourceLang    = 'ja'
    mode          = 'both'
    clickThrough  = $false
    captureDevice = $pick
    modelPath     = $modelFull
    whisperStream = $wsExe
}
$saved = $null
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $saved = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($defaults.Keys)) {
            if ($null -ne $saved.$k) { $defaults[$k] = $saved.$k }
        }
        Note '保留了配置文件里你原来的设置（字号、位置、语言等）'
    } catch {
        Warn '原来的配置文件读不动，这次会整份重写'
    }
}
# 模型和引擎是本次安装的结果，直接覆盖
$defaults['modelPath']     = $modelFull
$defaults['whisperStream'] = $wsExe

# 设备编号讲究一点：自检真的听到声音，才敢替你改；
# 没听到就尊重你原来的选择；全新安装才写推荐值，并提醒「不出字就换一个」。
if ($good -ge 0) {
    $defaults['captureDevice'] = $pick
    Note ("设备编号用自检试出来的：{0}" -f $pick)
} elseif ($null -ne $saved -and $null -ne $saved.captureDevice) {
    Note ("设备编号保持你原来的：{0}" -f $defaults['captureDevice'])
} else {
    $defaults['captureDevice'] = $pick
    Note ("先按推荐编号 {0} 写上；万一不出字，在设置里换一个就行" -f $pick)
}

$defaults | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
Ok "配置写好了：$cfgPath"
Note ("设备编号 {0} / 语言 {1} / 模型 {2}" -f $pick, $defaults['sourceLang'], (Split-Path $modelFull -Leaf))

# ---------- 第 7 步：收尾 ----------
Step 7 '收尾'

$bat = Join-Path $Root '启动字幕.bat'
if (Test-Path -LiteralPath $bat) {
    Ok '启动器在：启动字幕.bat'
} else {
    Note '没找到 启动字幕.bat，你可以直接跑：'
    Note ('powershell -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $Root '实时字幕.ps1'))
}

Write-Host ''
Write-Host '  装完了。' -ForegroundColor Green
Write-Host ''
Say  '  接下来这么用：'
Say  '    1. 双击「启动字幕.bat」，或者双击桌面上的「实时字幕」快捷方式'
Say  '    2. 第一次启动要加载模型，等 5 到 10 秒'
Say  '    3. 右下角托盘冒出一个小图标，说明它在工作了'
Say  '    4. 让电脑放出声音（放视频、放歌都行），字幕条上就会出字'
Write-Host ''
Say  '  想改设置：双击黑色字幕条，或者在托盘图标上点右键'
Say  '  想换识别语言：设置窗口最下面「识别语言」，选完点「应用并保存」'
Write-Host ''
Say  '  出问题看这两个文件：'
Say  ("    " + (Join-Path $Root 'debug.log') + "    运行日志")
Say  ("    " + (Join-Path $Root 'ws-live.txt') + "  识别出来的原始文字")
Write-Host ''
if (-not $hasNv -and -not $Cpu) {
    Warn '你是 CPU 跑的，如果字幕跟不上语速，可以换更小的模型：'
    Note '再跑一次 setup.ps1 -ModelName base'
}
