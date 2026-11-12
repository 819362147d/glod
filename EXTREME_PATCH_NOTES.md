# 极限版补丁说明（极限锁帧）

在社区补丁版（v1.1.1 / 20261028 包）基础上追加，**默认关闭，不改变原版行为**；
开启后多一个「极限锁帧」开关，位于 App 内「帧率演示」页、原 120Hz 开关下方。

## 实现方式（不改动原 zip）

仓库根目录 `codemagic.yaml` 在解压源码包后、构建前，会用 `extreme-overrides/`
里的同名文件覆盖 `GlobalRefresh-PiP-patched/pip_swift/pip_swift/` 下的源码
（极限锁帧 3 个文件；2026-11-09 性能补丁后共 5 个文件），
其余步骤与原版一致。想回退原版：删掉 codemagic.yaml 里的
"Apply extreme-lock overrides" 步骤即可（或直接关掉 App 内的开关）。

## 改动清单（共 3 个文件，均为最小改动）

1. `FrameRateTestTabBarController.swift`
   - 新增 `ExtremeRefreshLock` 偏好（UserDefaults 键 `globalRefresh.extremeLock120`，
     默认 false），切换时复用现有 `FrameRatePreference.didChangeNotification` 通知链，
     使调度器立即重算帧率区间。
   - 「帧率演示」页新增「极限锁帧」开关卡片（含中英文案与代价说明）。

2. `UnifiedDisplayLinkDispatcher.swift`（仅 1 行）
   - `applyFrameRatePolicy()` 的严格模式判定追加 `ExtremeRefreshLock.isEnabled`：
     开启后无视「强制 120」「帧率演示」两个开关的状态，统一 DisplayLink 始终以
     `minimum = maximum = preferred = 屏幕上限` 申请。

3. `ViewController.swift`（2 处赋值 + 1 个计算属性）
   - 新增 `pipBackingCompositionFrameDuration`：极限锁帧开启时返回 1/屏幕上限，
     关闭时返回原版 1/30。
   - PlayerLayer 兼容路线（状态视频、参考预设）原先写死 1/30 的两处
     `videoComposition.frameDuration` 改为读取该属性。主路线
     （`makeReferenceStyleTimeVideoComposition`）本来就按屏幕上限合成，未动。

## 核查结论（先于本补丁的事实澄清）

- `CADisableMinimumFrameDurationOnPhone` **原本就在** pip_swift 的 Info.plist 里
  （值为 true），无需添加；此前“缺失”的说法是检查方法出错，特此更正。
- 统一调度器的严格 120 区间在两个既有开关默认开启时本来就生效；
  本补丁的增量是让它**独立于那两个开关**（例如做帧率检测临时关掉演示开关时仍保持死锁），
  以及把兼容路线的合成帧率一并拉满。

## 2026-11-09 性能补丁（游戏前台 + 悬浮窗场景）

目标排序：游戏前台帧率稳定 > 本 App 少占 CPU/内存/磁盘 I/O > 锁帧与保活可靠性不变。
逐项对着源码复核后，只落地以下 5 处；预期是减少持续性的小开销和状态切换时的
诊断开销，不承诺可感知的帧率跃升（原包的热路径此前已被社区补丁优化得较深）。

1. `ViewController.swift` — FPS 归一化表改为一次性静态计算。
   `normalizedMeasuredFPS` 在时钟悬浮窗运行期间每秒被调用约 60 次，原实现每次
   都新建并过滤 `[30, 45, 60, 75, 80, 90, 100, 120]` 数组；该表只取决于设备
   最高刷新率，运行期不变，现改为 `standardFrameRates` 静态常量复用。

2. `ViewController.swift` — FPS 变化路径少读一次高刷偏好。
   `updateMeasuredFPS` 在 FPS 变化分支与其后的确认计算中各读一次
   `FrameRatePreference.isHighRefreshEnabled`（每次含 2 次 UserDefaults 查询）；
   现改为在变化分支读一次并传给确认计算。稳态帧（FPS 未变化）行为与开销不变。

3. `ViewController.swift` — 诊断关闭时跳过重型状态文本构建。
   `updateDiagnosticsPiPState` 原先无条件构建悬浮窗表面/熄屏诊断文本（遍历多个
   视图与图层、数十个字段格式化），而这些文本的消费者只有调试/诊断导出路径。
   现仅在调试模式或深度诊断开启时构建；`updateDisplaySleepDiagnostics` 同步加
   前置守卫，但显式要求写日志的调用（`shouldLog: true`）保持原行为。

4. `AppDebugLogger.swift` — 设备型号改为一次性计算。
   `deviceModelIdentifier` 原先是计算属性，每写一条调试日志都要重复
   `uname` + `Mirror` 反射拼字符串；设备型号运行期不变，现改为静态常量。
   （该路径仅在调试模式开启时执行，属顺手消除的重复开销。）

5. `KeepAliveLogger.swift` — 保活事件历史不再逐条强制刷盘。
   事件数组写入后原先每次都调用 `UserDefaults.synchronize()`；这些事件仅用于
   诊断导出，不参与保活判定，现只做普通写入。注意：心跳路径
   （`heartbeat()`）的 `synchronize()` **刻意保留不动**，因为异常中断推断
   依赖心跳落盘的新鲜度。

### 复核后未采纳（附理由）

- **`AppDebugLogger.logCritical` 去掉整表写盘 + `synchronize()`**：该入口的设计
  意图就是在生命周期/内存警告/保活切换时确保最后状态落盘，供下次启动推断异常
  中断；且它只在调试模式开启时才真正执行，对默认游戏场景零收益，不值得用
  诊断可靠性换取。
- **定位保活加 `distanceFilter`**：当前已是 3 公里粗精度档，加距离过滤的省电
  收益小，却可能让静止状态下长时间收不到定位回调、削弱后台保活可靠性，
  与「锁帧别断」目标冲突，不动。
- **自定义合成器逐帧对象分配 / 参考路线渲染尺寸上限**：
  `ReferenceStyleTimeVideoComposition` 确实逐帧新建颜色空间与 UIColor，
  `referenceRenderSize` 也确实按源轨道原始尺寸合成；但复核确认这条 pure 路线
  依赖的预置视频（`fc_ref_*`、`pip_reference_10_1` 等）在当前源码包与用户
  `_5` IPA 中均不存在（包内无任何 .mov/.mp4 资源），该路线在当前构建中
  不可达。没有为不可达路径新增覆盖文件；将来若补入预置视频资源，应先做这两项。
- **去掉统一调度器的 5× 回调循环（all-callbacks-5x）**：2026-11-09 深扫确认
  必须保留，不可当成冗余“优化”掉。它是该构建的命名特性（源码包即
  `GlobalRefresh-PiP-all-callbacks-5x-20261028.zip`；`PATCH_NOTES.md` 2026-10-28
  轮列在“保留不动（用户明确要求）”之下）。逐个 handler 核对过，5× 下均安全：
  隐藏 tick 按时间戳差推进（同帧重复调用推进为 0）、时钟有文本去重、播放器
  活性自带 1 秒节流、掉帧监控默认关闭。唯一非幂等的是滚动字
  （`updateScrollingText` 每次 +1pt）：60 次/秒 × 5 ≈ 300pt/秒，而单调设计值
  是 60pt/秒——这是自 20261018 起就有的实际速度，不是 bug；日后若嫌滚动太快，
  正确改法是每步改为 0.2pt，不是去掉 5×。另 `tickCount` 在 10 秒一条的诊断
  日志里会被 5× 夸大，仅影响一行日志数字，不影响行为。

## 已知边界（与原版相同，不因本补丁改变）

- 屏幕物理上限（60Hz 屏变不出 120Hz）、游戏自身锁帧、触控采样率：均无法突破。
- 发热降频是系统铁律：长时间满载后系统仍会降频，本开关绕不过。
- 死锁 120 与锁 60 内容帧率不同步时可能出现一快一慢的卡顿（原版 README 已注明），
  介意时关掉开关即恢复原版自适应行为。
- 本补丁未经真机编译验证：以 Codemagic 构建成功为准；若构建报错，把日志发回再修。

## 2026-11-13 前台性能（滚动字写入合并）+ Codemagic extreme 工作流

目标：游戏在前台、PiP 悬浮窗在后台时，本 App 少抢 CPU，让前台游戏拿到最多的设备性能；滚动视觉速度不变。

改动（`extreme-overrides/ViewController.swift`，仅 `updateScrollingText` + 1 个累加属性）：

- 统一调度器每帧固定回调 5 次，原先每次都 +1pt 写 `contentOffset`（300 次/秒，
  每次都触发 UITextView 布局），实际速度 300pt/秒，是设计值 60pt/秒的 5 倍。
- 现每步累加 0.2pt（11-09 节认定的正确改法），满 1pt 才写一次：速度回到设计值
  60pt/秒，布局写操作从 300 次/秒降到 60 次/秒。`pendingScrollOffsetDelta`
  在 `startDisplayLinks` / `stopDisplayLinks` 里随 `lastScrollTimestamp` 一起清零。
- 5× 回调循环本身不动（11-09 已确认必须保留）；`lastScrollTimestamp` 只写不读，
  其语义未变。

复核后未采纳（附理由）：

- **调度器 `step()` 里每轮 5 次上锁复查**：约 1200 次锁操作/秒，全是无竞争 NSLock，
  合计约 0.1ms/秒；改锁纪律会动 11-07 审计肯定的防崩快照语义，收益可忽略，不动。
- **时钟订阅 divisor 2→6**：`updateClockDisplay` 每调用一次多半是廉价守卫提前返回
  （`Date()` + 字符串比较，DateFormatter 最多 10 次/秒），降频省不下什么，
  却会让 FPS 读数在刷新率切换时确认变慢（24 个样本从 0.4 秒拖到 1.2 秒），不动。
- **`UIRequiresFullScreen`**：iPhone 上是空操作（无分屏），iPad 上会杀掉多任务；
  前台游戏在 iPhone 上零收益，不动。
- **SnapKit 符号表**：约 175KB，Mach-O 手工截断风险大，收益约 100KB（压缩后），不动。

Codemagic（`codemagic.yaml` 新增 `ios-unsigned-extreme` 工作流）：

- 与安全版 `ios-unsigned-patched` 同源同覆盖；打包时额外做二进制极限版同款处理：
  删 `Assets.car`（6.5MB）、图标改走 `CFBundleIconFiles`（loose PNG 必须在，
  否则构建直接报错停掉，不静默出无图标包）、补 `CADisableMinimumFrameDuration`。
- 安全版打包步骤也补了 `CADisableMinimumFrameDuration`（与二进制 maxframe 版一致）。
- 触发方式：仓库未接 Codemagic webhook，也无 API token，push 不会自动构建；
  在 Codemagic 网页选 app → Start build → workflow `ios-unsigned-extreme` →
  branch `main` 手动触发。构建成功即编译验证通过；产物下载后按二进制极限版
  同款清单校验（解压、plist 回读、cryptid、SHA256），再挂 passpor。

## 2026-11-13 编码优化（保活静音重编码）

- `slience.mp3`（保活静音，`BackgroundTaskManager/` 下）原为 64kbps MP3，
  81,216 字节、10.152 秒、8kHz 单声道。静音内容用 64kbps 纯属浪费，
  重编码为 8kbps：10,557 字节，时长同为 10.152 秒，同样 MP3 8kHz 单声道，
  解码验证仍为静音（max_volume -91dB，听不见）。
- 文件名、格式、时长都不变，`BackgroundTaskManager` 按名加载不受影响。
  仅极限版用：`extreme-overrides/slience.mp3` + `ios-unsigned-extreme`
  工作流新增 `Apply extreme audio encoding` 步骤覆盖；安全版不动。
- 诚实数字：IPA 只小了 174 字节（918,781 → 918,607），因为 zip 本来就把
  静音压得很小；省的是安装后体积（约 70KB），不是下载体积。
- 编译器编码：Release 已是 `SWIFT_OPTIMIZATION_LEVEL = -O` + wholemodule
 （Debug 才是 `-Onone`），Codemagic 用 `-configuration Release`，编译器优化已开。
- 视频编码：`pipBackingCompositionFrameDuration` 在极限锁帧开启时已是 1/屏幕上限；
  自定义合成器逐帧建颜色空间的问题只在不可达的 pure 参考路线（包内无预置视频），
  优化死代码零收益，不动。

## 2026-11-13 元计算微优化（`hardwareMaximumFrameRate` 静态常量）

- `normalizedMeasuredFPS` 原先每次调用都读一次 `UIScreen.main.maximumFramesPerSecond`
  （时钟可见时 300 次/秒）。该值是硬件常量，运行期不变，提到静态常量
  `hardwareMaximumFrameRate`（`static let`，首次访问懒初始化，线程安全）；
  `standardFrameRates` 的初始化闭包也改用同一常量。行为不变，省掉重复属性读取。
- 视频合成路径（`pipBackingCompositionFrameDuration`、参考路线）里同名读取是
  一次性装配调用，不在热路径上，留原样。
