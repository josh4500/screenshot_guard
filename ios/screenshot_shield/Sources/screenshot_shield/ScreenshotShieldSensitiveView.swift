import Flutter
import UIKit

/// Registers the platform view behind `ScreenshotShieldSensitiveView`.
/// EXPERIMENTAL: per-region capture exclusion. Only the region's layer is nested in
/// a secure canvas. Relies on undocumented UIKit behaviour, and the region shows a
/// Flutter-rendered snapshot, so animations and video lag behind.
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

/// Native side of one guarded region: draws the Flutter snapshot it receives and
/// keeps its layer nested in a secure canvas, so captures show the placeholder.
final class ScreenshotShieldSensitivePlatformView: NSObject, FlutterPlatformView {
    private let container: SecureRegionView
    private let imageView = UIImageView()
    private let channel: FlutterMethodChannel
    private var secureField: UITextField?
    // Canvas held as its *view*, and `originalSuperlayer` held strongly: both are
    // `unowned(unsafe)`, so a layer kept alive on its own can outlive its owner and
    // crash in `objc_retain`. `isNested` tracks the move instead of comparing.
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
                // Left the hierarchy (screen popping, or Flutter resetting platform
                // views while backgrounded): UIKit is mid-teardown, so do not move layers.
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
                    // Raw RGBA: the region refreshes on every guarded repaint, so
                    // encoding each frame would dominate cost.
                    image = Self.makeImage(fromRawRgba: data.data, width: width, height: height)
                } else if let data {
                    // Tolerate an encoded image from an older client.
                    image = UIImage(data: data.data)
                }
                if let image {
                    // Painted inside the canvas behind the copy: visible through
                    // transparent parts, absent from captures.
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

    /// Builds the image for the region from raw RGBA. `ui.ImageByteFormat.rawRgba` is
    /// premultiplied RGBA, i.e. `byteOrder32Big | premultipliedLast`.
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
        // No teardown: Flutter disposes platform views inside a frame submit, where
        // moving layers crashes (EXC_BAD_ACCESS in objc_retain).
        channel.setMethodCallHandler(nil)
    }

    // MARK: - Capture exclusion

    private func installProtection() {
        // Flutter creates the view before it has a size; `onLayout` retries.
        guard enabled, secureField == nil, container.window != nil, !container.bounds.isEmpty else { return }

        // The field goes *inside* the region, so the canvas inherits Flutter's
        // transform and clip with no geometry mirrored into window coordinates.
        // View-to-view conversion does not reflect Flutter's layer transform.
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
        // `container.layer` avoids reading the unsafe `superlayer` property.
        originalSuperlayer = container.layer
        imageView.frame = container.bounds
        nestSnapshot(in: canvasView.layer)
        SecureCanvas.log(
            "sensitive view \(viewId): snapshot layer nested in "
                + "\(NSStringFromClass(type(of: canvasView))), frame \(imageView.layer.frame)"
        )
    }

    /// Undoes the capture exclusion; only while the region is alive and in the
    /// window. Never from `deinit` or mid-teardown, where moving layers is unsafe.
    private func removeProtection() {
        if isNested {
            imageView.layer.removeFromSuperlayer()
            originalSuperlayer?.addSublayer(imageView.layer)
            imageView.layer.frame = imageView.frame
            isNested = false
        }
        secureField?.removeFromSuperview()
        secureField = nil
        // Released on the next runloop turn: CoreAnimation's transaction can still
        // reference the layer, and outliving its `unowned(unsafe)` delegate crashes.
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
            // UIKit took the field's internals down (layout pass or system snapshot):
            // drop and rebuild outside this pass.
            removeProtection()
            DispatchQueue.main.async { [weak self] in
                self?.installProtection()
            }
            return
        }
        let bounds = container.bounds
        if field.frame != bounds || imageView.frame != bounds {
            imageView.frame = bounds
            field.frame = bounds
            // Laying the field out sizes the private canvas, which UIKit may replace;
            // that is why it is re-resolved below. Only needed when the size changed:
            // this runs on every layout pass of the region.
            field.setNeedsLayout()
            field.layoutIfNeeded()
        }
        guard let canvasView = SecureCanvas.containerView(of: field) else {
            // Mid-rebuild: keep the current nesting - and the canvas view holding the
            // snapshot layer alive - and retry on the next pass.
            SecureCanvas.log("sensitive view \(viewId): canvas not available, keeping the current nesting")
            return
        }
        // UIKit may have replaced the canvas. The snapshot layer is still a sublayer
        // of the previous one, whose layer delegate is `unowned(unsafe)`: releasing
        // that view before the layer moves out crashes in `objc_retain`. Swap first,
        // re-nest, then retire the previous view on the next runloop turn.
        let previousCanvasView = self.canvasView
        self.canvasView = canvasView
        // Reading `superlayer` is safe here: the canvas view we compare against is held
        // strongly, and a replaced one is kept alive until the next runloop turn.
        if !(isNested && previousCanvasView === canvasView && imageView.layer.superlayer === canvasView.layer) {
            nestSnapshot(in: canvasView.layer)
        }
        if let previousCanvasView, previousCanvasView !== canvasView {
            DispatchQueue.main.async { _ = previousCanvasView }
        }
        if bounds.size != lastLoggedSize {
            lastLoggedSize = bounds.size
            SecureCanvas.log(
                "sensitive view \(viewId): region \(bounds.size), canvas \(canvasView.layer.frame), "
                    + "snapshot \(imageView.layer.frame)"
            )
        }
    }

    private func nestSnapshot(in canvas: CALayer) {
        // UIKit moves the layer back when it lays the view out, so re-nest every
        // time. Actions are disabled: this runs inside UIKit's layout/snapshot passes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.layer.removeFromSuperlayer()
        canvas.addSublayer(imageView.layer)
        imageView.layer.frame = imageView.frame
        CATransaction.commit()
        isNested = true
    }
}

/// Reports layout changes so the protected region can be re-nested and aligned.
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
