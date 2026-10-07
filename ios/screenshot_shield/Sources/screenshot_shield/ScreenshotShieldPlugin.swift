import Flutter
import UIKit

public class ScreenshotShieldPlugin: NSObject, FlutterPlugin, ScreenshotShieldHostApi {
    private let streamHandler = ScreenshotShieldStreamHandler()
    private let screenRecordingStreamHandler = ScreenRecordingStreamHandler()
    private var screenshotObserver: NSObjectProtocol?
    private var screenRecordingObserver: NSObjectProtocol?
    private var secureTextField: UITextField?
    private var protectedContentView: UIView?
    private weak var protectedContentSuperlayer: CALayer?
    private weak var protectedContainerLayer: CALayer?
    private var backgroundBlurEnabled = false
    private var backgroundBlurView: UIVisualEffectView?
    private var backgroundObserverTokens: [NSObjectProtocol] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()
        let instance = ScreenshotShieldPlugin()
        ScreenshotShieldHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
        OnScreenshotDetectedStreamHandler.register(with: messenger, streamHandler: instance.streamHandler)
        OnScreenRecordingChangedStreamHandler.register(
            with: messenger,
            streamHandler: instance.screenRecordingStreamHandler
        )
        registrar.register(
            ScreenshotShieldSensitiveViewFactory(messenger: messenger),
            withId: ScreenshotShieldSensitiveViewFactory.viewType
        )
    }

    // MARK: - ScreenshotShieldHostApi

    public func startListening() throws {
        if screenshotObserver == nil {
            screenshotObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.userDidTakeScreenshotNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.streamHandler.emitScreenshotDetected()
            }
        }
        if screenRecordingObserver == nil {
            screenRecordingObserver = NotificationCenter.default.addObserver(
                forName: UIScreen.capturedDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.emitScreenRecordingState()
            }
        }
        // Report the state at the moment listening starts; the notification only
        // fires on subsequent changes.
        emitScreenRecordingState()
    }

    public func stopListening() throws {
        if let screenshotObserver {
            NotificationCenter.default.removeObserver(screenshotObserver)
            self.screenshotObserver = nil
        }
        if let screenRecordingObserver {
            NotificationCenter.default.removeObserver(screenRecordingObserver)
            self.screenRecordingObserver = nil
        }
    }

    // MARK: - Screen recording

    private func emitScreenRecordingState() {
        screenRecordingStreamHandler.emitScreenRecordingChanged(isScreenRecording)
    }

    /// `UIScreen.isCaptured` covers screen recording and screen mirroring. The
    /// simulator always reports `true`, so it is treated as not captured to
    /// avoid false positives during development.
    private var isScreenRecording: Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            return UIScreen.main.isCaptured
        #endif
    }

    public func setProtected(protected: Bool) throws {
        if protected {
            enableCaptureProtection()
        } else {
            disableCaptureProtection()
        }
    }

    // MARK: - Capture protection

    /// Blanks screenshots and screen recordings of the app.
    ///
    /// iOS has no public API for this. The workaround is a `UITextField` with
    /// `isSecureTextEntry` enabled: UIKit renders such a field through a
    /// private, capture-excluded canvas layer (see [SecureCanvas]). The canvas
    /// only protects its own content, so the app's content layer is re-parented
    /// into it. Simply adding a secure field as a sibling subview - which this
    /// plugin used to do - protects nothing but the (empty) field itself, so
    /// screenshots still show the app.
    ///
    /// The field is sized to the window and inserted at origin (0, 0) so the
    /// canvas layer's coordinate space matches the window's. That keeps the
    /// content layer's frame valid across the move and lets UIKit keep applying
    /// `view.frame` updates without shifting the content.
    private func enableCaptureProtection() {
        if let contentView = protectedContentView, let container = protectedContainerLayer {
            // Re-assert the nesting: UIKit can rebuild the window's layer tree
            // (for example while returning from the background), which moves the
            // content layer back under the window and silently disables the
            // protection. The guards call this again whenever a guarded screen
            // becomes active.
            if contentView.layer.superlayer !== container {
                contentView.layer.removeFromSuperlayer()
                container.addSublayer(contentView.layer)
                contentView.layer.frame = contentView.frame
                SecureCanvas.log("capture protection re-asserted")
            }
            return
        }
        guard secureTextField == nil, protectedContentView == nil else { return }
        guard let window = Self.keyWindow() else {
            SecureCanvas.log("capture protection skipped: no key window yet")
            return
        }
        guard let contentView = window.rootViewController?.view ?? window.subviews.first else {
            SecureCanvas.log("capture protection skipped: window has no content view")
            return
        }

        let field = SecureCanvas.makeField(frame: window.bounds)
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.insertSubview(field, at: 0)
        window.layoutIfNeeded()
        field.layoutIfNeeded()

        guard let secureContainer = SecureCanvas.containerLayer(of: field) else {
            field.removeFromSuperview()
            SecureCanvas.log("capture protection failed: no secure container layer on the text field")
            return
        }

        let originalSuperlayer = contentView.layer.superlayer
        contentView.layer.removeFromSuperlayer()
        secureContainer.addSublayer(contentView.layer)
        contentView.layer.frame = contentView.frame

        secureTextField = field
        protectedContentView = contentView
        protectedContentSuperlayer = originalSuperlayer
        protectedContainerLayer = secureContainer
        SecureCanvas.log(
            "capture protection enabled: \(type(of: contentView)) layer nested in "
                + "\(NSStringFromClass(type(of: secureContainer))), superlayer now "
                + "\(contentView.layer.superlayer.map { NSStringFromClass(type(of: $0)) } ?? "nil")"
        )
    }

    private func disableCaptureProtection() {
        if let contentView = protectedContentView {
            contentView.layer.removeFromSuperlayer()
            let parent = protectedContentSuperlayer ?? Self.keyWindow()?.layer
            parent?.addSublayer(contentView.layer)
            contentView.layer.frame = contentView.frame
            SecureCanvas.log("capture protection disabled: content layer restored to \(String(describing: parent))")
        }
        secureTextField?.removeFromSuperview()
        secureTextField = nil
        protectedContentView = nil
        protectedContentSuperlayer = nil
        protectedContainerLayer = nil
    }

    public func setBackgroundBlur(blurEnabled: Bool) throws {
        backgroundBlurEnabled = blurEnabled
        if blurEnabled {
            guard backgroundObserverTokens.isEmpty else { return }
            // willResignActive fires before the app-switcher snapshot is
            // captured, so the blur is reliably included in it.
            let willResignActive = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showBackgroundBlur()
            }
            let didEnterBackground = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showBackgroundBlur()
            }
            let didBecomeActive = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.hideBackgroundBlur()
            }
            let willEnterForeground = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.hideBackgroundBlur()
            }
            backgroundObserverTokens =
                [willResignActive, didEnterBackground, didBecomeActive, willEnterForeground]
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
        var fallback: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if windowScene.activationState == .foregroundActive,
                let window = windowScene.windows.first(where: { $0.isKeyWindow })
            {
                return window
            }
            if fallback == nil {
                fallback = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first
            }
        }
        return fallback
    }

    deinit {
        if let screenshotObserver {
            NotificationCenter.default.removeObserver(screenshotObserver)
        }
        if let screenRecordingObserver {
            NotificationCenter.default.removeObserver(screenRecordingObserver)
        }
        for token in backgroundObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        disableCaptureProtection()
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

class ScreenRecordingStreamHandler: OnScreenRecordingChangedStreamHandler {
    private var eventSink: PigeonEventSink<Bool>?
    private var lastState: Bool?

    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<Bool>) {
        eventSink = sink
        if let lastState {
            sink.success(lastState)
        }
    }

    override func onCancel(withArguments arguments: Any?) {
        eventSink = nil
    }

    func emitScreenRecordingChanged(_ isRecording: Bool) {
        lastState = isRecording
        eventSink?.success(isRecording)
    }
}
