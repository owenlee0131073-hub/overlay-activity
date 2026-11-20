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
    private var fpsEnabled = UserDefaults.standard.bool(forKey: "MeasureDisplayFPS")

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
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        showOverlay()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        positionOverlay()
        configureFPS()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
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
        positionOverlay()
    }

    @objc private func toggleOverlay() {
        overlayVisible.toggle()
        if overlayVisible {
            showOverlay()
        } else {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
            configureFPS()
        }
    }

    @objc private func toggleFPS() {
        fpsEnabled.toggle()
        UserDefaults.standard.set(fpsEnabled, forKey: "MeasureDisplayFPS")
        if fpsEnabled, !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        configureFPS()
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
        configureFPS()
    }

    private func showOverlay() {
        positionOverlay()
        configureFPS()
        metrics.resetCPU()
        refresh()

        let timer = Timer(timeInterval: 1, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func positionOverlay() {
        guard overlayVisible else { return }
        guard let screen = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        let available = screen.visibleFrame
        let origin = NSPoint(x: available.maxX - panel.frame.width - 12, y: available.maxY - panel.frame.height - 10)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    private func configureFPS() {
        let displayID = NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        fps.configure(for: overlayVisible && fpsEnabled ? displayID?.uint32Value : nil)
        updateMenu()
    }

    @objc private func refresh() {
        panel.update(cpu: metrics.cpuPercent(), gpu: metrics.gpuPercent(), ram: metrics.ramPercent())
        panel.updateFPS(fps.sample())
        updateMenu()
    }

    private func updateMenu() {
        visibilityItem.title = overlayVisible ? "오버레이 숨기기" : "오버레이 표시"
        fpsItem.title = fpsEnabled ? "FPS 측정 끄기" : "FPS 측정 켜기"
        fpsItem.toolTip = "기본 디스플레이의 화면 갱신 빈도를 측정합니다."
        fpsHelpItem.isHidden = true
        if overlayVisible, fpsEnabled {
            switch fps.status {
            case .permissionRequired:
                fpsHelpItem.title = "화면 기록 설정 열기"
                fpsHelpItem.isHidden = false
            case .unavailable:
                fpsHelpItem.title = "FPS 측정 다시 시도"
                fpsHelpItem.isHidden = false
            case .off, .starting, .running:
                break
            }
        }
    }
}

@MainActor
private final class OverlayPanel: NSPanel {
    private let background = NSView()
    private let cpu = MetricCell("CPU")
    private let gpu = MetricCell("GPU")
    private let ram = MetricCell("RAM")
    private let fps = MetricCell("FPS")

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

        let row = NSStackView(views: [cpu, gpu, ram, fps])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 0
        row.wantsLayer = true
        row.layer?.shadowColor = NSColor.black.cgColor
        row.layer?.shadowOpacity = 0.9
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
        hasShadow = opacity > 0
        invalidateShadow()
    }

    func update(cpu: Int?, gpu: Int?, ram: Int?) {
        self.cpu.setUsage(cpu)
        self.gpu.setUsage(gpu)
        self.ram.setUsage(ram)
    }

    func updateFPS(_ value: Int?) {
        fps.setValue(value.map(String.init) ?? "–", level: .normal)
    }
}

@MainActor
private final class MetricCell: NSStackView {
    private let valueLabel = NSTextField(labelWithString: "–")

    init(_ name: String) {
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

    func setUsage(_ value: Int?) {
        setValue(value.map { "\($0)%" } ?? "–", level: UsageLevel(percent: value))
    }

    func setValue(_ text: String, level: UsageLevel) {
        guard valueLabel.stringValue != text else { return }
        valueLabel.stringValue = text
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
