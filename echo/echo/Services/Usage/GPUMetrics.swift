import Darwin
import Foundation
import IOKit

/// GPU utilization. Prefer this-process AGX/Metal time; otherwise system GPU, labeled as such.
/// Never invent 0 when a sample is missing.
nonisolated enum GPUMetrics: Sendable {
    enum Source: String, Sendable, Equatable, Codable {
        case process
        case system
    }

    struct Raw: Sendable, Equatable {
        /// Cumulative Metal/AGX GPU time for this PID, nanoseconds. `nil` if no client exists.
        var processGPUTimeNS: UInt64?
        /// IOAccelerator / AGX `Device Utilization %`. `nil` if the registry has no figure.
        var systemPercent: Double?
    }

    struct Reading: Sendable, Equatable {
        var percent: Double
        var source: Source
    }

    static func readRaw() -> Raw {
        var processNS: UInt64 = 0
        var foundProcessClient = false
        var systemPercent: Double?

        for className in ["AGXAccelerator", "IOGPU", "IOAccelerator"] {
            enumerateServices(named: className) { service in
                if systemPercent == nil {
                    systemPercent = utilization(fromRegistry: service)
                }
                walkChildren(of: service, depth: 3) { child in
                    guard creatorPID(fromRegistry: child) == getpid() else { return }
                    if let ns = appUsageGPUTimeNS(fromRegistry: child) {
                        processNS &+= ns
                        foundProcessClient = true
                    }
                }
            }
        }

        return Raw(
            processGPUTimeNS: foundProcessClient ? processNS : nil,
            systemPercent: systemPercent
        )
    }

    static func processPercent(from previousNS: UInt64, to currentNS: UInt64, elapsedNS: UInt64) -> Double? {
        guard elapsedNS > 0, currentNS >= previousNS else { return nil }
        return Double(currentNS &- previousNS) / Double(elapsedNS) * 100
    }

    /// Parses IOKit `PerformanceStatistics`. Missing keys stay `nil` — not 0.
    static func utilization(fromPerformanceStatistics stats: [String: Any]) -> Double? {
        let keys = ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"]
        for key in keys {
            if let value = double(from: stats[key]) {
                return min(max(value, 0), 100)
            }
        }
        return nil
    }

    static func parseCreatorPID(_ raw: String) -> pid_t? {
        guard let mark = raw.range(of: "pid ") else { return nil }
        let digits = raw[mark.upperBound...].prefix(while: \.isNumber)
        guard !digits.isEmpty, let value = Int32(digits) else { return nil }
        return pid_t(value)
    }

    static func appUsageGPUTimeNS(fromAppUsage usage: [[String: Any]]) -> UInt64? {
        var total: UInt64 = 0
        var found = false
        for entry in usage {
            guard let value = entry["accumulatedGPUTime"] else { continue }
            if let ns = uint64(from: value) {
                total &+= ns
                found = true
            }
        }
        return found ? total : nil
    }

    // MARK: - IOKit

    private static func enumerateServices(named className: String, body: (io_service_t) -> Void) {
        let matching = IOServiceMatching(className)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private static func walkChildren(
        of service: io_registry_entry_t,
        depth: Int,
        body: (io_registry_entry_t) -> Void
    ) {
        guard depth > 0 else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != 0 {
            body(child)
            walkChildren(of: child, depth: depth - 1, body: body)
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
    }

    private static func utilization(fromRegistry service: io_registry_entry_t) -> Double? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any],
              let stats = dict["PerformanceStatistics"] as? [String: Any]
        else { return nil }
        return utilization(fromPerformanceStatistics: stats)
    }

    private static func creatorPID(fromRegistry service: io_registry_entry_t) -> pid_t? {
        guard let raw = stringProperty("IOUserClientCreator", service: service) else { return nil }
        return parseCreatorPID(raw)
    }

    private static func appUsageGPUTimeNS(fromRegistry service: io_registry_entry_t) -> UInt64? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "AppUsage" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let value = property.takeRetainedValue()
        guard let array = value as? [[String: Any]] else { return nil }
        return appUsageGPUTimeNS(fromAppUsage: array)
    }

    private static func stringProperty(_ key: String, service: io_registry_entry_t) -> String? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return property.takeRetainedValue() as? String
    }

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let number as Double: number
        case let number as Float: Double(number)
        case let number as Int: Double(number)
        case let number as Int64: Double(number)
        case let number as UInt64: Double(number)
        case let number as NSNumber: number.doubleValue
        default: nil
        }
    }

    private static func uint64(from value: Any) -> UInt64? {
        switch value {
        case let number as UInt64: number
        case let number as Int64: UInt64(clamping: number)
        case let number as Int: UInt64(clamping: number)
        case let number as Double: UInt64(number)
        case let number as NSNumber: number.uint64Value
        default: nil
        }
    }
}
