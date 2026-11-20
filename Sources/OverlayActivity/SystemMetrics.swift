import Darwin
import Foundation
import IOKit

final class SystemMetrics {
    private let host = mach_host_self()
    private let gpuStatisticsProperty = "PerformanceStatistics" as CFString
    // Prefer whole-device counters over individual GPU engines.
    private let gpuUtilizationKeys: [NSString] = ["Device Utilization %", "GPU Activity(%)", "GPU Utilization %"]
    private var previousCPU: host_cpu_load_info_data_t?
    private var accelerators: [io_service_t] = []
    private var nextGPUDiscovery: TimeInterval = 0
    private lazy var ramPageFraction: Double? = {
        var pageSize: vm_size_t = 0
        let capacity = ProcessInfo.processInfo.physicalMemory
        guard capacity > 0, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return Double(pageSize) / Double(capacity)
    }()

    deinit {
        releaseAccelerators()
        mach_port_deallocate(mach_task_self_, host)
    }

    func resetSampling() {
        previousCPU = nil
        releaseAccelerators()
        invalidateGPUDiscovery()
    }

    func invalidateGPUDiscovery() {
        nextGPUDiscovery = 0
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

    func gpuPercent(at uptime: TimeInterval) -> Int? {
        if uptime >= nextGPUDiscovery {
            // Recheck occasionally for a GPU change that didn't affect screen parameters.
            nextGPUDiscovery = uptime + 30
            discoverAccelerators()
        }

        var busiestGPU: Double?
        for service in accelerators {
            guard let stats = IORegistryEntryCreateCFProperty(
                service, gpuStatisticsProperty, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSDictionary else { continue }

            for key in gpuUtilizationKeys {
                guard let utilization = (stats[key] as? NSNumber)?.doubleValue,
                      (0...100).contains(utilization) else { continue }
                busiestGPU = max(busiestGPU ?? utilization, utilization)
                break
            }
        }
        return busiestGPU.map { Int($0.rounded()) }
    }

    private func discoverAccelerators() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        releaseAccelerators()
        while case let service = IOIteratorNext(iterator), service != 0 {
            accelerators.append(service)
        }
    }

    private func releaseAccelerators() {
        for service in accelerators {
            IOObjectRelease(service)
        }
        accelerators.removeAll()
    }

    func ramPercent() -> Int? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, let ramPageFraction else { return nil }

        // Internal pages exclude file cache. Purgeable pages can be reclaimed on demand.
        let appPages = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count))
        let usedPages = appPages + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        let used = Double(usedPages) * ramPageFraction
        return Int((min(used, 1) * 100).rounded())
    }
}
