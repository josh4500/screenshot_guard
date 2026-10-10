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
    // Held as the canvas *view*: the canvas layer's `delegate` is `unowned(unsafe)`,
    // so a layer kept alive on its own can outlive the view and crash in `objc_retain`.
    private var protectedContainerView: UIView?
    private var keyboardProtectionEnabled = false
    private var keyboardObserverTokens: [NSObjectProtocol] = []
    private var keyboardSecureTextField: UITextField?
    private var keyboardProtectedContentView: UIView?
    private var keyboardProtectedSuperlayer: CALayer?
    private var keyboardProtectedContainerView: UIView?
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
        // Report the current state now; the notification only fires on changes.
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

    /// `UIScreen.isCaptured` covers screen recording and mirroring. The simulator
    /// always reports `true`, so it is treated as not captured.
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

    /// Blanks screenshots and recordings of the app.
    ///
    /// iOS has no public API: a secure `UITextField` supplies the private
    /// capture-excluded canvas layer, and the app's content layer is re-parented
    /// into it (a sibling field only protects itself). The field is sized to the
    /// window at origin so canvas coordinates and the content frame stay valid.
    private func enableCaptureProtection() {
        if let contentView = protectedContentView, let field = secureTextField {
            // Re-assert the nesting: UIKit can rebuild the window's layer tree (e.g.
            // on return from background) and silently undo it; re-resolve the canvas too.
            guard let canvasView = SecureCanvas.containerView(of: field) else {
                SecureCanvas.log("capture protection re-assert deferred: no secure canvas view")
                return
            }
            protectedContainerView = canvasView
            if contentView.layer.superlayer !== canvasView.layer {
                nest(contentLayer: contentView.layer, in: canvasView.layer, frame: contentView.frame)
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

        guard let canvasView = SecureCanvas.containerView(of: field) else {
            field.removeFromSuperview()
            SecureCanvas.log("capture protection failed: no secure canvas view on the text field")
            return
        }

        let originalSuperlayer = contentView.layer.superlayer
        nest(contentLayer: contentView.layer, in: canvasView.layer, frame: contentView.frame)

        secureTextField = field
        protectedContentView = contentView
        protectedContentSuperlayer = originalSuperlayer
        protectedContainerView = canvasView
        SecureCanvas.log(
            "capture protection enabled: \(type(of: contentView)) layer nested in "
                + "\(NSStringFromClass(type(of: canvasView))), superlayer now "
                + "\(contentView.layer.superlayer.map { NSStringFromClass(type(of: $0)) } ?? "nil")"
        )
    }

    // MARK: - Keyboard protection (iOS only)

    /// Keeps the on-screen keyboard out of captures. The keyboard is its own private
    /// window, so window protection and sensitive regions never reach it; its content
    /// is nested in a canvas the same way. Best effort: re-installed when a keyboard
    /// window appears or changes frame.
    public func setKeyboardProtected(enabled: Bool) throws {
        keyboardProtectionEnabled = enabled
        if enabled {
            installKeyboardObservers()
            protectKeyboardWindow()
        } else {
            removeKeyboardObservers()
            unprotectKeyboardWindow()
        }
    }

    private func installKeyboardObservers() {
        guard keyboardObserverTokens.isEmpty else { return }
        // `keyboardWillHide` matters most: the layer tree has to be handed back to
        // UIKit *before* it dismantles the keyboard window, or the move crashes.
        let protect: [Notification.Name] = [
            UIWindow.didBecomeVisibleNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ]
        let restore: [Notification.Name] = [UIResponder.keyboardWillHideNotification]
        keyboardObserverTokens = protect.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.protectKeyboardWindow()
            }
        }
        keyboardObserverTokens += restore.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.unprotectKeyboardWindow()
            }
        }
    }

    private func removeKeyboardObservers() {
        for token in keyboardObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        keyboardObserverTokens = []
    }

    private func protectKeyboardWindow() {
        guard keyboardProtectionEnabled else { return }
        guard let window = Self.keyboardWindow() else { return }
        // Only touch a window UIKit identifies as a keyboard, and only when visible.
        guard NSStringFromClass(type(of: window)).lowercased().contains("keyboard") else { return }
        guard !window.isHidden, window.alpha > 0 else { return }
        guard let contentView = window.rootViewController?.view ?? window.subviews.first else { return }
        // Rebuilt keyboards replace the window's content view; re-install.
        if keyboardProtectedContentView === contentView {
            return
        }
        unprotectKeyboardWindow()

        let field = SecureCanvas.makeField(frame: window.bounds)
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.insertSubview(field, at: 0)
        window.layoutIfNeeded()
        field.layoutIfNeeded()

        guard let canvasView = SecureCanvas.containerView(of: field) else {
            field.removeFromSuperview()
            SecureCanvas.log("keyboard protection failed: no secure canvas view on the text field")
            return
        }

        let originalSuperlayer = contentView.layer.superlayer
        nest(contentLayer: contentView.layer, in: canvasView.layer, frame: contentView.frame)

        keyboardSecureTextField = field
        keyboardProtectedContentView = contentView
        keyboardProtectedSuperlayer = originalSuperlayer
        keyboardProtectedContainerView = canvasView
        SecureCanvas.log(
            "keyboard protection enabled: \(type(of: contentView)) layer nested in "
                + "\(NSStringFromClass(type(of: canvasView)))"
        )
    }

    private func unprotectKeyboardWindow() {
        if let contentView = keyboardProtectedContentView {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentView.layer.removeFromSuperlayer()
            let parent = keyboardProtectedSuperlayer ?? Self.keyboardWindow()?.layer
            parent?.addSublayer(contentView.layer)
            contentView.layer.frame = contentView.frame
            CATransaction.commit()
        }
        keyboardProtectedContentView = nil
        keyboardProtectedSuperlayer = nil
        keyboardSecureTextField?.removeFromSuperview()
        keyboardSecureTextField = nil
        // Retired on the next runloop turn: `CALayer.delegate` is `unowned(unsafe)`,
        // so a canvas layer that outlives its view crashes in `objc_retain`.
        if let retired = keyboardProtectedContainerView {
            keyboardProtectedContainerView = nil
            DispatchQueue.main.async { _ = retired }
        }
    }

    /// The keyboard lives in its own private window in the app's scene.
    private static func keyboardWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows
            where NSStringFromClass(type(of: window)).lowercased().contains("keyboard") {
                return window
            }
        }
        return nil
    }

    /// Moves [contentLayer] into the capture-excluded [canvas] without an implicit
    /// animation, since this can run inside UIKit's own layout passes.
    private func nest(contentLayer: CALayer, in canvas: CALayer, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.removeFromSuperlayer()
        canvas.addSublayer(contentLayer)
        contentLayer.frame = frame
        CATransaction.commit()
    }

    private func disableCaptureProtection() {
        if let contentView = protectedContentView {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentView.layer.removeFromSuperlayer()
            let parent = protectedContentSuperlayer ?? Self.keyWindow()?.layer
            parent?.addSublayer(contentView.layer)
            contentView.layer.frame = contentView.frame
            CATransaction.commit()
            SecureCanvas.log("capture protection disabled: content layer restored to \(String(describing: parent))")
        }
        secureTextField?.removeFromSuperview()
        secureTextField = nil
        protectedContentView = nil
        protectedContentSuperlayer = nil
        // Released on the next runloop turn: CoreAnimation's transaction can still
        // reference the layer, and outliving its `unowned(unsafe)` delegate crashes.
        if let retired = protectedContainerView {
            protectedContainerView = nil
            DispatchQueue.main.async { _ = retired }
        }
    }

    public func setBackgroundBlur(blurEnabled: Bool) throws {
        backgroundBlurEnabled = blurEnabled
        if blurEnabled {
            guard backgroundObserverTokens.isEmpty else { return }
            // willResignActive fires before the app-switcher snapshot, so the blur is in it.
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
