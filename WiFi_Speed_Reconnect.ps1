# ============================================================
#  WiFi Channel Benchmark  v5
#  功能：枚举同 SSID 下所有 AP(BSSID)，逐通道多次采样测速，
#        按 BSSID 聚合统计（中位数抗噪），选出最优通道并尝试切回。
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File "WiFi_Speed_Reconnect.ps1"
#
#  可选参数：见下方 param 块，均有默认值，直接跑即可。
# ============================================================

param(
    # ---- 采样控制 ----
    [int]$MaxTries        = 12,      # 总采样轮数
    [int]$MinSamplesPerAp = 2,       # 每个 BSSID 至少采几次（保证可比性）

    # ---- 达标阈值（用于评分归一化）----
    [double]$LinkRatio    = 0.6,     # 自动门槛 = 链路速率 × 此比例
    [double]$MinSpeedMbps = 0,       # 手动门槛；>0 时覆盖自动计算
    [int]$MaxLatencyMs    = 200,     # 延迟满分基准
    [int]$MaxLossPercent  = 20,      # 丢包上限（%）

    # ---- 测速控制 ----
    [int]$SpeedSeconds    = 5,       # 正式测速窗口（秒）
    [int]$PingCount       = 5,       # 每目标 ping 次数
    [string]$PingTarget   = '223.5.5.5',

    # ---- 切换控制 ----
    [int]$SwitchMaxRetry  = 6,       # 切回最优 BSSID 的最大重试次数

    # ---- 行为 ----
    [switch]$DryRun,                # 只测不切（不执行 disconnect/connect）
    [switch]$NoPause,               # 执行完不等待按键（便于自动化/计划任务）
    [string]$LogPath   = '',        # CSV 日志路径；默认写到脚本同目录
    [switch]$ScanOnly               # 只扫描并列出所有 AP，不测速
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# 控制台统一走 UTF-8。
# 这不只是为了显示：netsh 会跟随控制台编码决定输出语言与字节编码。
# 设成 UTF8 后 netsh 输出稳定的英文文本，解析不再依赖系统语言。
try {
    $script:PrevOutEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
} catch { }

# 输出重定向到文件时，PowerShell 5.1 默认写 UTF-16LE，中文查看器易乱码。
# 这里显式改为 UTF-8，保证 `... > log.txt` 与管道场景下中文可读。
try { $global:OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
if (-not $LogPath) {
    $LogPath = Join-Path $ScriptDir ("wifi_bench_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

# ============================================================
#  基础工具
# ============================================================

# 统一的 netsh 调用入口（编码已在脚本级设置）
function Invoke-Netsh {
    param([Parameter(Mandatory = $true)][string[]]$NetshArgs)
    return @(& netsh.exe @NetshArgs 2>$null)
}

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return [double]$s[[int](($n - 1) / 2)] }
    return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2
}

function Format-Null($v, [string]$fmt = '0.0') {
    if ($null -eq $v) { return 'N/A' }
    # 注意：.NET 自定义格式串里 '2' 这类非 0/# 占位符会被当字面量，导致数值丢失。
    # 因此只接受 F / N / P 等真实格式，调用方一律传 'F2' / 'F1' 形式。
    switch -Regex ($fmt) {
        '^[FNPfnp]\d*$' { return ([double]$v).ToString($fmt) }
        default         { return ([double]$v).ToString('F2') }
    }
}

# ============================================================
#  1. 读取当前连接信息
#     正则同时匹配中英文标签，即使某台机器 netsh 仍输出中文也能解析。
# ============================================================
function Get-WifiInfo {
    $raw = Invoke-Netsh -NetshArgs @('wlan', 'show', 'interfaces')

    $ssid = ''; $signal = $null; $band = ''; $rate = $null
    $bssid = ''; $channel = $null; $radio = ''; $auth = ''

    foreach ($line in $raw) {
        if ($line -match '^\s*SSID\s*:\s*(.+)$')                        { $ssid    = $Matches[1].Trim() }
        elseif ($line -match '^\s*(Signal|信号)\s*:\s*(\d+)')           { $signal  = [int]$Matches[2] }
        elseif ($line -match '^\s*(Band|波段)\s*:\s*(.+)$')              { $band    = $Matches[2].Trim() }
        elseif ($line -match '^\s*(Channel|通道)\s*:\s*(\d+)')          { $channel = [int]$Matches[2] }
        elseif ($line -match '^\s*(Radio type|无线电类型)\s*:\s*(.+)$') { $radio   = $Matches[2].Trim() }
        elseif ($line -match '^\s*(Authentication|身份验证)\s*:\s*(.+)$'){ $auth    = $Matches[2].Trim() }
        elseif ($line -match '^\s*(接收速率|Receive rate)\s*(\(\s*Mbps\s*\))?\s*:\s*(\d+(?:\.\d+)?)') { $rate = [double]$Matches[3] }
        elseif ($line -match 'AP\s*BSSID\s*:\s*(.+)$')                  { $bssid   = $Matches[1].Trim().ToLower() }
    }

    return [pscustomobject]@{
        SSID    = $ssid
        Signal  = $signal
        Band    = $band
        Channel = $channel
        Radio   = $radio
        Auth    = $auth
        Rate    = $rate      # 链路协商速率 Mbps
        BSSID   = $bssid
    }
}

# ============================================================
#  2. 枚举当前可见的同 SSID 所有 AP（BSSID）
#     这是「把所有通道列出来」的数据来源。
# ============================================================
function Get-VisibleAp {
    param([string]$TargetSsid)

    $raw = Invoke-Netsh -NetshArgs @('wlan', 'show', 'networks', 'mode=bssid')

    $list    = New-Object System.Collections.Generic.List[object]
    $curSsid = $null
    $cur     = $null

    foreach ($line in $raw) {
        if ($line -match '^\s*SSID\s*\d+\s*:\s*(.+)$') {
            $curSsid = $Matches[1].Trim()
            $cur = $null
            continue
        }
        if ($line -match '^\s*BSSID\s*\d+\s*:\s*([0-9a-fA-F:]{17})') {
            if ($TargetSsid -and $curSsid -ne $TargetSsid) { continue }
            $cur = [pscustomobject]@{
                SSID    = $curSsid
                BSSID   = $Matches[1].ToLower()
                Signal  = $null
                Band    = ''
                Channel = $null
                Radio   = ''
            }
            [void]$list.Add($cur)
            continue
        }
        if (-not $cur) { continue }

        if ($line -match '^\s*(Signal|信号)\s*:\s*(\d+)')               { $cur.Signal  = [int]$Matches[2] }
        elseif ($line -match '^\s*(Band|波段)\s*:\s*(.+)$')              { $cur.Band    = $Matches[2].Trim() }
        elseif ($line -match '^\s*(Channel|通道)\s*:\s*(\d+)')          { $cur.Channel = [int]$Matches[2] }
        elseif ($line -match '^\s*(Radio type|无线电类型)\s*:\s*(.+)$') { $cur.Radio   = $Matches[2].Trim() }
    }

    # 注意：PS 5.1 下 @($list) 对 List[object] 会抛「参数类型不匹配」，必须用 ToArray()
    return $list.ToArray()
}

# ============================================================
#  3. 延迟 / 丢包
#     兼容 PS 5.1(ResponseTime) 与 PS 7+(Latency)
# ============================================================
function Test-PingStats {
    param([string]$Target, [int]$Count = 5)

    if (-not $Target) { return [pscustomobject]@{ AvgMs = $null; Loss = 100 } }

    $res = @()
    try { $res = @(Test-Connection -ComputerName $Target -Count $Count -ErrorAction SilentlyContinue) }
    catch { $res = @() }

    if ($res.Count -eq 0) {
        return [pscustomobject]@{ AvgMs = $null; Loss = 100 }
    }

    $samples = @()
    foreach ($p in $res) {
        $rt = $null
        if ($p.PSObject.Properties.Name -contains 'ResponseTime') { $rt = $p.ResponseTime }
        elseif ($p.PSObject.Properties.Name -contains 'Latency')    { $rt = $p.Latency }
        if ($null -ne $rt) { $samples += [double]$rt }
    }

    $loss = [math]::Round(100.0 * (1.0 - ($res.Count / [double]$Count)), 1)
    $avg  = if ($samples.Count -gt 0) { [math]::Round((Get-Median $samples), 1) } else { $null }

    return [pscustomobject]@{ AvgMs = $avg; Loss = $loss }
}

# ============================================================
#  4. 测速源探测
#     硬编码会随版本滚动失效（实测 ubuntu-24.04.4 已 404），
#     所以启动时先探一轮，选实测最快的源用于后续采样。
# ============================================================
function Get-SpeedProbeCandidates {
    return @(
        'https://mirrors.ustc.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso',
        'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso',
        'https://mirrors.aliyun.com/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso',
        'https://mirrors.aliyun.com/debian/ls-lR.gz',
        'https://mirrors.ustc.edu.cn/debian/ls-lR.gz'
    )
}

function Select-SpeedSource {
    param([int]$ProbeSeconds = 3)

    Write-Host '  探测测速源 ...' -ForegroundColor DarkGray
    $best = $null

    foreach ($u in (Get-SpeedProbeCandidates)) {
        # 预热一次（不计时），排除 TLS 握手与首包延迟
        curl.exe -L -o NUL --max-time 2 -s -w '' $u 2>$null | Out-Null
        $r = curl.exe -L -o NUL --max-time $ProbeSeconds -s -w '%{http_code}|%{speed_download}' $u 2>$null
        if (-not $r) { continue }
        $p = $r -split '\|'
        if ($p[0] -ne '200') { continue }
        $mbps = [double]$p[1] * 8 / 1000000
        if ($mbps -lt 5) { continue }

        $short = ($u -replace '^https://','') -replace '/ubuntu-releases.*',''
        Write-Host ("    {0,-24} {1,7} Mbps" -f $short, [math]::Round($mbps,1)) -ForegroundColor DarkGray

        if (-not $best -or $mbps -gt $best.Mbps) {
            $best = [pscustomobject]@{ Url = $u; Mbps = $mbps }
        }
    }

    if (-not $best) { return $null }
    return $best
}

# 正式测速：预热 + 计时窗口
function Measure-DownloadSpeed {
    param([string]$Url, [int]$Seconds = 5)

    if (-not $Url) { return $null }

    curl.exe -L -o NUL --max-time 2 -s -w '' $Url 2>$null | Out-Null
    $r = curl.exe -L -o NUL --max-time $Seconds -s -w '%{http_code}|%{speed_download}' $Url 2>$null
    if (-not $r) { return $null }

    $p = $r -split '\|'
    if ($p[0] -ne '200') { return $null }

    $mbps = [double]$p[1] * 8 / 1000000
    if ($mbps -le 0) { return $null }
    return [math]::Round($mbps, 2)
}

# ============================================================
#  5. 评分（纯函数，全部显式传参，可单测）
# ============================================================
function Get-ChannelScore {
    param(
        $LatencyMs, $SpeedMbps, $SignalPct,
        [double]$Threshold, [int]$LatencyBase, $LossPct
    )

    $l = 0.0
    if ($null -ne $LatencyMs) {
        $l = [math]::Max(0.0, 1.0 - ([double]$LatencyMs / [double]$LatencyBase))
    }

    $s = 0.0
    if ($null -ne $SpeedMbps -and $Threshold -gt 0) {
        $s = [math]::Min(1.0, [double]$SpeedMbps / $Threshold)
    }

    $sig = 0.0
    if ($null -ne $SignalPct) {
        $sig = [math]::Min(1.0, [double]$SignalPct / 100.0)
    }

    $lossScore = [math]::Max(0.0, 1.0 - ([double]$LossPct / 100.0))

    # 丢包极低的通道额外加权：丢包对体感的影响远大于均速差。
    # 权重和为 1.0，故基准得分上限恰为 1.0，加权后可达 1.15。
    $base = 0.35 * $l + 0.40 * $s + 0.15 * $sig + 0.10 * $lossScore
    $lossBonus = 1.0 + (0.15 * $lossScore)

    return [math]::Round($base * $lossBonus, 4)
}

# ============================================================
#  6. 网络恢复等待
# ============================================================
function Wait-NetworkUp {
    param([string]$GwIp, [int]$TimeoutSec = 20)

    $probe = if ($GwIp) { $GwIp } else { $PingTarget }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            if (Test-Connection -ComputerName $probe -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                return $true
            }
        } catch { }
        Start-Sleep -Milliseconds 800
    }
    return $false
}

# ============================================================
#  7. 重连（触发系统重新选 AP）
# ============================================================
function Invoke-Reconnect {
    param([string]$Ssid, [string]$GwIp, [int]$SettleSec = 3)

    if ($DryRun) {
        Start-Sleep -Seconds 2
        return $true
    }

    Invoke-Netsh -NetshArgs @('wlan', 'disconnect') | Out-Null
    Start-Sleep -Seconds 2
    Invoke-Netsh -NetshArgs @('wlan', 'connect', "name=$Ssid") | Out-Null

    $up = Wait-NetworkUp -GwIp $GwIp -TimeoutSec 20
    if ($up) { Start-Sleep -Seconds $SettleSec }   # 等速率稳定，避免虚高读数
    return $up
}

# ============================================================
#  8. 切回指定 BSSID
#     说明：Windows/netsh 没有「连接到指定 BSSID」的命令，
#     只能反复重连碰运气。这里做成有上限的重试，
#     并如实报告命中率，而不是假装一定能切过去。
# ============================================================
function Connect-TargetBssid {
    param([string]$Ssid, [string]$TargetBssid, [string]$GwIp, [int]$MaxRetry = 6)

    if (-not $TargetBssid) { return $false }
    if ($DryRun) { return $false }

    for ($i = 1; $i -le $MaxRetry; $i++) {
        Invoke-Netsh -NetshArgs @('wlan', 'disconnect') | Out-Null
        Start-Sleep -Seconds 2
        Invoke-Netsh -NetshArgs @('wlan', 'connect', "name=$Ssid") | Out-Null
        Wait-NetworkUp -GwIp $GwIp -TimeoutSec 15 | Out-Null

        $w = Get-WifiInfo
        if ($w.BSSID -eq $TargetBssid) { return $true }

        Write-Host ("    [{0}/{1}] 当前 {2}，非目标，重试" -f $i, $MaxRetry, $w.BSSID) -ForegroundColor DarkYellow
        Start-Sleep -Seconds 1
    }
    return $false
}

# ============================================================
#  主流程
# ============================================================
Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '   WiFi Channel Benchmark v5' -ForegroundColor Cyan
Write-Host '   枚举全部通道 · 多次采样 · 按 BSSID 聚合择优' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

$wifi = Get-WifiInfo
if (-not $wifi.SSID) {
    Write-Host '未检测到已连接的 WiFi，退出。' -ForegroundColor Red
    exit 1
}

Write-Host ("SSID : {0}    BSSID : {1}    信道 {2}    {3}    {4}" -f $wifi.SSID, $wifi.BSSID, $wifi.Channel, $wifi.Band, $wifi.Radio) -ForegroundColor White
Write-Host ("信号 : {0}%   链路协商速率 : {1} Mbps" -f $wifi.Signal, $wifi.Rate) -ForegroundColor White

# ---- 扫描同 SSID 全部 AP ----
$aps = @(Get-VisibleAp -TargetSsid $wifi.SSID |
         Sort-Object -Property @{Expression='Channel';Descending=$false}, @{Expression='Signal';Descending=$true})

Write-Host ''
Write-Host '---------- 扫描到的全部 AP ----------' -ForegroundColor Cyan
if ($aps.Count -eq 0) {
    Write-Host '  netsh 未返回 AP 明细（部分驱动不支持 mode=bssid）。' -ForegroundColor Yellow
    Write-Host '  将只按当前所在 AP 采样。' -ForegroundColor Yellow
} else {
    Write-Host ("  {0,-5} {1,-20} {2,-7} {3,-8} {4,-7} {5}" -f '#','BSSID','信号','波段','信道','制式') -ForegroundColor DarkGray
    $idx = 0
    foreach ($ap in $aps) {
        $idx++
        $mark = if ($ap.BSSID -eq $wifi.BSSID) { '  <= 当前' } else { '' }
        Write-Host ("  {0,-5} {1,-20} {2,-7} {3,-8} {4,-7} {5}{6}" -f `
            $idx, $ap.BSSID, "$($ap.Signal)%", $ap.Band, $ap.Channel, $ap.Radio, $mark) -ForegroundColor White
    }
}

if ($ScanOnly) {
    Write-Host ''
    Write-Host 'ScanOnly 模式，结束。' -ForegroundColor Cyan
    exit 0
}

# ---- 评分参考线 ----
$threshold = $MinSpeedMbps
if ($threshold -le 0) {
    if ($null -ne $wifi.Rate -and $wifi.Rate -gt 0) {
        $threshold = [math]::Round($wifi.Rate * $LinkRatio, 1)
    } else {
        $threshold = 300.0
    }
}
Write-Host ''
Write-Host ("评分参考线 : {0} Mbps   (链路速率 {1} × {2})" -f $threshold, $wifi.Rate, $LinkRatio) -ForegroundColor Yellow

# ---- 网关 ----
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
       Sort-Object -Property RouteMetric | Select-Object -First 1).NextHop
Write-Host ("网关 : {0}" -f $(if ($gw) { $gw } else { '未取到，使用公网探测' })) -ForegroundColor DarkGray

# ---- 选测速源 ----
$src = Select-SpeedSource
if (-not $src) {
    Write-Host '所有测速源均不可用，无法测速。' -ForegroundColor Red
    exit 2
}
Write-Host ("测速源 : {0}  (探测 {1} Mbps)" -f $src.Url, [math]::Round($src.Mbps,1)) -ForegroundColor Yellow

# ---- 采样循环 ----
$samples = New-Object System.Collections.Generic.List[object]

for ($t = 1; $t -le $MaxTries; $t++) {
    Write-Host ''
    Write-Host ("========== 第 {0}/{1} 轮 ==========" -f $t, $MaxTries) -ForegroundColor Cyan

    $w = Get-WifiInfo
    $gwPing  = Test-PingStats -Target $(if ($gw) { $gw } else { $PingTarget }) -Count $PingCount
    $netPing = Test-PingStats -Target $PingTarget -Count $PingCount

    Write-Host ("  当前 BSSID {0}  信道 {1}  信号 {2}%" -f $w.BSSID, $w.Channel, $w.Signal)
    Write-Host ("  网关 {0}ms/{1}%   公网 {2}ms/{3}%" -f (Format-Null $gwPing.AvgMs 'F1'), $gwPing.Loss, (Format-Null $netPing.AvgMs 'F1'), $netPing.Loss) -ForegroundColor DarkGray
    Write-Host ("  测速中（{0}s）..." -f $SpeedSeconds) -ForegroundColor DarkGray

    $speed = Measure-DownloadSpeed -Url $src.Url -Seconds $SpeedSeconds
    if ($null -eq $speed) { Write-Host '  测速失败' -ForegroundColor DarkYellow }

    # 延迟取网关与公网两者中较差者
    $lat = $null
    if ($null -ne $gwPing.AvgMs -and $null -ne $netPing.AvgMs) { $lat = [math]::Max($gwPing.AvgMs, $netPing.AvgMs) }
    elseif ($null -ne $gwPing.AvgMs) { $lat = $gwPing.AvgMs }
    elseif ($null -ne $netPing.AvgMs) { $lat = $netPing.AvgMs }

    $loss = [math]::Max($gwPing.Loss, $netPing.Loss)
    $score = Get-ChannelScore -LatencyMs $lat -SpeedMbps $speed -SignalPct $w.Signal `
                              -Threshold $threshold -LatencyBase $MaxLatencyMs -LossPct $loss

    [void]$samples.Add([pscustomobject]@{
        Round    = $t
        BSSID    = $w.BSSID
        Channel  = $w.Channel
        Signal   = $w.Signal
        LinkMbps = $w.Rate
        Latency  = $lat
        Loss     = $loss
        Speed    = $speed
        Score    = $score
        Time     = (Get-Date).ToString('HH:mm:ss')
    })

    if ($null -ne $speed) {
        Write-Host ("  速度 {0} Mbps   得分 {1}" -f $speed, $score) -ForegroundColor Green
    } else {
        Write-Host ("  得分 {0}" -f $score) -ForegroundColor DarkGray
    }

    if ($t -lt $MaxTries) {
        if ($DryRun) {
            Write-Host '  [DryRun] 模拟重连' -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
        } else {
            Invoke-Reconnect -Ssid $wifi.SSID -GwIp $gw | Out-Null
        }
    }
}

# ============================================================
#  逐轮明细
# ============================================================
Write-Host ''
Write-Host '========== 逐轮明细 ==========' -ForegroundColor Cyan
$samples | Select-Object Round, Channel, BSSID, Signal, Latency, Loss, Speed, Score, Time |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Host ''

# ============================================================
#  按 BSSID 聚合 —— 核心：不要用「最快的那一轮」当结论，
#  那是噪声取最大值。要按通道聚合，用中位数。
# ============================================================
Write-Host '========== 各通道聚合（中位数）==========' -ForegroundColor Cyan

$agg = @()
foreach ($g in ($samples | Group-Object -Property BSSID)) {
    $sp = [double[]]@($g.Group | Where-Object { $null -ne $_.Speed }    | ForEach-Object { [double]$_.Speed })
    $lt = [double[]]@($g.Group | Where-Object { $null -ne $_.Latency } | ForEach-Object { [double]$_.Latency })
    $sg = [double[]]@($g.Group | Where-Object { $null -ne $_.Signal }  | ForEach-Object { [double]$_.Signal })
    $ls = [double[]]@($g.Group | ForEach-Object { [double]$_.Loss })

    $medSpeed = Get-Median $sp
    $medLat   = Get-Median $lt
    $medSig   = Get-Median $sg
    $medLoss  = Get-Median $ls
    $medScore = Get-Median ([double[]]@($g.Group | ForEach-Object { [double]$_.Score }))

    $agg += [pscustomobject]@{
        BSSID    = $g.Name
        Channel  = ($g.Group | Select-Object -First 1).Channel
        N        = $g.Count
        SigMed   = $medSig
        SpeedMed = $medSpeed
        SpeedMax = if ($sp.Count -gt 0) { [math]::Round(($sp | Measure-Object -Maximum).Maximum, 2) } else { $null }
        LatMed   = $medLat
        LossMed  = $medLoss
        ScoreMed = $medScore
        Complete = ($g.Count -ge $MinSamplesPerAp)
    }
}

$agg = @($agg | Sort-Object -Property @{Expression={ if ($null -eq $_.SpeedMed) { -1 } else { $_.SpeedMed } }; Descending=$true})

$agg | Select-Object @{N='BSSID';E={$_.BSSID}}, @{N='信道';E={$_.Channel}}, @{N='样本';E={$_.N}},
                  @{N='信号中位';E={"$(Format-Null $_.SigMed 'F0')%"}},
                  @{N='速度中位';E={Format-Null $_.SpeedMed 'F2'}},
                  @{N='速度峰值';E={Format-Null $_.SpeedMax 'F2'}},
                  @{N='延迟中位';E={Format-Null $_.LatMed 'F1'}},
                  @{N='丢包中位';E={"$(Format-Null $_.LossMed 'F1')%"}},
                  @{N='综合得分';E={Format-Null $_.ScoreMed 'F4'}} |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Host ''

# ============================================================
#  最优通道 + 切换
# ============================================================
$best = $agg | Where-Object { $null -ne $_.SpeedMed -and $_.Complete } | Select-Object -First 1
if (-not $best) { $best = $agg | Where-Object { $null -ne $_.SpeedMed } | Select-Object -First 1 }

if (-not $best) {
    Write-Host '没有取得任何有效测速数据。' -ForegroundColor Red
} else {
    Write-Host ("最优通道 : BSSID {0}   信道 {1}   速度中位 {2} Mbps   得分 {3}   (样本 {4} 次)" -f `
        $best.BSSID, $best.Channel, (Format-Null $best.SpeedMed 'F2'), (Format-Null $best.ScoreMed 'F4'), $best.N) -ForegroundColor Green

    $lowSample = @($agg | Where-Object { -not $_.Complete }).Count
    if ($lowSample -gt 0) {
        Write-Host ("提示 : 有 {0} 个通道样本不足 {1} 次，结论仅供参考，可加大 -MaxTries 复测。" -f $lowSample, $MinSamplesPerAp) -ForegroundColor Yellow
    }

    Write-Host ''
    $current = Get-WifiInfo
    if ($current.BSSID -eq $best.BSSID) {
        Write-Host ("当前已在最优通道 {0}，无需切换。" -f $best.BSSID) -ForegroundColor Green
    } elseif ($DryRun) {
        Write-Host ("[DryRun] 当前 {0}，目标 {1}，未执行切换。" -f $current.BSSID, $best.BSSID) -ForegroundColor DarkGray
    } else {
        Write-Host ("当前 {0} → 目标 {1}，开始尝试切换..." -f $current.BSSID, $best.BSSID) -ForegroundColor Yellow
        $ok = Connect-TargetBssid -Ssid $wifi.SSID -TargetBssid $best.BSSID -GwIp $gw -MaxRetry $SwitchMaxRetry
        if ($ok) {
            Write-Host ("切换成功，当前已在最优通道 {0}" -f $best.BSSID) -ForegroundColor Green
        } else {
            Write-Host ("[未能切到 {0}]，{1} 次重试均未命中。" -f $best.BSSID, $SwitchMaxRetry) -ForegroundColor Red
            Write-Host '原因：Windows / netsh 不支持指定 BSSID 连接，只能反复重连碰运气。' -ForegroundColor DarkYellow
            Write-Host ("请手动断开 WiFi 后重连，多试几次直到连上 {0}。" -f $best.BSSID) -ForegroundColor DarkYellow
            Write-Host '若该通道长期无法稳定命中，说明它并非真正的最优解，结论需重新评估。' -ForegroundColor DarkYellow
        }
    }
}

# ============================================================
#  CSV 留痕
# ============================================================
try {
    $samples | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host ("采样明细已保存 : {0}" -f $LogPath) -ForegroundColor DarkGray
} catch {
    Write-Host ("写入日志失败 : {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
}

if (-not $NoPause) {
    Write-Host ''
    Write-Host '按任意键退出 ...' -ForegroundColor DarkGray
    try { $null = [Console]::ReadKey() } catch { }
}

try { [Console]::OutputEncoding = $script:PrevOutEnc } catch { }
