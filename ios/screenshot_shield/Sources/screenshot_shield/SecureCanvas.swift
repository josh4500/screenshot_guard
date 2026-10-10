import UIKit

/// The secure-text-field technique shared by window protection and the per-region
/// `ScreenshotShieldSensitiveView`. iOS has no public API: a `UITextField` with
/// `isSecureTextEntry` is rendered through a private capture-excluded canvas layer,
/// and nesting a layer into that canvas excludes its content. Undocumented behaviour.
enum SecureCanvas {
    /// Creates the capture-excluded text field used as a container. The caller
    /// must add it to the hierarchy and lay it out before calling
    /// [containerView(of:)], because UIKit builds the canvas lazily.
    static func makeField(frame: CGRect) -> UITextField {
        let field = UITextField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.isAccessibilityElement = false
        field.frame = frame
        return field
    }

    /// The private capture-excluded canvas view inside a secure text field, or `nil`
    /// before the field is laid out. Hold the *view*, not its layer: the canvas
    /// layer's `delegate` is `unowned(unsafe)`, so a lone layer can outlive the view
    /// and crash in `objc_retain`. Re-resolve rather than caching the layer.
    static func containerView(of field: UITextField) -> UIView? {
        if let canvas = canvasView(in: field) {
            return canvas
        }
        let subviews = field.subviews.map { NSStringFromClass(type(of: $0)) }
        log("no secure canvas view on the text field; subviews: \(subviews)")
        return nil
    }

    /// The capture-excluded layer, falling back to the field's last sublayer. For
    /// immediate nesting only; across layout passes hold [containerView(of:)].
    static func containerLayer(of field: UITextField) -> CALayer? {
        if let canvas = containerView(of: field) {
            log("secure canvas view: \(NSStringFromClass(type(of: canvas))), frame \(canvas.frame)")
            return canvas.layer
        }
        return field.layer.sublayers?.last
    }

    private static func canvasView(in view: UIView) -> UIView? {
        for subview in view.subviews {
            if NSStringFromClass(type(of: subview)).range(of: "canvas", options: .caseInsensitive) != nil {
                return subview
            }
            if let match = canvasView(in: subview) {
                return match
            }
        }
        return nil
    }

    /// Diagnostics: this relies on undocumented UIKit behaviour.
    static func log(_ message: String) {
        #if DEBUG
            NSLog("[ScreenshotShield] \(message)")
        #endif
    }
}
