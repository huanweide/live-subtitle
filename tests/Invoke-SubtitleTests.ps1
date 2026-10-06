#Requires -Version 5.1
<#
    SubtitleText.ps1 的单元测试。

    为什么不用 Pester：
      这台开发机（以及很多只装了系统自带 Windows PowerShell 5.1 的机器）上的
      Pester 是 3.4.0，装新版要连 PSGallery，公司网 / 离线环境下经常拉不下来。
      本项目对外打的旗号就是「不用装东西」，所以测试也做成零依赖：
      自制断言 + 非 0 退出码，本地双击能跑，CI 里同样能跑。

    用法：
      powershell -ExecutionPolicy Bypass -File tests\Invoke-SubtitleTests.ps1
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'lib\SubtitleText.ps1')

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    $a = "$Actual"; $e = "$Expected"
    if ($a -eq $e) {
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        期望: [$e]" -ForegroundColor Red
        Write-Host "        实际: [$a]" -ForegroundColor Red
    }
}

function Assert-True {
    param($Value, [string]$Name)
    Assert-Equal ([bool]$Value) $true $Name
}

function Assert-False {
    param($Value, [string]$Name)
    Assert-Equal ([bool]$Value) $false $Name
}

function Assert-Count {
    param($Array, [int]$Expected, [string]$Name)
    $n = @($Array).Count
    Assert-Equal $n $Expected $Name
}

Write-Host ''
Write-Host '=== Get-CleanSubtitleText：剥离时间戳 ===' -ForegroundColor Cyan
Assert-Equal (Get-CleanSubtitleText '[00:00:12.345 --> 00:00:15.678] こんにちは') 'こんにちは' '剥掉带箭头的时间戳'
Assert-Equal (Get-CleanSubtitleText '[00:00:12.345] こんにちは')             'こんにちは' '剥掉单段时间戳'
Assert-Equal (Get-CleanSubtitleText '(00:00:12.345 --> 00:00:15.678) hi')   'hi'         '剥掉圆括号时间戳'
Assert-Equal (Get-CleanSubtitleText 'こんにちは')                            'こんにちは' '没有时间戳时原样返回'
Assert-Equal (Get-CleanSubtitleText '')                                     ''           '空串返回空'
Assert-Equal (Get-CleanSubtitleText '   ')                                  ''           '纯空白返回空'
Assert-Equal (Get-CleanSubtitleText '[音楽]')                               '[音楽]'     '内容性方括号标记要保留'
Assert-Equal (Get-CleanSubtitleText (Get-CleanSubtitleText '[00:00:01.000 --> 00:00:02.000] あ')) 'あ' '幂等：剥两次结果不变'
# 这条最关键：不剥时间戳的话，去重和黑名单都会失效
Assert-Equal (Get-CleanSubtitleText '[00:00:01.000 --> 00:00:02.000] ありがとうございました') `
             (Get-CleanSubtitleText '[00:00:03.000 --> 00:00:04.000] ありがとうございました') `
             '不同时间戳的同一句话，清洗后应完全相同（去重才能生效）'

Write-Host ''
Write-Host '=== Test-SubtitleHallucination：幻觉过滤 ===' -ForegroundColor Cyan
$bl = @('ご視聴ありがとうございました', 'Thank you for watching', '字幕')
Assert-True  (Test-SubtitleHallucination 'ご視聴ありがとうございました' $bl) '命中日语幻觉（片尾语）'
Assert-True  (Test-SubtitleHallucination 'ご視聴ありがとうございました。' $bl) '带句末标点仍命中'
Assert-True  (Test-SubtitleHallucination 'Thank you for watching' $bl) '命中英语幻觉（带空格）'
Assert-True  (Test-SubtitleHallucination '字幕' $bl) '命中中文幻觉'
Assert-True  (Test-SubtitleHallucination '' $bl) '空串视为幻觉'
Assert-True  (Test-SubtitleHallucination '   ' $bl) '纯空白视为幻觉'
Assert-False (Test-SubtitleHallucination '今日はいい天気ですね' $bl) '正常句子不误杀'
Assert-False (Test-SubtitleHallucination 'ありがとう' $bl) '短的「谢谢」不误杀（只在完整片尾语时拦）'
Assert-False (Test-SubtitleHallucination '字幕を表示します' $bl) '包含黑名单词但整句不同，不拦'
# 关键：清洗过时间戳后，黑名单才比得上
Assert-True  (Test-SubtitleHallucination (Get-CleanSubtitleText '[00:00:09.000 --> 00:00:11.000] ご視聴ありがとうございました') $bl) `
             '清洗时间戳后黑名单能命中（不清洗则永远命中不了）'

Write-Host ''
Write-Host '=== Split-SubtitleLine：断句 ===' -ForegroundColor Cyan
Assert-Equal (@(Split-SubtitleLine 'こんにちは' -Lang 'ja' -MaxChars 42)).Count 1 '短句不切，保持一条'
Assert-Equal (@(Split-SubtitleLine 'こんにちは' -Lang 'ja' -MaxChars 42)[0]) 'こんにちは' '短句内容不变'

# 整段要明显长于 MaxChars，才会触发切分
$long = '今日はとてもいい天気ですね。散歩に行きましょう。それから晩ごはんを食べて、ゆっくり休みます。'
$parts = @(Split-SubtitleLine $long -Lang 'ja' -MaxChars 42)
Assert-True ($parts.Count -ge 2) '长句按句末标点切成多条'
Assert-True (($parts | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum -le 42) '切出的每条都不超过 MaxChars'
Assert-Equal ($parts -join '') ($long -replace '\s', '') '切分不丢字（拼回去内容一致）'

$noPunct = 'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろ'
$hard = @(Split-SubtitleLine $noPunct -Lang 'ja' -MaxChars 20)
Assert-True ($hard.Count -ge 2) '无标点的超长串按长度硬切'
Assert-True (($hard | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum -le 20) '硬切后每条不超长'

$frag = @(Split-SubtitleLine ('あ。い。う。え。お。' * 1) -Lang 'ja' -MaxChars 42)
Assert-True ($frag.Count -le 2) '过短碎片会被拼回去，不剁成一堆单行'

$en = 'This is a fairly long English sentence that needs to be wrapped somewhere sensible for reading.'
$enParts = @(Split-SubtitleLine $en -Lang 'en' -MaxChars 30)
Assert-True ($enParts.Count -ge 2) '英文长句会被切'
foreach ($p in $enParts) {
    if ($p.Length -gt 30) { $script:Failed++; Write-Host "  FAIL  英文切分超长: [$p]" -ForegroundColor Red }
}
$script:Passed++
Write-Host '  PASS  英文切分每条都不超过 MaxChars' -ForegroundColor Green

# 注意：空数组不能直接当参数传给函数（会被展开成「没传参」），先取 Count 再断言
Assert-Equal (@(Split-SubtitleLine '' -Lang 'ja' -MaxChars 42)).Count 0 '空串切出 0 条'
Assert-Equal (@(Split-SubtitleLine '   ' -Lang 'ja' -MaxChars 42)).Count 0 '纯空白切出 0 条'

Write-Host ''
Write-Host '=== ConvertFrom-SubtitleGlossary：术语替换 ===' -ForegroundColor Cyan
$g = @{ '阿梓' = '阿梓(Azusa)'; '阿梓的森林' = '阿梓森林' }
Assert-Equal (ConvertFrom-SubtitleGlossary '阿梓です' $g) '阿梓(Azusa)です' '单条术语被替换'
Assert-Equal (ConvertFrom-SubtitleGlossary '阿梓的森林へようこそ' $g) '阿梓森林へようこそ' '长词优先，不会被短词先替换'
Assert-Equal (ConvertFrom-SubtitleGlossary 'こんにちは' $g) 'こんにちは' '没命中时原样返回'
Assert-Equal (ConvertFrom-SubtitleGlossary 'こんにちは' $null) 'こんにちは' '术语表为空时原样返回'
Assert-Equal (ConvertFrom-SubtitleGlossary '' $g) '' '空串原样返回'
$g2 = @{ 'あ' = 'ア' }
Assert-Equal (ConvertFrom-SubtitleGlossary 'あああ' $g2) 'アアア' '同一词多次出现都替换'
$g3 = @{ 'あ' = '' }
Assert-Equal (ConvertFrom-SubtitleGlossary 'ああ' $g3) 'ああ' '目标为空的条目跳过，不会把词删光'

Write-Host ''
Write-Host '────────────────────────────────' -ForegroundColor DarkGray
Write-Host "  通过 $script:Passed / 失败 $script:Failed" -ForegroundColor $(if ($script:Failed -gt 0) { 'Red' } else { 'Green' })
Write-Host ''

if ($script:Failed -gt 0) { exit 1 }
exit 0
