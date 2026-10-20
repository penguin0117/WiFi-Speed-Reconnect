# ============================================================
#  WiFi Bench v6
#
#  v5 的问题：用 5 秒单线程 curl 取一个数，那个数测的是"当时镜像站的状态"，
#  不是你的链路。源端一被限速，数字就崩，所以数据再好看也和体感对不上。
#
#  v6 改的是测量方法，不是换个皮：
#    1) 多源 + 多线程，源端先探测，测完标注"是否被源端卡住"
#    2) 15 秒稳态，丢掉前 3 秒预热，取稳态平均，不用瞬时峰值当结论
#    3) 同时测满载延迟（bufferbloat）—— 这是"卡不卡"的直接指标
#    4) 报最差 1 秒窗口 —— 体感卡顿来自谷值，不是均值
#    5) AP 列表可手动选，连过去是轮盘重连（Windows 没有指定 BSSID 的 API）
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File "WiFi_Bench_v6.ps1"
#    WiFi_Bench_v6.ps1 -Test           直接测当前连接（15s）
#    WiFi_Bench_v6.ps1 -Test -Seconds 25
#    WiFi_Bench_v6.ps1 -List           只列 AP
#    WiFi_Bench_v6.ps1 -Connect 3      连接到列表中第 3 个 AP
#    WiFi_Bench_v6.ps1 -Auto           依次切到每个 5G AP 并测速
#    WiFi_Bench_v6.ps1 -Quiet          CSV 用，不打实时进度
# ============================================================

param(
    [int]$Seconds        = 15,     # 测速时长（秒）
    [int]$WarmupSec      = 3,      # 预热丢弃时长
    [int]$Threads        = 6,      # 并发下载线程
    [string]$LatencyTarget = '',   # 延迟探测目标，留空用 223.5.5.5
    [int]$ConnectRetry   = 12,     # 切换 BSSID 的最大重连次数
    [string]$LogPath     = '',
    [switch]$Test,
    [switch]$List,
    [int]$Connect        = 0,      # 1-based AP 编号
    [string]$ConnectBssid = '',    # 按 BSSID 指定 AP，比编号稳定（编号会随信号变化重排）
    [switch]$Auto,                 # 依次测试全部 5G AP
    [switch]$Quiet,
    [switch]$NoPause
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# netsh 的输出语言跟随控制台编码。锁 UTF8 后输出稳定的英文标签。
try {
    $script:PrevOutEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
} catch { }
$global:OutputEncoding = [Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
if (-not $LogPath) { $LogPath = Join-Path $ScriptDir 'wifi_v6_result.csv' }
if (-not $LatencyTarget) { $LatencyTarget = '223.5.5.5' }

# 测速源池。
# 实测教训：镜像站会对高频下载限流（403 / 418 / 429），每次限流后要等几分钟才恢复。
# 所以这里铺开多个不同厂商的源，并且探测只发一次请求，尽量少触发限速。
function Get-SourcePool {
    return @(
        [pscustomobject]@{ Name='tencent'; Url='https://mirrors.cloud.tencent.com/debian/dists/stable/main/binary-amd64/Packages.xz' }
        [pscustomobject]@{ Name='tuna';    Url='https://mirrors.tuna.tsinghua.edu.cn/debian/dists/stable/main/binary-amd64/Packages.xz' }
        [pscustomobject]@{ Name='netease'; Url='https://mirrors.163.com/debian/dists/stable/main/binary-amd64/Packages.xz' }
        [pscustomobject]@{ Name='aliyun';  Url='https://mirrors.aliyun.com/debian/dists/stable/main/binary-amd64/Packages.xz' }
        [pscustomobject]@{ Name='ustc';    Url='https://mirrors.ustc.edu.cn/debian/dists/stable/main/binary-amd64/Packages.xz' }
        [pscustomobject]@{ Name='huawei';  Url='https://mirrors.huaweicloud.com/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso' }
        [pscustomobject]@{ Name='bfsu';    Url='https://mirrors.bfsu.edu.cn/debian/dists/stable/main/binary-amd64/Packages.xz' }
        [pscustomobject]@{ Name='cn99';    Url='https://mirrors.cn99.com/debian/dists/stable/main/binary-amd64/Packages.xz' }
    )
}

# ============================================================
#  采集：当前连接 / AP 列表
# ============================================================
function Get-WifiState {
    $raw = @(& netsh.exe wlan show interfaces 2>$null)
    $st = [pscustomobject]@{
        Connected=$false; Ssid=''; Bssid=''; Band=''; Channel=$null; Rate=$null; Signal=$null; Radio=''
    }
    foreach ($line in $raw) {
        if     ($line -match '^\s*(State|状态)\s*:\s*(.+)$')                  { if ($Matches[2] -match 'connected|已连接') { $st.Connected = $true } }
        elseif ($line -match '^\s*SSID\s*:\s*(.+)$')                          { $st.Ssid    = $Matches[1].Trim() }
        elseif ($line -match 'AP\s*BSSID\s*:\s*(.+)$')                        { $st.Bssid   = $Matches[1].Trim().ToLower() }
        elseif ($line -match '^\s*(Band|波段)\s*:\s*(.+)$')                   { $st.Band    = $Matches[2].Trim() }
        elseif ($line -match '^\s*(Channel|通道)\s*:\s*(\d+)')                { $st.Channel = [int]$Matches[2] }
        elseif ($line -match '^\s*(Signal|信号)\s*:\s*(\d+)')                 { $st.Signal  = [int]$Matches[2] }
        elseif ($line -match '^\s*(Radio type|无线电类型)\s*:\s*(.+)$')      { $st.Radio   = $Matches[2].Trim() }
        elseif ($line -match '^\s*(接收速率|Receive rate)\s*(\(\s*Mbps\s*\))?\s*:\s*(\d+(?:\.\d+)?)') { $st.Rate = [double]$Matches[3] }
    }
    if (-not $st.Ssid) { $st.Connected = $false }
    return $st
}

function Get-BandClass {
    param([string]$Band)
    if (-not $Band) { return '?' }
    if ($Band -match '2\.4')    { return '2.4G' }
    if ($Band -match '6\s*GHz') { return '6G' }
    if ($Band -match '5\s*GHz') { return '5G' }
    return '?'
}

# netsh 的扫描结果是缓存的。连着重连时可能只返回 1 个 AP，
# 而且会卡在这个残缺状态几十秒。所以：多轮合并，仍然只看到 1 个时，
# 用「断开-扫描-重连」强制刷新（仅在需要选 AP 时做，测速路径不碰）。
function Get-VisibleAp {
    param([string]$TargetSsid, [int]$Rounds = 4)

    $seen = @{}
    for ($r = 1; $r -le $Rounds; $r++) {
        $raw = @(& netsh.exe wlan show networks mode=bssid 2>$null)
        $curSsid = $null; $cur = $null
        foreach ($line in $raw) {
            if ($line -match '^\s*SSID\s*\d+\s*:\s*(.+)$') { $curSsid = $Matches[1].Trim(); $cur = $null; continue }
            if ($line -match '^\s*BSSID\s*\d+\s*:\s*([0-9a-fA-F:]{17})') {
                if ($TargetSsid -and $curSsid -ne $TargetSsid) { continue }
                $b = $Matches[1].ToLower()
                $cur = $b
                if (-not $seen.ContainsKey($b)) {
                    $seen[$b] = [pscustomobject]@{ SSID=$curSsid; Bssid=$b; Signal=$null; Band=''; Channel=$null; Radio='' }
                }
                continue
            }
            if (-not $cur) { continue }
            if     ($line -match '^\s*(Signal|信号)\s*:\s*(\d+)')                   { $seen[$cur].Signal  = [int]$Matches[2] }
            elseif ($line -match '^\s*(Band|波段)\s*:\s*(.+)$')                     { $seen[$cur].Band    = $Matches[2].Trim() }
            elseif ($line -match '^\s*(Channel|通道)\s*:\s*(\d+)')                  { $seen[$cur].Channel = [int]$Matches[2] }
            elseif ($line -match '^\s*(Radio type|无线电类型)\s*:\s*(.+)$')        { $seen[$cur].Radio   = $Matches[2].Trim() }
        }
        if ($seen.Count -ge 3) { break }
        if ($r -lt $Rounds) { Start-Sleep -Milliseconds 1500 }
    }

    $list = @($seen.Values | Sort-Object -Property @{Expression={ Get-BandClass $_.Band }; Descending=$false}, @{Expression='Signal'; Descending=$true})
    return $list
}

# 强制刷新：断开 → 扫描 → 重连。只在扫描结果残缺且用户要选 AP 时用。
function Get-VisibleApForced {
    param([string]$TargetSsid, [string]$CurrentSsid)

    Write-Host '  扫描结果异常（只看到 1 个 AP），强制刷新列表：断开 → 扫描 → 重连 ...' -ForegroundColor DarkYellow
    & netsh.exe wlan disconnect 2>$null | Out-Null
    Start-Sleep -Milliseconds 2000
    $list = @(Get-VisibleAp -TargetSsid $TargetSsid -Rounds 3)
    & netsh.exe wlan connect "name=$CurrentSsid" 2>$null | Out-Null
    Start-Sleep -Milliseconds 2500
    return $list
}

function Show-ApList {
    param($Aps, $Current)

    Write-Host ''
    Write-Host '  #   BSSID               频段    信道   信号   制式       备注' -ForegroundColor DarkGray
    $i = 0
    foreach ($ap in $Aps) {
        $i++
        $mark = ''
        if ($Current -and $ap.Bssid -eq $Current.Bssid) { $mark = '<= 当前' }
        $band = Get-BandClass $ap.Band
        $color = if ($band -eq '2.4G') { 'DarkYellow' } else { 'White' }
        Write-Host (" {0,2}   {1,-19} {2,-6} {3,4}  {4,4}%  {5,-10} {6}" -f `
            $i, $ap.Bssid, $ap.Band, $ap.Channel, $ap.Signal, $ap.Radio, $mark) -ForegroundColor $color
    }
    Write-Host ''
    if ($Aps.Count -le 1) {
        Write-Host '注意：这次只扫到 1 个 AP，多半是 Windows 的扫描缓存没刷新。' -ForegroundColor DarkYellow
        Write-Host '      要完整列表（选 AP 用），加 -List 参数，程序会强制断开重扫一次。' -ForegroundColor DarkYellow
    } else {
        Write-Host ("共 {0} 个 AP：5G/6G {1} 个，2.4G {2} 个" -f `
            $Aps.Count,
            (@($Aps | Where-Object { (Get-BandClass $_.Band) -ne '2.4G' }).Count),
            (@($Aps | Where-Object { (Get-BandClass $_.Band) -eq '2.4G' }).Count)) -ForegroundColor DarkGray
    }
}

# ============================================================
#  切 BSSID：Windows 没有指定 BSSID 的 API，只能断开重连碰运气。
#  命中率取决于系统打分，这里如实显示每次尝试的结果，不假装能锁定。
# ============================================================
function Connect-Bssid {
    param([string]$Ssid, [string]$TargetBssid, [int]$MaxRetry = 12)

    if (-not $TargetBssid) { return $false }
    $hit = 0
    for ($i = 1; $i -le $MaxRetry; $i++) {
        & netsh.exe wlan disconnect 2>$null | Out-Null
        Start-Sleep -Milliseconds 1200
        & netsh.exe wlan connect "name=$Ssid" 2>$null | Out-Null

        $got = $null
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 700
            $s = Get-WifiState
            if ($s.Connected) { $got = $s; break }
        }

        if (-not $got) {
            if (-not $Quiet) { Write-Host ("   [{0,2}/{1}] 未连上" -f $i, $MaxRetry) -ForegroundColor DarkYellow }
            continue
        }
        if ($got.Bssid -eq $TargetBssid) {
            $hit++
            if (-not $Quiet) { Write-Host ("   [{0,2}/{1}] 命中 {2}  ch{3}" -f $i, $MaxRetry, $got.Bssid, $got.Channel) -ForegroundColor Green }
            return $true
        }
        if (-not $Quiet) { Write-Host ("   [{0,2}/{1}] 落到 {2}，不是目标" -f $i, $MaxRetry, $got.Bssid) -ForegroundColor DarkGray }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

# ============================================================
#  源端探测：3 秒单线程，选出能跑起来的源
# ============================================================
function Test-SourceSpeed {
    param([string]$Url, [int]$ProbeSec = 3)

    # 不做预热：多一次请求就多一次触发限流的机会
    $r = & curl.exe -L -o NUL -s --max-time $ProbeSec -w '%{http_code}|%{speed_download}' $Url 2>$null
    if (-not $r) { return [pscustomobject]@{ Ok=$false; Mbps=0; Code='000'; Note='无响应' } }
    $p = $r -split '\|'
    $code = $p[0]
    $mbps = if ($p[1]) { [double]$p[1] * 8 / 1e6 } else { 0 }

    $note = ''
    if ($code -match '^(403|418|429)$') { $note = '被限流' }
    elseif ($code -eq '404') { $note = '文件不存在' }
    elseif ($code -ne '200') { $note = "HTTP $code" }

    $ok = ($code -eq '200' -and $mbps -ge 1)
    return [pscustomobject]@{ Ok=$ok; Mbps=[math]::Round($mbps,1); Code=$code; Note=$note }
}

# ============================================================
#  测速引擎：N 个 runspace 并发下载 + 一个延迟探针
#  数据通过固定长度数组在 runspace 之间共享，避免锁。
# ============================================================
function Invoke-LoadTest {
    param(
        [string[]]$Urls, [int]$Threads, [int]$DurationSec,
        [string]$LatencyTarget, [bool]$ShowProgress
    )

    $stop     = [bool[]]::new(1)
    $counters = [long[]]::new($Threads)
    $errs     = New-Object string[] $Threads

    # 延迟采样：每秒约 2.5 次 TCP 握手计时
    $latCap   = [int]($DurationSec * 3) + 6
    $latBuf   = New-Object int[] $latCap
    $latIdx   = [int[]]::new(1)

    $pool = [runspacefactory]::CreateRunspacePool(1, $Threads + 1)
    $pool.Open()
    $jobs = @()

    for ($i = 0; $i -lt $Threads; $i++) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript({
            param($url, $idx, $counters, $stop, $errs)
            [System.Net.ServicePointManager]::DefaultConnectionLimit = 32
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $buf = New-Object byte[] 262144
            while (-not $stop[0]) {
                try {
                    $req = [System.Net.WebRequest]::Create($url)
                    $req.Timeout = 30000
                    $req.ReadWriteTimeout = 30000
                    $resp = $req.GetResponse()
                    $s = $resp.GetResponseStream()
                    while (-not $stop[0]) {
                        $n = $s.Read($buf, 0, $buf.Length)
                        if ($n -le 0) { break }
                        $counters[$idx] = $counters[$idx] + $n
                    }
                    $s.Dispose(); $resp.Close()
                } catch {
                    $errs[$idx] = $_.Exception.GetBaseException().Message
                    Start-Sleep -Milliseconds 250
                }
            }
        }).AddArgument($Urls[$i % $Urls.Count]).AddArgument($i).AddArgument($counters).AddArgument($stop).AddArgument($errs)
        $jobs += @{ PS = $ps; H = $ps.BeginInvoke() }
    }

    # 延迟探针（满载期间跑，用于算 bufferbloat）
    $psL = [powershell]::Create()
    $psL.RunspacePool = $pool
    [void]$psL.AddScript({
        param($target, $buf, $idxBox, $stop)
        $n = $buf.Length
        while (-not $stop[0]) {
            $k = $idxBox[0]
            if ($k -ge $n) { break }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $c = $null
            try {
                $c = New-Object Net.Sockets.TcpClient
                $iar = $c.BeginConnect($target, 443, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(1500)) {
                    try { $c.EndConnect($iar) } catch { }
                    $sw.Stop()
                    $buf[$k] = [int]$sw.ElapsedMilliseconds
                    $idxBox[0] = $k + 1
                }
            } catch { } finally { if ($c) { $c.Close() } }
            Start-Sleep -Milliseconds 380
        }
    }).AddArgument($LatencyTarget).AddArgument($latBuf).AddArgument($latIdx).AddArgument($stop)
    $jobs += @{ PS = $psL; H = $psL.BeginInvoke() }

    # 采样循环
    $series = New-Object System.Collections.Generic.List[double]
    $prev = [long]0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tickMs = 250

    while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
        Start-Sleep -Milliseconds $tickMs
        $sum = [long]0
        foreach ($c in $counters) { $sum += $c }
        $inst = ($sum - $prev) * 8 / 1e6 / ($tickMs / 1000.0)
        $prev = $sum
        [void]$series.Add($inst)

        if ($ShowProgress) {
            $ratio = [math]::Min(1.0, $sw.Elapsed.TotalSeconds / $DurationSec)
            $w = 30
            $fill = [int]($ratio * $w)
            $bar = ('=' * $fill) + (' ' * ($w - $fill))
            $remain = [int]($DurationSec - $sw.Elapsed.TotalSeconds)
            Write-Host ("`r  [{0}] {1,7:N1} Mbps   剩余 {2,2}s " -f $bar, $inst, $remain) -NoNewline
        }
    }

    $stop[0] = $true
    Start-Sleep -Milliseconds 800
    foreach ($j in $jobs) { try { $j.PS.EndInvoke($j.H) } catch { }; $j.PS.Dispose() }
    $pool.Close(); $pool.Dispose()
    if ($ShowProgress) { Write-Host '' }

    $total = [long]0
    foreach ($c in $counters) { $total += $c }

    $lats = @()
    $cnt = [math]::Min($latIdx[0], $latCap)
    for ($k = 0; $k -lt $cnt; $k++) { if ($latBuf[$k] -gt 0) { $lats += $latBuf[$k] } }

    return [pscustomobject]@{
        Series   = $series.ToArray()
        TotalB   = $total
        Latency  = [int[]]$lats
        Errors   = @($errs | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Get-Stats {
    param([double[]]$Series, [int]$WarmupSec, [double]$TickSec)

    if (-not $Series -or $Series.Count -eq 0) { return $null }

    $skip = [int]($WarmupSec / $TickSec)
    $steady = if ($Series.Count -gt $skip) { $Series[$skip..($Series.Count - 1)] } else { $Series }
    if ($steady.Count -eq 0) { $steady = $Series }

    $avg = ($steady | Measure-Object -Average).Average

    # 1 秒滑窗
    $perSec = [int](1.0 / $TickSec)
    $windows = @()
    for ($i = 0; $i + $perSec -le $Series.Count; $i++) {
        $slice = $Series[$i..($i + $perSec - 1)]
        $windows += [math]::Round(($slice | Measure-Object -Average).Average, 1)
    }

    # 稳态段的滑窗（峰值/最差都用稳态段，避免把预热算进去）
    $wSteady = @()
    for ($i = 0; $i + $perSec -le $steady.Count; $i++) {
        $slice = $steady[$i..($i + $perSec - 1)]
        $wSteady += [math]::Round(($slice | Measure-Object -Average).Average, 1)
    }
    if ($wSteady.Count -eq 0) { $wSteady = @($avg) }

    return [pscustomobject]@{
        SteadyAvg = [math]::Round($avg, 1)
        Peak      = ($wSteady | Measure-Object -Maximum).Maximum
        Worst     = ($wSteady | Measure-Object -Minimum).Minimum
        Samples   = $steady.Count
    }
}

function Get-LatencyStats {
    param([int[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    $n = $s.Count
    $p50 = $s[[int][math]::Floor($n * 0.5)]
    $p95 = $s[[math]::Min($n - 1, [int][math]::Floor($n * 0.95))]
    $jit = 0.0
    if ($n -gt 1) {
        $d = @()
        for ($i = 1; $i -lt $n; $i++) { $d += [math]::Abs($s[$i] - $s[$i - 1]) }
        $jit = ($d | Measure-Object -Average).Average
    }
    return [pscustomobject]@{
        N = $n
        P50 = $p50
        P95 = $p95
        Max = $s[$n - 1]
        Jitter = [math]::Round($jit, 1)
    }
}

function Test-IdleLatency {
    param([string]$Target, [int]$Samples = 16)

    $vals = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $c = $null
        try {
            $c = New-Object Net.Sockets.TcpClient
            $iar = $c.BeginConnect($Target, 443, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(1500)) {
                try { $c.EndConnect($iar) } catch { }
                $sw.Stop()
                # 前两次是冷路径，丢掉
                if ($i -ge 2) { $vals += [int]$sw.ElapsedMilliseconds }
            }
        } catch { } finally { if ($c) { $c.Close() } }
        Start-Sleep -Milliseconds 300
    }
    return [int[]]$vals
}

# ============================================================
#  结论：把数字翻译成人话
# ============================================================
function Get-Verdict {
    param($S, $Idle, $Loaded, $SourceCap, $BandClass, $Rate)

    $notes = @()

    if ($null -eq $S -or $S.SteadyAvg -le 0) { return @('测速失败：所有下载线程都没拿到数据。') }

    # 1. 是不是被源端卡住（三档判断，别拿一个数硬套）
    if ($SourceCap -and $SourceCap -gt 0) {
        if ($S.SteadyAvg -gt ($SourceCap * 1.15)) {
            $notes += ("稳态 {0:N0} Mbps，高于源端探测合计 {1:N0} Mbps —— 源端不是瓶颈，这个数能代表链路附近的能力。" -f $S.SteadyAvg, $SourceCap)
        } elseif ($S.SteadyAvg -ge ($SourceCap * 0.85)) {
            $notes += ("稳态 {0:N0} Mbps 与源端探测合计 {1:N0} Mbps 基本持平 —— 很可能卡在源端，别拿这个数判断链路好坏。" -f $S.SteadyAvg, $SourceCap)
        } else {
            $notes += ("稳态 {0:N0} Mbps，明显低于源端探测合计 {1:N0} Mbps —— 瓶颈在链路侧（空口/干扰/出口）。" -f $S.SteadyAvg, $SourceCap)
        }
    } else {
        $notes += ("稳态 {0:N0} Mbps。" -f $S.SteadyAvg)
    }

    # 2. 波动
    if ($S.Worst -lt ($S.SteadyAvg * 0.35)) {
        $notes += ("最差 1 秒只有 {0:N0} Mbps（均值的 {1:N0}%）—— 速率起伏大，下载和视频会一顿一顿。" -f $S.Worst, (100 * $S.Worst / $S.SteadyAvg))
    } else {
        $notes += ("最差 1 秒 {0:N0} Mbps，速率平稳。" -f $S.Worst)
    }

    # 3. bufferbloat：用中位数比，p95 在小样本上不稳
    if ($Idle -and $Loaded) {
        $delta = $Loaded.P50 - $Idle.P50
        if ($delta -ge 100) {
            $notes += ("满载延迟中位比空闲高 {0:N0} ms（{1} → {2} ms）—— 明显 bufferbloat，下载时视频会议、游戏会卡。" -f $delta, $Idle.P50, $Loaded.P50)
        } elseif ($delta -ge 30) {
            $notes += ("满载延迟中位升高 {0:N0} ms（{1} → {2} ms）—— 轻度排队，高负载时会感到顿。" -f $delta, $Idle.P50, $Loaded.P50)
        } else {
            $notes += ("满载延迟中位只升高 {0:N0} ms（{1} → {2} ms）—— 排队控制良好。" -f $delta, $Idle.P50, $Loaded.P50)
        }
    }

    # 4. 频段
    if ($BandClass -eq '2.4G') {
        $notes += "当前在 2.4GHz。同信道拥挤，速度和稳定性都会明显低于 5GHz，别在这里下结论。"
    }

    # 5. 协商速率对照
    if ($Rate -and $Rate -gt 0) {
        $eff = 100 * $S.SteadyAvg / $Rate
        $notes += ("实测 / 协商 = {0:N0}%（协商 {1:N0} Mbps）" -f $eff, $Rate)
        if ($eff -lt 25) {
            $notes += "效率低于 25%，说明瓶颈不在空口速率，而在源端、出口或干扰。"
        }
    }

    return $notes
}

# ============================================================
#  把一次测速跑完 + 落库
# ============================================================
function Invoke-FullTest {
    param($State, [bool]$ShowProgress)

    $pool = @(Get-SourcePool)
    if ($ShowProgress) { Write-Host '' ; Write-Host '探测测速源 ...' -ForegroundColor DarkGray }

    $good = @()
    $throttled = @()
    foreach ($s in $pool) {
        $m = Test-SourceSpeed -Url $s.Url -ProbeSec 3
        if ($m.Ok) {
            $good += [pscustomobject]@{ Name = $s.Name; Url = $s.Url; Mbps = $m.Mbps }
            if ($ShowProgress) { Write-Host ("  {0,-9} {1,7:N1} Mbps" -f $s.Name, $m.Mbps) -ForegroundColor DarkGray }
        } else {
            $tag = if ($m.Note) { $m.Note } else { '不可用' }
            if ($m.Note -eq '被限流') { $throttled += $s.Name }
            if ($ShowProgress) { Write-Host ("  {0,-9} {1}" -f $s.Name, $tag) -ForegroundColor DarkGray }
        }
    }
    if ($good.Count -eq 0) {
        Write-Host '没有可用的测速源。' -ForegroundColor Red
        if ($throttled.Count -gt 0) {
            Write-Host ("说明：{0} 正在限流（HTTP 403/418/429）。镜像站对短时间内反复下载会封几分钟，" -f ($throttled -join ' / ')) -ForegroundColor DarkYellow
            Write-Host '      这是源端问题，不是你的网络问题。等 3-5 分钟再跑，或者换 -Source 指定别的源。' -ForegroundColor DarkYellow
        }
        return $null
    }

    $good = @($good | Sort-Object -Property Mbps -Descending)
    $useCount = [math]::Min($good.Count, 3)
    $urls = @($good[0..($useCount - 1)] | ForEach-Object { $_.Url })
    # 源少于线程数时重复铺开
    $expanded = @()
    for ($i = 0; $i -lt $Threads; $i++) { $expanded += $urls[$i % $urls.Count] }

    $cap = 0.0
    for ($i = 0; $i -lt $useCount; $i++) { $cap += $good[$i].Mbps }

    if ($ShowProgress) {
        Write-Host ("源 : {0}   线程 {1}   时长 {2}s" -f (($good[0..($useCount-1)] | ForEach-Object { $_.Name }) -join ' / '), $Threads, $Seconds) -ForegroundColor Yellow
        Write-Host '空闲延迟基线 ...' -ForegroundColor DarkGray
    }
    $idle = Test-IdleLatency -Target $LatencyTarget -Samples 12
    $idleStats = Get-LatencyStats $idle

    if ($ShowProgress) { Write-Host '' }
    $res = Invoke-LoadTest -Urls $expanded -Threads $Threads -DurationSec $Seconds `
                           -LatencyTarget $LatencyTarget -ShowProgress $ShowProgress

    $st = Get-Stats -Series $res.Series -WarmupSec $WarmupSec -TickSec 0.25
    $loadedStats = Get-LatencyStats $res.Latency

    return [pscustomobject]@{
        State       = $State
        BandClass   = Get-BandClass $State.Band
        Stats       = $st
        Idle        = $idleStats
        Loaded      = $loadedStats
        SourceCap   = $cap
        Sources     = ($good[0..($useCount-1)] | ForEach-Object { $_.Name }) -join '+'
        Errors      = $res.Errors
        Time        = (Get-Date)
    }
}

function Write-ResultCsv {
    param($R)

    if (-not $R -or -not $R.Stats) { return }

    # 先把条件值算出来，PS 5.1 的哈希字面量里不能直接写 if
    $idleP95   = ''
    $loadedP95 = ''
    $bloatMs   = ''
    $jitMs     = ''
    $latN      = 0
    if ($R.Idle)   { $idleP95   = $R.Idle.P95 }
    if ($R.Loaded) { $loadedP95 = $R.Loaded.P95; $jitMs = $R.Loaded.Jitter; $latN = $R.Loaded.N }
    if ($R.Idle -and $R.Loaded) { $bloatMs = $R.Loaded.P95 - $R.Idle.P95 }

    $row = [pscustomobject]@{
        Time          = $R.Time.ToString('yyyy-MM-dd HH:mm:ss')
        Ssid          = $R.State.Ssid
        Bssid         = $R.State.Bssid
        Band          = $R.BandClass
        Channel       = $R.State.Channel
        Signal        = $R.State.Signal
        LinkMbps      = $R.State.Rate
        Sources       = $R.Sources
        Threads       = $Threads
        WindowSec     = $Seconds
        SteadyMbps    = $R.Stats.SteadyAvg
        PeakMbps      = $R.Stats.Peak
        WorstMbps     = $R.Stats.Worst
        IdleP95       = $idleP95
        LoadedP95     = $loadedP95
        BloatMs       = $bloatMs
        JitterMs      = $jitMs
        LatSamples    = $latN
        SourceCapMbps = $R.SourceCap
    }

    if (Test-Path $LogPath) {
        $row | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8 -Append
    } else {
        $row | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
    }
}

function Show-Result {
    param($R)

    if (-not $R -or -not $R.Stats) {
        Write-Host '没有有效结果。' -ForegroundColor Red
        return
    }

    $S = $R.Stats
    Write-Host ''
    Write-Host '---------------- 结果 ----------------' -ForegroundColor Cyan
    Write-Host ("  AP            {0}  {1}  ch{2}  信号 {3}%" -f $R.State.Bssid, $R.BandClass, $R.State.Channel, $R.State.Signal)
    Write-Host ("  协商速率      {0} Mbps" -f $R.State.Rate)
    Write-Host ("  稳态下行      {0,7:N1} Mbps     干掉前 {1}s 预热，取 {2} 个采样" -f $S.SteadyAvg, $WarmupSec, $S.Samples) -ForegroundColor Green
    Write-Host ("  峰值 1 秒     {0,7:N1} Mbps" -f $S.Peak)
    Write-Host ("  最差 1 秒     {0,7:N1} Mbps" -f $S.Worst) -ForegroundColor $(if ($S.Worst -lt $S.SteadyAvg * 0.35) { 'Yellow' } else { 'Gray' })
    if ($R.Idle)   { Write-Host ("  空闲延迟      {0,7} ms  p95 {1}" -f $R.Idle.P50, $R.Idle.P95) }
    if ($R.Loaded) { Write-Host ("  满载延迟      {0,7} ms  p95 {1}   抖动 {2} ms" -f $R.Loaded.P50, $R.Loaded.P95, $R.Loaded.Jitter) }
    if ($R.Idle -and $R.Loaded) {
        $d = $R.Loaded.P50 - $R.Idle.P50
        $c = if ($d -ge 100) { 'Red' } elseif ($d -ge 30) { 'Yellow' } else { 'Green' }
        Write-Host ("  延迟增量      {0,7} ms   (满载中位 - 空闲中位)" -f $d) -ForegroundColor $c
    }
    Write-Host ("  源端合计      {0,7:N1} Mbps   ({1})" -f $R.SourceCap, $R.Sources) -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '---------------- 结论 ----------------' -ForegroundColor Cyan
    foreach ($n in (Get-Verdict -S $S -Idle $R.Idle -Loaded $R.Loaded -SourceCap $R.SourceCap -BandClass $R.BandClass -Rate $R.State.Rate)) {
        Write-Host ("  · {0}" -f $n) -ForegroundColor White
    }
    if ($R.Errors) {
        Write-Host ("  · 部分线程报错：{0}" -f ($R.Errors[0])) -ForegroundColor DarkYellow
    }
    Write-Host ''
}

# ============================================================
#  主流程
# ============================================================
Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '   WiFi Bench v6   稳态 / 满载延迟 / 手动选 AP' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

$state = Get-WifiState
if (-not $state.Connected) {
    Write-Host '未连接 WiFi，退出。' -ForegroundColor Red
    exit 1
}

Write-Host ("当前 : {0}   {1}   ch{2}   {3}   {4} Mbps" -f `
    $state.Ssid, $state.Band, $state.Channel, $state.Bssid, $state.Rate) -ForegroundColor White

$aps = @(Get-VisibleAp -TargetSsid $state.Ssid -Rounds 4)
if ($aps.Count -le 1 -and ($List -or $Connect -gt 0 -or $ConnectBssid -or $Auto)) {
    $aps = @(Get-VisibleApForced -TargetSsid $state.Ssid -CurrentSsid $state.Ssid)
    $state = Get-WifiState
}
Show-ApList -Aps $aps -Current $state

if ($List) { exit 0 }

# ---- 连接指定 AP ----
if ($Connect -gt 0 -or $ConnectBssid) {

    $target = $null
    if ($ConnectBssid) {
        $norm = $ConnectBssid.Trim().ToLower()
        $target = @($aps | Where-Object { $_.Bssid -eq $norm }) | Select-Object -First 1
        if (-not $target) {
            Write-Host ("列表里找不到 {0}。" -f $ConnectBssid) -ForegroundColor Red
            Write-Host '可能信号太弱这次没扫到，或者这个 BSSID 已经不存在了。先跑 -List 看看。' -ForegroundColor DarkYellow
            exit 1
        }
    } else {
        if ($Connect -gt $aps.Count) {
            Write-Host ("编号超范围：只有 {0} 个 AP。" -f $aps.Count) -ForegroundColor Red
            exit 1
        }
        $target = $aps[$Connect - 1]
    }
    Write-Host ''
    Write-Host ("目标 : {0}   {1}   ch{2}" -f $target.Bssid, $target.Band, $target.Channel) -ForegroundColor Yellow
    Write-Host ("说明 : Windows 没有『连接到指定 BSSID』的接口，只能断开重连碰运气，最多试 {0} 次。" -f $ConnectRetry) -ForegroundColor DarkGray

    $ok = Connect-Bssid -Ssid $state.Ssid -TargetBssid $target.Bssid -MaxRetry $ConnectRetry
    if ($ok) {
        Write-Host '已连上目标 AP。' -ForegroundColor Green
    } else {
        Write-Host ("{0} 次重连都没命中 {1}。" -f $ConnectRetry, $target.Bssid) -ForegroundColor Red
        Write-Host '这台 AP 可能不是系统当前会优先选择的那个；可以加大 -ConnectRetry，或手动在系统托盘里断开重连直到命中。' -ForegroundColor DarkYellow
        $state = Get-WifiState
    }
    if (-not $Test -and -not $Auto) {
        if (-not $NoPause) { Write-Host '按任意键退出 ...' -ForegroundColor DarkGray; try { $null = [Console]::ReadKey() } catch { } }
        exit 0
    }
}

# ---- 自动遍历全部 5G AP ----
if ($Auto) {
    $targets = @($aps | Where-Object { (Get-BandClass $_.Band) -ne '2.4G' })
    if ($targets.Count -eq 0) { $targets = $aps }

    $rows = @()
    $i = 0
    foreach ($ap in $targets) {
        $i++
        Write-Host ''
        Write-Host ("===== [{0}/{1}] {2}  ch{3} =====" -f $i, $targets.Count, $ap.Bssid, $ap.Channel) -ForegroundColor Cyan

        $cur = Get-WifiState
        if ($cur.Bssid -ne $ap.Bssid) {
            $ok = Connect-Bssid -Ssid $state.Ssid -TargetBssid $ap.Bssid -MaxRetry $ConnectRetry
            if (-not $ok) {
                Write-Host '  切不过去，跳过。' -ForegroundColor DarkYellow
                continue
            }
        }
        $cur = Get-WifiState
        if ($cur.Bssid -ne $ap.Bssid) { Write-Host '  当前不在目标 AP，跳过。' -ForegroundColor DarkYellow; continue }

        $r = Invoke-FullTest -State $cur -ShowProgress (-not $Quiet)
        if ($r) {
            Show-Result -R $r
            Write-ResultCsv -R $r
            $bloat = $null
            if ($r.Idle -and $r.Loaded) { $bloat = $r.Loaded.P95 - $r.Idle.P95 }
            $rows += [pscustomobject]@{
                Bssid  = $r.State.Bssid
                Band   = $r.BandClass
                Ch     = $r.State.Channel
                Steady = $r.Stats.SteadyAvg
                Worst  = $r.Stats.Worst
                Bloat  = $bloat
            }
        }
    }

    if ($rows.Count -gt 0) {
        Write-Host ''
        Write-Host '========== 各 AP 汇总 ==========' -ForegroundColor Cyan
        $rows | Sort-Object -Property Steady -Descending |
            Format-Table @{N='BSSID';E={$_.Bssid}}, @{N='频段';E={$_.Band}}, @{N='信道';E={$_.Ch}},
                         @{N='稳态Mbps';E={"{0:N1}" -f $_.Steady}}, @{N='最差1s';E={"{0:N1}" -f $_.Worst}},
                         @{N='延迟增量ms';E={ if ($null -ne $_.Bloat) { "{0}" -f $_.Bloat } else { '-' } }} `
                -AutoSize | Out-String -Width 160 | Write-Host
    }

    if (-not $NoPause) { Write-Host '按任意键退出 ...' -ForegroundColor DarkGray; try { $null = [Console]::ReadKey() } catch { } }
    exit 0
}

# ---- 默认：测当前连接 ----
$r = Invoke-FullTest -State (Get-WifiState) -ShowProgress (-not $Quiet)
Show-Result -R $r
if ($r) { Write-ResultCsv -R $r; Write-Host ("结果已追加 : {0}" -f $LogPath) -ForegroundColor DarkGray }

if (-not $NoPause) {
    Write-Host '按任意键退出 ...' -ForegroundColor DarkGray
    try { $null = [Console]::ReadKey() } catch { }
}
try { [Console]::OutputEncoding = $script:PrevOutEnc } catch { }
