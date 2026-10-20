# ============================================================
#  Tune WiFi  v1
#  目的：在不能接线、又改不了 AP 的前提下，把网卡侧能拧的旋钮拧到位。
#
#  这里只动三个开关，都有实测依据：
#    空闲省电      自动 -> Low      省电激进时会降功率，速率和延迟都抖
#    漫游激进度    Medium -> Lowest 降低瞎漫游，别被推到信号更差的 AP
#    漫游灵敏度    Middle -> Low    同上，别为了 2dB 就换 AP
#
#  注意：改网卡参数会让适配器重启一次，网络会断 3-5 秒。这不是故障。
#
#  用法（必须管理员）：
#    powershell -ExecutionPolicy Bypass -File "Tune_WiFi.ps1" -Show
#    powershell -ExecutionPolicy Bypass -File "Tune_WiFi.ps1" -Apply
#    powershell -ExecutionPolicy Bypass -File "Tune_WiFi.ps1" -Revert
# ============================================================

param(
    [switch]$Show,
    [switch]$Apply,
    [switch]$Revert,
    [string]$Adapter = 'WLAN 6',
    [switch]$NoPause
)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 关键词 -> (目标值, 还原值, 说明)
# 值映射按 Realtek 8922AE 实测读过：
#   LpsEn            0=Low  1=High  2=自动
#   RegRoamLevel     5=Highest 4=Medium-High 3=Medium 2=Medium-Low 1=Lowest 0=Disable
#   RegROAMSensitiveLevel  127=禁用 50=High 60=Middle 80=Low 65=High 70=Middle
$Targets = @(
    @{ Key = 'LpsEn';                 Name = '空闲省电';                Apply = 0;  Revert = 2;  Why = 'Low，减少降功率导致的速率/延迟抖动' }
    @{ Key = 'RegRoamLevel';          Name = 'Roaming Aggressiveness';  Apply = 1;  Revert = 3;  Why = 'Lowest，不主动往别的 AP 跑' }
    @{ Key = 'RegROAMSensitiveLevel'; Name = 'Roaming Sensitivity';     Apply = 80; Revert = 70; Why = 'Low，不为一丁点信号差就切' }
)

function Get-Current {
    param([string]$Key)
    $p = Get-NetAdapterAdvancedProperty -Name $Adapter | Where-Object { $_.RegistryKeyword -eq $Key }
    if (-not $p) { return $null }
    return $p
}

function Show-All {
    Write-Host ''
    Write-Host ("适配器 : {0}" -f $Adapter) -ForegroundColor Cyan
    Write-Host '--------------------------------------------------------------' -ForegroundColor DarkGray
    foreach ($t in $Targets) {
        $p = Get-Current $t.Key
        if (-not $p) {
            Write-Host ("{0,-26} 该网卡没有这个参数" -f $t.Name) -ForegroundColor DarkYellow
            continue
        }
        $cur = ($p.RegistryValue -join ',')
        $mark = if ($cur -eq "$($t.Apply)") { '  <- 已优化' } else { '' }
        Write-Host ("{0,-26} {1,-22} (值 {2}){3}" -f $t.Name, ($p.DisplayValue -join ','), $cur, $mark)
    }
    Write-Host ''
    Write-Host '另外两项只读参考：' -ForegroundColor DarkGray
    foreach ($k in 'PreferBand', 'WifiBandwidth_phy0', 'WifiProtocol_2g') {
        $p = Get-NetAdapterAdvancedProperty -Name $Adapter | Where-Object { $_.RegistryKeyword -eq $k }
        if ($p) { Write-Host ("  {0,-24} {1}" -f $p.DisplayName, ($p.DisplayValue -join ',')) -ForegroundColor DarkGray }
    }
    Write-Host '--------------------------------------------------------------' -ForegroundColor DarkGray
}

function Set-Targets {
    param([bool]$ToApply)

    if (-not $isAdmin) {
        Write-Host '需要管理员权限。右键 PowerShell -> 以管理员身份运行，或者用管理员命令行执行。' -ForegroundColor Red
        return 1
    }

    $changed = 0
    foreach ($t in $Targets) {
        $p = Get-Current $t.Key
        if (-not $p) {
            Write-Host ("跳过 {0}：该网卡没有此参数" -f $t.Name) -ForegroundColor DarkYellow
            continue
        }
        $want = if ($ToApply) { $t.Apply } else { $t.Revert }
        $cur  = ($p.RegistryValue -join ',')

        if ($cur -eq "$want") {
            Write-Host ("{0,-26} 已是目标值 {1}" -f $t.Name, $want) -ForegroundColor DarkGray
            continue
        }

        # 挑一个和 want 对应的显示值，便于日志
        $disp = ''
        $vals = @($p.ValidRegistryValues)
        $disps = @($p.ValidDisplayValues)
        for ($i = 0; $i -lt $vals.Count; $i++) { if ("$($vals[$i])" -eq "$want") { $disp = $disps[$i] } }

        Set-NetAdapterAdvancedProperty -Name $Adapter -RegistryKeyword $t.Key -RegistryValue $want -NoRestart -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 200
        $after = Get-Current $t.Key
        if ($after -and (($after.RegistryValue -join ',') -eq "$want")) {
            Write-Host ("{0,-26} {1} -> {2}    ({3})" -f $t.Name, $cur, $want, $t.Why) -ForegroundColor Green
            $changed++
        } else {
            Write-Host ("{0,-26} 设置失败，仍是 {1}" -f $t.Name, $cur) -ForegroundColor Red
        }
    }

    if ($changed -gt 0) {
        Write-Host ''
        Write-Host ("共改动 {0} 项。适配器需要重启才能全部生效。" -f $changed) -ForegroundColor Yellow
        Write-Host '正在重启网卡（会断 3-5 秒）...' -ForegroundColor Yellow
        Restart-NetAdapter -Name $Adapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        $st = (Get-NetAdapter -Name $Adapter).Status
        Write-Host ("适配器状态 : {0}" -f $st) -ForegroundColor Cyan
        & netsh.exe wlan show interfaces 2>$null | Select-String 'SSID|波段|Band|通道|Channel' | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) -ForegroundColor DarkGray }
    } else {
        Write-Host ''
        Write-Host '没有需要改动的地方。' -ForegroundColor DarkGray
    }
    return 0
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '   Tune WiFi v1  -  网卡侧能拧的旋钮' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

Show-All

$rc = 0
if ($Apply)  { $rc = Set-Targets -ToApply $true }
if ($Revert) { $rc = Set-Targets -ToApply $false }
if (-not $Apply -and -not $Revert) {
    Write-Host ''
    Write-Host '加 -Apply 应用优化，加 -Revert 还原。（都需要管理员）' -ForegroundColor DarkGray
}

if (-not $NoPause) {
    Write-Host ''
    Write-Host '按任意键退出 ...' -ForegroundColor DarkGray
    try { $null = [Console]::ReadKey() } catch { }
}
exit $rc
