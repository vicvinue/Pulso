import Foundation
import SwiftUI

struct Snapshot {
    static let historyLength = 60

    var cpu: Double = 0
    var cores: [Double] = []
    var cpuHistory = [Double](repeating: 0, count: historyLength)
    var gpu: Double?
    var gpuHistory = [Double](repeating: 0, count: historyLength)

    var memory = MemInfo()
    var memHistory = [Double](repeating: 0, count: historyLength)

    var diskTotal: Double = 0
    var diskFree: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0

    var netIn: Double = 0
    var netOut: Double = 0
    var netInHistory = [Double](repeating: 0, count: historyLength)
    var netOutHistory = [Double](repeating: 0, count: historyLength)
    var sessionIn: Double = 0
    var sessionOut: Double = 0
    var net = NetIdentity()
    var latency: Double?
    var latencyChecked = false
    var latencyFailures = 0

    var battery: BatteryInfo?
    var processes: [ProcEntry] = []
    var thermal: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = 0
    var load: [Double] = []
}

final class Monitor: ObservableObject {
    /// Lo que ve la interfaz. Solo se actualiza mientras el widget está a la vista.
    @Published private(set) var s = Snapshot()
    /// Se llama tras cada muestra (también en pausa), p. ej. para los avisos.
    var onSample: ((Snapshot) -> Void)?

    /// En pausa se muestrea cada 5 s sin redibujar; los avisos siguen funcionando.
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if !paused { publish(); refreshProcesses() }
        }
    }

    private let prefs: Prefs
    private var data = Snapshot()
    private let cpuSampler = CPUSampler()
    private let processSampler = ProcessSampler()
    private let latencyProbe = LatencyProbe()
    private let background = DispatchQueue(label: "pulso.sampler", qos: .utility)
    private var timer: Timer?
    private var tick = 0
    private var lastLatencyTick = Int.min / 2

    private var lastNet: (rx: UInt64, tx: UInt64)?
    private var lastDisk: (read: UInt64, write: UInt64)?
    private var lastTime = Date()

    init(prefs: Prefs) { self.prefs = prefs }

    func start() {
        _ = cpuSampler.sample()
        lastNet = readNetTotals()
        lastDisk = readDiskIOTotals()
        lastTime = Date()
        slowRefresh(force: true)

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Fuerza una nueva medición de latencia (p. ej. al cambiar el servidor).
    func latencySettingsChanged() {
        data.latency = nil
        data.latencyChecked = false
        data.latencyFailures = 0
        lastLatencyTick = Int.min / 2
        measureLatencyIfDue()
        publish()
    }

    private func publish() {
        if !paused { s = data }
    }

    private func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Snapshot.historyLength { array.removeFirst(array.count - Snapshot.historyLength) }
    }

    private func step() {
        tick += 1
        if paused && tick % 5 != 0 { return }

        var n = data
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTime), 0.001)
        lastTime = now

        let cpu = cpuSampler.sample()
        n.cpu = cpu.total
        n.cores = cpu.cores
        push(&n.cpuHistory, cpu.total)

        n.gpu = readGPU()
        push(&n.gpuHistory, n.gpu ?? 0)

        n.memory = readMemory()
        push(&n.memHistory, n.memory.total > 0 ? n.memory.used / n.memory.total : 0)

        let net = readNetTotals()
        if let last = lastNet {
            let rx = net.rx >= last.rx ? Double(net.rx - last.rx) : 0
            let tx = net.tx >= last.tx ? Double(net.tx - last.tx) : 0
            n.netIn = rx / dt
            n.netOut = tx / dt
            n.sessionIn += rx
            n.sessionOut += tx
        }
        lastNet = net
        push(&n.netInHistory, n.netIn)
        push(&n.netOutHistory, n.netOut)

        let disk = readDiskIOTotals()
        if let last = lastDisk {
            n.diskRead = disk.read >= last.read ? Double(disk.read - last.read) / dt : 0
            n.diskWrite = disk.write >= last.write ? Double(disk.write - last.write) / dt : 0
        }
        lastDisk = disk

        n.thermal = ProcessInfo.processInfo.thermalState
        n.uptime = readUptime()
        n.load = readLoadAverage()

        data = n
        publish()
        onSample?(data)
        slowRefresh(force: false)
    }

    private func refreshProcesses() {
        background.async { [weak self] in
            guard let self, let procs = self.processSampler.sample() else { return }
            DispatchQueue.main.async {
                self.data.processes = procs
                self.publish()
            }
        }
    }

    private func measureLatencyIfDue() {
        guard let host = prefs.latencyHost else { return }
        guard tick - lastLatencyTick >= prefs.latencyInterval else { return }
        lastLatencyTick = tick
        latencyProbe.measure(host: host) { [weak self] ms in
            guard let self, self.prefs.latencyHost == host else { return }
            self.data.latency = ms
            self.data.latencyChecked = true
            self.data.latencyFailures = ms == nil ? self.data.latencyFailures + 1 : 0
            self.publish()
        }
    }

    /// Métricas más costosas, en segundo plano y con menor frecuencia.
    private func slowRefresh(force: Bool) {
        let t = tick
        if !paused && (force || t % 3 == 0) {
            refreshProcesses()
        }
        if force || t % 10 == 0 {
            background.async { [weak self] in
                let battery = readBattery()
                let identity = readNetIdentity()
                DispatchQueue.main.async {
                    self?.data.battery = battery
                    self?.data.net = identity
                    self?.publish()
                }
            }
        }
        measureLatencyIfDue()
        if force || t % 30 == 0 {
            background.async { [weak self] in
                guard let disk = readDiskSpace() else { return }
                DispatchQueue.main.async {
                    self?.data.diskTotal = disk.total
                    self?.data.diskFree = disk.free
                    self?.publish()
                }
            }
        }
    }
}

// MARK: - Formato

enum Fmt {
    static func bytes(_ value: Double, binary: Bool = false) -> String {
        let base: Double = binary ? 1024 : 1000
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(value, 0)
        var i = 0
        while v >= base && i < units.count - 1 { v /= base; i += 1 }
        let decimals = (i == 0 || v >= 100) ? 0 : 1
        return String(format: "%.\(decimals)f", locale: Locale.current, v) + " " + units[i]
    }

    static func rate(_ value: Double) -> String { bytes(value) + "/s" }

    static func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds) / 60
        let d = total / 1440, h = (total % 1440) / 60, m = total % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
}
