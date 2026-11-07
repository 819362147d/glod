# 防闪退审计报告（pip_swift 全部源码）

审计日期：2026-11-07
审计范围：zip 内 `GlobalRefresh-PiP-patched/pip_swift/pip_swift/` 全部 Swift 源文件
（即 Codemagic 实际构建的目标；pip_oc 不参与构建，未审）。
方法：全量模式扫描 + 逐处人工核对上下文。**结论：本轮不改任何代码**，理由见下。

## 总账

| 类别 | 数量 | 结论 |
| --- | --- | --- |
| 字面量强制解包 `!` | 5 处 | 全部可证明安全，见逐处结论 |
| 强制类型转换 `as!` | 0 | — |
| `try!` | 0 | — |
| 动态集合下标 / `first!` / `max()!` 等 | 0 | 集合取值一律走 `guard let .first` |
| KVC `value(forKey:)` 强取 | 0 | 社区补丁 3 已改为先 `responds(to:)` 探测 |
| `fatalError` | 6 处 | 全部是 `required init?(coder:)` 未实现桩，标准写法，代码构建 UI 永不触发 |
| 隐式解包属性（IUO）直接访问 | 7 个属性 / 144 处访问 | 结构性风险，见第 3 节，本轮不动 |

## 1. 字面量强制解包逐处结论（5 处，全部保留）

- `VersionViewController.swift` 4 处 `URL(string:)!`：字符串均为编译期常量
  （GitHub API 与发布页地址，仓库名 `Yoroin/GlobalRefresh-PiP` 为硬编码常量，
  不含空格或非法字符），`URL(string:)` 不可能返回 nil。
- `PiPShortcutIntents.swift:63` `fallbackURL`：拼接结果为
  `globalrefresh://` + 枚举穷举的路径（仅 `start` / `hide` / `startandhide` 三种常量），
  不可能失败。

## 2. 与补丁说明「260 处强制解包未审计」的对账

原 PATCH_NOTES 称「高频路径 260 处强制解包审计（未做）」。按本版本源码实测：
字面量解包 5 处；若把 7 个 IUO 属性的每处直接访问都算作一次隐式解包，
合计约 149 处，仍与 260 有出入。该数字应来自更早的代码状态或不同的计数口径，
**不适用于当前包**。当前包的解包面比补丁说明描述的要干净得多——这与补丁 1–9
已落地的加固（降级路径、启动失败熔断、KVC 探测、统一 DisplayLink）相互印证。

## 3. 唯一的结构性风险：ViewController 的 7 个 IUO 属性

`playerLayer`、`pipController`、`pipSourceView`、`customView`、`textView`、
`clockLabel`、`clockOverlayView` 声明为隐式解包可选型，代码会在 teardown 时
将它们置 nil（约 1814–1829 行）、在 setup 时重建（约 1895–2094 行），
共 144 处直接成员访问。

- 已有的防护：主要入口（2135 / 2238 / 2328 行等）先过
  `preparePiPInfrastructureIfNeeded()` 守卫；多处热路径用 `guard let` / `if let`
  绑定后再用（4144 行起多处）。抽查生命周期入口，未发现 teardown 与重建之间
  存在可达的裸访问路径。
- 残余风险：若未来新增入口在 teardown 窗口内裸访问这些属性，会直接闪退。
  这是注意义务，不是现行缺陷。
- 为什么本轮不改：改成真 Optional 需要逐一改写 144 处访问，分布在一个
  6445 行的文件里；在没有本地 Xcode 编译验证的条件下批量改写，
  引入新崩溃的概率大于消除的风险。**建议**：以后谁在有真机编译环境时做这件事，
  一次只改一个属性、改完即构建验证。

## 4. 审计未覆盖的部分（诚实边界）

- 本审计只针对解包/强转类崩溃源。竞态、KVO/通知观察者失衡、私有 API 在未来
  iOS 版本上的行为变化不在本次范围内（私有路线已有版本门禁与降级，见原补丁 1/2）。
- 未做真机运行验证：以上结论均为静态审计结果。
