# 本地改动说明（IR 红外在场检测 / 只灭屏不锁屏）

基于 upstream `jvloo/lockscreen-dah-macos` v1.5.0（commit 7c191dd）。代码 MIT。

## 这个 fork 做了什么

1. **新增 `.dimmed` 状态**：确认无人后不再走「倒计时 → 锁屏」，而是全屏纯黑遮罩 + 保持相机低帧采样；检测到人脸立即撤罩。不锁屏，所以回来不需要密码。
2. **人脸面积门限** `Settings.minFaceAreaRatio = 0.01`：无人时 Vision 仍会 100% 报出 0.21–0.55% 的小框（置信度最高 0.88，比真人还高），必须用面积过滤。实测：坐姿 5.0–9.6%，后靠 1.48–3.39%，无人 ≤0.55%。
3. **优先选择 IR 摄像头**：`AVCaptureDevice.default(for:)` 永远拿不到 IR（UVC/external、无 position）。改为 `DiscoverySession` + 名字匹配 `IR Camera`。
4. **去掉 `sessionPreset = .vga640x480`**：IR 模块在该 preset 下能配置、能 startRunning，但**一帧都不出**（实测 3.3s 卡死 → 重试循环）。
5. **帧率设置加保护**：IR 只报 60-60 固定帧率，`setActiveVideoMinFrameDuration` 会抛 ObjC 异常（Swift 的 do/catch 抓不住，实测 SIGSEGV 崩溃）→ 仅在 `min < max` 的格式上设置。
6. **启动时先请求摄像头**：在 `NSApplication.shared` 之前请求，可继承启动终端（ZCode/Terminal）的 TCC 授权。创建 NSApp 之后请求会被当成独立 app 而拒绝。

## 参数（菜单 Settings 里全部可调，**改完立即生效，无需重启**）

| 菜单项 | 含义 | 默认 |
|---|---|---|
| **Input Counts as Presence** | 键鼠有输入后的多少秒内视为在场，相机完全关闭（0 = 关闭此功能，相机常开） | 5 秒 |
| **Quick Check Every** | 已确认在场、但没人在操作时，每隔多久开一次相机快速判人 | 5 秒 |
| **Quick Check Length** | 一次快速检查最长开多久（判到人就提前关） | 1.5 秒 |
| **Absence Delay** | 判定无人后，持续多久才灭屏 | 5 秒 |
| **While Dimmed, Check Every** | 灭屏后每隔多久开一次相机（决定回来多快亮） | 3 秒 |
| **While Dimmed, Check Length** | 灭屏后每次开多久（判到人脸立即提前结束） | 1 秒 |
| 人脸面积门限 | 0.01（1%） | 固定 |
| 模式 | Dim instead of Locking（关掉即恢复上游「倒计时→锁屏」） | 开 |
| 监测时段 | 关（Always on） | — |

相机只在三种时刻真的开流：①快速检查的 1.5 秒；②怀疑无人后的连续确认；③灭屏后等你回来。**打字/用鼠标期间相机是彻底关闭的**，红外补光灯、白色摄像头灯、菜单栏绿点都会灭。

## 在这台机器上怎么跑

```bash
./build.sh     # 编译 + 打包 build/Lockscreen Dah.app
./run.sh       # 复制一份未签名副本到 /tmp，从终端启动（TCC 授权继承）
./stop.sh      # 停止
```

**已安装版本（2026-11-25）**：
- `/Applications/Lockscreen Dah.app` —— 中文界面，但**双击它拿不到摄像头**（TCC 拒绝签名包，本机缺陷）；
- **`/Applications/启动 Lockscreen Dah.command`** —— 双击这个启动：复制未签名副本、从终端启动、继承摄像头授权（实测 auth=3）。日常请用它。
- 单实例锁：已有实例在跑时，任何再次启动都会直接退出并提示。
- 登录自启默认关闭：自启会从 `/tmp` 副本启动，拿不到终端授权，且多实例曾导致两次 WindowServer panic。

**必须用 `run.sh` 启动。** 直接双击 .app 或 `open` 会走「独立 app」的 TCC 路径——这台黑苹果不给任何 .app 弹摄像头授权窗，结果是静默拒绝。菜单栏图标：🔵 正常监测 / 🌙 已灭屏 / ⚠️ 未注册人脸（presence-only）。

灭屏后想立刻恢复：**按一次 Esc**（dim 模式不需要验证），或直接回到座位让相机看到脸。

## 实测验收（2026-11-25）

- 离开座位约 10 秒（grace 5s + 采样间隔）后：屏幕亮度 229 → **0.2**，多出全屏遮罩窗口。
- 回到座位约 2 秒后：亮度恢复到 231，遮罩消失。
- 全程 `auth=3`，使用 `Integrated IR Camera`，首次分析结果在启动后 1.07s。
- 119 个单元测试全过（含 6 个新增 dim 模式监督器测试）。

## 已知限制

- **无 FaceEmbedding 模型**（`scripts/fetch-model.sh` 未运行）→ presence-only：任何人脸都算在场，不区分是不是你。要「只认我」需拉模型 + 同域注册。
- **绿灯**：相机 watching 期间常开，菜单栏摄像头指示灯可能常亮；灭屏时遮罩会盖住菜单栏。
- **功耗**：watching 期间每 2.5 秒一次 Vision（约 100ms/次）；灭屏后每 1 秒一次。
- **FileVault 开机解锁**：preboot 阶段任何第三方 app 都跑不了，此方案只覆盖「使用中离开」。

## 2026-11-25 17:20 追加：会话自愈与输入唤醒

- **灭屏时任意键鼠输入也能亮屏**（不再只能按 Esc 或等人脸）；恢复原因记在日志 `reason=face/body/input/escape/setting`。
- **参数下限**：灭屏检查时长 ≥1 秒、间隔 ≥3 秒、快速检查时长 ≥1 秒。原因是 IR 相机开流后第一帧（0.46–0.58s）几乎必然无脸，脸要到 0.76–1.0 秒才出现；窗口太短等于每次都在脸出现前关机。
- **会话重建**：每 50 次开流自动重建采集图。
- **盲帧自愈**：会话曾有过正常画面、预热 2 秒后仍连续 10 帧零方差 → 判定退化并重建；暗房间/遮镜头不会误触发。
- 实测：修正后 2 分钟内 0 次误重建，快检每 30 秒一次且每次确认在场，瞬时 CPU 0%。

## 2026-11-25 18:25 追加：主队列空转修复 + 灭屏检查提前结束

- **主队列空转（已修）**：打字期间每个 tick 都会刷新在场时间戳；`handleGraceExpired` 门控分支强制排到未来。修复前 54 分钟烧掉 5m16s CPU（瞬时 58–117%），修复后 41 秒仅 0.34s、瞬时 0%。
- **灭屏检查提前结束**：`DetectionResult.imageWasFlat` 标记预热黑帧；拿到预热 0.8 秒后第一帧有效画面就立即关相机（有人则立即亮屏），不再等 1 秒 tick 或撞时长上限。
- 灭屏检查时长默认/下限 1.5 秒（兜底），菜单可选 1.5/2/3/5。
- 138 个测试全过；实测人脸唤醒 `reason=face` 成功。

## 2026-11-25 19:05 追加：CPU 优化落地（frameIsFlat 2vuy 修复 + 灭屏降频）

- **真实像素格式**：IR 相机输出 **2vuy（UYVY 打包，640×480）**。旧 `frameIsFlat` 每 16 字节采样（永远偶数偏移）→ 只采到恒为 128 的色度字节 → **所有帧恒判「全平」**。探针实测：同一帧 Vision 检出人脸（conf 0.82、面积 10.5%），判定仍是全平。
- **后果**：灭屏「有效帧提前关相机」从未生效（每次跑满 1.5 s）；「盲帧自愈」实际失效；预热帧的 Vision 照跑。
- **修复**：`frameIsFlat` 改为格式感知的**亮度采样**——2vuy 取奇数 Y 字节、yuvs 取偶数、planar 取 plane 0、未知格式保留保守全字节扫描；**真全平帧跳过 Vision**（仍上报空结果，保 liveness / 预热门控 / 盲帧检测），日志记 `flat frame; vision skipped`。新增 `FrameFlatnessTests` 8 例，全套 **146 个测试通过**。
- **设置**：灭屏检查间隔 3 s → **10 s**（`defaults write com.xavierloo.lockscreen-dah dimmedCheckInterval -float 10`；菜单「灭屏检查间隔」显示 10 秒）。
- **实测（19:07:53–19:11:12，19 次脉冲）**：间隔精确 10.00 s；每次开流 **1.00 s**（0.99–1.04）；每次 **3 次 Vision**；单次脉冲 CPU 136 → **86.5 ms**；灭屏平均 3.14% → **0.92%**（−71%）；8 小时无人约 **265 s CPU**（原 904 s）。人脸唤醒在开流后 0.70 s。
- **装机**：`./build.sh` → `InputMapper Self-Signed` 重签 → `/Applications/Lockscreen Dah.app`（旧版备份 `Lockscreen Dah.app.bak-20261125-1905`）→ 经 `.command` 重启为 pid 44490，`camera auth at start: 3`。
- 完整测量报告：Obsidian `ZCode/实测-红外在场检测CPU占用-20261125.md`。


## 2026-11-25 19:26 追加：TCC 方案 A 落地（.app 可直开）+ 34.5 分钟浸泡

- 新增 `scripts/grant-camera-tcc.sh`：把 TCC 用户库里 camera 行的 `csreq` 从 40 B 旧 cdhash 改成当前 84 B 证书根型 DR；`auth_value=2` 不变；写前 `.backup`，之后 kickstart `gui/501/com.apple.tccd`。备份 `TCC.db.bak.20261125-192625`。
- `build.sh`：优先用 `InputMapper Self-Signed` 签名并保留 `--options runtime --entitlements`；`--install` 先 grant 再 `open`，支持 `--no-grant`。
- 验证：`open /Applications/Lockscreen Dah.app` → `camera auth at start: 3`、`paused -> watching`、单实例；TCC 行 84 B。
- 首次冷启动一次 3 s 无帧 → `cameraUnavailable`，30 s 重试自愈（既有抖动，浸泡未复现）。
- 浸泡（34.5 min，灭屏 17m55s / 180 脉冲，设置 5 s、你已确认保留）：灭屏 1.59%、在座 0.28%、整段 0.96%；无 stall / 误重建 / panic；WindowServer 0.8–7.6%。10 s 配置按此前实测约 0.92%。
- 遗留：`.app` 被拒占锁未修；系统级 TCC 弹窗仍关死（其它 app 受影响）；清理/git 待拍板。

## 2026-11-25 20:15 追加：占锁退出 / 登录自启 / 默认值规范化 / 背光

- **`.app` 被拒占锁（已修）**：`showCameraDeniedAlert` 弹完提示后 `NSApp.terminate(nil)`，不再带着单实例锁停在弹窗上；`.command` 仍可启动。
- **登录自启（已启用并注册）**：`openAtLoginEnabled=1`，启动时 `SMAppService.mainApp.register()` 成功（日志 `login item registered`；`sfltool dumpbtm` 可见 `Lockscreen Dah` / `file:///Applications/Lockscreen%20Dah.app/`）。实际登录启动尚未验证。
- **defaults 规范化（已修）**：启动时 `Settings.normalizeStoredValues()` 把被钳制的值写回。实测 `dimmedCheckDuration` 从存储 0.5 变为 **1.5**；`dimmedCheckInterval=5` 保持。新增 4 个测试，全套 **150 个测试通过**。
- **背光（新功能）**：`DisplayBrightness.swift` 通过私有 `DisplayServices` 把内屏背光置 0；进入灭屏时保存亮度并关背光，退罩/暂停/锁屏/相机故障/录入/退出时恢复；崩溃或 `kill -9` 用 UserDefaults 标记 + 下次启动恢复（若用户已手动调亮则不覆盖）。探针已验证 `Get/Set`；**已实测**：20:21:05 关背光、20:22:59 恢复（亮度回到 0.8125）。
- **`build.sh --install` 全流程（已复测）**：构建 17.9 s → 安装 → grant（already granted）→ `open`；新 pid 79988，`auth=3`，`watching`。
- **清理**：删除两个旧 TCC 备份与旧版 `.app` 备份；`/tmp` 采样已归档到 `cpu-probe/sessions/` 后删除；保留最新 TCC 备份 `TCC.db.bak.20261125-192625`。
- **git**：3 个提交（`693ef91` 源码/测试、`5ed3240` 构建/TCC、`ec736d6` 文档），工作区干净，未 push。
- **唤醒实测**：开流→亮屏 **0.70 s**（首分析 0.48 s + 匹配）；回座等待受灭屏检查间隔限制（5 s：平均 ~3.2 s、最坏 ~5.7 s）。待定 3 s / 5 s。
- **未做/待验证**：实际登录自启；`.app` 被拒退出路径未实测（需清 TCC 记录，未做）。

## 2026-11-25 20:50 追加：灭屏检查跑满 / 3 秒间隔 / 身体建立 presence / IR 图标

- **F1（灭屏检查跑满）**：不再「有效帧提前关」，每次跑满 `dimmedCheckDuration`（1.5 s）或直到脸/身体；间隔 3 s。实测：开流 1.50 s、关→开 3.00 s；一次 `bodies=1` 在 0.79 s 撤罩（reason=body），不碰键盘也能唤醒。
- **F1.1（身体建立 presence）**：presence-only 模式下 `bodyCount>0` 可以**建立**存在链（原来只能维持）；避免「坐着、脸不在画面里 → 先灭屏，再被身体唤醒」。`PresenceTracker.observe(_:now:presenceOnly:)` + `MonitorCoordinator` 传入 `recognizer.isPresenceOnly`；新增 2 测试，全套 **151 通过**。
- **IR 图标**：新做 1024×1024 深蓝底 + 白色“IR” + 青色镜头环/LED 点；生成 `Resources/Icon.icns`（全尺寸 iconset），`CFBundleIconFile=Icon`，`build.sh` 复制 icns。Finder 中应用图标显示“IR”。
- **实测**：20:50 启动 pid 96528，auth=3；快检在 1.0–1.5 s 内 `faces=1`，保持 watching，不再误灭屏。
- **注意**：慢启动时脸可能 1.5–1.7 s 才出现；若仍偶发漏检，可把「灭屏检查时长」从 1.5 s 提到 2 s（菜单项，热生效）——先观察。

## 2026-11-25 21:14 追加：C2/C3/C4 + 完整安装包

- **C2 身体建立 presence 加固**：presence-only 下需**连续 2 帧** `bodyCount>0` 才建立存在链（单帧可能是误报）；维护仍单帧。测试覆盖 1 帧不建立、2 帧建立、中间空帧重置。
- **C3 冷启动帧缺口**：首个分析结果之前，帧缺口改用 `startupAllowance`（15 s）判定，不再用 3 s 稳态门槛。修复 19:27「一帧后静默 3 s → cameraUnavailable」的误判；仍保留 15 s 上限。测试覆盖。
- **C4 菜单栏 IR 图标**：watching/alerting/locked 用代码绘制的 “IR” template monogram；paused/cameraUnavailable/enrolling/dimmed 保留原 SF Symbols。截图确认菜单栏显示 IR。
- 全套 **154 个测试通过**；当前 pid **8916**，auth=3。
- **完整安装包**：`/Volumes/DATA/LockscreenDah-1.5.0-20261125.dmg`（698 KB，sha256 `7d6910b9…59204`），含 app、`安装.command`、`启动 Lockscreen Dah.command`、`scripts/grant-camera-tcc.sh`、`README-安装说明.md`。
- **推送待办**：SSH 身份为 `sailingalone-cn`，但未找到公开的 `lockscreen-dah-macos` fork；需 fork URL 后再推。
