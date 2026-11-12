import Foundation
import Darwin
import IOKit
import IOKit.ps
import Network
import CoreWLAN
import SystemConfiguration

// MARK: - Helpers

func sysctlValue<T: BitwiseCopyable>(_ name: String, _ fallback: T) -> T {
    var value = fallback
    var size = MemoryLayout<T>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : fallback
}

private func ioProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

private func forEachService(_ className: String, _ body: (io_object_t) -> Void) {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        body(service)
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
}

// MARK: - CPU

final class CPUSampler {
    private struct Ticks { var user, system, idle, nice: UInt32 }
    private var previous: [Ticks] = []

    /// Devuelve uso total (0–1) y uso por núcleo.
    func sample() -> (total: Double, cores: [Double]) {
        var cpuCount: natural_t = 0
        var infoPtr: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoPtr, &infoCount) == KERN_SUCCESS,
              let info = infoPtr else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var current: [Ticks] = []
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            current.append(Ticks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                                 system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                                 idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                                 nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }

        var cores: [Double] = []
        var usedAll: UInt64 = 0, totalAll: UInt64 = 0
        if previous.count == current.count {
            for (p, c) in zip(previous, current) {
                let used = UInt64(c.user &- p.user) + UInt64(c.system &- p.system) + UInt64(c.nice &- p.nice)
                let total = used + UInt64(c.idle &- p.idle)
                cores.append(total > 0 ? Double(used) / Double(total) : 0)
                usedAll += used
                totalAll += total
            }
        }
        previous = current
        return (totalAll > 0 ? Double(usedAll) / Double(totalAll) : 0, cores)
    }
}

// MARK: - GPU (Apple Silicon / IOAccelerator)

func readGPU() -> Double? {
    var best: Double?
    forEachService("IOAccelerator") { service in
        if let stats = ioProperty(service, "PerformanceStatistics") as? [String: Any],
           let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
            best = max(best ?? 0, util / 100)
        }
    }
    return best
}

// MARK: - Memoria

struct MemInfo {
    var total: Double = 0
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var swapUsed: Double = 0
    var swapTotal: Double = 0
    var pressure: Int = 1        // 1 normal, 2 advertencia, 4 crítica
    var used: Double { app + wired + compressed }
}

func readMemory() -> MemInfo {
    var info = MemInfo()
    info.total = Double(ProcessInfo.processInfo.physicalMemory)

    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    let page = Double(pageSize)

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        info.app = Double(Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page
        info.wired = Double(stats.wire_count) * page
        info.compressed = Double(stats.compressor_page_count) * page
        info.cached = Double(stats.external_page_count + stats.purgeable_count) * page
    }

    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
        info.swapUsed = Double(swap.xsu_used)
        info.swapTotal = Double(swap.xsu_total)
    }
    info.pressure = Int(sysctlValue("kern.memorystatus_vm_pressure_level", Int32(1)))
    return info
}

// MARK: - Almacenamiento

func readDiskSpace() -> (total: Double, free: Double)? {
    let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
          let total = v.volumeTotalCapacity else { return nil }
    let free = v.volumeAvailableCapacityForImportantUsage.map(Double.init) ?? Double(v.volumeAvailableCapacity ?? 0)
    return (Double(total), free)
}

/// Bytes leídos/escritos acumulados por todos los discos.
func readDiskIOTotals() -> (read: UInt64, write: UInt64) {
    var read: UInt64 = 0, write: UInt64 = 0
    forEachService("IOBlockStorageDriver") { service in
        if let stats = ioProperty(service, "Statistics") as? [String: Any] {
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
    }
    return (read, write)
}

// MARK: - Red

/// Bytes recibidos/enviados acumulados en interfaces físicas (en*), contadores de 64 bits.
func readNetTotals() -> (rx: UInt64, tx: UInt64) {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
    var buffer = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buffer, &len, nil, 0) == 0 else { return (0, 0) }

    var rx: UInt64 = 0, tx: UInt64 = 0
    buffer.withUnsafeBytes { raw in
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= len {
            let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            let msgLen = Int(header.ifm_msglen)
            if msgLen == 0 { break }
            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                if if_indextoname(UInt32(h2.ifm_index), &name) != nil,
                   String(cString: name).hasPrefix("en"),
                   (h2.ifm_flags & IFF_UP) != 0 {
                    rx &+= h2.ifm_data.ifi_ibytes
                    tx &+= h2.ifm_data.ifi_obytes
                }
            }
            offset += msgLen
        }
    }
    return (rx, tx)
}

struct NetIdentity {
    var interface: String?
    var kind: String = "Sin conexión"
    var ip: String?
    var rssi: Int?
}

func readNetIdentity() -> NetIdentity {
    var id = NetIdentity()
    guard let store = SCDynamicStoreCreate(nil, "Pulso" as CFString, nil, nil),
          let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
          let iface = global["PrimaryInterface"] as? String else { return id }
    id.interface = iface

    let wifi = CWWiFiClient.shared().interface()
    if iface == wifi?.interfaceName {
        id.kind = "Wi-Fi"
        if let r = wifi?.rssiValue(), r != 0 { id.rssi = r }
    } else if iface.hasPrefix("utun") || iface.hasPrefix("ipsec") {
        id.kind = "VPN"
    } else if iface.hasPrefix("en") {
        id.kind = "Ethernet"
    } else {
        id.kind = iface
    }

    var ifap: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifap) == 0, let first = ifap {
        defer { freeifaddrs(ifap) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == iface {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    id.ip = String(cString: host)
                    break
                }
            }
            ptr = ifa.ifa_next
        }
    }
    return id
}

/// Mide la latencia como tiempo de conexión TCP al puerto 443 del servidor indicado.
final class LatencyProbe {
    private let queue = DispatchQueue(label: "pulso.latency")

    func measure(host: String, _ completion: @escaping (Double?) -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        let conn = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp)
        var finished = false
        let finish: (Double?) -> Void = { value in
            guard !finished else { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async { completion(value) }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            case .failed, .waiting: finish(nil)
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }
}

// MARK: - Batería

struct BatteryInfo {
    var percent: Double = 0
    var charging = false
    var onAC = false
    var charged = false
    var minutes: Int?
    var watts: Double?
    var cycles: Int?
    var health: Double?
}

func readBattery() -> BatteryInfo? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

    for source in list {
        guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
        var b = BatteryInfo()
        let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap = max(d[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
        b.percent = Double(current) / Double(maxCap)
        b.charging = d[kIOPSIsChargingKey] as? Bool ?? false
        b.charged = d[kIOPSIsChargedKey] as? Bool ?? false
        b.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let t = (b.charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
        if t > 0 && (b.charging || !b.onAC) { b.minutes = t }

        let smart = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if smart != 0 {
            defer { IOObjectRelease(smart) }
            if let telemetry = ioProperty(smart, "PowerTelemetryData") as? [String: Any],
               let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
                b.watts = load / 1000
            } else if let amp = ioProperty(smart, "Amperage") as? NSNumber,
                      let volt = ioProperty(smart, "Voltage") as? NSNumber {
                let a = Double(Int64(truncatingIfNeeded: amp.uint64Value))
                let w = abs(a * volt.doubleValue) / 1_000_000
                if w > 0.1 { b.watts = w }
            }
            b.cycles = (ioProperty(smart, "CycleCount") as? NSNumber)?.intValue
            if let data = ioProperty(smart, "BatteryData") as? [String: Any],
               let nominal = (data["NominalChargeCapacity"] as? NSNumber)?.doubleValue,
               let design = (data["DesignCapacity"] as? NSNumber)?.doubleValue, design > 0 {
                b.health = min(nominal / design, 1)
            }
        }
        return b
    }
    return nil
}

// MARK: - Procesos

struct ProcEntry: Identifiable {
    let id: Int
    let name: String
    let cpu: Double      // % de un núcleo, instantáneo
    let memory: Double   // bytes (huella física si se puede leer, si no RSS)
}

/// Huella de memoria como la muestra el Monitor de Actividad (solo procesos del propio usuario).
private func physFootprint(_ pid: pid_t) -> Double? {
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return r == 0 ? Double(info.ri_phys_footprint) : nil
}

/// Convierte el TIME de ps ("[[dd-]hh:]mm:ss.cc") a segundos.
private func parseCPUTime(_ text: Substring) -> Double? {
    var days = 0.0
    var rest = text
    if let dash = rest.firstIndex(of: "-") {
        days = Double(rest[..<dash]) ?? 0
        rest = rest[rest.index(after: dash)...]
    }
    var seconds = 0.0
    for part in rest.split(separator: ":") {
        guard let v = Double(part.replacingOccurrences(of: ",", with: ".")) else { return nil }
        seconds = seconds * 60 + v
    }
    return days * 86_400 + seconds
}

/// Usa /bin/ps (setuid root, ve todos los procesos) y calcula el % de CPU instantáneo
/// como la diferencia de tiempo de CPU acumulado entre dos muestras.
final class ProcessSampler {
    private var previous: [pid_t: Double] = [:]
    private var previousTime: TimeInterval?

    /// Devuelve nil en la primera muestra o tras una pausa larga (aún no hay diferencia válida).
    func sample(limit: Int = 4) -> [ProcEntry]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid=,time=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let now = ProcessInfo.processInfo.systemUptime
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var current: [pid_t: Double] = [:]
        var rows: [(pid: pid_t, cpu: Double, rss: Double, name: String)] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = pid_t(parts[0]), let cpuTime = parseCPUTime(parts[1]),
                  let rss = Double(parts[2]) else { continue }
            current[pid] = cpuTime
            rows.append((pid, cpuTime, rss, String(parts[3])))
        }

        defer { previous = current; previousTime = now }
        guard let last = previousTime, now - last > 0.5, now - last < 15 else { return nil }
        let dt = now - last

        let ranked = rows.compactMap { row -> (pid_t, Double, Double, String)? in
            guard row.name != "ps", let before = previous[row.pid] else { return nil }
            return (row.pid, max(0, (row.cpu - before) / dt * 100), row.rss, row.name)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)

        return ranked.enumerated().map { i, r in
            ProcEntry(id: i, name: r.3, cpu: r.1, memory: physFootprint(r.0) ?? r.2 * 1024)
        }
    }
}

// MARK: - Sistema

func readUptime() -> TimeInterval {
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
    return Date().timeIntervalSince1970 - Double(boot.tv_sec)
}

func readLoadAverage() -> [Double] {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) == 3 ? loads : []
}
