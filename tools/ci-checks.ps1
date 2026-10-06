#Requires -Version 5.1
<#
    live-subtitle 全量门禁：语法 / 编码 / 单元测试 / 引用完整性 / 凭据扫描 / 工作流自保护

    为什么这些检查要放在 .ps1 文件里，而不是写在 ci.yml 的 run: 块里？
    因为 GitHub 的 Windows runner 会把 run: 的内容写进一个临时 .ps1 再交给
    Windows PowerShell 5.1 执行，而那个临时文件不带 UTF-8 BOM。5.1 会按系统
    代码页（中文机器上是 GBK）去解码，于是内联的所有中文都会变成乱码、
    直接 ParseException。ci.yml 的 run 块因此必须保持纯 ASCII。

    本文件自身带 UTF-8 BOM，用 -File 调用，5.1 能正确读取中文。
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$script:Failures = 0

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 60)
    Write-Host "  $Title"
    Write-Host ('=' * 60)
}

function Fail {
    param([string]$Message)
    $script:Failures++
    Write-Host "  FAIL  $Message"
}

function Pass {
    param([string]$Message)
    Write-Host "  PASS  $Message"
}

# ---------------------------------------------------------------- 1. 语法解析
Write-Section '1) PowerShell 语法解析（不执行，只让解析器过一遍）'

$ps1Files = @(Get-ChildItem -Path $root -Recurse -File -Filter *.ps1 |
    Where-Object { $_.FullName -notmatch '\\\.git\\' })

if ($ps1Files.Count -eq 0) {
    Fail '一个 .ps1 都没找到，脚本清单本身就有问题'
}
else {
    foreach ($f in $ps1Files) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        $rel = $f.FullName.Substring($root.Length + 1)
        if ($errors -and $errors.Count -gt 0) {
            Fail "语法错误 $rel"
            $errors | Select-Object -First 3 | ForEach-Object { Write-Host "        $($_.Message)" }
        }
        else {
            Pass "语法 OK  $rel"
        }
    }
}

# ---------------------------------------------------------------- 2. 编码检查
Write-Section '2) UTF-8 BOM 检查（Windows PowerShell 5.1 的专属坑）'

# 5.1 读没有 BOM 的 UTF-8 会按 ANSI 解码，中文全变乱码并直接解析失败。
# 这个坑在 pwsh 7 上不存在，所以门禁必须用 5.1 跑才有意义。
foreach ($f in $ps1Files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $hasNonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $hasNonAscii = $true; break } }
    $rel = $f.FullName.Substring($root.Length + 1)
    if ($hasNonAscii -and -not $hasBom) {
        Fail "缺少 BOM  $rel —— 含非 ASCII 字符却没有 UTF-8 BOM，PS 5.1 会读成乱码"
    }
    else {
        Pass "BOM OK    $rel"
    }
}

# ------------------------------------------------------- 3. 工作流自保护检查
Write-Section '3) 工作流自保护：ci.yml 的 run 段必须是纯 ASCII'

# 这是本轮 CI 真红之后补的元检查。
# 教训：CI 逻辑写在 run: 里含中文，在 runner 上就是一堆乱码，而且本地永远发现不了，
# 因为本地不会走「写临时文件 → 5.1 按 ANSI 解码」这条路径。
$workflows = @(Get-ChildItem -Path (Join-Path $root '.github/workflows') -File -Filter *.yml -ErrorAction SilentlyContinue)
if ($workflows.Count -eq 0) {
    Fail '.github/workflows 下没有任何 yml'
}
else {
    foreach ($wf in $workflows) {
        $lines = @(Get-Content -LiteralPath $wf.FullName -Encoding UTF8)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            # name: 是给人在日志里看的，YAML 层 UTF-8 正常，允许中文
            if ($line -match '^\s*#') { continue }
            if ($line -match '^\s*name\s*:') { continue }
            $hasNonAscii = $false
            foreach ($ch in $line.ToCharArray()) { if ([int]$ch -gt 127) { $hasNonAscii = $true; break } }
            if ($hasNonAscii) {
                Fail "$($wf.Name):$($i + 1) 含非 ASCII 字符 —— run 段在 Windows runner 上会乱码：$($line.Trim())"
            }
        }
        Pass "工作流 ASCII 检查  $($wf.Name)"
    }
}

# ---------------------------------------------------------------- 4. 单元测试
Write-Section '4) 文字处理单元测试'

$testFile = Join-Path $root 'tests/Invoke-SubtitleTests.ps1'
if (-not (Test-Path $testFile)) {
    Fail "测试文件不存在：$testFile"
}
else {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $testFile
    if ($LASTEXITCODE -ne 0) {
        Fail "单元测试失败，退出码 $LASTEXITCODE"
    }
    else {
        Pass '单元测试全绿'
    }
}

# ------------------------------------------------------------ 5. 引用完整性
Write-Section '5) 引用完整性'

$libFile = Join-Path $root 'lib/SubtitleText.ps1'
if (-not (Test-Path $libFile)) {
    Fail 'lib/SubtitleText.ps1 不存在'
}
else {
    Pass '函数库存在  lib/SubtitleText.ps1'
}

# 注意：只查「文件名字符串是否出现」是不够的 —— 配置行里本来就有这个字符串。
# 必须查真正的 dot-source 语句还在不在，否则把引用注释掉这个检查会假绿。
$mainFile = Join-Path $root '实时字幕.ps1'
if (-not (Test-Path $mainFile)) {
    Fail '主脚本 实时字幕.ps1 不存在'
}
else {
    $main = Get-Content -Raw -Encoding UTF8 -LiteralPath $mainFile
    if ($main -notmatch '(?m)^\s*\.\s+\$script:LibPath') {
        Fail '主脚本没有 dot-source 函数库 —— 文字处理会整体失效，而且肉眼看不出来'
    }
    else {
        Pass '主脚本已 dot-source 函数库'
    }
}

$glossary = Join-Path $root 'subtitle-glossary.example.json'
if (-not (Test-Path $glossary)) {
    Fail '术语表模板 subtitle-glossary.example.json 缺失'
}
else {
    Pass '术语表模板存在  subtitle-glossary.example.json'
}

# -------------------------------------------------------------- 6. 凭据扫描
Write-Section '6) 凭据泄露扫描'

# 特征串用拼接构造，避免扫描器命中本文件自己的规则文本（自指误报）。
# 这样扫描范围可以覆盖全仓库，不需要排除工具目录 —— 比排除法更严。
$patterns = @(
    ('sk' + '-[A-Za-z0-9]{20,}'),
    ('ck' + '_[A-Za-z0-9_.]{10,}'),
    ('ghp' + '_[A-Za-z0-9]{30,}'),
    ('gho' + '_[A-Za-z0-9]{30,}'),
    ('xox[baprs]' + '-[A-Za-z0-9-]{10,}'),
    ('AKIA' + '[0-9A-Z]{16}'),
    ('-----BEGIN ' + '[A-Z ]*PRIVATE KEY-----'),
    ('SES' + 'SDATA=[A-Za-z0-9%]{10,}'),
    ('postgres(ql)?' + '://[^:\s/]+:[^@\s]+@')
)

$skipLine = '(你的|your[-_ ]?key|YOUR[_A-Z]*|placeholder|示例|占位|xxx|TODO|EXAMPLE)'
$exts = @('.ps1', '.json', '.md', '.bat', '.vbs', '.yml', '.yaml', '.txt', '.config', '.xml', '.properties', '.ini')

$scanFiles = @(Get-ChildItem -Path $root -Recurse -File | Where-Object {
        ($exts -contains $_.Extension.ToLower()) -and
        ($_.FullName -notmatch '\\\.git\\')
    })

$hit = 0
foreach ($f in $scanFiles) {
    $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match $skipLine) { continue }
        foreach ($p in $patterns) {
            if ($line -match $p) {
                $hit++
                $rel = $f.FullName.Substring($root.Length + 1)
                Write-Host "  CREDENTIAL-HIT  ${rel}:$($i + 1)"
                break
            }
        }
    }
}

if ($hit -gt 0) {
    Fail "扫到 $hit 处疑似真实凭据，禁止合入"
}
else {
    Pass "凭据扫描通过（扫了 $($scanFiles.Count) 个文件，0 命中）"
}

# ------------------------------------------------------------------- 汇总
Write-Host ''
Write-Host ('=' * 60)
if ($script:Failures -gt 0) {
    Write-Host "  门禁失败：共 $($script:Failures) 项不通过"
    Write-Host ('=' * 60)
    exit 1
}
Write-Host '  全部通过：语法 / BOM / 工作流 ASCII / 单元测试 / 引用完整性 / 凭据'
Write-Host ('=' * 60)
exit 0
