import Flutter
import UIKit

/// Registers the platform view behind `ScreenshotShieldSensitiveView`.
///
/// EXPERIMENTAL. This is a prototype of *per-region* capture exclusion on iOS:
/// instead of excluding the whole Flutter view (what
/// `setProtection(preventCapture: true)` does), the region occupied by one
/// platform view is nested into its own secure canvas layer, so only that
/// region is left out of screenshots and screen recordings.
///
/// It depends on the same undocumented UIKit behaviour as the whole-window
/// protection, and the region is displayed from a Flutter-rendered snapshot, so
/// animations, video and text cursors inside it are only as fresh as the last
/// refresh.
final class ScreenshotShieldSensitiveViewFactory: NSObject, FlutterPlatformViewFactory {
    /// The `UiKitView` view type that maps to this factory.
    static let viewType = "screenshot_shield/sensitive_view"

    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        ScreenshotShieldSensitivePlatformView(
            frame: frame,
            viewId: viewId,
            messenger: messenger,
            arguments: args
        )
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

/// The native side of one guarded region.
///
/// It draws the Flutter-rendered snapshot it receives over the method channel
/// and keeps its own layer nested in a secure canvas layer so that the region
/// is excluded from system captures. Everything Flutter draws underneath the
/// region (the widget's placeholder) is what a capture shows instead.
final class ScreenshotShieldSensitivePlatformView: NSObject, FlutterPlatformView {
    private let container: SecureRegionView
    private let imageView = UIImageView()
    private let channel: FlutterMethodChannel
    private var secureField: UITextField?
    // `CALayer.superlayer` is imported as `unowned(unsafe)`, so it dangles as
    // soon as the superlayer is deallocated (UIKit tears the secure field's
    // internal canvas down when the view leaves the window). These are held
    // strongly so the layers that the snapshot layer is moved between stay
    // alive, and `isNested` tracks the move instead of comparing `superlayer`.
    //
    // The canvas is held as its *view*, because the canvas layer's `delegate` is
    // that view and is `unowned(unsafe)`: a canvas layer kept alive on its own can
    // outlive its view and be left with a dangling delegate, which crashes in
    // `objc_retain` as soon as the layer is touched again (UIKit rebuilding the
    // private canvas during a system snapshot pass used to trigger exactly that).
    private var canvasView: UIView?
    private var originalSuperlayer: CALayer?
    private var isNested = false
    private var enabled: Bool
    private var lastLoggedSize: CGSize = .zero
    private let viewId: Int64

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, arguments: Any?) {
        container = SecureRegionView(frame: frame)
        self.viewId = viewId
        channel = FlutterMethodChannel(
            name: "\(ScreenshotShieldSensitiveViewFactory.viewType)/\(viewId)",
            binaryMessenger: messenger
        )
        enabled = (arguments as? [String: Any])?["enabled"] as? Bool ?? true
        super.init()

        container.backgroundColor = .clear
        container.clipsToBounds = true
        imageView.frame = container.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleToFill
        imageView.backgroundColor = .clear
        container.addSubview(imageView)
        container.onLayout = { [weak self] in
            guard let self else { return }
            guard self.container.window != nil else {
                // The view left the hierarchy: the screen is being popped, or
                // Flutter's platform-views controller is resetting (which it does
                // while the app is backgrounded). UIKit is mid-teardown there, so
                // do not move layers at all - a layer whose delegate UIKit has
                // already released is retained by the next layer operation and
                // crashes in `objc_retain`. The views and layers are released
                // together with the platform view, which needs no cleanup.
                SecureCanvas.log("sensitive view \(self.viewId): left the window (detached)")
                return
            }
            if self.secureField == nil {
                self.installProtection()
            } else {
                self.layoutProtectedRegion()
            }
        }

        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterMethodNotImplemented)
                return
            }
            switch call.method {
            case "setSnapshot":
                let arguments = call.arguments as? [String: Any]
                let data = arguments?["bytes"] as? FlutterStandardTypedData
                let width = arguments?["width"] as? Int
                let height = arguments?["height"] as? Int
                let backdropValue = (arguments?["backdropColor"] as? NSNumber)?.uint32Value
                    ?? (arguments?["backdropColor"] as? Int).map { UInt32(truncatingIfNeeded: $0) }
                var image: UIImage?
                if let data, let width, let height {
                    // Raw RGBA pixels: the region is refreshed whenever the
                    // guarded subtree repaints, so encoding every frame would be
                    // the dominant cost.
                    image = Self.makeImage(fromRawRgba: data.data, width: width, height: height)
                } else if let data {
                    // Tolerate an encoded image from an older client.
                    image = UIImage(data: data.data)
                }
                if let image {
                    // The backdrop is painted *inside* the capture-excluded canvas,
                    // behind the copy: the user sees it through the transparent
                    // parts of the subtree, while a capture still sees only what
                    // Flutter painted behind the canvas.
                    self.imageView.backgroundColor = backdropValue.map(Self.color(fromArgb:)) ?? .clear
                    self.imageView.image = image
                }
                result(nil)
            case "setEnabled":
                self.enabled = (call.arguments as? Bool) ?? true
                if self.enabled {
                    self.installProtection()
                } else {
                    self.removeProtection()
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        if enabled {
            installProtection()
        }
    }

    func view() -> UIView {
        container
    }

    /// Builds the image displayed for the region from raw RGBA pixels.
    ///
    /// `ui.ImageByteFormat.rawRgba` is premultiplied RGBA, eight bits per
    /// channel, which is `byteOrder32Big | premultipliedLast` for CoreGraphics.
    private static func makeImage(fromRawRgba bytes: Data, width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0, bytes.count >= width * height * 4 else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// Builds a colour from a Flutter ARGB int, the format of `Color.toARGB32()`.
    private static func color(fromArgb argb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255
        )
    }

    deinit {
        // Deliberately does no teardown of the layer tree. Flutter disposes
        // platform views from `FlutterPlatformViewsController
        // computeViewsToDispose`, inside a frame submit: moving layers around
        // while that runs crashes (EXC_BAD_ACCESS in objc_retain), because the
        // view is already being torn down. The region's views and layers are
        // released together, which needs no cleanup.
        channel.setMethodCallHandler(nil)
    }

    // MARK: - Capture exclusion

    private func installProtection() {
        // Flutter creates the platform view before it has been given a size, so
        // wait for the first real layout; `onLayout` retries.
        guard enabled, secureField == nil, container.window != nil, !container.bounds.isEmpty else { return }

        // The field is added *inside* the region, so the secure canvas inherits
        // every transform and clip Flutter applies to the platform view
        // (scrolling, rotation, keyboard insets) and no geometry has to be
        // mirrored into window coordinates. Flutter positions iOS platform
        // views with a layer transform, which view-to-view conversion does not
        // reflect.
        let field = SecureCanvas.makeField(frame: container.bounds)
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(field)
        container.layoutIfNeeded()
        field.layoutIfNeeded()

        guard let canvasView = SecureCanvas.containerView(of: field), !canvasView.layer.bounds.isEmpty else {
            field.removeFromSuperview()
            SecureCanvas.log("sensitive view \(viewId): canvas not sized yet, retrying on layout")
            return
        }

        secureField = field
        self.canvasView = canvasView
        // The snapshot view is a subview of the region, so this is its
        // superlayer; `container.layer` avoids reading the unsafe property.
        originalSuperlayer = container.layer
        imageView.frame = container.bounds
        nestSnapshot(in: canvasView.layer)
        SecureCanvas.log(
            "sensitive view \(viewId): snapshot layer nested in "
                + "\(NSStringFromClass(type(of: canvasView))), frame \(imageView.layer.frame)"
        )
    }

    /// Undoes the capture exclusion. Only called while the region is still alive
    /// and in the window (being disabled) - never from `deinit` and never while
    /// UIKit is tearing the view down, because mutating the layer tree there is
    /// unsafe.
    private func removeProtection() {
        if isNested {
            imageView.layer.removeFromSuperlayer()
            originalSuperlayer?.addSublayer(imageView.layer)
            imageView.layer.frame = imageView.frame
            isNested = false
        }
        secureField?.removeFromSuperview()
        secureField = nil
        // The canvas view is released on the next runloop turn: CoreAnimation's
        // current transaction can still reference its layer, and a layer that
        // outlives its delegate - `CALayer.delegate` is `unowned(unsafe)` - is
        // what crashes in `objc_retain` when it is touched again.
        if let retired = canvasView {
            canvasView = nil
            DispatchQueue.main.async { _ = retired }
        }
        originalSuperlayer = nil
        SecureCanvas.log("sensitive view \(viewId): protection removed")
    }

    /// Re-nests the snapshot layer, which UIKit moves back when it lays the view
    /// out, and keeps the canvas aligned with the region.
    private func layoutProtectedRegion() {
        guard let field = secureField else { return }
        guard container.window != nil, field.superview === container else {
            // UIKit took the field's internals down (it does that during some of
            // its own layout passes, and during a system snapshot). Drop what is
            // left and rebuild the protection outside this layout pass.
            removeProtection()
            DispatchQueue.main.async { [weak self] in
                self?.installProtection()
            }
            return
        }
        let bounds = container.bounds
        imageView.frame = bounds
        field.frame = bounds
        // Laying the field out is what gives the private canvas its size - and
        // UIKit may replace that canvas while doing it, which is why it is
        // re-resolved below instead of reusing the one cached at install time.
        field.setNeedsLayout()
        field.layoutIfNeeded()
        guard let canvasView = SecureCanvas.containerView(of: field) else {
            // Mid-rebuild: keep the current nesting and try again on the next
            // layout pass rather than touching a canvas that may be going away.
            self.canvasView = nil
            SecureCanvas.log("sensitive view \(viewId): canvas not available, keeping the current nesting")
            return
        }
        self.canvasView = canvasView
        nestSnapshot(in: canvasView.layer)
        if bounds.size != lastLoggedSize {
            lastLoggedSize = bounds.size
            SecureCanvas.log(
                "sensitive view \(viewId): region \(bounds.size), canvas \(canvasView.layer.frame), "
                    + "snapshot \(imageView.layer.frame)"
            )
        }
    }

    private func nestSnapshot(in canvas: CALayer) {
        // UIKit puts the layer back when it lays the view out, so re-nest every
        // time rather than trusting `isNested` here. Implicit animations are
        // disabled: this also runs inside UIKit's own layout and snapshot passes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.layer.removeFromSuperlayer()
        canvas.addSublayer(imageView.layer)
        // The canvas sits at the region's origin and matches its bounds, so the
        // snapshot's frame in the canvas equals its frame in the region.
        imageView.layer.frame = imageView.frame
        CATransaction.commit()
        isNested = true
    }
}

/// A container that reports layout changes so the protected region can be
/// re-nested and re-aligned when Flutter resizes or moves it.
final class SecureRegionView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onLayout?()
    }
}
