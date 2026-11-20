import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class DisplayFPS {
    enum Status {
        case off, permissionRequired, starting, running, unavailable
    }

    private struct Session {
        let displayID: CGDirectDisplayID
        let stream: SCStream
        let output: FrameCounter
    }

    private var requestedDisplay: CGDirectDisplayID?
    private var session: Session?
    private var transitioning = false
    private var captureStatus: Status = .off

    var status: Status {
        session?.output.didStop == true ? .unavailable : captureStatus
    }

    func configure(for displayID: CGDirectDisplayID?) {
        requestedDisplay = displayID
        if displayID == nil { captureStatus = .off }
        guard !transitioning else { return }
        transitioning = true
        Task { [weak self] in
            guard let self else { return }
            await reconcileCapture()
            transitioning = false
        }
    }

    func sample() -> Int? {
        guard status == .running, let session, session.displayID == requestedDisplay else { return nil }
        return session.output.sample()
    }

    private func reconcileCapture() async {
        while true {
            if let session {
                if session.displayID == requestedDisplay, !session.output.didStop {
                    captureStatus = .running
                    return
                }
                self.session = nil
                try? await session.stream.stopCapture()
            }

            guard let displayID = requestedDisplay else {
                captureStatus = .off
                return
            }
            guard CGPreflightScreenCaptureAccess() else {
                captureStatus = .permissionRequired
                return
            }

            captureStatus = .starting
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard displayID == requestedDisplay else { continue }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    captureStatus = .unavailable
                    return
                }

                let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = 160
                configuration.height = 90
                configuration.showsCursor = false
                configuration.capturesAudio = false

                let output = FrameCounter()
                let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try await stream.startCapture()
                session = Session(displayID: displayID, stream: stream, output: output)
                if output.didStop, displayID == requestedDisplay {
                    captureStatus = .unavailable
                    return
                }
            } catch {
                guard displayID == requestedDisplay else { continue }
                captureStatus = CGPreflightScreenCaptureAccess() ? .unavailable : .permissionRequired
                return
            }
        }
    }
}

private final class FrameCounter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "OverlayActivity.FrameCounter", qos: .utility)
    private let lock = NSLock()
    private var frames = 0
    private var lastSample: TimeInterval?
    private var stopped = false

    var didStop: Bool { lock.withLock { stopped } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Read the frame status only. The buffer's image is never accessed or retained.
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue else { return }

        lock.withLock { frames += 1 }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock { stopped = true }
    }

    func sample() -> Int? {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            defer {
                lastSample = now
                frames = 0
            }
            guard let lastSample, now > lastSample, !stopped else { return nil }
            return Int((Double(frames) / (now - lastSample)).rounded())
        }
    }
}
