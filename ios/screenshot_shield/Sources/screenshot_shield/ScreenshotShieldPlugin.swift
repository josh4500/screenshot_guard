import Flutter
import UIKit

public class ScreenshotShieldPlugin: NSObject, FlutterPlugin, ScreenshotShieldHostApi {
    private let streamHandler = ScreenshotShieldStreamHandler()
    private var screenshotObserver: NSObjectProtocol?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()
        let instance = ScreenshotShieldPlugin()
        ScreenshotShieldHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
        OnScreenshotDetectedStreamHandler.register(with: messenger, streamHandler: instance.streamHandler)
    }

    // MARK: - ScreenshotShieldHostApi

    public func startListening() throws {
        guard screenshotObserver == nil else { return }
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.streamHandler.emitScreenshotDetected()
        }
    }

    public func stopListening() throws {
        if let screenshotObserver {
            NotificationCenter.default.removeObserver(screenshotObserver)
            self.screenshotObserver = nil
        }
    }

    public func setProtected(protected: Bool) throws {
        // iOS has no public API to prevent screenshots, so this is a no-op.
    }

    deinit {
        if let screenshotObserver {
            NotificationCenter.default.removeObserver(screenshotObserver)
        }
    }
}

class ScreenshotShieldStreamHandler: OnScreenshotDetectedStreamHandler {
    private var eventSink: PigeonEventSink<Int64>?

    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<Int64>) {
        eventSink = sink
    }

    override func onCancel(withArguments arguments: Any?) {
        eventSink = nil
    }

    func emitScreenshotDetected() {
        eventSink?.success(0)
    }
}
