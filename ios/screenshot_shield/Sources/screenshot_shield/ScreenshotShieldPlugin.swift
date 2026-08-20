import Flutter
import UIKit

public class ScreenshotShieldPlugin: NSObject, FlutterPlugin, ScreenshotShieldHostApi {
    private let streamHandler = ScreenshotShieldStreamHandler()
    private var screenshotObserver: NSObjectProtocol?
    private var backgroundBlurEnabled = false
    private var backgroundBlurView: UIVisualEffectView?
    private var backgroundObserverTokens: [NSObjectProtocol] = []

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

    public func setBackgroundBlur(blurEnabled: Bool) throws {
        backgroundBlurEnabled = blurEnabled
        if blurEnabled {
            guard backgroundObserverTokens.isEmpty else { return }
            let didEnterBackground = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showBackgroundBlur()
            }
            let willEnterForeground = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.hideBackgroundBlur()
            }
            backgroundObserverTokens = [didEnterBackground, willEnterForeground]
        } else {
            for token in backgroundObserverTokens {
                NotificationCenter.default.removeObserver(token)
            }
            backgroundObserverTokens = []
            hideBackgroundBlur()
        }
    }

    // MARK: - Background blur

    private func showBackgroundBlur() {
        guard backgroundBlurEnabled else { return }
        guard let window = Self.keyWindow() else { return }
        let blurView = backgroundBlurView ?? UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.frame = window.bounds
        if blurView.superview !== window {
            window.addSubview(blurView)
        }
        backgroundBlurView = blurView
        // Commit the blur immediately so the app-switcher snapshot includes it.
        window.setNeedsLayout()
        window.layoutIfNeeded()
        CATransaction.flush()
    }

    private func hideBackgroundBlur() {
        backgroundBlurView?.removeFromSuperview()
        backgroundBlurView = nil
    }

    private static func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
            return windowScene.windows.first
        }
        return nil
    }

    deinit {
        if let screenshotObserver {
            NotificationCenter.default.removeObserver(screenshotObserver)
        }
        for token in backgroundObserverTokens {
            NotificationCenter.default.removeObserver(token)
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
