//
//  UnifiedDisplayLinkDispatcher.swift
//  pip_swift
//
//  【社区补丁 2026-10-18】统一 DisplayLink 调度器（补丁 9）
//
//  背景：App 内原来有 6 个常驻 CADisplayLink 各自为政——
//    隐藏 PiP 渲染 tick（120fps）、前台刷新驱动（120fps 空回调）、
//    滚动字（60fps）、时钟（60fps）、播放器活性（30fps link 内 1Hz 节流）、
//    调试掉帧监控（每帧）。每秒约 420 次 runloop 唤醒，且各自申请刷新率区间，
//    互相打架、浪费 CPU/发热。
//
//  本调度器只保留 ONE 个 CADisplayLink，用 divisor 分频把 6 个驱动并到同一时钟上：
//    divisor 1   = 每帧（120fps）：隐藏 PiP tick、掉帧监控
//    divisor 2   = 60fps：滚动字、时钟
//    divisor 120 = 1Hz：播放器活性检查
//  前台刷新驱动的空回调直接退役——调度器自身的存在即刷新请求。
//
//  帧率策略（"纹丝不动"）：强制 120 开启时申请最严格的
//    CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)（按屏幕上限钳制），
//    不给系统上下浮动的空间；关闭时 preferred 回 0、minimum 30，
//    把刷新率还给系统自适应，不干涉其它 App。
//  注意：发热降频是 iOS 铁律，任何 App 都绕不过；本调度器只保证"请求拉满、开销最小"。
//

import UIKit

final class UnifiedDisplayLinkDispatcher {
    static let shared = UnifiedDisplayLinkDispatcher()

    /// 订阅 ID（对外可见，调用方用来自查/退订）
    enum SubscriptionID {
        static let pipHiddenTick = "pip.hiddenTick"       // 隐藏 PiP 渲染，每帧
        static let pipScroll = "pip.scroll"               // PiP 滚动字，60fps
        static let pipClock = "pip.clock"                 // PiP 时钟，60fps
        static let playerActivity = "pip.playerActivity" // 播放器活性，1Hz
        static let stutterMonitor = "debug.stutter"       // 掉帧监控（调试），每帧
    }

    private struct Subscriber {
        let divisor: Int
        var tickCounter: Int
        let handler: (CFTimeInterval, CFTimeInterval) -> Void
    }

    private var link: CADisplayLink?
    private var subscribers: [String: Subscriber] = [:]
    private let lock = NSLock()

    /// 每个订阅到期时，统一执行 5 次回调。注意：这是任务调用次数，不是屏幕 FPS。
    private let callbackIterationsPerFire = 5

    private init() {}

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return link != nil
    }

    func isSubscribed(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return subscribers[id] != nil
    }

    /// divisor: 1=每帧，2=隔帧(60fps)，120=每秒1次。必须在主线程调用。
    func subscribe(id: String, divisor: Int, handler: @escaping (CFTimeInterval, CFTimeInterval) -> Void) {
        assert(Thread.isMainThread, "UnifiedDisplayLinkDispatcher.subscribe must be called on main thread")
        lock.lock()
        subscribers[id] = Subscriber(divisor: max(1, divisor), tickCounter: 0, handler: handler)
        let needsLink = link == nil
        lock.unlock()
        if needsLink {
            startLink()
        }
    }

    func unsubscribe(_ id: String) {
        assert(Thread.isMainThread, "UnifiedDisplayLinkDispatcher.unsubscribe must be called on main thread")
        lock.lock()
        subscribers.removeValue(forKey: id)
        let shouldStop = subscribers.isEmpty
        lock.unlock()
        if shouldStop {
            stopLink()
        }
    }

    /// 根据强制 120 开关重算刷新率区间。开关变化时由各处调用。
    func applyFrameRatePolicy() {
        assert(Thread.isMainThread, "UnifiedDisplayLinkDispatcher.applyFrameRatePolicy must be called on main thread")
        guard let link else { return }
        let screenMax = UIScreen.main.maximumFramesPerSecond
        // 【极限版】极限锁帧开启时无视其它刷新开关，始终走最严格区间。
        let strict = ExtremeRefreshLock.isEnabled || FrameRatePreference.isHighRefreshEnabled || DemoFrameRatePreference.isHighRefreshEnabled
        if #available(iOS 15.0, *) {
            if strict {
                // 纹丝不动：最小=最大=首选=120（按屏幕钳制），不给系统浮动空间
                let target = Float(min(120, screenMax))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: target, maximum: target, preferred: target)
            } else {
                // 关闭时释放：preferred=0 让系统自适应，不干涉其它 App
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(screenMax), preferred: 0)
            }
        } else {
            link.preferredFramesPerSecond = strict ? min(120, screenMax) : 30
        }
    }

    var diagnosticSummary: String {
        lock.lock(); defer { lock.unlock() }
        let ids = subscribers.keys.sorted().joined(separator: ",")
        return "running=\(link != nil), subscribers=[\(ids)]"
    }

    // MARK: - Private

    private func startLink() {
        assert(Thread.isMainThread)
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        // .common：滚动手势 tracking 期间也不停，与原隐藏 PiP 链路一致
        link.add(to: .main, forMode: .common)
        self.link = link
        applyFrameRatePolicy()
        AppDebugLogger.log("UnifiedDisplayLinkDispatcher started (single link, strict-120 policy applied)")
    }

    private func stopLink() {
        assert(Thread.isMainThread)
        link?.invalidate()
        link = nil
        AppDebugLogger.log("UnifiedDisplayLinkDispatcher stopped (no subscribers)")
    }

    @objc private func step(_ link: CADisplayLink) {
        // 快照订阅表，避免回调中 subscribe/unsubscribe 造成变异崩溃
        lock.lock()
        let snapshot = subscribers
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let timestamp = link.timestamp
        let targetTimestamp = link.targetTimestamp
        for (id, var sub) in snapshot {
            sub.tickCounter += 1
            if sub.tickCounter >= sub.divisor {
                sub.tickCounter = 0
                lock.lock()
                // 回调期间若被退订则跳过，避免对已释放逻辑的调用
                let stillSubscribed = subscribers[id] != nil
                if stillSubscribed {
                    subscribers[id]?.tickCounter = 0
                }
                lock.unlock()
                if stillSubscribed {
                    // 所有订阅（隐藏渲染、滚动、时钟、播放器活性、调试监控）
                    // 在各自 divisor 到期时统一执行 5 次；同一显示回调的时间戳相同。
                    for _ in 0..<callbackIterationsPerFire {
                        // 如果某次回调中退订，停止本轮剩余调用。
                        lock.lock()
                        let remainsSubscribed = subscribers[id] != nil
                        lock.unlock()
                        guard remainsSubscribed else { break }
                        sub.handler(timestamp, targetTimestamp)
                    }
                }
            } else {
                lock.lock()
                subscribers[id]?.tickCounter = sub.tickCounter
                lock.unlock()
            }
        }
    }
}
