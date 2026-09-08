import Darwin
import Foundation

/// Process CPU and memory. Live 1 Hz only while Resources is visible; persist at most once a minute.
nonisolated enum ProcessMetrics: Sendable {
    struct Raw: Sendable {
        var cpuTicks: UInt64
        var wallTicks: UInt64
        var residentBytes: UInt64
        var footprintBytes: UInt64
        var processorCount: Int
    }

    static func read() -> Raw? {
        guard let cpuTicks = cpuTicks(), let memory = memoryInfo() else { return nil }
        return Raw(
            cpuTicks: cpuTicks,
            wallTicks: mach_absolute_time(),
            residentBytes: memory.resident,
            footprintBytes: memory.footprint,
            processorCount: hostProcessorCount()
        )
    }

    static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        let base = timebase
        return ticks &* UInt64(base.numer) / UInt64(max(base.denom, 1))
    }

    static func cpuPercent(from previous: Raw, to current: Raw) -> Double {
        let deltaCPU = current.cpuTicks &- previous.cpuTicks
        let deltaWall = current.wallTicks &- previous.wallTicks
        guard deltaWall > 0 else { return 0 }
        return Double(deltaCPU) / Double(deltaWall) * 100
    }

    private static func cpuTicks() -> UInt64? {
        var info = task_absolutetime_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_absolutetime_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_ABSOLUTETIME_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.total_user &+ info.total_system
    }

    private static func memoryInfo() -> (resident: UInt64, footprint: UInt64)? {
        var info = task_vm_info_data_t()
        let fieldCount = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        var count = mach_msg_type_number_t(fieldCount)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: fieldCount) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt64(info.resident_size), UInt64(info.phys_footprint))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func hostProcessorCount() -> Int {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let status = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &infoArray,
            &infoCount
        )
        if status == KERN_SUCCESS, let infoArray {
            let bytes = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: infoArray)), bytes)
        }
        if status == KERN_SUCCESS, cpuCount > 0 {
            return Int(cpuCount)
        }
        return ProcessInfo.processInfo.processorCount
    }
}
