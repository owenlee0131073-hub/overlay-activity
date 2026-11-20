import Darwin
import Foundation
import IOKit

final class SystemMetrics {
    private let host = mach_host_self()
    private var previousCPU: host_cpu_load_info_data_t?

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func resetCPU() {
        previousCPU = nil
    }

    func cpuPercent() -> Int? {
        var current = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: current) / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &current) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let previous = previousCPU
        previousCPU = current
        guard let previous else { return nil }

        // The kernel's cumulative tick counters can wrap independently.
        let user = UInt64(current.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = UInt64(current.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = UInt64(current.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = UInt64(current.cpu_ticks.3 &- previous.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return Int((100 * Double(busy) / Double(total)).rounded())
    }

    func gpuPercent() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        // Drivers expose different keys. Prefer whole-device counters over individual engines.
        let keys = ["Device Utilization %", "GPU Activity(%)", "GPU Utilization %"]
        var busiestGPU: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            let readings = keys.lazy.compactMap { (stats[$0] as? NSNumber)?.doubleValue }
            guard let utilization = readings.first(where: { $0.isFinite && (0...100).contains($0) }) else { continue }
            busiestGPU = max(busiestGPU ?? utilization, utilization)
        }
        return busiestGPU.map { Int($0.rounded()) }
    }

    func ramPercent() -> Int? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS, physicalMemory > 0 else {
            return nil
        }

        // Internal pages exclude file cache. Purgeable pages can be reclaimed on demand.
        let appPages = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count))
        let usedPages = appPages + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        let used = Double(usedPages) * Double(pageSize) / Double(physicalMemory)
        return Int((min(used, 1) * 100).rounded())
    }
}
