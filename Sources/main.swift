import Cocoa
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

// MARK: - Preferencias

final class Prefs: ObservableObject {
    private let d = UserDefaults.standard

    @Published var compact: Bool { didSet { d.set(compact, forKey: "compact") } }
    @Published var opacity: Double { didSet { d.set(opacity, forKey: "opacity") } }
    @Published var onDesktop: Bool { didSet { d.set(onDesktop, forKey: "onDesktop") } }
    @Published var clickThrough: Bool { didSet { d.set(clickThrough, forKey: "clickThrough") } }
    @Published var theme: Int { didSet { d.set(theme, forKey: "theme") } }   // 0 oscuro, 1 claro, 2 sistema
    @Published var visible: Bool { didSet { d.set(visible, forKey: "visible") } }
    /// nil = medición de latencia desactivada.
    @Published var latencyHost: String? { didSet { d.set(latencyHost ?? "", forKey: "latencyHost") } }
    /// Segundos entre mediciones de latencia.
    @Published var latencyInterval: Int { didSet { d.set(latencyInterval, forKey: "latencyInterval") } }
    @Published var alertsOff: [String] { didSet { d.set(alertsOff, forKey: "alertsOff") } }

    init() {
        d.register(defaults: ["opacity": 0.92, "theme": 0, "visible": true,
                              "latencyHost": "1.1.1.1", "latencyInterval": 10])
        compact = d.bool(forKey: "compact")
        opacity = d.double(forKey: "opacity")
        onDesktop = d.bool(forKey: "onDesktop")
        clickThrough = d.bool(forKey: "clickThrough")
        theme = d.integer(forKey: "theme")
        visible = d.bool(forKey: "visible")
        let host = d.string(forKey: "latencyHost") ?? ""
        latencyHost = host.isEmpty ? nil : host
        latencyInterval = max(d.integer(forKey: "latencyInterval"), 5)
        alertsOff = d.stringArray(forKey: "alertsOff") ?? []
    }

    func alertEnabled(_ kind: String) -> Bool { !alertsOff.contains(kind) }
}

// MARK: - Vista arrastrable

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        window?.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Prefs()
    private lazy var monitor = Monitor(prefs: prefs)
    private lazy var alerts = Alerts(prefs: prefs)
    private var panel: NSPanel!
    private var effect: NSVisualEffectView!
    private var statusItem: NSStatusItem!
    private var topLeft: NSPoint?
    private var restoring = false

    private static let latencyHosts: [(String, String)] = [
        ("Cloudflare (1.1.1.1)", "1.1.1.1"),
        ("Google (8.8.8.8)", "8.8.8.8"),
        ("Quad9 (9.9.9.9)", "9.9.9.9"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildStatusItem()
        applyPrefs()
        registerHotKeys()
        monitor.onSample = { [weak self] snapshot in self?.alerts.evaluate(snapshot) }
        monitor.start()
        alerts.requestAuthorization()
        if CommandLine.arguments.contains("--test-alert") { alerts.sendTest() }   // diagnóstico: open Pulso.app --args --test-alert
        if prefs.visible { panel.orderFrontRegardless() }
        updatePaused()
    }

    // Atajos globales: ⌃⌥P mostrar/ocultar · ⌃⌥C ignorar clics

    private func registerHotKeys() {
        let mods = controlKey | optionKey
        HotKeys.register(keyCode: kVK_ANSI_P, modifiers: mods) { [weak self] in self?.toggleVisible() }
        HotKeys.register(keyCode: kVK_ANSI_C, modifiers: mods) { [weak self] in
            guard let self else { return }
            self.toggleClickThrough()
            if !self.panel.isVisible { self.toggleVisible() }
        }
    }

    // Panel flotante

    private func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 16)

        let hosting = DraggableHostingView(rootView: WidgetView(monitor: monitor, prefs: prefs, alerts: alerts))
        hosting.onDoubleClick = { [weak self] in self?.prefs.compact.toggle() }
        hosting.menu = makeMenu()
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        let d = UserDefaults.standard
        if d.object(forKey: "originX") != nil {
            topLeft = NSPoint(x: d.double(forKey: "originX"), y: d.double(forKey: "originY"))
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            topLeft = NSPoint(x: vf.maxX - 300, y: vf.maxY - 16)
        }
        panel.layoutIfNeeded()
        restorePosition()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            self?.restorePosition()
        }
        nc.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, !self.restoring else { return }
            let f = self.panel.frame
            self.topLeft = NSPoint(x: f.minX, y: f.maxY)
            UserDefaults.standard.set(f.minX, forKey: "originX")
            UserDefaults.standard.set(f.maxY, forKey: "originY")
        }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restorePosition()
        }
        // Pausa el redibujo cuando el widget no se ve (oculto, tapado, pantalla apagada o bloqueada).
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            self?.updatePaused()
        }
    }

    private func updatePaused() {
        monitor.paused = !panel.isVisible || !panel.occlusionState.contains(.visible)
    }

    /// Mantiene fija la esquina superior izquierda aunque cambie la altura, y dentro de la pantalla.
    private func restorePosition() {
        guard var p = topLeft else { return }
        let size = panel.frame.size
        let onScreen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: p.x + 20, y: p.y - 10)) }
        if let vf = (onScreen ?? NSScreen.main)?.visibleFrame {
            p.x = min(max(p.x, vf.minX), vf.maxX - size.width)
            p.y = min(max(p.y, vf.minY + size.height), vf.maxY)
        }
        restoring = true
        panel.setFrameTopLeftPoint(p)
        restoring = false
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func applyPrefs() {
        panel.alphaValue = prefs.opacity
        panel.ignoresMouseEvents = prefs.clickThrough
        panel.level = prefs.onDesktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
        switch prefs.theme {
        case 0: panel.appearance = NSAppearance(named: .vibrantDark)
        case 1: panel.appearance = NSAppearance(named: .vibrantLight)
        default: panel.appearance = nil
        }
        updateStatusIcon()
    }

    // Barra de menús

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = makeMenu()
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let name = prefs.clickThrough ? "cursorarrow.slash" : "gauge.with.dots.needle.67percent"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Pulso")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = prefs.clickThrough
            ? "Pulso — ignorando clics (⌃⌥C para desactivar)"
            : "Pulso — monitor del sistema"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        alerts.refreshPermission()
        populate(menu)
    }

    private func item(_ title: String, _ action: Selector, tag: Int = 0, on: Bool = false,
                      key: String = "", mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        i.tag = tag
        i.state = on ? .on : .off
        return i
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        items.forEach(sub.addItem)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(panel.isVisible ? "Ocultar widget" : "Mostrar widget", #selector(toggleVisible),
                          key: "p", mods: [.control, .option]))
        menu.addItem(item("Ignorar clics (atravesable)", #selector(toggleClickThrough), on: prefs.clickThrough,
                          key: "c", mods: [.control, .option]))
        menu.addItem(item("Modo compacto", #selector(toggleCompact), on: prefs.compact))
        menu.addItem(.separator())

        menu.addItem(submenu("Opacidad", [100, 90, 80, 70, 60, 50, 40, 30].map {
            item("\($0) %", #selector(setOpacity(_:)), tag: $0, on: abs(prefs.opacity * 100 - Double($0)) < 3)
        }))
        menu.addItem(submenu("Posición", [
            item("Siempre encima", #selector(setLevel(_:)), tag: 0, on: !prefs.onDesktop),
            item("En el escritorio (detrás de ventanas)", #selector(setLevel(_:)), tag: 1, on: prefs.onDesktop),
            .separator(),
            item("Volver a la esquina superior derecha", #selector(resetPosition)),
        ]))
        menu.addItem(submenu("Tema", ["Oscuro", "Claro", "Según el sistema"].enumerated().map {
            item($0.element, #selector(setTheme(_:)), tag: $0.offset, on: prefs.theme == $0.offset)
        }))

        var latencyItems = [item("Desactivada", #selector(setLatencyHost(_:)), tag: -1, on: prefs.latencyHost == nil)]
        for (i, h) in Self.latencyHosts.enumerated() {
            latencyItems.append(item(h.0, #selector(setLatencyHost(_:)), tag: i, on: prefs.latencyHost == h.1))
        }
        latencyItems.append(.separator())
        for secs in [10, 30, 60] {
            let it = item("Cada \(secs) s", #selector(setLatencyInterval(_:)), tag: secs, on: prefs.latencyInterval == secs)
            it.isEnabled = prefs.latencyHost != nil
            latencyItems.append(it)
        }
        menu.addItem(submenu("Latencia a internet", latencyItems))

        var alertItems = Alerts.Kind.allCases.enumerated().map {
            item($0.element.menuTitle, #selector(toggleAlert(_:)), tag: $0.offset, on: prefs.alertEnabled($0.element.rawValue))
        }
        alertItems.append(.separator())
        if !alerts.notificationsAllowed {
            alertItems.append(item("⚠︎ macOS bloquea las notificaciones de Pulso — Permitir…", #selector(openNotificationSettings)))
        }
        alertItems.append(item("Enviar aviso de prueba", #selector(sendTestAlert)))
        alertItems.append(item("Ajustes de notificaciones…", #selector(openNotificationSettings)))
        menu.addItem(submenu("Avisos", alertItems))
        menu.addItem(.separator())

        menu.addItem(item("Abrir al iniciar sesión", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Abrir Monitor de Actividad", #selector(openActivityMonitor)))
        menu.addItem(.separator())
        menu.addItem(item("Salir de Pulso", #selector(quit), key: "q"))
    }

    // Acciones

    @objc private func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        prefs.visible = panel.isVisible
        updatePaused()
    }

    @objc private func toggleCompact() { prefs.compact.toggle() }

    @objc private func toggleClickThrough() { prefs.clickThrough.toggle(); applyPrefs() }

    @objc private func setOpacity(_ sender: NSMenuItem) { prefs.opacity = Double(sender.tag) / 100; applyPrefs() }

    @objc private func setLevel(_ sender: NSMenuItem) { prefs.onDesktop = sender.tag == 1; applyPrefs() }

    @objc private func setTheme(_ sender: NSMenuItem) { prefs.theme = sender.tag; applyPrefs() }

    @objc private func setLatencyHost(_ sender: NSMenuItem) {
        prefs.latencyHost = sender.tag < 0 ? nil : Self.latencyHosts[sender.tag].1
        monitor.latencySettingsChanged()
    }

    @objc private func setLatencyInterval(_ sender: NSMenuItem) {
        prefs.latencyInterval = sender.tag
    }

    @objc private func toggleAlert(_ sender: NSMenuItem) {
        let kind = Alerts.Kind.allCases[sender.tag].rawValue
        if prefs.alertsOff.contains(kind) { prefs.alertsOff.removeAll { $0 == kind } } else { prefs.alertsOff.append(kind) }
    }

    @objc private func sendTestAlert() { alerts.sendTest() }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func resetPosition() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let p = NSPoint(x: vf.maxX - panel.frame.width - 16, y: vf.maxY - 16)
        topLeft = p
        restorePosition()
        UserDefaults.standard.set(p.x, forKey: "originX")
        UserDefaults.standard.set(p.y, forKey: "originY")
        if !panel.isVisible { toggleVisible() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "No se pudo cambiar el inicio automático"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Arranque

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
