# WiFi-Speed-Reconnect

**只想点文件、不想看文档 → 进 `USE` 文件夹。** 里面按 1/2/3/4 排好了，按顺序点就行。

Windows 校园网 / 宿舍 WiFi 工具集。三个东西，各管一件事：

| 工具 | 一句话 |
|---|---|
| `Run_Bench_v6.bat` | 测速，数能对上体感（稳态 / 最差 1 秒 / 满载延迟） |
| `Run_Guard.bat` | 保频段，掉到 2.4GHz 自动拉回 5GHz |
| `Run_Tune.bat` | 修网卡参数，减少乱漫游和省电降速（双击自动提权） |

## 开机之后点哪个

**日常不用点任何东西。** 无线连上就能用。

要测速时双击 `Run_Bench_v6.bat`。要看历史记录就跑 `Run_Guard.bat -Status`。

## 文件清单

| 文件 | 类型 | 用途 |
|---|---|---|
| `Run_Bench_v6.bat` | 启动器 | 双击出菜单：列 AP / 测当前 / 深度测 / 连指定 AP / 遍历 5G AP |
| `WiFi_Bench_v6.ps1` | 主程序 | v6 测速引擎 |
| `Run_Guard.bat` | 启动器 | 双击出菜单：监控 / 单次检查 / 汇总 |
| `Band_Guard.ps1` | 主程序 | 频段守卫 |
| `Tune_WiFi.ps1` | 主程序 | 网卡参数调优，`-Show` / `-Apply` / `-Revert` |
| `Run_Tune.bat` | 启动器 | Tune_WiFi 的提权外壳（`.ps1` 没有「以管理员身份运行」菜单项） |
| `wifi_v6_result.csv` | 数据 | 每次测速追加一行 |
| `band_guard_log.csv` | 数据 | 频段事件日志 |
| `Cleanup_MuMu.ps1` | 无关 | MuMu 模拟器残留清理（旧文件，保留） |
| `Run_As_Admin.bat` | 无关 | 旧的管理员启动器（旧文件，保留） |

## 测速：v6

v5 用 5 秒单线程 curl 取一个数，那个数测的是**镜像站当时愿不愿意给带宽**，不是你的链路。实测同一时刻：科大 403、华为 418、阿里 3.5 Mbps、腾讯 20 Mbps —— 差 60 倍。

v6 换的是测法：

| 指标 | 怎么来的 |
|---|---|
| 稳态下行 | 6 线程并发 15 秒，丢掉前 3 秒预热，取剩余平均 |
| 峰值 / 最差 1 秒 | 全程 1 秒滑窗的最大值和最小值 |
| 满载延迟 | 打满带宽时并发测 TCP 握手 RTT，取中位数 |
| 延迟增量 | 满载中位 − 空闲中位：<30ms 良好，30–100 轻度排队，>100 明显卡 |
| 源端合计 | 启动时逐个探测 8 个源后求和，用来判断这个数被源卡住没有 |

结论会明确说是哪一种：**源端不是瓶颈 / 卡在源端别信这数 / 瓶颈在链路侧**。

```powershell
Run_Bench_v6.bat -List                          # 完整 AP 列表（强制断开重扫一次）
Run_Bench_v6.bat -Seconds 20                    # 测当前连接
Run_Bench_v6.bat -ConnectBssid a2:82:3d:91:39:9b   # 按 BSSID 指定 AP（推荐）
Run_Bench_v6.bat -Connect 7                     # 按列表编号（编号会随信号重排，慎用）
Run_Bench_v6.bat -Auto                          # 逐个切到每个 5G AP 测速，出对比表
```

**不知道选哪个就用 `-Auto`。** 它会自动切到每个 5G AP 各测一遍，最后出一张对比表，按稳态速度排序。这比看信号强度可靠得多 —— 信号 100% 的两台 AP 实测能差 3-4 倍。

## 保频段：Band_Guard

不做测速、不 ping、不排名。只每 20 秒读一次波段，掉到 2.4G 才断开重连，最多 3 次，失败退避 5 分钟。

```powershell
Run_Guard.bat -Status      # 看历史：掉 2.4G 次数 / 断链次数 / 按天按小时分布
Run_Guard.bat -Once        # 只查一次（适合计划任务）
Run_Guard.bat -DryRun      # 只告警不断网
Run_Guard.bat -Pause       # 暂停修复：掉 2.4G 只记录，不重连
Run_Guard.bat -Resume      # 恢复修复
```

### 打游戏 / 开会时先暂停

修复动作是断开重连，**断 2-5 秒**。这在打游戏时比卡顿更糟 —— 一局可能直接掉。

所以加了暂停开关：暂停后掉到 2.4G 只打一行提示，不动手。你手感会差点（抖动从 40ms 涨到 90ms），但不会掉线。打完恢复，下一次巡检就拉回去。

暂停状态写在 `band_guard.pause` 这个标记文件里，`-Once` 和常驻监控都认它，重启也还在。

计划任务（每 5 分钟查一次）：

```bat
schtasks /create /tn "BandGuard" /sc minute /mo 5 /tr "powershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0Band_Guard.ps1\" -Once -NoPause" /f
```

## 网卡调优：Tune_WiFi

| 参数 | 默认 | 改成 | 为什么 |
|---|---|---|---|
| 空闲省电 | 自动 | Low | 省电激进时降功率，速率和延迟一起抖 |
| Roaming Aggressiveness | 4. Medium | 2. Lowest | 不主动往别的 AP 跑 |
| Roaming Sensitivity | Middle | Low | 不为一丁点信号差就切 |

```powershell
# 推荐：双击 Run_Tune.bat，弹 UAC 点「是」，然后选菜单
#   .ps1 文件在资源管理器里没有「以管理员身份运行」这一项，所以要包一层 bat

# 或者手动：右键开始菜单 -> 终端(管理员)，然后
cd E:\Desktop\WiFi-Speed-Reconnect
powershell -ExecutionPolicy Bypass -File "Tune_WiFi.ps1" -Apply
```

改完网卡重启一次，断 3-5 秒。**这三项改善稳定性，不提高峰值。**

## 两个平台级限制，先知道再折腾

**1. Windows 没有「连接到指定 BSSID」的接口。**
`netsh wlan connect` 只接受 SSID，连哪台 AP 由系统打分决定。所以「选通道」实际是断开重连轮盘，每次尝试的结果都会打出来，不假装成功。命中后别断开，Windows 会优先重连上次成功的 BSSID。

**2. `netsh wlan show networks` 会返回残缺的缓存列表。**
连着重连时可能只报 1 个网络，而实际有 8-11 个。所以看到「只有 2.4G」时不要下结论，先跑 `-List`，它会强制断开重扫一次。

校园网环境下还有第三条：band steering、AP 选择、漫游阈值都在校方 AC 上配，本地改不了，也压不过。想彻底解决只能布线。

## 已知限制

- 切换 BSSID 靠轮盘，切系统偏好的 AP 一两次就中；切信号 10% 的边缘 AP 基本切不过去
- 国内镜像站高频下载会限流（403/418/429），限流后要等几分钟；脚本会把「被限流」标出来，不会编一个数
- 无线链路速率是协商值，实测 TCP 吞吐通常只有其 30-50%
- 每次重连断网 2-5 秒

## 环境要求

Windows 10 / 11，PowerShell 5.1+，自带 `curl.exe`。

## 打包成 exe（可选）

```powershell
Install-Module ps2exe -Scope CurrentUser -Force
Invoke-ps2exe .\WiFi_Bench_v6.ps1 .\WiFi_Bench_v6.exe -title "WiFi Bench v6"
```

约 100 KB，仍依赖系统自带 PowerShell 5.1（Win10/11 都有），不是独立运行时。

## 免责说明

只做断开-重连、测速和网卡参数调整，不安装驱动、不采集任何个人数据，不上传。
