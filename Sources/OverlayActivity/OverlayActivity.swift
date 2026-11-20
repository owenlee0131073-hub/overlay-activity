import AppKit
import CoreGraphics
import OverlayCore
import ServiceManagement

@main
@MainActor
private struct OverlayActivity {
    static func main() {
        let app = NSApplication.shared
        let controller = OverlayController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
private final class OverlayController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let panel = OverlayPanel()
    private let metrics = SystemMetrics()
    private let fps = DisplayFPS()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let visibilityItem = NSMenuItem(title: "오버레이 숨기기", action: #selector(toggleOverlay), keyEquivalent: "")
    private let fpsItem = NSMenuItem(title: "FPS 측정 켜기", action: #selector(toggleFPS), keyEquivalent: "")
    private let fpsHelpItem = NSMenuItem(title: "화면 기록 설정 열기", action: #selector(resolveFPS), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let transparencyMenu = NSMenu()
    private let transparencyKey = "OverlayBackgroundTransparency"
    private var timer: Timer?
    private var overlayVisible = true
    private var screensSleeping = false
    private var fpsEnabled = UserDefaults.standard.bool(forKey: "MeasureDisplayFPS")

    private var monitoringScreen: NSScreen? {
        overlayVisible && !screensSleeping ? NSScreen.screens.first : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Overlay Activity")
        statusItem.button?.toolTip = "Overlay Activity"

        let menu = NSMenu()
        menu.delegate = self
        visibilityItem.target = self
        menu.addItem(visibilityItem)

        let transparencyItem = NSMenuItem(title: "배경 투명도", action: nil, keyEquivalent: "")
        transparencyItem.submenu = transparencyMenu
        for transparency in BackgroundTransparency.allCases {
            let item = NSMenuItem(title: "\(transparency.rawValue)%", action: #selector(changeTransparency(_:)), keyEquivalent: "")
            item.target = self
            item.tag = transparency.rawValue
            transparencyMenu.addItem(item)
        }
        menu.addItem(transparencyItem)
        let savedTransparency = UserDefaults.standard.object(forKey: transparencyKey) as? Int
        applyTransparency(BackgroundTransparency(savedPercent: savedTransparency))

        for item in [fpsItem, fpsHelpItem] {
            item.target = self
            menu.addItem(item)
        }
        fpsItem.toolTip = "기본 디스플레이의 화면 갱신 빈도를 측정합니다."
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self, selector: #selector(activeSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        workspaceNotifications.addObserver(
            self, selector: #selector(screenPowerChanged(_:)),
            name: NSWorkspace.screensDidSleepNotification, object: nil
        )
        workspaceNotifications.addObserver(
            self, selector: #selector(screenPowerChanged(_:)),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )
        updateOverlay()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        metrics.invalidateGPUDiscovery()
        updateOverlay()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        visibilityItem.title = overlayVisible ? "오버레이 숨기기" : "오버레이 표시"
        fpsItem.title = fpsEnabled ? "FPS 측정 끄기" : "FPS 측정 켜기"
        switch fpsEnabled ? fps.status : .off {
        case .permissionRequired:
            fpsHelpItem.title = "화면 기록 설정 열기"
            fpsHelpItem.isHidden = false
        case .unavailable:
            fpsHelpItem.title = "FPS 측정 다시 시도"
            fpsHelpItem.isHidden = false
        case .off, .starting, .running:
            fpsHelpItem.isHidden = true
        }

        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : .off
        loginItem.title = status == .requiresApproval ? "로그인 시 실행 승인…" : "로그인 시 실행"
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            @unknown default:
                return
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "로그인 시 실행 설정을 변경할 수 없습니다."
            alert.runModal()
        }
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        if let screen = monitoringScreen { positionOverlay(on: screen) }
    }

    @objc private func screenPowerChanged(_ notification: Notification) {
        screensSleeping = notification.name == NSWorkspace.screensDidSleepNotification
        updateOverlay()
    }

    @objc private func toggleOverlay() {
        overlayVisible.toggle()
        updateOverlay()
    }

    @objc private func toggleFPS() {
        fpsEnabled.toggle()
        UserDefaults.standard.set(fpsEnabled, forKey: "MeasureDisplayFPS")
        if fpsEnabled, !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        updateOverlay()
        panel.updateFPS(nil)
    }

    @objc private func changeTransparency(_ item: NSMenuItem) {
        guard let transparency = BackgroundTransparency(rawValue: item.tag) else { return }
        UserDefaults.standard.set(transparency.rawValue, forKey: transparencyKey)
        applyTransparency(transparency)
    }

    private func applyTransparency(_ transparency: BackgroundTransparency) {
        panel.setBackgroundTransparency(transparency)
        for item in transparencyMenu.items {
            item.state = item.tag == transparency.rawValue ? .on : .off
        }
    }

    @objc private func resolveFPS() {
        if fps.status == .permissionRequired, !CGPreflightScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
            return
        }
        configureFPS(for: monitoringScreen)
    }

    private func updateOverlay() {
        let screen = monitoringScreen
        configureFPS(for: screen)
        guard let screen else {
            panel.orderOut(nil)
            if let timer {
                timer.invalidate()
                self.timer = nil
                metrics.resetSampling()
            }
            return
        }
        positionOverlay(on: screen)

        let interval: TimeInterval = fpsEnabled ? 1 : 2
        guard timer?.timeInterval != interval else { return }
        if let timer { timer.invalidate() } else { refresh() }
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer.tolerance = interval * 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func positionOverlay(on screen: NSScreen) {
        let available = screen.visibleFrame
        let origin = NSPoint(x: available.maxX - panel.frame.width - 12, y: available.maxY - panel.frame.height - 10)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    private func configureFPS(for screen: NSScreen?) {
        let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        fps.configure(for: fpsEnabled ? displayID?.uint32Value : nil)
    }

    @objc private func refresh() {
        let uptime = ProcessInfo.processInfo.systemUptime
        if fpsEnabled { panel.updateFPS(fps.sample(at: uptime)) }
        panel.update(cpu: metrics.cpuPercent(), gpu: metrics.gpuPercent(at: uptime), ram: metrics.ramPercent())
    }
}

@MainActor
private final class OverlayPanel: NSPanel {
    private let background = NSView()
    private let cpu = MetricCell("CPU", suffix: "%")
    private let gpu = MetricCell("GPU", suffix: "%")
    private let ram = MetricCell("RAM", suffix: "%")
    private let fps = MetricCell("FPS")
    private lazy var row = NSStackView(views: [cpu, gpu, ram, fps])

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        let bounds = NSRect(x: 0, y: 0, width: 232, height: 46)
        super.init(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Overlay Activity"
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        background.frame = bounds
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.borderWidth = 1
        contentView = background

        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 0
        row.wantsLayer = true
        row.layer?.shadowColor = NSColor.black.cgColor
        row.layer?.shadowRadius = 2
        row.layer?.shadowOffset = CGSize(width: 0, height: -1)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 5),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -5),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
    }

    func setBackgroundTransparency(_ transparency: BackgroundTransparency) {
        let opacity = CGFloat(transparency.opacity)
        background.layer?.backgroundColor = NSColor(srgbRed: 0.075, green: 0.085, blue: 0.10, alpha: opacity).cgColor
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.18 * opacity).cgColor
        row.layer?.shadowOpacity = opacity < 0.5 ? 0.9 : 0
        hasShadow = opacity > 0
        invalidateShadow()
    }

    func update(cpu: Int?, gpu: Int?, ram: Int?) {
        self.cpu.setValue(cpu)
        self.gpu.setValue(gpu)
        self.ram.setValue(ram)
    }

    func updateFPS(_ value: Int?) {
        fps.setValue(value)
    }
}

@MainActor
private final class MetricCell: NSStackView {
    private let valueLabel = NSTextField(labelWithString: "–")
    private let suffix: String
    private var value: Int?
    private var level: UsageLevel = .normal

    init(_ name: String, suffix: String = "") {
        self.suffix = suffix
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 1

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        nameLabel.textColor = NSColor(srgbRed: 0.69, green: 0.73, blue: 0.80, alpha: 1)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = .white
        addArrangedSubview(nameLabel)
        addArrangedSubview(valueLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setValue(_ value: Int?) {
        guard self.value != value else { return }
        self.value = value
        valueLabel.stringValue = value.map { "\($0)\(suffix)" } ?? "–"
        guard !suffix.isEmpty else { return }

        let level = UsageLevel(percent: value)
        guard self.level != level else { return }
        self.level = level
        switch level {
        case .normal:
            valueLabel.textColor = .white
        case .high:
            valueLabel.textColor = NSColor(srgbRed: 1, green: 0.83, blue: 0.32, alpha: 1)
        case .critical:
            valueLabel.textColor = NSColor(srgbRed: 1, green: 0.40, blue: 0.41, alpha: 1)
        }
    }
}
