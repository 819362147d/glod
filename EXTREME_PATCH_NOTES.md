# 极限版补丁说明（极限锁帧）

在社区补丁版（v1.1.1 / 20261028 包）基础上追加，**默认关闭，不改变原版行为**；
开启后多一个「极限锁帧」开关，位于 App 内「帧率演示」页、原 120Hz 开关下方。

## 实现方式（不改动原 zip）

仓库根目录 `codemagic.yaml` 在解压源码包后、构建前，会用 `extreme-overrides/`
里的 3 个同名文件覆盖 `GlobalRefresh-PiP-patched/pip_swift/pip_swift/` 下的源码，
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

## 已知边界（与原版相同，不因本补丁改变）

- 屏幕物理上限（60Hz 屏变不出 120Hz）、游戏自身锁帧、触控采样率：均无法突破。
- 发热降频是系统铁律：长时间满载后系统仍会降频，本开关绕不过。
- 死锁 120 与锁 60 内容帧率不同步时可能出现一快一慢的卡顿（原版 README 已注明），
  介意时关掉开关即恢复原版自适应行为。
- 本补丁未经真机编译验证：以 Codemagic 构建成功为准；若构建报错，把日志发回再修。
