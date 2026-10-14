# WiFi-Speed-Reconnect

Windows 桌面 WiFi 通道测速工具。枚举同一 SSID 下的**所有 AP（BSSID）**，逐通道**多次采样测速**，按通道聚合出中位数，选出最优通道并尝试切回。

## 快速开始

双击 **`Run_Benchmark.bat`** 即可运行。

也可以命令行调用（可透传任意参数）：

```powershell
# 只看有哪些通道，不测速
Run_Benchmark.bat -ScanOnly

# 安全试跑：只测不切，不断网
Run_Benchmark.bat -DryRun

# 正式：12 轮采样 + 自动切回
Run_Benchmark.bat

# 自动化 / 计划任务（结束不等按键）
powershell -NoProfile -ExecutionPolicy Bypass -File "WiFi_Speed_Reconnect.ps1" -NoPause -MaxTries 20
```

退出码：`0` 正常，`1` 未检测到 WiFi 连接，`2` 所有测速源不可用。

## 文件说明

| 文件 | 用途 |
|---|---|
| `Run_Benchmark.bat` | 双击启动器（纯 ASCII，避免命令行编码问题） |
| `WiFi_Speed_Reconnect.ps1` | 核心脚本（UTF-8 with BOM） |


## v5 相比 v4 的变化

| 项 | v4 | v5 |
|---|---|---|
| netsh 输出解析 | 只匹配英文标签，中文系统上**全部解析失败** | 控制台锁 UTF-8 + 中英双语正则，实测中文系统正常 |
| AP 枚举 | 无 | `netsh wlan show networks mode=bssid` 列出同 SSID 全部通道 |
| 最优判定 | 取「最快的那一轮」= 噪声最大值 | **按 BSSID 聚合 + 中位数**，抗噪 |
| 样本可比性 | 无概念 | `-MinSamplesPerAp` 保证每通道至少 N 次 |
| 测速源 | 硬编码会随版本 404（实测已失效） | 启动时探测多个源，自动选实测最快的 |
| 测速窗口 | 直接计时，含握手/首包 | 先预热 2s 不计时，再正式计时 |
| 切换 BSSID | 假装能切，5 次静默重试 | 明确如实报告成败与原因 |
| 日志 | 无 | 每轮明细落 CSV |
| 字段 | 中文做对象键 | 英文键，显示层再映射 |
| 启动器 | `WiFi测速重连.bat`（内容已过时） | `Run_Benchmark.bat`：菜单 + 参数透传 + 代码页还原 |

## 关于「切换通道」的实话

Windows / netsh **没有「连接到指定 BSSID」的命令**。`netsh wlan connect` 只能给 SSID，具体连哪个 AP 由系统决定。

脚本的做法是：反复 `disconnect` + `connect`，每次读回当前 BSSID，直到命中目标。有上限（`-SwitchMaxRetry`），**失败会如实告诉你**，不会假装成功。

若多次重试都切不过去，通常说明这个通道并非真正最优，或该 AP 正在被占用/干扰。结论需要重新评估。

## 使用

**最简单：双击 `Run_Benchmark.bat`**，会出菜单：

| 菜单项 | 等价命令 |
|---|---|
| 1) Quick scan | `-ScanOnly`（只列通道，不测速） |
| 2) Safe test | `-DryRun`（只测不切，不断网） |
| 3) Full run | 无参数（12 轮 + 自动切回） |
| 4) Deep test | `-MaxTries 24` |
| 5) Custom | 自填参数 |
| 6) Exit | 退出 |

命令行用法：

```powershell
# 只看有哪些通道，不测速
powershell -NoProfile -ExecutionPolicy Bypass -File "WiFi_Speed_Reconnect.ps1" -ScanOnly

# 安全试跑：只测不切，不断网
powershell -NoProfile -ExecutionPolicy Bypass -File "WiFi_Speed_Reconnect.ps1" -DryRun

# 正式：12 轮采样 + 自动切回
powershell -NoProfile -ExecutionPolicy Bypass -File "WiFi_Speed_Reconnect.ps1"

# 自动化/计划任务（结束不等待按键）
powershell -NoProfile -ExecutionPolicy Bypass -File "WiFi_Speed_Reconnect.ps1" -NoPause -MaxTries 20
```

> 启动器 `Run_Benchmark.bat` 是纯 ASCII，并在运行期间临时切到 codepage 65001，
> 因为 PS1 会把控制台编码设为 UTF8（否则 netsh 输出无法稳定解析）。
> 脚本退出时会自动还原原来的代码页（实测已还原为 936）。

### 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-MaxTries` | 12 | 总采样轮数 |
| `-MinSamplesPerAp` | 2 | 每通道最少样本数，不足会提示结论仅供参考 |
| `-LinkRatio` | 0.6 | 自动门槛 = 链路速率 × 此比例 |
| `-MinSpeedMbps` | 0 | 手动门槛，>0 时覆盖自动计算 |
| `-MaxLatencyMs` | 200 | 延迟满分基准 |
| `-MaxLossPercent` | 20 | 丢包参考上限（%） |
| `-SpeedSeconds` | 5 | 正式测速窗口（秒） |
| `-PingCount` | 5 | 每目标 ping 次数 |
| `-PingTarget` | 223.5.5.5 | 公网探测目标 |
| `-SwitchMaxRetry` | 6 | 切回最优 BSSID 的最大重试次数 |
| `-DryRun` | 关 | 只测不切，不断网 |
| `-ScanOnly` | 关 | 只列全部 AP 后退出 |
| `-NoPause` | 关 | 结束不等按键 |
| `-LogPath` | 自动 | CSV 明细输出路径 |

## 评分规则

综合得分 = (延迟分×0.35 + 速度分×0.40 + 信号分×0.15 + 丢包分×0.10) × 丢包加权

- 延迟分 = max(0, 1 − 延迟 / MaxLatencyMs)
- 速度分 = min(1, 速度 / 门槛)
- 信号分 = min(1, 信号% / 100)
- 丢包分 = max(0, 1 − 丢包% / 100)
- 丢包加权 = 1 + 0.15 × 丢包分（丢包对体感影响远大于均速差）

权重和为 1.0，所以零丢包时基准得分上限为 1.0，加权后最高 1.15（这是设计值，不是溢出）。

## 为什么用中位数而不是最快值

测速噪声很大。实测同一通道 4 次采样得到 `20.39 / 44.31 / 75.34 / 103.29` Mbps：

- 取最快值 → 103.29（运气）
- 取中位数 → 59.83（真实水平）

拿最快值当结论，选出来的通道大概率是**噪声最大**的那个，而不是最好的。

## 已知限制

- **只能切到 SSID，不能指定 BSSID**（见上文）
- 部分网卡驱动（如 Realtek 8922AE）不支持 `mode=bssid` 输出全部 AP 明细，此时脚本降级为只测当前所在 AP
- 校园网/受限网络可能只放行部分测速源，脚本启动时会自动探测可用源并选最快的
- 无线链路速率是协商理论值，TCP 实际吞吐通常只有其 50~70%；出口带宽本身跑不满门槛时会大量触发「速度低」，可调低 `-LinkRatio`
- 每次重连会造成 2~5 秒断网，轮数越多总断网时间越长

## 环境要求

Windows 10 / 11，PowerShell 5.1+，自带 `curl.exe`。

## 免责说明

只做断开-重连和测速对比，不修改系统设置、不安装驱动、不采集任何个人数据。
