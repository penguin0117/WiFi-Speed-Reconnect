# ============================================================
#  Band Guard  v1
#  职责只有一个：盯住频段。一旦掉到 2.4GHz，把链路拉回 5/6GHz。
#
#  它不做测速、不 ping、不排名、不枚举 AP。
#  理由：带宽数字和实际体感的相关性极低，断连次数才是。
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File "Band_Guard.ps1"
#    Band_Guard.ps1 -Once        只检查一次（适合计划任务）
#    Band_Guard.ps1 -Status      读日志，汇总过去掉 2.4G / 断连次数
#    Band_Guard.ps1 -DryRun      只检测告警，不断网
#
#  退出码：0 正常 / 1 未连接 / 3 修复失败
# ============================================================

param(
    [int]$IntervalSec     = 20,    # 巡检间隔（秒）
    [int]$MaxFixAttempts  = 3,     # 单次掉频最多重连几次
    [int]$BackoffSec      = 300,   # 修不好就退避这么久，禁止死循环刷断网
    [string]$Ssid         = '',    # 留空则取当前连接的 SSID
    [string]$LogPath      = '',
    [switch]$Once,
    [switch]$Status,
    [switch]$DryRun,
    [switch]$Pause,       # 暂停修复：掉到 2.4G 只记录，不断网
    [switch]$Resume,      # 恢复修复
    [switch]$Toggle,      # 切换暂停状态（给一键 bat 用）
    [switch]$NoPause
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# netsh 跟随控制台编码决定输出语言。锁 UTF8 后输出稳定的英文标签，解析不依赖系统语言。
try {
    $script:PrevOutEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
} catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
if (-not $LogPath) { $LogPath = Join-Path $ScriptDir 'band_guard_log.csv' }

# 暂停标记文件。存在 = 只观察不修复。
# 场景：正在打游戏，宁可 90ms 抖动也不要 2 秒断线。
$PauseFile = Join-Path $ScriptDir 'band_guard.pause'
function Test-GuardPaused { return (Test-Path $PauseFile) }

# ============================================================
#  状态读取
# ============================================================
function Get-WifiState {
    $raw = @(& netsh.exe wlan show interfaces 2>$null)

    $st = [pscustomobject]@{
        Connected = $false
        Ssid      = ''
        Bssid     = ''
        Band      = ''
        Channel   = $null
        Rate      = $null
        State     = ''
    }

    foreach ($line in $raw) {
        if ($line -match '^\s*(State|状态)\s*:\s*(.+)$')                { $st.State = $Matches[2].Trim() }
        elseif ($line -match '^\s*SSID\s*:\s*(.+)$')                    { $st.Ssid  = $Matches[1].Trim() }
        elseif ($line -match 'AP\s*BSSID\s*:\s*(.+)$')                  { $st.Bssid = $Matches[1].Trim().ToLower() }
        elseif ($line -match '^\s*(Band|波段)\s*:\s*(.+)$')             { $st.Band  = $Matches[2].Trim() }
        elseif ($line -match '^\s*(Channel|通道)\s*:\s*(\d+)')          { $st.Channel = [int]$Matches[2] }
        elseif ($line -match '^\s*(接收速率|Receive rate)\s*(\(\s*Mbps\s*\))?\s*:\s*(\d+(?:\.\d+)?)') { $st.Rate = [double]$Matches[3] }
    }

    # 中文系统 State 值是「已连接」
    $st.Connected = ($st.State -match 'connected|已连接') -and [bool]$st.Ssid
    return $st
}

# 归一化成 2.4G / 5G / 6G，方便比较
function Get-BandClass {
    param([string]$Band)
    if (-not $Band) { return 'unknown' }
    if ($Band -match '2\.4') { return '2.4G' }
    if ($Band -match '6\s*GHz') { return '6G' }
    if ($Band -match '5\s*GHz') { return '5G' }
    return 'unknown'
}

# ============================================================
#  日志
# ============================================================
$LogColumns = @(
    'Time','Event','Ssid','BandBefore','ChBefore','BssidBefore',
    'BandAfter','ChAfter','BssidAfter','Attempts','Msg'
)

function Write-Log {
    param(
        [string]$Event, $Before, $After,
        [int]$Attempts = 0, [string]$Msg = ''
    )

    $row = [pscustomobject]@{
        Time        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Event       = $Event
        Ssid        = $(if ($Before) { $Before.Ssid } else { '' })
        BandBefore  = $(if ($Before) { $Before.Band } else { '' })
        ChBefore    = $(if ($Before) { $Before.Channel } else { '' })
        BssidBefore = $(if ($Before) { $Before.Bssid } else { '' })
        BandAfter   = $(if ($After)  { $After.Band } else { '' })
        ChAfter     = $(if ($After)  { $After.Channel } else { '' })
        BssidAfter  = $(if ($After)  { $After.Bssid } else { '' })
        Attempts    = $Attempts
        Msg         = $Msg
    }

    $exists = Test-Path $LogPath
    try {
        if ($exists) {
            $row | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8 -Append
        } else {
            $row | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
        }
    } catch { }
}

# ============================================================
#  状态摘要
# ============================================================
function Show-Status {
    if (-not (Test-Path $LogPath)) {
        Write-Host ("日志不存在：{0}" -f $LogPath) -ForegroundColor Yellow
        Write-Host '先跑一次 -Once 或直接启动监控，才会有记录。' -ForegroundColor DarkGray
        return 0
    }

    $rows = @(Import-Csv -Path $LogPath)
    if ($rows.Count -eq 0) {
        Write-Host '日志为空。' -ForegroundColor Yellow
        return 0
    }

    $first = [datetime]::Parse($rows[0].Time)
    $last  = [datetime]::Parse($rows[-1].Time)
    $span  = $last - $first

    Write-Host ''
    Write-Host '========== Band Guard 汇总 ==========' -ForegroundColor Cyan
    Write-Host ("记录区间 : {0}  ~  {1}   (跨度 {2:N1} 小时)" -f `
        $first.ToString('MM-dd HH:mm'), $last.ToString('MM-dd HH:mm'), $span.TotalHours) -ForegroundColor White
    Write-Host ("日志文件 : {0}" -f $LogPath) -ForegroundColor DarkGray
    Write-Host ''

    $g = $rows | Group-Object -Property Event
    $order = @('BAND_2G4','FIX_OK','FIX_FAIL','LINK_DOWN','LINK_UP','START','STOP')
    foreach ($name in $order) {
        $hit = $g | Where-Object { $_.Name -eq $name }
        if (-not $hit) { continue }
        $label = switch ($name) {
            'BAND_2G4'  { '掉到 2.4GHz 次数' }
            'FIX_OK'    { '成功拉回高频次数' }
            'FIX_FAIL'  { '拉回失败次数' }
            'LINK_DOWN' { '断链次数' }
            'LINK_UP'   { '重新连上次数' }
            'START'     { '启动次数' }
            'STOP'      { '停止次数' }
            default     { $name }
        }
        Write-Host ("{0,-22} {1,6}" -f $label, $hit.Count) -ForegroundColor White
    }

    # 每天掉频次数
    $byDay = $rows | Where-Object { $_.Event -eq 'BAND_2G4' } |
             Group-Object -Property { ([datetime]::Parse($_.Time)).ToString('yyyy-MM-dd') }
    if ($byDay) {
        Write-Host ''
        Write-Host '---- 每天掉到 2.4GHz 的次数 ----' -ForegroundColor Cyan
        foreach ($d in ($byDay | Sort-Object Name)) {
            $bar = '#' * [math]::Min(60, $d.Count)
            Write-Host ("  {0}  {1,4}  {2}" -f $d.Name, $d.Count, $bar) -ForegroundColor Gray
        }
    }

    # 高频时段（哪个钟点最容易掉）
    $byHour = $rows | Where-Object { $_.Event -eq 'BAND_2G4' } |
              Group-Object -Property { ([datetime]::Parse($_.Time)).Hour }
    if ($byHour) {
        Write-Host ''
        Write-Host '---- 按小时分布 ----' -ForegroundColor Cyan
        foreach ($h in ($byHour | Sort-Object { [int]$_.Name })) {
            Write-Host ("  {0:00}:00  {1,4}" -f [int]$h.Name, $h.Count) -ForegroundColor Gray
        }
    }

    Write-Host ''
    $drops = ($rows | Where-Object { $_.Event -eq 'BAND_2G4' }).Count
    if ($drops -gt 0 -and $span.TotalHours -gt 0) {
        Write-Host ("平均每 {0:N1} 小时掉一次 2.4G" -f ($span.TotalHours / $drops)) -ForegroundColor Yellow
    } elseif ($drops -eq 0 -and $span.TotalHours -gt 0) {
        Write-Host ("{0:N1} 小时内一次都没掉过 2.4G" -f $span.TotalHours) -ForegroundColor Green
    }
    return 0
}

# ============================================================
#  修复：断开重连直到落回高频
# ============================================================
function Invoke-BandFix {
    param([string]$Ssid, $Before, [int]$MaxAttempts)

    $after = $Before
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        & netsh.exe wlan disconnect 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        & netsh.exe wlan connect "name=$Ssid" 2>$null | Out-Null

        # 最多等 12 秒让它连上并稳定
        $deadline = (Get-Date).AddSeconds(12)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 600
            $after = Get-WifiState
            if ($after.Connected) {
                if ((Get-BandClass $after.Band) -ne '2.4G') { return @{ Ok = $true; State = $after; Attempts = $i } }
                break
            }
        }
        Start-Sleep -Milliseconds 800
    }
    return @{ Ok = $false; State = $after; Attempts = $MaxAttempts }
}

# ============================================================
#  暂停 / 恢复 / 切换
# ============================================================
if ($Pause -or $Resume -or $Toggle) {
    $willPause = $true
    if ($Resume) { $willPause = $false }
    if ($Toggle) { $willPause = -not (Test-GuardPaused) }

    if ($willPause) {
        if (-not (Test-GuardPaused)) {
            Set-Content -Path $PauseFile -Value ("paused at " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
        }
        Write-Host ''
        Write-Host '已暂停修复。' -ForegroundColor Yellow
        Write-Host '  掉到 2.4GHz 时只记录，不重连。适合打游戏、开会、下大文件。' -ForegroundColor DarkGray
        Write-Host ('  恢复：  Band_Guard.ps1 -Resume') -ForegroundColor DarkGray
        Write-Host ('  标记文件：{0}' -f $PauseFile) -ForegroundColor DarkGray
    } else {
        if (Test-GuardPaused) { Remove-Item $PauseFile -Force -ErrorAction SilentlyContinue }
        Write-Host ''
        Write-Host '已恢复修复。' -ForegroundColor Green
        Write-Host '  下次巡检发现掉到 2.4GHz 就会动手。' -ForegroundColor DarkGray
    }
    Write-Host ''
    if (-not $NoPause) {
        Write-Host '按任意键退出 ...' -ForegroundColor DarkGray
        try { $null = [Console]::ReadKey() } catch { }
    }
    try { [Console]::OutputEncoding = $script:PrevOutEnc } catch { }
    exit 0
}

# ============================================================
#  Status 模式
# ============================================================
if ($Status) {
    $rc = Show-Status
    if (-not $NoPause) {
        Write-Host '按任意键退出 ...' -ForegroundColor DarkGray
        try { $null = [Console]::ReadKey() } catch { }
    }
    try { [Console]::OutputEncoding = $script:PrevOutEnc } catch { }
    exit $rc
}

# ============================================================
#  主流程
# ============================================================
Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '   Band Guard v1  -  只保频段，不测速' -ForegroundColor Cyan
Write-Host ("   巡检 {0}s / 单次最多重连 {1} 次 / 失败退避 {2}s" -f $IntervalSec, $MaxFixAttempts, $BackoffSec) -ForegroundColor Cyan
if ($DryRun) { Write-Host '   [DryRun] 只告警，不断网' -ForegroundColor Yellow }
Write-Host '==================================================' -ForegroundColor Cyan

$cur = Get-WifiState
if (-not $cur.Connected) {
    Write-Host '当前未连接 WiFi。' -ForegroundColor Red
    Write-Log -Event 'LINK_DOWN' -Before $null -After $null -Msg '启动时未连接'
    if (-not $NoPause) { Write-Host '按任意键退出 ...' -ForegroundColor DarkGray; try { $null = [Console]::ReadKey() } catch { } }
    exit 1
}

if (-not $Ssid) { $Ssid = $cur.Ssid }
Write-Host ("SSID : {0}   当前 {1}  ch{2}  {3}" -f $cur.Ssid, $cur.Band, $cur.Channel, $cur.Bssid) -ForegroundColor White
Write-Log -Event 'START' -Before $cur -After $null -Msg ("巡检间隔 {0}s" -f $IntervalSec)

$lastBand  = Get-BandClass $cur.Band
$lastConn  = $true
$backoffUntil = (Get-Date)

function Invoke-Cycle {
    param($PrevBand, $PrevConn)

    $st = Get-WifiState

    # --- 链路掉了 ---
    if (-not $st.Connected) {
        if ($PrevConn) {
            Write-Host ("[{0}] 断链" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Red
            Write-Log -Event 'LINK_DOWN' -Before $st -After $null -Msg '检测到断开'
            return @{ Band = 'down'; Conn = $false; Fixed = $false }
        }
        return @{ Band = $PrevBand; Conn = $false; Fixed = $false }
    }

    if (-not $PrevConn) {
        Write-Host ("[{0}] 已连上 {1} ch{2}" -f (Get-Date -Format 'HH:mm:ss'), $st.Band, $st.Channel) -ForegroundColor Green
        Write-Log -Event 'LINK_UP' -Before $null -After $st -Msg '自动恢复'
    }

    $cls = Get-BandClass $st.Band

    # --- 落在 2.4G ---
    if ($cls -eq '2.4G') {
        # 只在刚掉下来那一刻记一条，避免每 20 秒刷一行
        if ($PrevBand -ne '2.4G') {
            Write-Host ("[{0}] 掉到 2.4GHz  ch{1}  {2}" -f (Get-Date -Format 'HH:mm:ss'), $st.Channel, $st.Bssid) -ForegroundColor Yellow
            Write-Log -Event 'BAND_2G4' -Before $st -After $null -Msg ("链路 {0} Mbps" -f $st.Rate)
        }

        # 暂停中：只看着，不动手
        if (Test-GuardPaused) {
            Write-Host '  已暂停修复，不重连（打游戏时宁可卡也别断）' -ForegroundColor DarkGray
            return @{ Band = $cls; Conn = $true; Fixed = $false }
        }

        if ($DryRun -or (Get-Date) -lt $backoffUntil) {
            if ((Get-Date) -lt $backoffUntil) {
                Write-Host ('  退避中，剩 {0:N0}s，不动' -f ($backoffUntil - (Get-Date)).TotalSeconds) -ForegroundColor DarkGray
            }
            return @{ Band = $cls; Conn = $true; Fixed = $false }
        }

        $r = Invoke-BandFix -Ssid $Ssid -Before $st -MaxAttempts $MaxFixAttempts
        if ($r.Ok) {
            Write-Host ("  已拉回 {0}  ch{1}  (第 {2} 次命中)" -f $r.State.Band, $r.State.Channel, $r.Attempts) -ForegroundColor Green
            Write-Log -Event 'FIX_OK' -Before $st -After $r.State -Attempts $r.Attempts -Msg '重连命中高频'
            return @{ Band = (Get-BandClass $r.State.Band); Conn = $true; Fixed = $true; Backoff = $false }
        }

        Write-Host ("  {0} 次重连仍未回到高频，退避 {1}s" -f $MaxFixAttempts, $BackoffSec) -ForegroundColor Red
        Write-Log -Event 'FIX_FAIL' -Before $st -After $r.State -Attempts $r.Attempts -Msg '5G 可能真的不可用'
        return @{ Band = (Get-BandClass $r.State.Band); Conn = $true; Fixed = $false; Backoff = $true }
    }

    # --- 正常，只在频段变化时打一行 ---
    if ($cls -ne $PrevBand) {
        Write-Host ("[{0}] 当前 {1}  ch{2}  {3}  {4} Mbps" -f (Get-Date -Format 'HH:mm:ss'), $st.Band, $st.Channel, $st.Bssid, $st.Rate) -ForegroundColor Green
    }
    return @{ Band = $cls; Conn = $true; Fixed = $false }
}

if ($Once) {
    $res = Invoke-Cycle -PrevBand $lastBand -PrevConn $lastConn
    Write-Log -Event 'STOP' -Before $null -After $null -Msg 'Once 模式结束'
    if ($res.Band -eq '2.4G') { exit 3 }
    exit 0
}

Write-Host ''
Write-Host '开始监控，Ctrl+C 停止。' -ForegroundColor DarkGray

try {
    while ($true) {
        $res = Invoke-Cycle -PrevBand $lastBand -PrevConn $lastConn
        $lastBand = $res.Band
        $lastConn = $res.Conn
        if ($res.Backoff) { $backoffUntil = (Get-Date).AddSeconds($BackoffSec) }
        Start-Sleep -Seconds $IntervalSec
    }
} finally {
    Write-Log -Event 'STOP' -Before $null -After $null -Msg '手动停止'
    try { [Console]::OutputEncoding = $script:PrevOutEnc } catch { }
}
