import SwiftUI

// MARK: - Colores

func loadColor(_ v: Double) -> Color {
    switch v {
    case ..<0.6: return .green
    case ..<0.85: return .orange
    default: return .red
    }
}

// MARK: - Componentes

struct Segment {
    let fraction: Double
    let color: Color
}

struct SegmentedBar: View {
    let segments: [Segment]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                HStack(spacing: 0) {
                    ForEach(segments.indices, id: \.self) { i in
                        let seg = segments[i]
                        Rectangle().fill(seg.color)
                            .frame(width: max(0, g.size.width * min(seg.fraction, 1)))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }
}

struct Sparkline: View {
    let series: [(values: [Double], color: Color)]
    var maxValue: Double? = nil
    var floor: Double = 0

    var body: some View {
        GeometryReader { g in
            let all = series.flatMap(\.values)
            let top = max(maxValue ?? (all.max() ?? 1), floor, 0.0001)
            ZStack {
                ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                    let pts = points(s.values, size: g.size, top: top)
                    Path { p in
                        guard let first = pts.first, let last = pts.last else { return }
                        p.move(to: CGPoint(x: first.x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [s.color.opacity(0.35), s.color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(pts) }
                        .stroke(s.color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
            }
        }
    }

    private func points(_ values: [Double], size: CGSize, top: Double) -> [CGPoint] {
        let n = max(values.count - 1, 1)
        return values.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(n),
                    y: size.height * (1 - CGFloat(min(v / top, 1))))
        }
    }
}

struct CoreBars: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, v in
                GeometryReader { g in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(loadColor(v))
                            .frame(height: max(1.5, g.size.height * v))
                    }
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.10)))
                }
            }
        }
        .frame(height: 16)
    }
}

struct SectionHeader: View {
    let icon: String
    let title: String
    let value: String
    var valueColor: Color = .primary
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()   // el título nunca se parte; si falta espacio, se encoge el valor
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
        }
    }
}

struct Detail: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
        }
    }
}

// MARK: - Widget

struct WidgetView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var prefs: Prefs
    @ObservedObject var alerts: Alerts

    private var s: Snapshot { monitor.s }
    private var compact: Bool { prefs.compact }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 11) {
            header
            if !alerts.current.isEmpty { alertBanner }
            cpuSection
            memorySection
            diskSection
            networkSection
            if let b = s.battery { batterySection(b) }
            if !compact && !s.processes.isEmpty { processSection }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280)   // mismo ancho en ambos modos; el compacto solo reduce la altura
        .fixedSize(horizontal: false, vertical: true)
    }

    // Encabezado

    private var thermalInfo: (String, Color) {
        switch s.thermal {
        case .nominal: return ("Normal", .green)
        case .fair: return ("Templado", .yellow)
        case .serious: return ("Caliente", .orange)
        case .critical: return ("Crítico", .red)
        @unknown default: return ("—", .secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("PULSO")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1.5)
            Spacer()
            if prefs.clickThrough {
                Image(systemName: "cursorarrow.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Ignorando clics (⌃⌥C para desactivar)")
            }
            if !compact {
                Text("activo \(Fmt.duration(s.uptime))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                Circle().fill(thermalInfo.1).frame(width: 6, height: 6)
                Text(thermalInfo.0)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .help("Estado térmico del sistema")
        }
    }

    // Avisos activos (visibles aunque No molestar o el permiso bloqueen las notificaciones)

    private var alertBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Alerts.Kind.allCases.filter { alerts.current[$0] != nil }, id: \.self) { kind in
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(alerts.current[kind] ?? "")
                        .lineLimit(1)
                }
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(0.85)))
    }

    // CPU / GPU

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(icon: "cpu", title: "CPU", value: Fmt.pct(s.cpu), valueColor: loadColor(s.cpu),
                          trailing: s.gpu.map { "GPU \(Fmt.pct($0))" })
            if !compact {
                Sparkline(series: [(s.cpuHistory, .accentColor), (s.gpuHistory, .purple.opacity(0.8))], maxValue: 1)
                    .frame(height: 30)
                CoreBars(cores: s.cores)
                HStack(spacing: 10) {
                    LegendDot(color: .accentColor, label: "CPU")
                    LegendDot(color: .purple, label: "GPU")
                    Spacer()
                    if s.load.count == 3 {
                        Text(String(format: "carga %.2f · %.2f · %.2f", locale: Locale.current, s.load[0], s.load[1], s.load[2]))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    // Memoria

    private var pressureInfo: (String, Color) {
        switch s.memory.pressure {
        case 4: return ("crítica", .red)
        case 2: return ("alta", .orange)
        default: return ("normal", .green)
        }
    }

    private var memorySection: some View {
        let m = s.memory
        let total = max(m.total, 1)
        return VStack(alignment: .leading, spacing: 5) {
            SectionHeader(icon: "memorychip", title: "MEMORIA",
                          value: compact ? Fmt.bytes(m.used, binary: true)
                                             : "\(Fmt.bytes(m.used, binary: true)) / \(Fmt.bytes(m.total, binary: true))",
                          valueColor: pressureInfo.1 == .green ? .primary : pressureInfo.1)
            SegmentedBar(segments: [
                Segment(fraction: m.app / total, color: .blue),
                Segment(fraction: m.wired / total, color: .orange),
                Segment(fraction: m.compressed / total, color: .pink),
            ])
            if !compact {
                HStack(spacing: 8) {
                    LegendDot(color: .blue, label: "Apps")
                    LegendDot(color: .orange, label: "Kernel")
                    LegendDot(color: .pink, label: "Compr.")
                    Spacer()
                    HStack(spacing: 3) {
                        Circle().fill(pressureInfo.1).frame(width: 5, height: 5)
                        Text("presión \(pressureInfo.0)")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                Detail(text: "Caché \(Fmt.bytes(m.cached, binary: true)) · Swap \(Fmt.bytes(m.swapUsed, binary: true))"
                       + (m.swapTotal > 0 ? " de \(Fmt.bytes(m.swapTotal, binary: true))" : ""))
            }
        }
    }

    // Disco

    private var diskSection: some View {
        let used = max(s.diskTotal - s.diskFree, 0)
        let frac = s.diskTotal > 0 ? used / s.diskTotal : 0
        return VStack(alignment: .leading, spacing: 5) {
            SectionHeader(icon: "internaldrive", title: "DISCO",
                          value: "\(Fmt.bytes(s.diskFree)) libres",
                          valueColor: frac > 0.9 ? .red : (frac > 0.8 ? .orange : .primary))
            SegmentedBar(segments: [Segment(fraction: frac, color: loadColor(frac))])
            if !compact {
                HStack {
                    Detail(text: "\(Fmt.pct(frac)) de \(Fmt.bytes(s.diskTotal)) usado")
                    Spacer()
                    Detail(text: "L \(Fmt.rate(s.diskRead)) · E \(Fmt.rate(s.diskWrite))")
                }
            }
        }
    }

    // Red

    private var latencyColor: Color {
        guard let l = s.latency else { return .red }
        return l < 60 ? .green : (l < 150 ? .orange : .red)
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(icon: "network", title: "RED",
                          value: "↓ \(Fmt.rate(s.netIn))  ↑ \(Fmt.rate(s.netOut))")
            if !compact {
                Sparkline(series: [(s.netInHistory, .teal), (s.netOutHistory, .orange)], floor: 50_000)
                    .frame(height: 26)
                HStack(spacing: 6) {
                    Detail(text: s.net.kind
                           + (s.net.rssi.map { " \($0) dBm" } ?? "")
                           + (s.net.ip.map { " · \($0)" } ?? ""))
                    Spacer(minLength: 2)
                    if let host = prefs.latencyHost {
                        HStack(spacing: 3) {
                            Circle().fill(s.latencyChecked ? latencyColor : Color.secondary).frame(width: 5, height: 5)
                            Text(!s.latencyChecked ? "midiendo…" : s.latency.map { "\(Int($0.rounded())) ms" } ?? "sin internet")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Latencia: tiempo de conexión a \(host)")
                    }
                }
                Detail(text: "Sesión: ↓ \(Fmt.bytes(s.sessionIn))  ↑ \(Fmt.bytes(s.sessionOut))")
            }
        }
    }

    // Batería

    private func batterySection(_ b: BatteryInfo) -> some View {
        let icon: String = {
            if b.charging { return "battery.100percent.bolt" }
            switch b.percent {
            case ..<0.15: return "battery.0percent"
            case ..<0.4: return "battery.25percent"
            case ..<0.65: return "battery.50percent"
            case ..<0.9: return "battery.75percent"
            default: return "battery.100percent"
            }
        }()
        let state: String = {
            if b.charging { return b.minutes.map { "cargando · llena en \(Fmt.minutes($0))" } ?? "cargando" }
            if b.onAC { return b.charged ? "cargada · conectada" : "conectada" }
            return b.minutes.map { "quedan \(Fmt.minutes($0))" } ?? "calculando…"
        }()
        let color: Color = b.percent < 0.2 && !b.onAC ? .red : (b.percent < 0.4 ? .orange : .green)
        return VStack(alignment: .leading, spacing: 5) {
            SectionHeader(icon: icon, title: "BATERÍA", value: Fmt.pct(b.percent),
                          valueColor: b.percent < 0.2 && !b.onAC ? .red : .primary,
                          trailing: b.watts.map { String(format: "%.1f W", locale: Locale.current, $0) })
            SegmentedBar(segments: [Segment(fraction: b.percent, color: color)])
            if !compact {
                HStack {
                    Detail(text: state)
                    Spacer()
                    Detail(text: [b.health.map { "salud \(Fmt.pct($0))" }, b.cycles.map { "\($0) ciclos" }]
                        .compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
    }

    // Procesos

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(icon: "list.bullet.rectangle", title: "PROCESOS", value: "")
            ForEach(s.processes) { p in
                HStack(spacing: 6) {
                    Text(p.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Fmt.bytes(p.memory, binary: true))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                    Text(String(format: "%.0f%%", p.cpu))
                        .foregroundStyle(loadColor(p.cpu / 100))
                        .frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 10.5))
                .monospacedDigit()
            }
        }
    }
}
