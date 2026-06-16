import Foundation
import Darwin

// MARK: - Apple Silicon 温度读取（私有 IOHID 传感器 API）

/// 通过私有 `IOHIDEventSystemClient` 接口读取芯片温度传感器。
/// Apple Silicon 没有公开的 CPU 温度 API —— 这是 Stats / TG Pro 等监控软件都在走的标准路线。
/// 实测 M4：page=0xff00 / usage=5 能枚举到 47 个温度传感器，其中名字含 `tdie`（裸片温度）
/// 的一组（PMU tdie1..14 / PMU2 tdie1..10）读数稳定，平均值即为 SoC/CPU 近似温度。
/// 用 `dlsym` 取私有符号，避免桥接头（本项目纯 SPM 无 bridging header）。
@MainActor
final class ThermalSensorReader {
    private typealias CreateFn       = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn  = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject?, CFString) -> Unmanaged<CFString>?
    private typealias CopyEventFn    = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn     = @convention(c) (AnyObject?, Int32) -> Double

    private var copyEvent: CopyEventFn
    private var getFloat: GetFloatFn
    /// 必须持有 client：温度服务由它派生，client 释放后服务会失效
    private var client: AnyObject?
    /// 已缓存的裸片温度传感器（名字含 "tdie"），初始化时筛一次
    private var dieSensors: [AnyObject] = []

    private let kTemperatureType: Int64 = 15
    private let tempField: Int32 = 15 << 16   // IOHIDEventFieldBase(kIOHIDEventTypeTemperature)

    /// false = 这台机器 / 这个系统版本读不到温度（优雅降级，UI 不显示温度）
    private(set) var available = false

    init() {
        // 解析失败时塞两个空实现，保证非 optional 属性有值
        copyEvent = { _, _, _, _ in nil }
        getFloat = { _, _ in .nan }

        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func sym<T>(_ name: String, _ t: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let create       = sym("IOHIDEventSystemClientCreate", CreateFn.self),
            let setMatching  = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
            let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
            let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
            let copyEvt      = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
            let getFlt       = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
            let clientUM     = create(kCFAllocatorDefault)
        else { return }

        self.copyEvent = copyEvt
        self.getFloat = getFlt

        let c = clientUM.takeRetainedValue()
        self.client = c

        // PrimaryUsagePage=0xff00 (AppleVendor) / PrimaryUsage=5 (TemperatureSensor)
        let match: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = setMatching(c, match as CFDictionary)

        if let servicesUM = copyServices(c) {
            let services = servicesUM.takeRetainedValue() as [AnyObject]
            for s in services {
                guard let nameUM = copyProperty(s, "Product" as CFString) else { continue }
                let name = nameUM.takeRetainedValue() as String
                if name.contains("tdie") { dieSensors.append(s) }
            }
        }
        available = !dieSensors.isEmpty
    }

    /// 当前芯片裸片温度（°C）—— 所有有效 tdie 传感器的平均值；读不到返回 nil
    func read() -> Double? {
        guard available else { return nil }
        var sum = 0.0
        var count = 0
        for s in dieSensors {
            guard let evUM = copyEvent(s, kTemperatureType, 0, 0) else { continue }
            let ev = evUM.takeRetainedValue()
            let t = getFloat(ev, tempField)
            if t.isFinite && t > 10 && t < 120 {   // 过滤无效读数（未接传感器会给 -21 之类）
                sum += t
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }
}

// MARK: - 系统资源采样中枢

/// 每 2s 采样一次系统状态，供灵动岛右耳轮播 + hover 面板显示。
/// 采样全部走公开 mach / BSD API（温度除外，见 `ThermalSensorReader`），调用都是微秒级，
/// 放在主线程每 2s 一次成本可忽略。`@Observable` → SwiftUI 读属性即自动订阅刷新。
@MainActor
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    private(set) var cpuUsage: Double = 0          // 整机 CPU 占用 0...1
    private(set) var memUsedGB: Double = 0         // 已用内存（GB，≈ 活动监视器「已用内存」）
    private(set) var memTotalGB: Double = 0
    private(set) var memUsedFraction: Double = 0   // 已用 / 总量 0...1
    private(set) var netDownBytesPerSec: Double = 0
    private(set) var netUpBytesPerSec: Double = 0
    private(set) var cpuTempCelsius: Double? = nil // nil = 这台机器读不到温度
    /// 每次采样自增 —— 右耳轮播靠它驱动（避免内联 Timer 被每次重绘重置导致永不触发的坑）
    private(set) var sampleTick: Int = 0

    private var loopTask: Task<Void, Never>?
    private var running = false

    // CPU 用差值算：保存上一次累计 tick
    private var prevCPU: (used: Double, total: Double)? = nil
    // 网速用差值算：保存上一次累计字节 + 时间戳
    private var prevNet: (rx: UInt64, tx: UInt64, t: Date)? = nil

    private let thermal = ThermalSensorReader()

    private init() {
        memTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000
    }

    func start() {
        guard !running else { return }
        running = true
        sample()   // 立刻先采一次，避免首帧全 0
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.running else { break }
                self.sample()
            }
        }
    }

    func stop() {
        running = false
        loopTask?.cancel()
        loopTask = nil
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleNetwork()
        cpuTempCelsius = thermal.read()
        sampleTick &+= 1
    }

    // MARK: 采样实现

    private func sampleCPU() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let user   = Double(info.cpu_ticks.0)   // CPU_STATE_USER
        let system = Double(info.cpu_ticks.1)   // CPU_STATE_SYSTEM
        let idle   = Double(info.cpu_ticks.2)   // CPU_STATE_IDLE
        let nice   = Double(info.cpu_ticks.3)   // CPU_STATE_NICE
        let used  = user + system + nice
        let total = used + idle
        if let p = prevCPU {
            let dUsed  = used - p.used
            let dTotal = total - p.total
            if dTotal > 0 { cpuUsage = max(0, min(1, dUsed / dTotal)) }
        }
        prevCPU = (used, total)
    }

    private func sampleMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let ps = Double(pageSize)
        // ≈ 活动监视器「已用内存」= 活动页 + 联动(wired) + 压缩页
        let usedBytes = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * ps
        memUsedGB = usedBytes / 1_000_000_000
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        memUsedFraction = totalBytes > 0 ? max(0, min(1, usedBytes / totalBytes)) : 0
    }

    private func sampleNetwork() {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return }
        defer { freeifaddrs(ifap) }
        var ptr = ifap
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            // 跳过回环 + 各类虚拟接口，只统计真实网卡（en0 / en1 等）
            if name.hasPrefix("lo") || name.hasPrefix("gif") || name.hasPrefix("stf")
                || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun")
                || name.hasPrefix("bridge") || name.hasPrefix("anpi") { continue }
            guard let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            rx += UInt64(data.pointee.ifi_ibytes)
            tx += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        if let p = prevNet {
            let dt = now.timeIntervalSince(p.t)
            if dt > 0 {
                // if_data 计数是 32 位会回绕；回绕时这一拍当 0，不显示负速度
                let dRx = rx >= p.rx ? Double(rx - p.rx) : 0
                let dTx = tx >= p.tx ? Double(tx - p.tx) : 0
                netDownBytesPerSec = dRx / dt
                netUpBytesPerSec = dTx / dt
            }
        }
        prevNet = (rx, tx, now)
    }

    // MARK: 格式化（UI 用）

    /// 网速：B/s → "12B" / "8K" / "1.2M"，控制在 4 字以内方便塞进右耳
    nonisolated static func formatRate(_ bytesPerSec: Double) -> String {
        let b = max(0, bytesPerSec)
        if b >= 1_000_000 { return String(format: "%.1fM", b / 1_000_000) }
        if b >= 1_000     { return String(format: "%.0fK", b / 1_000) }
        return String(format: "%.0fB", b)
    }
}
