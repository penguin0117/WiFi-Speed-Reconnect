# ============================================================
#  WiFi Speed Test + Smart Reconnect (SVIST)  v3
#  功能：测速（延迟/丢包/下载速度）+ 综合评分 + 逐轮对比，
#        达标（≥300Mbps）即停；不达标依次测满 3→6→10 轮，
#        最终从所有轮次中选出网速最快的通道。
#  用法：
#    双击同目录下 WiFi测速重连.bat（自动测速重连，无需确认）
#  可选参数（示例）：
#    WiFi测速重连.bat -MinSpeedMbps 300 -MaxLatencyMs 150 -MaxTries 10
#    -MaxTries N  封顶轮数（默认 10，不达标依次测满 3→6→10 轮）
#    -DryRun  只模拟重连不实际断网（用于测试）
# ============================================================

param(
    [int]$MaxLatencyMs = 200,
    [int]$MaxLossPercent = 20,
    [int]$MinSpeedMbps = 300,   # 下载速度达标线(Mbps)：300 左右即可
    [int]$MaxTries = 10,   # 封顶轮数：不达标依次测满 3→6→10 轮（默认 10）
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------- 1. 获取当前 WiFi 信息 ----------
function Get-WifiInfo {
    $raw = netsh wlan show interfaces 2>$null
    $ssid = ''; $signal = ''; $band = ''; $rate = ''
    foreach ($line in $raw) {
        if ($line -match '^\s*SSID\s*:\s*(.+)$') { $ssid = $Matches[1].Trim() }
        elseif ($line -match '^\s*Signal\s*:\s*(.+)$') { $signal = $Matches[1].Trim() }
        elseif ($line -match '^\s*Radio type\s*:\s*(.+)$') { $band = $Matches[1].Trim() }
        elseif ($line -match '^\s*Receive rate[^:]*:\s*(.+)$') { $rate = $Matches[1].Trim() }
    }
    $signalNum = 0
    if ($signal -match '(\d+)') { $signalNum = [int]$Matches[1] }
    return @{ SSID = $ssid; Signal = $signalNum; Band = $band; Rate = $rate }
}

# ---------- 2. 延迟 / 丢包测试（ping 10 次） ----------
function Test-PingStats([string]$Target) {
    $results = Test-Connection -ComputerName $Target -Count 10 -ErrorAction SilentlyContinue
    if (-not $results -or $results.Count -eq 0) {
        return @{ AvgMs = $null; Loss = 100 }
    }
    $avg = [math]::Round(($results | Measure-Object -Property ResponseTime -Average).Average, 1)
    $loss = [math]::Round(100 * (1 - $results.Count / 10.0), 1)
    return @{ AvgMs = $avg; Loss = $loss }
}

# ---------- 3. 下载速度测试（5 秒样本，镜像不可达时返回 $null） ----------
function Test-DownloadSpeed {
    $urls = @(
        'https://mirrors.aliyun.com/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso',
        'https://mirrors.ustc.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso',
        'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso'
    )
    foreach ($u in $urls) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
            $req.Timeout = 5000
            $req.ReadWriteTimeout = 8000
            $req.AllowAutoRedirect = $true
            $resp = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            $buf = New-Object byte[] 1048576
            $total = 0
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 5 -and $total -lt 8MB) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $total += $n
            }
            $sw.Stop()
            $stream.Close()
            $resp.Close()
            if ($sw.Elapsed.TotalSeconds -gt 0 -and $total -gt 0) {
                return [math]::Round(($total * 8) / $sw.Elapsed.TotalSeconds / 1MB, 2)
            }
        } catch { }
    }
    return $null
}

# ---------- 4. 综合评分：延迟 40% + 速度 40% + 信号 20% ----------
# 注意：必须显式使用 double，否则 PS5.1 会把 [math]::Max/Min 绑定到 (int,int) 重载
#       导致 0.8 被四舍五入成 1、0.002 被舍成 0，得分失真（历史 bug）
function Get-Score($latencyMs, $speedMbps, $signalPct) {
    $l = 0.0
    if ($null -ne $latencyMs) { $l = [math]::Max(0.0, 1.0 - ([double]$latencyMs / [double]$MaxLatencyMs)) }
    $s = 0.0
    if ($null -ne $speedMbps) { $s = [math]::Min(1.0, [double]$speedMbps / 300.0) }
    $sig = 0.0
    if ($null -ne $signalPct) { $sig = [math]::Min(1.0, [double]$signalPct / 100.0) }
    return [math]::Round(0.4 * $l + 0.4 * $s + 0.2 * $sig, 2)
}

# ---------- 5. 快速重连（不断开，尽量不断网；未生效则兜底完整重连） ----------
function Reconnect-Wifi([string]$SSID) {
    if ($DryRun) {
        Write-Host '  [DryRun] 模拟重连，不实际执行' -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
        return
    }
    if (-not $SSID) {
        Write-Host '  [重连] 未获取到 SSID，仅尝试断开后恢复' -ForegroundColor Yellow
        netsh wlan disconnect | Out-Null
        Start-Sleep -Seconds 1
        return
    }
    # 轻量路径：不手动断开，直接触发重新关联，中断仅 1~3 秒
    Write-Host ("  [重连] 快速重连 [{0}]（不断开，约 1~3 秒恢复）..." -f $SSID) -ForegroundColor Yellow
    netsh wlan connect name="$SSID" | Out-Null
    Start-Sleep -Seconds 5
    # 兜底：5 秒后公网仍不通（关联失败/掉线），才执行完整断开重连
    $probe = Test-Connection -ComputerName '223.5.5.5' -Count 2 -ErrorAction SilentlyContinue
    if (-not $probe) {
        Write-Host '  [重连] 快速重连未生效，执行完整断开重连' -ForegroundColor Yellow
        netsh wlan disconnect | Out-Null
        Start-Sleep -Seconds 1
        netsh wlan connect name="$SSID" | Out-Null
        Start-Sleep -Seconds 6
    }
}

# ---------- 主流程（自动三轮，无需确认） ----------
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '   WiFi Speed Test + Smart Reconnect (SVIST) v3' -ForegroundColor Cyan
Write-Host ('   （达标即停，不达标最多测 {0} 轮，选网速最快的通道）' -f $MaxTries) -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

$wifi = Get-WifiInfo
$ssidShow = $(if ($wifi.SSID) { $wifi.SSID } else { '未连接' })
$bandShow = $(if ($wifi.Band) { $wifi.Band } else { '-' })
$rateShow = $(if ($wifi.Rate) { $wifi.Rate } else { '-' })
Write-Host ("当前 WiFi : {0}   信号 {1}%   频段 {2}   链路速率 {3}" -f $ssidShow, $wifi.Signal, $bandShow, $rateShow)

$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop

$rounds = @()
$tries = 0
$finalOk = $false

do {
    $tries++
    Write-Host ("`n========== 第 {0} 轮测试 ==========" -f $tries) -ForegroundColor Cyan

    $w = Get-WifiInfo
    $signalNow = $w.Signal

    $gwPing = @{ AvgMs = $null; Loss = 0 }
    if ($gw) {
        $gwPing = Test-PingStats $gw
        $gwShow = $(if ($null -eq $gwPing.AvgMs) { 'N/A' } else { $gwPing.AvgMs })
        Write-Host ("  网关 {0}    : 延迟 {1} ms, 丢包 {2}%" -f $gw, $gwShow, $gwPing.Loss)
    }
    $dnsPing = Test-PingStats '223.5.5.5'
    $dnsShow = $(if ($null -eq $dnsPing.AvgMs) { 'N/A' } else { $dnsPing.AvgMs })
    Write-Host ("  公网 223.5.5.5 : 延迟 {0} ms, 丢包 {1}%" -f $dnsShow, $dnsPing.Loss)

    Write-Host '  下载测速（5 秒样本）...'
    $speed = Test-DownloadSpeed
    if ($null -eq $speed) { Write-Host '  下载测速失败，跳过速度判断' -ForegroundColor DarkGray }
    else { Write-Host ("  下载速度 : {0} Mbps" -f $speed) }

    $latencyNow = $(if ($null -eq $gwPing.AvgMs) { $dnsPing.AvgMs }
                    elseif ($null -eq $dnsPing.AvgMs) { $gwPing.AvgMs }
                    else { [math]::Max($gwPing.AvgMs, $dnsPing.AvgMs) })
    $lossNow = [math]::Max($gwPing.Loss, $dnsPing.Loss)
    $score = Get-Score $latencyNow $speed $signalNow

    $bad = @()
    if ($null -ne $latencyNow -and $latencyNow -gt $MaxLatencyMs) { $bad += ("延迟 {0}ms > {1}ms" -f $latencyNow, $MaxLatencyMs) }
    if ($lossNow -gt $MaxLossPercent) { $bad += ("丢包 {0}% > {1}%" -f $lossNow, $MaxLossPercent) }
    if ($null -ne $speed -and $speed -lt $MinSpeedMbps) { $bad += ("下载 {0}Mbps < {1}Mbps" -f $speed, $MinSpeedMbps) }

    $rounds += [pscustomobject]@{
        轮次 = $tries
        信号 = "$signalNow%"
        延迟 = $(if ($null -eq $latencyNow) { 'N/A' } else { "$latencyNow ms" })
        丢包 = "$lossNow%"
        速度 = $(if ($null -eq $speed) { 'N/A' } else { "$speed Mbps" })
        得分 = $score
        结果 = $(if ($bad.Count -eq 0) { '达标' } else { '不达标' })
    }

    if ($bad.Count -eq 0) {
        Write-Host ("  本轮达标（得分 {0}）" -f $score) -ForegroundColor Green
        $finalOk = $true
        break
    }

    Write-Host ("  本轮不达标（得分 {0}）：{1}" -f $score, ($bad -join '；')) -ForegroundColor Red

    # 阶段提示：第 3 轮 / 第 6 轮是检查点，未达标则进入下一阶段
    if ($tries -lt $MaxTries -and ($tries -eq 3 -or $tries -eq 6)) {
        $nextStage = [math]::Min(10, $MaxTries)
        if ($tries -lt $nextStage) {
            Write-Host ("  已测 {0} 轮仍未达标，继续测到第 {1} 轮" -f $tries, $nextStage) -ForegroundColor DarkYellow
        }
    }

    if ($tries -ge $MaxTries) {
        Write-Host ("  已达最大尝试次数 {0}，停止重连" -f $MaxTries) -ForegroundColor DarkGray
        break
    }

    Reconnect-Wifi $wifi.SSID
} while ($true)

# ---------- 汇总报告 ----------
Write-Host "`n========== 逐轮对比 ==========" -ForegroundColor Cyan
$rounds | Format-Table -AutoSize | Out-String | Write-Host

if ($rounds.Count -gt 0) {
    # 最佳通道：以网速（下载速度）为准，速度最高的轮次胜出
    $best = $rounds | Sort-Object @{ Expression = {
        $v = $_.速度 -replace ' Mbps', ''
        if ($v -eq 'N/A') { -1 } else { [double]$v }
    } } -Descending | Select-Object -First 1
    Write-Host ("最佳通道 : 第 {0} 轮（{1}，得分 {2}）" -f $best.轮次, $best.速度, $best.得分) -ForegroundColor Green
    if ($finalOk) {
        Write-Host '最终状态 : 网络达标 ✓' -ForegroundColor Green
    } else {
        Write-Host ("最终状态 : 尝试 {0} 轮后仍未达标（<{1}Mbps），请检查路由器 / 宽带 / 信号遮挡" -f $tries, $MinSpeedMbps) -ForegroundColor Red
        if ($best.轮次 -lt $tries) {
            Write-Host ("提示 : 当前连接不如第 {0} 轮（{1}），该轮是网速最快的通道" -f $best.轮次, $best.速度) -ForegroundColor Yellow
        }
    }
}

Write-Host "`n按任意键退出 ..."
$null = [Console]::ReadKey()
