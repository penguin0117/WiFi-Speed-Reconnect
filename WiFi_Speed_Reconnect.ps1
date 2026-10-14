# ============================================================
#  WiFi Speed Test + Smart Reconnect (SVIST)  v4
#  功能：多轮测速 + 差中选优，跑满 N 轮后自动切回最快通道
#  用法：
#    双击同目录下 WiFi测速重连.bat
#  可选参数：
#    -MaxTries 10         测试轮数（默认 10）
#    -LinkRatio 0.6       参考门槛 = 链路速率 × 60%
#    -MaxLatencyMs 200    延迟上限（评分用）
#    -DryRun              只模拟不实际断网
# ============================================================

param(
    [int]$MaxLatencyMs = 200,
    [int]$MaxLossPercent = 20,
    [double]$LinkRatio = 0.6,
    [int]$MaxTries = 10,
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------- 1. 获取当前 WiFi 信息（含 BSSID） ----------
function Get-WifiInfo {
    $raw = netsh wlan show interfaces 2>$null
    $ssid = ''; $signal = ''; $band = ''; $rate = ''; $bssid = ''; $channel = ''
    foreach ($line in $raw) {
        if ($line -match '^\s*SSID\s*:\s*(.+)$') { $ssid = $Matches[1].Trim() }
        elseif ($line -match '^\s*Signal\s*:\s*(.+)$') { $signal = $Matches[1].Trim() }
        elseif ($line -match '^\s*Radio type\s*:\s*(.+)$') { $band = $Matches[1].Trim() }
        elseif ($line -match '^\s*Receive rate[^:]*:\s*(.+)$') { $rate = $Matches[1].Trim() }
        elseif ($line -match 'AP BSSID\s*:\s*(.+)$') { $bssid = $Matches[1].Trim().ToLower() }
        elseif ($line -match '^\s*Channel\s*:\s*(.+)$') { $channel = $Matches[1].Trim() }
    }
    $signalNum = 0
    if ($signal -match '(\d+)') { $signalNum = [int]$Matches[1] }
    return @{ SSID = $ssid; Signal = $signalNum; Band = $band; Rate = $rate; BSSID = $bssid; Channel = $channel }
}

# ---------- 2. 解析链路速率 ----------
function Get-LinkMbps([string]$rateText) {
    if (-not $rateText) { return $null }
    $m = [regex]::Match($rateText, '(\d+(?:\.\d+)?)')
    if (-not $m.Success) { return $null }
    $val = [double]$m.Groups[1].Value
    if ($rateText -match 'Gbps') { $val = $val * 1000 }
    return $val
}

# ---------- 3. 延迟 / 丢包（ping 5 次） ----------
function Test-PingStats([string]$Target) {
    $results = Test-Connection -ComputerName $Target -Count 5 -ErrorAction SilentlyContinue
    if (-not $results -or $results.Count -eq 0) {
        return @{ AvgMs = $null; Loss = 100 }
    }
    $avg = [math]::Round(($results | Measure-Object -Property ResponseTime -Average).Average, 1)
    $loss = [math]::Round(100 * (1 - $results.Count / 5.0), 1)
    return @{ AvgMs = $avg; Loss = $loss }
}

# ---------- 4. 下载测速（curl.exe，6 秒窗口，自动跟随重定向） ----------
function Test-DownloadSpeed {
    $urls = @(
        'https://mirrors.ustc.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso',
        'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso',
        'https://mirrors.aliyun.com/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso'
    )
    foreach ($u in $urls) {
        try {
            # curl: -L 跟随重定向, --max-time 7 秒, -o NUL 丢弃内容
            # %{speed_download} 返回字节/秒
            $raw = curl.exe -L -o NUL --max-time 7 -s -w "%{speed_download}|%{http_code}" $u 2>$null
            if (-not $raw) { continue }
            $parts = $raw -split '\|'
            $bytesPerSec = [double]$parts[0]
            $httpCode = $parts[1]
            if ($httpCode -eq '200' -and $bytesPerSec -gt 10000) {
                # 字节/秒 → Mbps (×8bit ÷ 1,000,000)
                return [math]::Round($bytesPerSec * 8 / 1000000, 2)
            }
        } catch { }
    }
    return $null
}

# ---------- 5. 综合评分：延迟 40% + 速度 40% + 信号 20% ----------
function Get-Score($latencyMs, $speedMbps, $signalPct, $threshold) {
    $l = 0.0
    if ($null -ne $latencyMs) { $l = [math]::Max(0.0, 1.0 - ([double]$latencyMs / [double]$MaxLatencyMs)) }
    $s = 0.0
    if ($null -ne $speedMbps) { $s = [math]::Min(1.0, [double]$speedMbps / [double]$threshold) }
    $sig = 0.0
    if ($null -ne $signalPct) { $sig = [math]::Min(1.0, [double]$signalPct / 100.0) }
    return [math]::Round(0.4 * $l + 0.4 * $s + 0.2 * $sig, 3)
}

# ---------- 6. 等待网络恢复 ----------
function Wait-NetworkUp([string]$gwIp, [int]$timeoutSec = 20) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        if ($gwIp) {
            $ok = Test-Connection -ComputerName $gwIp -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($ok) { return $true }
        } else {
            $w = Get-WifiInfo
            if ($w.BSSID) { return $true }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

# ---------- 7. 强制重连（disconnect → connect，触发 Windows 重新选 AP） ----------
function Reconnect-Wifi([string]$SSID, [string]$gwIp) {
    if ($DryRun) {
        Write-Host '  [DryRun] 模拟重连' -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
        return
    }
    netsh wlan disconnect | Out-Null
    Start-Sleep -Seconds 3
    netsh wlan connect name="$SSID" | Out-Null
    Write-Host '  等待网络恢复...' -ForegroundColor DarkGray
    $up = Wait-NetworkUp $gwIp -timeoutSec 20
    if (-not $up) {
        Write-Host '  [警告] 20 秒内网络未恢复，继续测试' -ForegroundColor Yellow
    }
}

# ---------- 8. 切回指定 BSSID（多次重试碰运气） ----------
function Connect-TargetBssid([string]$SSID, [string]$targetBssid, [string]$gwIp, [int]$maxRetry = 5) {
    if ($DryRun) { return $true }
    if (-not $targetBssid) { return $false }
    for ($i = 1; $i -le $maxRetry; $i++) {
        Write-Host ("  切回最优通道（第 {0}/{1} 次，目标 BSSID {2}）..." -f $i, $maxRetry, $targetBssid) -ForegroundColor Yellow
        netsh wlan disconnect | Out-Null
        Start-Sleep -Seconds 3
        netsh wlan connect name="$SSID" | Out-Null
        Wait-NetworkUp $gwIp -timeoutSec 20 | Out-Null
        $w = Get-WifiInfo
        if ($w.BSSID -eq $targetBssid) {
            Write-Host ("  已连上目标 BSSID {0}" -f $targetBssid) -ForegroundColor Green
            return $true
        }
        Write-Host ("  当前 BSSID {0}，不是目标，重试" -f $w.BSSID) -ForegroundColor DarkYellow
    }
    return $false
}

# ============================================================
#  主流程：跑满 MaxTries 轮，最后切回最优通道
# ============================================================
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '   WiFi Speed Reconnect (SVIST) v4 - 差中选优模式' -ForegroundColor Cyan
Write-Host ('   跑满 {0} 轮，自动切回最快通道' -f $MaxTries) -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

$wifi = Get-WifiInfo
$ssidShow = $(if ($wifi.SSID) { $wifi.SSID } else { '未连接' })
Write-Host ("当前 WiFi : {0}   信号 {1}%   信道 {2}   BSSID {3}" -f $ssidShow, $wifi.Signal, $wifi.Channel, $wifi.BSSID)

# 参考门槛（仅用于评分归一化，不做达标中断）
$linkMbps = Get-LinkMbps $wifi.Rate
$threshold = 300.0
if ($null -ne $linkMbps -and $linkMbps -gt 0) {
    $threshold = [math]::Round($linkMbps * $LinkRatio)
}
Write-Host ("  链路速率 {0} Mbps → 评分参考线 {1} Mbps" -f $linkMbps, $threshold) -ForegroundColor Yellow

$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
Write-Host ("  网关 : {0}" -f $gw) -ForegroundColor DarkGray

$rounds = @()

for ($tries = 1; $tries -le $MaxTries; $tries++) {
    Write-Host ("`n========== 第 {0}/{1} 轮测试 ==========" -f $tries, $MaxTries) -ForegroundColor Cyan

    Start-Sleep -Seconds 2

    $w = Get-WifiInfo
    $signalNow = $w.Signal
    $bssidNow = $w.BSSID

    $gwPing = @{ AvgMs = $null; Loss = 0 }
    if ($gw) { $gwPing = Test-PingStats $gw }
    $dnsPing = Test-PingStats '223.5.5.5'

    Write-Host ("  BSSID {0}   信道 {1}   信号 {2}%   网关延迟 {3}ms   公网延迟 {4}ms" -f $bssidNow, $w.Channel, $signalNow, $gwPing.AvgMs, $dnsPing.AvgMs)

    Write-Host '  下载测速（warmup 1.5s + 正式 5s）...'
    $speed = Test-DownloadSpeed
    if ($null -eq $speed) { Write-Host '  下载测速失败' -ForegroundColor DarkGray }
    else { Write-Host ("  下载速度 : {0} Mbps" -f $speed) }

    $latencyNow = $(if ($null -eq $gwPing.AvgMs) { $dnsPing.AvgMs }
                    elseif ($null -eq $dnsPing.AvgMs) { $gwPing.AvgMs }
                    else { [math]::Max($gwPing.AvgMs, $dnsPing.AvgMs) })
    $lossNow = [math]::Max($gwPing.Loss, $dnsPing.Loss)
    $score = Get-Score $latencyNow $speed $signalNow $threshold

    # 达标标记（仅展示，不中断）
    $bad = @()
    if ($null -ne $latencyNow -and $latencyNow -gt $MaxLatencyMs) { $bad += '延迟高' }
    if ($lossNow -gt $MaxLossPercent) { $bad += '丢包高' }
    if ($null -ne $speed -and $speed -lt $threshold) { $bad += '速度低' }
    $passFlag = if ($bad.Count -eq 0) { '达标' } else { $bad -join '/' }

    $rounds += [pscustomobject]@{
        轮次   = $tries
        信道   = $w.Channel
        BSSID  = $bssidNow
        信号   = "$signalNow%"
        延迟   = $(if ($null -eq $latencyNow) { 'N/A' } else { "$latencyNow" })
        丢包   = "$lossNow%"
        速度   = $(if ($null -eq $speed) { 'N/A' } else { "$speed" })
        得分   = $score
        状态   = $passFlag
    }

    if ($tries -lt $MaxTries) {
        Reconnect-Wifi $wifi.SSID $gw
    }
}

# ---------- 汇总报告 ----------
Write-Host "`n========== 逐轮对比 ==========" -ForegroundColor Cyan
$rounds | Format-Table -AutoSize | Out-String | Write-Host

# 按综合得分排序选最优
$best = $rounds | Sort-Object 得分 -Descending | Select-Object -First 1
Write-Host ("最佳通道 : 第 {0} 轮（BSSID {1}，速度 {2} Mbps，得分 {3}）" -f $best.轮次, $best.BSSID, $best.速度, $best.得分) -ForegroundColor Green

# 也按速度单独排一下，方便对照
$bestSpeed = $rounds | Sort-Object @{ Expression = {
    $v = $_.速度
    if ($v -eq 'N/A') { -1 } else { [double]$v }
} } -Descending | Select-Object -First 1
Write-Host ("速度最快 : 第 {0} 轮（{1} Mbps，得分 {2}）" -f $bestSpeed.轮次, $bestSpeed.速度, $bestSpeed.得分) -ForegroundColor DarkGreen

# 检查当前是否已在最优通道
$current = Get-WifiInfo
if ($current.BSSID -eq $best.BSSID) {
    Write-Host '当前已连接在综合最优通道 ✓' -ForegroundColor Green
} else {
    Write-Host ("`n当前 BSSID {0} 不是最优，正在切换..." -f $current.BSSID) -ForegroundColor Yellow
    $swapped = Connect-TargetBssid $wifi.SSID $best.BSSID $gw -maxRetry 5
    if ($swapped) {
        Write-Host '切换完成，已连接到最优通道 ✓' -ForegroundColor Green
    } else {
        Write-Host ("[警告] 5 次尝试后仍未切到目标 BSSID {0}" -f $best.BSSID) -ForegroundColor Red
        Write-Host '       可手动断开 WiFi 再重连，多试几次直到连到目标 AP' -ForegroundColor DarkYellow
        Write-Host ("       目标 BSSID : {0}" -f $best.BSSID) -ForegroundColor DarkYellow
    }
}

Write-Host "`n按任意键退出 ..."
$null = [Console]::ReadKey()
