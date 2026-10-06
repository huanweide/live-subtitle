#Requires -Version 5.1
<#
    SubtitleText.ps1 —— 字幕文本处理纯函数库

    为什么单独拆一个文件：
      主脚本 实时字幕.ps1 带 param() 且一执行就建窗口，没法被测试直接加载。
      这里只放纯函数（输入 → 输出，不碰 UI / 文件 / 网络 / 全局变量），
      主脚本 dot-source 它，Pester 也 dot-source 它，两边的行为完全一致。

    四个函数解决四件「whisper 类实时字幕的通病」：
      Get-CleanSubtitleText        剥掉时间戳前缀（否则时间戳会混进字幕、被送去翻译、
                                   还会让去重和黑名单全部失效）
      Test-SubtitleHallucination   静音时 whisper 自己编句子的过滤
      Split-SubtitleLine           长句断句（whisper 一口气吐一整段，字号再大也读不完）
      ConvertFrom-SubtitleGlossary 术语替换（专名错译，给个词典就能纠正）
#>

function Get-CleanSubtitleText {
    <#
        剥掉 whisper-stream 可能带的时间戳前缀，只留正文。

        whisper.cpp 的 stream 示例输出形如：
            [00:00:12.345 --> 00:00:15.678]   こんにちは
        少数版本写成圆括号。主脚本如果直接拿整行当字幕，会有四个后果：
          1. 字幕上显示一串时间戳；
          2. 时间戳跟着正文一起发给翻译接口，白白烧 token、还可能干扰译文；
          3. 每 2 秒时间戳都在变，「和上一句完全相同就跳过」的去重永远不命中，
             同一句话被反复翻译 —— 重复烧钱，字幕还一直闪；
          4. 幻觉黑名单是「去掉标点后全等」比对，带了前缀就永远比不上，过滤形同虚设。

        只剥「长得像时间戳」的方括号块，不动 [音楽] 这类内容性标记。
        没有时间戳时原样返回，幂等。
    #>
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return '' }
    $s = $Line.Trim()

    # 方括号时间戳：[00:00:12.345] 或 [00:00:12.345 --> 00:00:15.678]
    $tsSquare = '^\s*\[\s*\d{1,3}:\d{1,2}(:\d{1,2})?([.,]\d{1,3})?' +
                '(\s*-->\s*\d{1,3}:\d{1,2}(:\d{1,2})?([.,]\d{1,3})?\s*)?\]\s*'
    $prev = ''
    while ($s -ne $prev) {
        $prev = $s
        $s = ($s -replace $tsSquare, '').Trim()
    }

    # 圆括号时间戳：(00:00:12.345) 或 (00:00:12.345 --> 00:00:15.678)
    $tsRound = '^\s*\(\s*\d{1,3}:\d{1,2}(:\d{1,2})?([.,]\d{1,3})?' +
               '(\s*-->\s*\d{1,3}:\d{1,2}(:\d{1,2})?([.,]\d{1,3})?\s*)?\)\s*'
    $prev = ''
    while ($s -ne $prev) {
        $prev = $s
        $s = ($s -replace $tsRound, '').Trim()
    }

    return $s
}

function Test-SubtitleHallucination {
    <#
        判断这句话是不是 whisper 在静音时自己编出来的（最常见是片尾语）。
        比对前两边都去掉空白和标点 —— 否则 'Thank you for watching' 这种带空格的永远命中不了。
    #>
    param(
        [string]$Text,
        [string[]]$Blacklist = @()
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $s = ($Text -replace '[\s。、！？!?.,，．…]', '')
    if ($s.Length -eq 0) { return $true }

    foreach ($h in $Blacklist) {
        if ([string]::IsNullOrWhiteSpace($h)) { continue }
        if ($s -eq ($h -replace '[\s。、！？!?.,，．…]', '')) { return $true }
    }
    return $false
}

function Split-SubtitleLine {
    <#
        把一整段识别结果切成几条「一眼能读完」的字幕。

        切分优先级：句末标点 > 句中停顿 > 西文空格 > 按长度硬切。
        短于 MaxChars 的原样返回（绝大多数句子走这条路，行为与不开启完全一致）。
        切完还会把过短的碎片拼回去，避免一句话被剁成四五行。
    #>
    param(
        [string]$Text,
        [string]$Lang = 'ja',
        [int]$MaxChars = 42
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -le $MaxChars) { return @($t) }

    # 日/中文拼接不需要空格，西文要
    $joiner = ''
    if ($Lang -ne 'ja' -and $Lang -ne 'zh' -and $Lang -ne 'auto') { $joiner = ' ' }

    # ---- 1. 按句末标点切 ----
    $chunks = New-Object System.Collections.ArrayList
    foreach ($s in [regex]::Split($t, '(?<=[。！？!?．])')) {
        $s = "$s".Trim()
        if ($s.Length -eq 0) { continue }
        if ($s.Length -gt $MaxChars) {
            # ---- 2. 仍过长，再按句中停顿切 ----
            $subs = @([regex]::Split($s, '(?<=[、，,；;：:])') | ForEach-Object { "$_".Trim() } | Where-Object { $_.Length -gt 0 })
            if ($subs.Count -le 1) { $subs = @($s) }
            foreach ($p in $subs) { [void]$chunks.Add($p) }
        } else {
            [void]$chunks.Add($s)
        }
    }
    if ($chunks.Count -eq 0) { $chunks = New-Object System.Collections.ArrayList; [void]$chunks.Add($t) }

    # ---- 3. 还是过长：西文在空格处断，其它按长度硬切 ----
    $cut2 = New-Object System.Collections.ArrayList
    foreach ($c in $chunks) {
        if ($c.Length -le $MaxChars) { [void]$cut2.Add($c); continue }
        $rest = $c
        while ($rest.Length -gt $MaxChars) {
            $cut = -1
            if ($joiner -ne '') {
                # 西文：尽量在 MaxChars 以内最靠后的空格处断，别把单词劈开
                $upto = [Math]::Min($MaxChars, $rest.Length - 1)
                $idx = $rest.LastIndexOf(' ', $upto)
                if ($idx -gt [int]($MaxChars * 0.5)) { $cut = $idx }
            }
            if ($cut -lt 0) { $cut = $MaxChars }
            [void]$cut2.Add($rest.Substring(0, $cut).Trim())
            $rest = $rest.Substring($cut).Trim()
        }
        if ($rest.Length -gt 0) { [void]$cut2.Add($rest) }
    }

    # ---- 4. 把过短的碎片拼回相邻一条，别剁太碎 ----
    $final = New-Object System.Collections.ArrayList
    foreach ($c in $cut2) {
        if ($final.Count -gt 0) {
            $li = $final.Count - 1
            $mergedLen = $final[$li].Length + $joiner.Length + $c.Length
            if ($mergedLen -le $MaxChars) {
                $final[$li] = $final[$li] + $joiner + $c
                continue
            }
        }
        [void]$final.Add($c)
    }

    return @($final)
}

function ConvertFrom-SubtitleGlossary {
    <#
        按术语表替换专有名词，解决「人名 / 作品名被译错」这类问题。
        长词优先替换，避免「阿梓」先于「阿梓的森林」被替换掉。
    #>
    param(
        [string]$Text,
        $Glossary
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($null -eq $Glossary) { return $Text }

    $map = @{}
    foreach ($k in $Glossary.Keys) {
        $ks = "$k"
        $vs = "$($Glossary[$k])"
        if ($ks -eq '' -or $vs -eq '') { continue }
        $map[$ks] = $vs
    }
    if ($map.Count -eq 0) { return $Text }

    # 一次扫描替换，每个位置只处理一遍。
    #
    # 不能用「foreach 依次 $out.Replace()」：那样替换出来的结果会被后面的规则再吃一次。
    # 例：词典里有「阿梓→阿梓(Azusa)」和「阿梓的森林→阿梓森林」，
    # 长词先替换得到「阿梓森林」，里面又含「阿梓」，于是被短词规则二次替换成
    # 「阿梓(Azusa)森林」——越改越错。
    #
    # 用一条 alternation 正则 + 长词优先（正则的 | 是左优先，所以按长度降序拼）即可避免。
    $keys = @($map.Keys | Sort-Object -Property Length -Descending)
    $pattern = (($keys | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $eval = [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        return $map[$m.Value]
    }
    return [regex]::Replace($Text, $pattern, $eval)
}
