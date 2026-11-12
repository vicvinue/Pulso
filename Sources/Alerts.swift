import Foundation
import UserNotifications

/// Avisos del sistema con histéresis: cada tipo avisa una vez y se rearma cuando la condición se normaliza.
final class Alerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum Kind: String, CaseIterable {
        case memory, disk, battery, internet, thermal

        var menuTitle: String {
            switch self {
            case .memory: return "Presión de memoria crítica"
            case .disk: return "Disco con menos de 10 % libre"
            case .battery: return "Batería bajo 15 %"
            case .internet: return "Sin conexión a internet"
            case .thermal: return "Equipo muy caliente"
            }
        }
    }

    private let prefs: Prefs
    private var active: Set<Kind> = []
    /// Avisos vigentes, mostrados también dentro del widget (por si No molestar o el permiso los bloquean).
    @Published private(set) var current: [Kind: String] = [:]
    /// false si macOS no permite notificaciones a Pulso.
    @Published private(set) var notificationsAllowed = true
    private var evaluations = 0
    private var memoryCriticalSince: Date?

    init(prefs: Prefs) {
        self.prefs = prefs
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refreshPermission()
        }
    }

    func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { self?.notificationsAllowed = allowed }
        }
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "Pulso funciona"
        content.body = "Así se verán los avisos de memoria, disco, batería, internet y temperatura."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pulso.test", content: content, trigger: nil))
    }

    func evaluate(_ s: Snapshot) {
        evaluations += 1
        if evaluations % 60 == 0 { refreshPermission() }
        for kind in current.keys where !prefs.alertEnabled(kind.rawValue) { current[kind] = nil }
        // Memoria: crítica sostenida al menos 10 s.
        if s.memory.pressure >= 4 { memoryCriticalSince = memoryCriticalSince ?? Date() } else { memoryCriticalSince = nil }
        let memorySustained = memoryCriticalSince.map { Date().timeIntervalSince($0) >= 10 } ?? false
        check(.memory, on: memorySustained, off: s.memory.pressure < 2,
              title: "Memoria al límite",
              body: "La presión de memoria es crítica (\(Fmt.bytes(s.memory.used, binary: true)) en uso, swap \(Fmt.bytes(s.memory.swapUsed, binary: true))). Cierra apps que no estés usando.")

        // Disco.
        if s.diskTotal > 0 {
            let free = s.diskFree / s.diskTotal
            check(.disk, on: free < 0.10, off: free > 0.12,
                  title: "Poco espacio en disco",
                  body: "Quedan \(Fmt.bytes(s.diskFree)) libres (\(Fmt.pct(free))).")
        }

        // Batería.
        if let b = s.battery {
            check(.battery, on: !b.onAC && b.percent <= 0.15, off: b.onAC || b.percent > 0.20,
                  title: "Batería baja",
                  body: "Queda \(Fmt.pct(b.percent))" + (b.minutes.map { " (unos \(Fmt.minutes($0)))" } ?? "") + ". Conecta el cargador.")
        }

        // Internet: 3 mediciones fallidas seguidas estando conectado a una red.
        if prefs.latencyHost != nil {
            check(.internet, on: s.latencyFailures >= 3 && s.net.interface != nil, off: s.latencyFailures == 0,
                  title: "Sin conexión a internet",
                  body: "Estás conectado a \(s.net.kind), pero no hay respuesta de internet.",
                  recovered: "Conexión a internet restablecida")
        } else {
            active.remove(.internet)
            current[.internet] = nil
        }

        // Temperatura.
        check(.thermal, on: s.thermal == .serious || s.thermal == .critical,
              off: s.thermal == .nominal || s.thermal == .fair,
              title: "El equipo está muy caliente",
              body: "macOS está limitando el rendimiento para enfriarse. Revisa los procesos que más CPU consumen.")
    }

    private func check(_ kind: Kind, on: Bool, off: Bool, title: String, body: @autoclosure () -> String, recovered: String? = nil) {
        if active.contains(kind) {
            if off {
                active.remove(kind)
                current[kind] = nil
                if let recovered, prefs.alertEnabled(kind.rawValue) { send(kind, title: recovered, body: "") }
            }
        } else if on {
            active.insert(kind)
            if prefs.alertEnabled(kind.rawValue) { current[kind] = title }
            if prefs.alertEnabled(kind.rawValue) { send(kind, title: title, body: body()) }
        }
    }

    private func send(_ kind: Kind, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "pulso.\(kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
