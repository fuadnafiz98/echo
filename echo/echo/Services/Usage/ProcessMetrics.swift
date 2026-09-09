import Darwin
import Foundation

/// This-process CPU and memory from `task_info` / `host_statistics`.
///
/// **CPU (this process):** `TASK_ABSOLUTETIME_INFO` user+system over `mach_absolute_time`.
/// 100% means Echo fully used one logical CPU for the sample window. Multi-core work can exceed 100%.
///
/// **CPU (this Mac):** `HOST_CPU_LOAD_INFO` busy ticks over all cores. 100% means every logical CPU was busy.
///
/// **Memory:** `phys_footprint` is Activity Monitor’s Memory column. RSS is `resident_size`.
/// ANE / Core ML often sits in `ledger_tag_neural_nofootprint` (reclaimable) and is **not** in footprint.
nonisolated enum ProcessMetrics: Sendable {
    struct Raw: Sendable {
        var cpuTicks: UInt64
        var wallTicks: UInt64
        var residentBytes: UInt64
        var footprintBytes: UInt64
        var neuralInFootprintBytes: UInt64
        var neuralReclaimableBytes: UInt64
        var host: HostTicks?
    }

    struct HostTicks: Sendable, Equatable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    struct MemoryBreakdown: Sendable, Equatable {
        var footprintBytes: UInt64
        var residentBytes: UInt64
        var neuralInFootprintBytes: UInt64
        var neuralReclaimableBytes: UInt64

        /// Headline Memory — same quantity Activity Monitor labels Memory.
        var memoryHeadlineBytes: UInt64 { footprintBytes }
    }

    static func read() -> Raw? {
        guard let cpuTicks = cpuTicks(), let memory = memoryInfo() else { return nil }
        return Raw(
            cpuTicks: cpuTicks,
            wallTicks: mach_absolute_time(),
            residentBytes: memory.residentBytes,
            footprintBytes: memory.footprintBytes,
            neuralInFootprintBytes: memory.neuralInFootprintBytes,
            neuralReclaimableBytes: memory.neuralReclaimableBytes,
            host: hostTicks()
        )
    }

    static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        let base = timebase
        return ticks &* UInt64(base.numer) / UInt64(max(base.denom, 1))
    }

    /// This process, percent of one logical CPU. Needs two samples.
    static func cpuPercent(from previous: Raw, to current: Raw) -> Double? {
        let deltaCPU = current.cpuTicks &- previous.cpuTicks
        let deltaWall = current.wallTicks &- previous.wallTicks
        guard deltaWall > 0 else { return nil }
        return Double(deltaCPU) / Double(deltaWall) * 100
    }

    /// This Mac, 0…100 across all logical CPUs. Needs two samples.
    static func systemCPUPercent(from previous: HostTicks, to current: HostTicks) -> Double? {
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let idle = UInt64(current.idle &- previous.idle)
        let nice = UInt64(current.nice &- previous.nice)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }

    static func memoryBreakdown(from raw: Raw) -> MemoryBreakdown {
        MemoryBreakdown(
            footprintBytes: raw.footprintBytes,
            residentBytes: raw.residentBytes,
            neuralInFootprintBytes: raw.neuralInFootprintBytes,
            neuralReclaimableBytes: raw.neuralReclaimableBytes
        )
    }

    static func reclaimableNeuralBytes(nofootprint: Int64, compressed: Int64) -> UInt64 {
        UInt64(clamping: max(nofootprint, 0) + max(compressed, 0))
    }

    static func inFootprintNeuralBytes(footprint: Int64, compressed: Int64) -> UInt64 {
        UInt64(clamping: max(footprint, 0) + max(compressed, 0))
    }

    private static func cpuTicks() -> UInt64? {
        var info = task_absolutetime_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_absolutetime_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_ABSOLUTETIME_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.total_user &+ info.total_system
    }

    private static func memoryInfo() -> MemoryBreakdown? {
        var info = task_vm_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryBreakdown(
            footprintBytes: UInt64(info.phys_footprint),
            residentBytes: UInt64(info.resident_size),
            neuralInFootprintBytes: inFootprintNeuralBytes(
                footprint: info.ledger_tag_neural_footprint,
                compressed: info.ledger_tag_neural_footprint_compressed
            ),
            neuralReclaimableBytes: reclaimableNeuralBytes(
                nofootprint: info.ledger_tag_neural_nofootprint,
                compressed: info.ledger_tag_neural_nofootprint_compressed
            )
        )
    }

    private static func hostTicks() -> HostTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return HostTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}
